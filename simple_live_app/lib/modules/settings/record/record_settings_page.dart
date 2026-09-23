import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/recorder/room_recorder.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

/// 录制设置
///
/// 目前只有一项：录制文件的保存目录。做这个页面主要是为了把录制放到别的盘，
/// 系统盘空间不够时能换地方。
class RecordSettingsPage extends StatefulWidget {
  const RecordSettingsPage({super.key});

  @override
  State<RecordSettingsPage> createState() => _RecordSettingsPageState();
}

class _RecordSettingsPageState extends State<RecordSettingsPage> {
  /// 当前生效的目录（用户设置过就是它，否则是平台默认目录）
  String _effectiveDir = "";
  bool _loading = true;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final dir = await RoomRecorderController.effectiveRecordDir();
    if (!mounted) {
      return;
    }
    setState(() {
      _effectiveDir = dir;
      _loading = false;
    });
  }

  bool get _isCustom =>
      AppSettingsController.instance.recordDir.value.trim().isNotEmpty;

  Future<void> _pick() async {
    if (_picking) {
      return;
    }
    setState(() => _picking = true);
    try {
      final result = await RoomRecorderController.pickRecordDir();
      if (!mounted || result == null) {
        // 用户取消
        return;
      }
      if (result.isNotEmpty) {
        SmartDialog.showToast(result);
        return;
      }
      await _reload();
      SmartDialog.showToast("已更改录制目录，下次录制生效");
    } finally {
      if (mounted) {
        setState(() => _picking = false);
      }
    }
  }

  Future<void> _reset() async {
    final ok = await Utils.showAlertDialog(
      "恢复为默认目录？\n\n默认目录：\n${await RoomRecorderController.platformDefaultRecordDir()}",
      title: "恢复默认",
    );
    if (!ok) {
      return;
    }
    RoomRecorderController.resetRecordDir();
    await _reload();
    SmartDialog.showToast("已恢复默认目录");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("录制设置"),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: AppStyle.edgeInsetsA12,
              children: [
                Padding(
                  padding: AppStyle.edgeInsetsA12.copyWith(top: 4),
                  child: Text(
                    "保存位置",
                    style: Get.textTheme.titleSmall,
                  ),
                ),
                SettingsCard(
                  child: Column(
                    children: [
                      SettingsAction(
                        leading: const Icon(Remix.folder_line),
                        title: "录制目录",
                        subtitle: _effectiveDir,
                        value: _isCustom ? "自定义" : "默认",
                        onTap: _picking ? null : _pick,
                      ),
                      if (_isCustom) ...[
                        AppStyle.divider,
                        SettingsAction(
                          leading: const Icon(Remix.restart_line),
                          title: "恢复默认目录",
                          onTap: _reset,
                        ),
                      ],
                      AppStyle.divider,
                      SettingsAction(
                        leading: const Icon(Remix.file_copy_line),
                        title: "复制当前目录",
                        onTap: () {
                          Utils.copyToClipboard(_effectiveDir);
                          SmartDialog.showToast("已复制");
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
                  child: Text(
                    "说明",
                    style: Get.textTheme.titleSmall,
                  ),
                ),
                Padding(
                  padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
                  child: const Text(
                    "• 录制文件按「平台_主播昵称_开录时间_序号.flv」命名，"
                    "网络没断就只有 001 一个文件。\n"
                    "• 更改目录后，从下一次录制开始生效；正在进行的录制不受影响。\n"
                    "• 选目录时会先做一次写入测试，不可写的目录不会被保存。\n"
                    "• 目录空间不足会导致录制中断，建议选剩余空间较大的盘。",
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
    );
  }
}
