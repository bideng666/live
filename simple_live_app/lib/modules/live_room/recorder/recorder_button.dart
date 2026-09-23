import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/recorder/room_recorder.dart';

/// 播放器顶栏的录制按钮
///
/// 点击开始/停止，长按查看录制详情（时长、体积、文件数、输出目录）。
class RecorderButton extends StatelessWidget {
  const RecorderButton({
    super.key,
    required this.recorder,
    this.iconSize = 24,
  });

  final RoomRecorderController recorder;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final recording = recorder.recording.value;
      return IconButton(
        tooltip: recording ? '停止录制' : '开始录制',
        onPressed: () async {
          if (recorder.busy.value) {
            return;
          }
          if (recording) {
            final confirmed = await Utils.showAlertDialog(
              '确定停止录制吗？\n已录制 ${RoomRecorderController.formatDuration(recorder.elapsed.value)}',
              title: '停止录制',
            );
            if (!confirmed) {
              return;
            }
            await recorder.stop();
          } else {
            await recorder.start();
          }
        },
        onLongPress: () => _showDetail(context),
        icon: Icon(
          recording ? Icons.stop_circle : Icons.fiber_manual_record,
          color: recording ? Colors.redAccent : Colors.white,
          size: iconSize,
        ),
      );
    });
  }

  void _showDetail(BuildContext context) {
    final dir = recorder.outputDir.value;
    Utils.showBottomSheet(
      title: '录制信息',
      child: ListView(
        shrinkWrap: true,
        children: [
          _row('状态', recorder.statusText.value.isEmpty
              ? (recorder.recording.value ? '录制中' : '未录制')
              : recorder.statusText.value),
          _row('时长', RoomRecorderController.formatDuration(recorder.elapsed.value)),
          _row('体积', RoomRecorderController.formatBytes(recorder.totalBytes.value)),
          _row('文件数', '${recorder.fileCount.value}'),
          _row('输出目录', dir.isEmpty ? '-' : dir),
          if (dir.isNotEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('复制输出目录'),
              onTap: () {
                Utils.copyToClipboard(dir);
                SmartDialog.showToast('已复制');
              },
            ),
        ],
      ),
    );
  }

  Widget _row(String title, String value) {
    return ListTile(
      dense: true,
      title: Text(title),
      subtitle: Text(value, style: const TextStyle(fontSize: 12)),
    );
  }
}