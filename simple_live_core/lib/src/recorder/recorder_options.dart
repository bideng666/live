import 'dart:io';

/// 录制参数
class RecorderOptions {
  /// 录制文件输出目录
  final String outputDir;

  /// 单个文件的目标时长
  ///
  /// 默认 [Duration.zero]：不按时间切分，一次连续连接写成一个文件。
  /// 只有在网络中断、重新拉流时才会另开一个新文件。
  /// 需要定时切分（比如方便上传）时再设成 10 分钟之类。
  final Duration segmentDuration;

  /// 连续失败多少次后放弃录制
  final int maxConsecutiveFailures;

  /// 每次重连前的等待时间
  final Duration reconnectDelay;

  /// 写盘刷新的间隔，用于意外退出时尽量留下可播放的文件
  final Duration flushInterval;

  const RecorderOptions({
    required this.outputDir,
    this.segmentDuration = Duration.zero,
    this.maxConsecutiveFailures = 5,
    this.reconnectDelay = const Duration(seconds: 3),
    this.flushInterval = const Duration(seconds: 1),
  });
}

/// 被录制的直播间信息，用于文件命名
class RecorderRoomInfo {
  final String siteId;
  final String roomId;

  /// 主播昵称
  final String userName;

  /// 直播间标题
  final String title;

  /// 直播间地址，录制时作为 Referer 用
  final String url;

  const RecorderRoomInfo({
    required this.siteId,
    required this.roomId,
    required this.userName,
    required this.title,
    this.url = '',
  });
}

/// 清洗文件名中的非法字符
String sanitizeFileName(String name) {
  var cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_')
      .replaceAll(RegExp(r'\s+'), '_');
  if (cleaned.length > 40) {
    cleaned = cleaned.substring(0, 40);
  }
  cleaned = cleaned.replaceAll(RegExp(r'^[._]+|[._]+$'), '');
  return cleaned.isEmpty ? 'unknown' : cleaned;
}

/// 生成 `yyyyMMdd_HHmmss` 形式的时间串
String formatFileTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}${two(time.month)}${two(time.day)}_'
      '${two(time.hour)}${two(time.minute)}${two(time.second)}';
}

/// 跨平台路径拼接，避免为一个函数引入 path 依赖
String joinPath(String dir, String name) {
  if (dir.isEmpty) {
    return name;
  }
  final last = dir[dir.length - 1];
  if (last == '/' || last == '\\') {
    return '$dir$name';
  }
  return '$dir${Platform.pathSeparator}$name';
}