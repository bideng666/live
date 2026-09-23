import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播间录制控制器
///
/// 只负责三件事：把宿主的取流能力包装成 [PlayUrlResolver]、维护 UI 状态、
/// 开关录制。真正的拉流写盘在 [LiveRecorder] 里。
class RoomRecorderController extends GetxController {
  RoomRecorderController({
    required this.roomInfoProvider,
    required this.playUrlResolver,
    this.liveChecker,
    Future<RecorderOptions> Function()? optionsBuilder,
  }) : _optionsBuilder = optionsBuilder ?? _defaultOptions;

  /// 提供主播昵称等信息，用于文件命名
  final Future<RecorderRoomInfo> Function() roomInfoProvider;

  /// 重新解析一路可用的播放地址（内部需完成 房间详情 → 清晰度 → 播放地址）
  final PlayUrlResolver playUrlResolver;

  /// 检查主播是否还在播，用于流断开后判断是重连还是收工
  final LiveStatusChecker? liveChecker;

  final Future<RecorderOptions> Function() _optionsBuilder;

  final recording = false.obs;
  final busy = false.obs;
  final statusText = ''.obs;
  final elapsed = Duration.zero.obs;
  final totalBytes = 0.obs;
  final fileCount = 0.obs;
  final outputDir = ''.obs;

  LiveRecorder? _recorder;
  StreamSubscription<RecorderStatus>? _statusSub;
  Timer? _ticker;

  bool get isRecording => recording.value;

  Future<void> toggle() async {
    if (recording.value) {
      await stop();
    } else {
      await start();
    }
  }

  Future<void> start() async {
    if (recording.value || busy.value) {
      return;
    }
    busy.value = true;
    try {
      final info = await roomInfoProvider();
      final options = await _optionsBuilder();
      final recorder = LiveRecorder(
        options: options,
        room: info,
        resolvePlayUrl: playUrlResolver,
        liveStatusChecker: liveChecker,
      );

      _statusSub = recorder.statusStream.listen(_onStatus);
      await recorder.start();
      _recorder = recorder;
      recording.value = true;
      outputDir.value = recorder.outputDir ?? '';
      _startTicker();
      SmartDialog.showToast('开始录制\n${recorder.outputDir ?? ''}');
    } catch (e, stack) {
      Log.logPrint(e);
      Log.logPrint(stack);
      SmartDialog.showToast('开始录制失败：$e');
      await _teardown();
    } finally {
      busy.value = false;
    }
  }

  Future<void> stop() async {
    if (!recording.value || busy.value) {
      return;
    }
    busy.value = true;
    try {
      await _recorder?.stop();
    } catch (e) {
      Log.logPrint(e);
    } finally {
      await _teardown();
      busy.value = false;
    }
  }

  @override
  void onClose() {
    _ticker?.cancel();
    _statusSub?.cancel();
    // 这里不 await，页面退出时尽快释放
    _recorder?.dispose();
    _recorder = null;
    super.onClose();
  }

  void _onStatus(RecorderStatus status) {
    statusText.value = status.message;
    totalBytes.value = status.totalBytes;
    fileCount.value = status.fileCount;
    if (status.state == RecorderState.failed ||
        status.state == RecorderState.stopped) {
      // 主播下播或连续失败，录制器自行收工，这里同步 UI
      if (recording.value) {
        SmartDialog.showToast(status.state == RecorderState.failed
            ? '录制失败：${status.message}'
            : status.message);
      }
      recording.value = false;
      _ticker?.cancel();
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final recorder = _recorder;
      if (recorder == null || !recorder.isRecording) {
        return;
      }
      elapsed.value = recorder.elapsed;
    });
  }

  Future<void> _teardown() async {
    _ticker?.cancel();
    _ticker = null;
    await _statusSub?.cancel();
    _statusSub = null;
    final recorder = _recorder;
    _recorder = null;
    recording.value = false;
    if (recorder != null) {
      // dispose 内部会 stop 并关闭状态流，停止录制时调用是安全的
      await recorder.dispose();
    }
  }

  /// 默认录制参数。不按时间切分，输出目录取 [effectiveRecordDir]
  static Future<RecorderOptions> _defaultOptions() async {
    return RecorderOptions(
      outputDir: await effectiveRecordDir(),
    );
  }

  /// 实际使用的录制目录：用户设置过就用它，否则用平台默认目录
  static Future<String> effectiveRecordDir() async {
    final custom = AppSettingsController.instance.recordDir.value;
    if (custom.trim().isNotEmpty) {
      return custom.trim();
    }
    return platformDefaultRecordDir();
  }

  /// 平台默认录制目录
  ///
  /// * Android：`Android/data/<包名>/files/SimpleLiveRecords`
  ///   （应用私有外部目录，无需存储权限，可用数据线在电脑上取走）
  /// * iOS / 桌面：应用文档目录下的 `SimpleLiveRecords`
  static Future<String> platformDefaultRecordDir() async {
    if (Platform.isAndroid) {
      try {
        final dir = await getExternalStorageDirectory();
        if (dir != null) {
          return joinPath(dir.path, 'SimpleLiveRecords');
        }
      } catch (_) {
        // 部分设备取不到外部目录，退回文档目录
      }
    }
    final dir = await getApplicationDocumentsDirectory();
    return joinPath(dir.path, 'SimpleLiveRecords');
  }

  /// 让用户选一个目录作为录制输出目录。
  ///
  /// 返回 null 表示用户取消；返回空字符串表示设置成功；
  /// 返回非空字符串是错误说明（此时不会保存设置）。
  static Future<String?> pickRecordDir() async {
    String? picked;
    try {
      picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择录制文件保存目录',
      );
    } catch (e) {
      return '打开目录选择器失败：$e';
    }
    if (picked == null || picked.trim().isEmpty) {
      return null;
    }
    final error = await checkDirWritable(picked);
    if (error != null) {
      return error;
    }
    AppSettingsController.instance.setRecordDir(picked);
    return '';
  }

  /// 恢复默认目录
  static void resetRecordDir() {
    AppSettingsController.instance.setRecordDir("");
  }

  /// 检查目录是否可写。
  ///
  /// 录到一半才发现目录写不进去是最糟的情况，所以选目录时先探一次：
  /// 建目录 + 写一个小文件 + 删掉。
  static Future<String?> checkDirWritable(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File(joinPath(path, '.simple_live_write_test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return null;
    } catch (e) {
      return '这个目录不可写，换一个试试：\n$e';
    }
  }

  /// 把字节数格式化成人类可读的字符串
  static String formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 把时长格式化成 `HH:MM:SS`
  static String formatDuration(Duration duration) {
    String two(int value) => value.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;
    return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  }
}