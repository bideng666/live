import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../common/core_log.dart';
import '../model/live_play_url.dart';
import 'recorder_options.dart';

/// 解析一次可用的播放地址。
///
/// 每次重连都会重新调用，用来绕过抖音 CDN 地址上的 `expire` 签名过期问题：
/// 内部应当完成 `getRoomDetail` → `getPlayQualites` → `getPlayUrls` 三步。
typedef PlayUrlResolver = Future<LivePlayUrl> Function();

/// 主播是否还在直播；返回 false 时录制器会停止
typedef LiveStatusChecker = Future<bool> Function();

enum RecorderState {
  idle,
  preparing,

  /// 正在写盘
  recording,

  /// 流断开，等待重连
  reconnecting,

  /// 已停止（用户停止，或主播下播）
  stopped,

  /// 连续失败后放弃
  failed,
}

/// 录制器对外暴露的状态快照
class RecorderStatus {
  const RecorderStatus({
    required this.state,
    required this.message,
    required this.elapsed,
    required this.totalBytes,
    required this.fileCount,
    this.currentFile,
    this.outputDir,
  });

  final RecorderState state;
  final String message;

  /// 本次录制已进行的时长
  final Duration elapsed;

  /// 已写入的总字节数
  final int totalBytes;

  /// 已写出的文件个数（正常情况下是 1，断流重连后才会变多）
  final int fileCount;

  /// 当前正在写的文件
  final String? currentFile;

  /// 输出目录
  final String? outputDir;

  bool get isActive =>
      state == RecorderState.preparing ||
      state == RecorderState.recording ||
      state == RecorderState.reconnecting;
}

enum _Outcome {
  /// 到达分片时长，立刻开下一个文件
  rotate,

  /// 流自然结束，需要重连
  ended,

  /// 用户停止
  aborted,
}

/// 直播录制器：把直播的画面和音频录到本地文件。
///
/// 与播放器解耦——自己向 CDN 拉一路流写盘，不依赖播放器的解码状态，
/// 因此可以边看边录，也可以不播放只录制。
///
/// 录制能长时间跑下去的关键在两件事，也是这个类存在的主要理由：
/// 1. **地址会过期**：抖音的 CDN 地址带签名，几十分钟就失效。所以每次重连都
///    通过 [PlayUrlResolver] 重新走一遍取流流程，拿一份新签名的地址。
/// 2. **流会断**：网络抖动、CDN 切换都会让连接断开。断开后自动重连续录，
///    而不是整场结束。
///
/// 写出来的是 CDN 原始字节（抖音是 FLV），没有转码，画质和直播一致。
class LiveRecorder {
  LiveRecorder({
    required this.options,
    required this.room,
    required this.resolvePlayUrl,
    this.liveStatusChecker,
  });

  final RecorderOptions options;
  final RecorderRoomInfo room;
  final PlayUrlResolver resolvePlayUrl;
  final LiveStatusChecker? liveStatusChecker;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      // 直播流是长连接，必须关掉接收超时，否则会在空闲时被误杀
      receiveTimeout: Duration.zero,
      sendTimeout: Duration.zero,
      validateStatus: (code) => code != null && code >= 200 && code < 300,
    ),
  );

  final StreamController<RecorderStatus> _statusController =
      StreamController<RecorderStatus>.broadcast();
  final List<String> _files = <String>[];

  DateTime? _startedAt;
  String _baseName = '';
  Directory? _outputDir;
  CancelToken? _cancelToken;
  Future<void>? _loopFuture;

  bool _running = false;
  int _fileIndex = 0;
  int _totalBytes = 0;
  int _failures = 0;

  /// 上一个文件的墙钟时长，用于识别异常短的轮转
  int _lastFileWallMs = 0;

  RecorderState _state = RecorderState.idle;
  RecorderStatus? _status;

  RecorderStatus? get status => _status;
  Stream<RecorderStatus> get statusStream => _statusController.stream;

  /// 已写出的文件完整路径
  List<String> get files => List.unmodifiable(_files);

  /// 输出目录
  String? get outputDir => _outputDir?.path;

  bool get isRecording => _running;

  /// 已录制时长
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  /// 开始录制。重复调用会被忽略。
  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    _failures = 0;
    _fileIndex = 0;
    _totalBytes = 0;
    _files.clear();
    _startedAt = DateTime.now();
    _baseName = '${room.siteId}_${sanitizeFileName(room.userName)}'
        '_${formatFileTime(_startedAt!)}';
    _outputDir = Directory(options.outputDir);
    await _outputDir!.create(recursive: true);

    _emit(RecorderState.preparing, '准备录制');
    _loopFuture = _loop();
  }

  /// 停止录制
  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    _cancelToken?.cancel('stop');
    try {
      await _loopFuture;
    } catch (_) {}
    _loopFuture = null;
  }

  Future<void> dispose() async {
    await stop();
    await _statusController.close();
    _dio.close(force: true);
  }

  // ---------------------------------------------------------------- 内部实现

  Future<void> _loop() async {
    while (_running) {
      String? url;
      Map<String, String>? headers;

      try {
        // 每次都重新取地址：这是长时间录制不会被签名过期打断的原因
        final playUrl = await resolvePlayUrl();
        url = _pickUrl(playUrl.urls);
        headers = playUrl.headers;
        if (url == null) {
          throw Exception('没有可用的播放地址');
        }
      } catch (e) {
        CoreLog.error('取流地址解析失败: $e');
      }

      if (url == null) {
        _failures++;
        if (!await _waitBeforeRetry('解析播放地址失败')) {
          break;
        }
        continue;
      }

      var outcome = _Outcome.ended;
      try {
        outcome = await _recordOnce(url, headers);
        _failures = 0;
      } catch (e) {
        CoreLog.error('录流中断: $e');
        _failures++;
        if (!await _waitBeforeRetry('录流中断：${_brief(e)}')) {
          break;
        }
        continue;
      }

      if (!_running || outcome == _Outcome.aborted) {
        break;
      }
      if (outcome == _Outcome.rotate) {
        // 定时切分不算失败，不等待，直接开下一个文件
        if (_lastFileWallMs < 1000) {
          await Future.delayed(const Duration(seconds: 1));
        }
        continue;
      }

      // 流自然结束：先看主播是不是下播了
      if (liveStatusChecker != null) {
        bool live = false;
        try {
          live = await liveStatusChecker!();
        } catch (_) {}
        if (!live) {
          _emit(RecorderState.stopped, '直播已结束，录制停止');
          break;
        }
      }
      _failures++;
      if (!await _waitBeforeRetry('流已结束')) {
        break;
      }
    }

    _emit(
      _state == RecorderState.failed
          ? RecorderState.failed
          : RecorderState.stopped,
      _state == RecorderState.failed ? '录制失败' : '录制已停止',
    );
  }

  /// 失败退避；返回 false 表示应当停止录制
  Future<bool> _waitBeforeRetry(String reason) async {
    if (!_running) {
      return false;
    }
    if (_failures > options.maxConsecutiveFailures) {
      _emit(RecorderState.failed, '连续 $_failures 次取流失败，停止录制');
      _running = false;
      return false;
    }
    _emit(RecorderState.reconnecting, '$reason，第 $_failures 次重试');
    await Future.delayed(options.reconnectDelay);
    return _running;
  }

  /// 拉一段流写成一个文件
  Future<_Outcome> _recordOnce(String url, Map<String, String>? headers) async {
    final isHls = _looksLikeHls(url);
    final index = ++_fileIndex;
    final fileName = '${_baseName}_${index.toString().padLeft(3, '0')}'
        '.${isHls ? 'ts' : 'flv'}';
    final path = joinPath(_outputDir!.path, fileName);

    final cancelToken = CancelToken();
    _cancelToken = cancelToken;

    var bytes = 0;
    var hlsDurationMs = 0;
    var outcome = _Outcome.ended;
    final startedAt = DateTime.now();
    final sink = File(path).openWrite();
    Object? failure;

    try {
      if (isHls) {
        outcome = await _pumpHls(
          Uri.parse(url),
          headers,
          sink,
          cancelToken,
          onBytes: (n) {
            bytes += n;
            _totalBytes += n;
          },
          onDuration: (ms) => hlsDurationMs = ms,
        );
      } else {
        outcome = await _pumpFlv(
          url,
          headers,
          sink,
          cancelToken,
          onBytes: (n) {
            bytes += n;
            _totalBytes += n;
          },
        );
      }
    } catch (e) {
      failure = e;
    } finally {
      _cancelToken = null;
      if (!_running) {
        outcome = _Outcome.aborted;
      }
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}

      if (bytes > 0) {
        _files.add(path);
        _lastFileWallMs = DateTime.now().difference(startedAt).inMilliseconds;
      } else {
        // 空文件（地址被 CDN 拒绝等）直接删掉，不留下 0 字节垃圾
        try {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
        _fileIndex--;
      }
    }

    if (failure != null) {
      throw failure;
    }
    return outcome;
  }

  /// FLV 直录：拿到的是完整 FLV 字节流，原样落盘
  Future<_Outcome> _pumpFlv(
    String url,
    Map<String, String>? headers,
    IOSink sink,
    CancelToken cancelToken, {
    required void Function(int) onBytes,
  }) async {
    _emit(RecorderState.recording, '录制中');

    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {..._defaultHeaders(), ...?headers},
      ),
      cancelToken: cancelToken,
    );

    final stream = response.data!.stream;
    var lastFlush = DateTime.now();
    var checkedMagic = false;
    var segmentMs = 0;
    final segmentStart = DateTime.now();

    await for (final chunk in stream) {
      if (!_running) {
        return _Outcome.aborted;
      }

      // 头几个字节必须是 FLV 魔数，否则说明拿到的不是流（多半是风控页或错误响应），
      // 早点报错，免得录下一个几十字节的垃圾文件
      if (!checkedMagic) {
        checkedMagic = true;
        if (chunk.length >= 3 &&
            !(chunk[0] == 0x46 && chunk[1] == 0x4C && chunk[2] == 0x56)) {
          throw Exception('返回内容不是 FLV（地址可能被防盗链拦截）');
        }
      }

      sink.add(chunk);
      onBytes(chunk.length);

      if (DateTime.now().difference(lastFlush) >= options.flushInterval) {
        await sink.flush();
        lastFlush = DateTime.now();
        _emit(RecorderState.recording, '录制中');
      }

      // 定时切分（默认关闭）。按墙钟计时即可，不需要解析容器时间戳
      if (options.segmentDuration > Duration.zero) {
        segmentMs = DateTime.now().difference(segmentStart).inMilliseconds;
        if (segmentMs >= options.segmentDuration.inMilliseconds) {
          cancelToken.cancel('rotate');
          return _Outcome.rotate;
        }
      }
    }
    return _Outcome.ended;
  }

  /// HLS 兜底：把 media playlist 的分片顺序追加进同一个 .ts 文件
  ///
  /// 抖音的 FLV 地址通常都能用，这是万一 FLV 被拒时的备选路径。
  /// MPEG-TS 允许直接拼接，所以不需要像 FLV 那样靠重连来保证可播性。
  Future<_Outcome> _pumpHls(
    Uri playlistUri,
    Map<String, String>? headers,
    IOSink sink,
    CancelToken cancelToken, {
    required void Function(int) onBytes,
    required void Function(int) onDuration,
  }) async {
    _emit(RecorderState.recording, '录制中（HLS）');

    var target = playlistUri;
    var text = await _fetchText(target, headers, cancelToken);
    if (text.contains('#EXT-X-STREAM-INF')) {
      target = _firstVariant(text, target) ?? target;
      text = await _fetchText(target, headers, cancelToken);
    }

    final seen = <String>{};
    var segmentMs = 0;
    var idleRounds = 0;
    final startedAt = DateTime.now();

    while (_running) {
      final segments = _parseMediaPlaylist(text, target);
      var downloaded = 0;

      for (final segment in segments) {
        final key = segment.uri.toString();
        if (seen.contains(key)) {
          continue;
        }
        if (!_running) {
          return _Outcome.aborted;
        }
        seen.add(key);
        downloaded++;

        final data = await _dio.get<List<int>>(
          key,
          options: Options(
            responseType: ResponseType.bytes,
            headers: {..._defaultHeaders(), ...?headers},
          ),
          cancelToken: cancelToken,
        );
        final segmentBytes = data.data;
        if (segmentBytes == null || segmentBytes.isEmpty) {
          continue;
        }
        sink.add(segmentBytes);
        onBytes(segmentBytes.length);
        segmentMs += (segment.durationSeconds * 1000).round();
        onDuration(segmentMs);
        _emit(RecorderState.recording, '录制中（HLS）');

        if (options.segmentDuration > Duration.zero &&
            DateTime.now().difference(startedAt).inMilliseconds >=
                options.segmentDuration.inMilliseconds) {
          return _Outcome.rotate;
        }
      }

      if (downloaded > 0) {
        idleRounds = 0;
      } else {
        idleRounds++;
        if (idleRounds > 30) {
          // 一分钟没等到新分片，认为流已结束
          return _Outcome.ended;
        }
      }

      await Future.delayed(const Duration(seconds: 2));
      if (!_running) {
        return _Outcome.aborted;
      }
      text = await _fetchText(target, headers, cancelToken);
      if (text.contains('#EXT-X-ENDLIST')) {
        return _Outcome.ended;
      }
    }
    return _Outcome.aborted;
  }

  Future<String> _fetchText(
    Uri uri,
    Map<String, String>? headers,
    CancelToken cancelToken,
  ) async {
    final response = await _dio.get<String>(
      uri.toString(),
      options: Options(
        responseType: ResponseType.plain,
        headers: {..._defaultHeaders(), ...?headers},
      ),
      cancelToken: cancelToken,
    );
    return response.data ?? '';
  }

  Map<String, String> _defaultHeaders() => {
        'User-Agent': _userAgent,
        'Accept': '*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        // 抖音 CDN 的部分节点会校验来源
        if (room.url.isNotEmpty) 'Referer': room.url,
      };

  String? _pickUrl(List<String> urls) {
    if (urls.isEmpty) {
      return null;
    }
    // 优先 FLV：抖音的画质列表里 flv 在 hls 前面，且 FLV 是完整字节流更好处理
    return urls.firstWhere((u) => !_looksLikeHls(u), orElse: () => urls.first);
  }

  bool _looksLikeHls(String url) => url.contains('.m3u8');

  void _emit(RecorderState state, String message) {
    _state = state;
    _status = RecorderStatus(
      state: state,
      message: message,
      elapsed: elapsed,
      totalBytes: _totalBytes,
      fileCount: _files.length,
      currentFile: _files.isEmpty ? null : _files.last,
      outputDir: _outputDir?.path,
    );
    if (!_statusController.isClosed) {
      _statusController.add(_status!);
    }
  }

  static String _brief(Object error) {
    final text = error.toString();
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }

  /// 通用桌面浏览器 UA
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/116.0.5845.97 Safari/537.36';
}

class _HlsSegment {
  const _HlsSegment(this.uri, this.durationSeconds);
  final Uri uri;
  final double durationSeconds;
}

/// 解析 media playlist 中的分片
List<_HlsSegment> _parseMediaPlaylist(String text, Uri base) {
  final result = <_HlsSegment>[];
  var duration = 0.0;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith('#EXTINF:')) {
      duration = double.tryParse(line.substring(8).split(',').first) ?? 0;
    } else if (!line.startsWith('#')) {
      result.add(_HlsSegment(base.resolve(line), duration));
      duration = 0;
    }
  }
  return result;
}

/// 从 master playlist 中取第一个码率的地址
Uri? _firstVariant(String text, Uri base) {
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) {
      continue;
    }
    for (var j = i + 1; j < lines.length; j++) {
      final line = lines[j].trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      return base.resolve(line);
    }
  }
  return null;
}