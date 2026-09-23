# dart_simple_live 抖音直播录制

针对 [`lostars/dart_simple_live`](https://github.com/lostars/dart_simple_live) tag **v1.11.4**（commit `6b86e80`）的抖音取流实现分析，以及在其基础上**把直播画面和音频录到本地文件**的改造。

只做录制：不切片、不转码、不录弹幕。

## 结论速览

- **取流链路**：`getRoomDetail`（带 `a_bogus` 签名的 webcast 接口，或抓 HTML 兜底）→ `getPlayQualites`（解析 `live_core_sdk_data.pull_data`）→ `getPlayUrls`（原样返回，**不重新签名**）→ `Media(url)` 交给 media_kit/mpv 播放。
- **录制最大的障碍**：CDN 地址带过期签名，而原项目的断流处理 `player.jump()` 只会重放**同一条过期地址**（`live_room_controller.dart:445`）。挂机必断。
- **改造方案**：加一个与播放器解耦的独立录制器（`LiveRecorder`），每次重连都重跑一遍取流三件套拿新签名；一次连续连接写一个文件，断流才新开。
- **产物**：CDN 原始字节（FLV），无转码，画质和直播一致。

## 目录结构

```
docs/
  01-抖音取流链路分析.md      取流实现逐层拆解 + 可复用逻辑 + 三个坑
  02-录制改造方案.md          方案、4 个关键设计决策、集成步骤、限制
  03-使用教程.md              ★ 从零到录下第一段直播，含打包/运行/录制全流程
PACKAGING-WINDOWS.md          Windows 打包说明（本机打包 + GitHub 云端打包）
.gitattributes                行尾固定策略（.ps1/.cmd 强制 CRLF，补丁保持 LF）
.github/workflows/
  build-windows.yml           云端打包 workflow：kit 自检 → 下载上游源码 → 叠加改造 → 编译 → 出 zip
packaging/
  build_windows.cmd           双击即可打包（会自动修 .ps1 的编码）
  build_windows.ps1           打包主脚本
simple_live_core/lib/
  simple_live_core.dart       ← 改：加一行 export
  src/recorder/               ← 新增：录制器（纯 Dart，无新依赖）
    recorder_options.dart       录制参数、房间信息、路径/文件名工具
    live_recorder.dart          录制主循环：取地址、拉流、写盘、重连、HLS 兜底
    recorder.dart               汇总 export
simple_live_app/lib/
  modules/live_room/live_room_controller.dart   ← 改：接入录制器（3 处）
  modules/live_room/player/player_controls.dart ← 改：加录制按钮（1 行）
  modules/live_room/recorder/                  ← 新增：app 层
    room_recorder.dart          录制控制器：UI 状态、开关、默认输出目录
    recorder_button.dart        顶栏按钮 + 详情面板
patches/                     三个文件的 unified diff，可直接 git apply
_ref/dart_simple_live/       v1.11.4 原始文件（对照用）
```

## 快速开始

**完全没用过？直接看 [docs/03-使用教程.md](E:\ai\veido\docs\03-使用教程.md)**，那是从零开始的逐步教程。

下面是速览。

### 方式一：GitHub 云端打包（推荐，本机什么都不用装）

把整个 kit 推到一个 GitHub 仓库（私有也行），在 Actions 里跑 `build-windows`，跑完从 Artifacts 下载 zip。

它不需要仓库包含上游的 500 多个文件——只在构建时下载上游 v1.11.4 源码、叠加改造、编译、压包。

细节见 [PACKAGING-WINDOWS.md](E:\ai\veido\PACKAGING-WINDOWS.md) 第三节。

### 方式二：本机一键打包

在装了 Flutter 的 Windows 机器上双击 `packaging\build_windows.cmd`，产物在 `dist\SimpleLive-recorder-<版本>-windows.zip`。

### 方式三：手动接入已有工程

```bash
# 新增文件
cp -r simple_live_core/lib/src/recorder  <项目>/simple_live_core/lib/src/
cp -r simple_live_app/lib/modules/live_room/recorder  <项目>/simple_live_app/lib/modules/live_room/

# 修改已有文件
cd <项目> && git apply <本目录>/patches/*.patch
```

不需要改任何 `pubspec.yaml`：core 层只用已有的 dio，app 层只用已有的 path_provider。

```bash
cd simple_live_app && flutter pub get && flutter run -d windows
```

进任意抖音直播间 → 顶栏出现红色圆点按钮 → 点击开始录制 → 长按按钮看录制详情。

## 用起来

1. 进直播间，点顶栏的**红色圆点**开始录制
2. 挂着就行，可以边看边录，也可以切到别的房间（录制独立于播放器）
3. 长按按钮看状态：时长、体积、文件数、输出目录
4. 再点一次停止；离开直播间页面也会自动停止

文件在 `%USERPROFILE%\Documents\SimpleLiveRecords\`：

```
douyin_主播昵称_20260923_024000_001.flv     ← 一次连续连接的录像
douyin_主播昵称_20260923_024000_002.flv     ← 断流重连后新开的文件
```

检查录得对不对：

```bat
ffprobe -v error -show_entries format=duration,size -show_streams "文件.flv"
```

应该看到 `h264` + `aac`，时长和你录的时间接近。

## 验证状态（如实说明）

| 部分 | 状态 |
| --- | --- |
| Windows 打包脚本 | **已验证到"只差编译器"**：PS 官方 Parser 语法检查通过；实测下载 v1.11.4 源码包、解压、叠加改造、落地断言全绿；与原始树全量 diff 确认**3 改 / 2 新增 / 0 删除**，无误伤 |
| GitHub workflow | **YAML 结构与 6 个内嵌 PowerShell 步骤逐个过了语法检查**；退出码传递逻辑用三种场景实证过；kit 完整性自检步骤在完整/残缺两种 kit 下实测正确（退出码 0 / 1） |
| 文件可提交性 | **已实测**：模拟 `git add -A`，38 个文件全部会提交，5 个 recorder 文件一个不少（此前 `.gitignore` 的 `src/` 规则会漏掉 3 个，已修） |
| BOM 能否经 git 存活 | **已实测**：提交后从 git 存储层读回，`.ps1` 的 UTF-8 BOM 完好 |
| 依赖在 Windows 上可行 | **有上游佐证**：上游 CI 有完整的 Windows job 并产出 `-windows.zip`/`-windows.msix`；`dart_quickjs` 是 FFI + Hooks，README 明确支持 Flutter Windows，且上游 CI 未用任何 native-assets 实验开关 |
| Dart 代码 | **已静态检查**（8 个文件括号/字符串平衡）。**编译未验证**：本机无 Dart/Flutter SDK |
| `flutter build windows` | **未验证**：本机无 Flutter / VS |
| 真实抖音直播间取流+录制 | **未验证**：本机没有能访问抖音的网络环境 |

打包和代码结构是可信的；录制本身需要你在真机上跑一次验证。

## 使用前请注意

抖音用户协议通常禁止未经授权的抓取与二次传播；录制他人直播并分发可能侵犯著作权与肖像权。请仅在获得主播授权或个人学习研究等合法范围内使用，不要用于批量搬运。
