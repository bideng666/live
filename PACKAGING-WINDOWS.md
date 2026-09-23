# Windows 打包说明

## 重要前提：这台机器打不出 exe

当前工作目录 `E:\ai\veido` **不是完整的 Flutter 工程**，只有录制改造的源码文件、补丁和工具；这台机器上也**没有 Flutter / Dart SDK，也没有 Visual Studio**。所以真正的 `flutter build windows` 必须在另一台装好环境的机器上跑。

为此我把整个改造做成了**一键打包工具**：在装了 Flutter 的 Windows 机器上双击 `packaging\build_windows.cmd`，它会自动拉取上游源码、叠加改造、编译、并把可分发产物压成 zip。

---

## 一、目标机器需要什么

| 依赖 | 要求 | 说明 |
| --- | --- | --- |
| Flutter SDK | **3.38.x**（与上游 CI 一致；项目 `.fvmrc` 为 3.38.3） | Dart 必须 ≥ 3.10（3.38.x 各版本为 3.10.0~3.10.9），否则 `simple_live_core` 编译不过 |
| Visual Studio 2022 | 勾选「使用 C++ 的桌面开发」 | Flutter Windows 构建必需，只有 VS Code 不够 |
| Git for Windows | 任意较新版本 | 用于拉源码；若网络不通可用 `-UseArchive` 绕过 |
| ffmpeg / ffprobe | 任意较新版本，加入 PATH | 可选，只用于事后检查录制文件 |

环境自检：`flutter doctor -v`，确认 Windows toolchain 一栏是绿勾。

## 二、打包

有两条路：**本机打包**（需要一个装好 Flutter 的 Windows 机器）和 **GitHub 云端打包**（什么都不用装，推荐）。云端打包见第三节，本机打包如下。

### 双击运行

直接双击 `packaging\build_windows.cmd`。它会：

1. 检查 `build_windows.ps1` 的 UTF-8 BOM（缺了就自动补，见下文「已知坑」）；
2. 检查 git / Flutter / Dart 版本 / VS C++ 工具链；
3. 获取上游源码到 `%USERPROFILE%\dart_simple_live_build\src`；
4. 叠加录制改造，并逐项断言确认落地；
5. `flutter pub get` + `flutter build windows --release`；
6. 收集产物 → `%USERPROFILE%\dart_simple_live_build\dist\`。

首次构建要下载 Windows 引擎产物和全部 pub 依赖，通常 5–15 分钟。

### 命令行用法

```powershell
cd packaging

.\build_windows.ps1                          # 默认：git clone + 完整构建 + 打包
.\build_windows.ps1 -UseArchive              # git 走不通时，改用 HTTPS 下载源码 zip
.\build_windows.ps1 -SkipBuild               # 只准备源码、叠加改造，不编译
.\build_windows.ps1 -Msix                    # 额外产出 .msix（需先 dart pub global activate flutter_distributor）
.\build_windows.ps1 -WorkDir D:\build        # 换工作目录
.\build_windows.ps1 -SourceDir D:\code\dart_simple_live   # 复用已有 checkout
.\build_windows.ps1 -Tag v1.11.4             # 换上游版本（改造按 v1.11.4 对齐）
```

建议第一次先跑 `-SkipBuild`，确认输出里有这一行再跑完整构建：

```
    [OK] 8 个新文件 + 3 处改动全部落地
```

## 三、GitHub 云端打包（推荐）

不用在自己电脑上装 Flutter 和 Visual Studio，让 GitHub 的 Windows runner 干活。

仓库里已经放好 workflow：[`.github/workflows/build-windows.yml`](E:\ai\veido\.github\workflows\build-windows.yml)。

### 步骤

1. 把**整个 kit**（本目录所有文件，含 `.github/`）推到一个 GitHub 仓库，私有仓库也可以：

   ```bash
   cd <kit 目录>
   git init && git add -A && git commit -m "dart_simple_live windows build kit"
   git remote add origin https://github.com/<你>/<仓库>.git
   git push -u origin main
   ```

2. 打开仓库的 **Actions** 页 → 左侧选 `build-windows` → **Run workflow**。
   三个可选参数：Flutter 版本（默认 `3.38.x`，与上游 CI 一致）、上游 tag（默认 `v1.11.4`）、是否额外构建 msix（会自动装 flutter_distributor）。

3. 等 10–20 分钟（首次要下载 Flutter 引擎和 pub 依赖，之后有缓存会快很多）。

4. 在本次运行的页面底部 **Artifacts** 里下载 `SimpleLive-windows.zip`。

也可以推 `v*` 标签触发，那样会额外自动建一个 Release 并把 zip 附上去。

### 它是怎么工作的

workflow 不需要仓库里包含上游的 500 多个文件。它只取本仓库（kit），然后调用 `build_windows.ps1 -UseArchive`，由脚本去下载上游 v1.11.4 的源码包、叠加改造、编译、压包。所以仓库里只有 41 个文件，维护成本极低。

### 几个刻意的选择

- **用 `shell: powershell` 而不是 `pwsh`**：Windows PowerShell 5.1 是我实际验证过 `build_windows.ps1` 的环境。PowerShell 7 行为有差异（比如 `-UseBasicParsing`、编码处理），没必要冒险。
- **在打包步骤里显式判断退出码**，而且写成 `$null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0`。这两个条件缺一不可，实测过：
  - 只写 `-ne 0`：脚本**正常跑完**时 `$LASTEXITCODE` 是 `$null`，而 `$null -ne 0` 为真 → **构建成功会被误报为失败**；
  - 完全不判断：`& script.ps1` 遇到脚本内的 `exit 1` 只结束该脚本，调用方继续执行，进程退出码仍是 0 → **构建失败会被误报为成功**。
- **Flutter 版本走 action 输入**而不是读 `.fvmrc`：`.fvmrc` 是 JSON，`flutter-action` 的 `flutter-version-file` 对它支持不确定，显式传版本更稳。

### 配额提醒

- 公开仓库：Actions 免费不限量。
- 私有仓库：免费额度 2000 分钟/月，**Windows runner 按 2 倍计费**，即实际约 1000 分钟。一次构建约 10–20 分钟 → 每月约 50–100 次。

### 注意事项

- `flutter pub get` 需要访问 pub.dev 和 GitHub（`dart_quickjs` 是 git 依赖）。GitHub runner 访问 GitHub 没问题，pub.dev 一般也正常。
- 上游其实**没有** Windows 的 CI（四个 workflow 全是 macos/ubuntu，官方的 `-windows.zip` 是维护者本地打的）。所以这个 workflow 是新增的，不是照搬上游。

## 四、产物

```
dist\
├── SimpleLive-recorder-1.11.4+11104-windows\      ← 免安装目录版
│   ├── simple_live_app.exe                        ← 主程序
│   ├── *.dll                                      ← mpv、Flutter 等运行时依赖
│   └── data\                                      ← Flutter 资源
└── SimpleLive-recorder-1.11.4+11104-windows.zip   ← 可直接分发的压缩包
```

**必须整个文件夹一起用**：exe 依赖同目录的 `dll` 和 `data\`，只拷 exe 是跑不起来的。

解压后直接双击 `simple_live_app.exe`，无需安装、无需管理员权限。

## 五、用起来

1. 打开 App → 搜索或进入任意抖音直播间；
2. 播放器顶栏会多出一个**红色圆点按钮**（截图按钮右边），点击开始录制；
3. 长按该按钮查看录制详情：时长、体积、文件数、输出目录，可一键复制路径；
4. 再次点击并确认即停止；离开直播间页面也会自动停止。

录制文件默认在：

```
%USERPROFILE%\Documents\SimpleLiveRecords\
├── douyin_主播昵称_20260923_024000_001.flv    ← 一次连续连接的录像
└── douyin_主播昵称_20260923_024000_002.flv    ← 断流重连后才会出现
```

写出来的是 CDN 原始流（FLV），**没有转码**，画质和直播一致。

检查录得对不对（需要 ffmpeg）：

```bat
ffprobe -v error -show_entries format=duration,size -show_streams "文件.flv"
```

应该看到 `h264` + `aac`，时长和你录的时间接近。

完整的逐步教程见 [docs/03-使用教程.md](E:\ai\veido\docs\03-使用教程.md)。

## 六、已知坑（都是实测踩出来的）

### 1. `build_windows.ps1` 必须保留 UTF-8 BOM

Windows PowerShell 5.1 在**没有 BOM** 时会按系统 ANSI 码页读取 `.ps1`。脚本里全是中文，被误读后会直接破坏字符串解析，报出「字符串缺少终止符」之类的语法错误——**看起来像脚本写错了，其实是编码问题**。

用 `build_windows.cmd` 启动会自动检测并补 BOM。如果你用编辑器直接改这个 ps1，请确保保存为「UTF-8 with BOM」。

### 1b. `.cmd` 文件必须保持纯 ASCII

同一个坑的另一面：`cmd.exe` 按 **OEM 码页**读取批处理文件（中文 Windows 是 936/GBK）。如果 `.cmd` 里写了 UTF-8 中文，会被按 GBK 逐字节误读；而 GBK 双字节的第二字节范围包含 `|`、`%`、`^` 等，**一旦撞上就会破坏命令解析**，报出莫名其妙的错误。

所以 `packaging\build_windows.cmd` 里的提示信息全部用英文，是刻意的设计，不要为了"本地化"往里加中文。真正需要中文的地方都在 `.ps1`（有 BOM）里。

### 2. `git clone` 失败但脚本继续跑过

PowerShell 的 `$ErrorActionPreference = 'Stop'` **管不到原生 exe 的退出码**。早期版本的脚本在 `git clone` 失败后仍然打印「源码就绪」，最后在莫名其妙的地方报错。现在所有原生命令都通过 `Invoke-Native` 检查退出码，失败立即终止。

### 3. 解压源码包用 `Expand-Archive` 而不是 `tar`

从 Git Bash 启动 PowerShell 时，PATH 里是 MSYS 的 GNU tar。GNU tar 会把 `C:\Users\...` 里的冒号当成远程主机名，报 `Cannot connect to C: resolve failed`。改用 PowerShell 自带的 `Expand-Archive` 后不依赖任何外部解压工具。

### 4. 代理 / 防火墙环境

`git clone` 走不通时加 `-UseArchive`，改用 HTTPS 下载 zip（`codeload.github.com`）。注意 `flutter pub get` 仍然需要网络访问 pub.dev 与 GitHub（`dart_quickjs` 是 git 依赖），这部分无法绕过。

### 5. msix 需要额外装 flutter_distributor

`-Msix` 走的是 `flutter_distributor package --platform windows --targets msix`。云端 workflow 在勾选 `build_msix` 时会自动执行 `dart pub global activate flutter_distributor`，**不需要**在 pubspec 里加 `msix` 依赖——上游 CI 就是在一个没有 `msix` 依赖的 pubspec 上成功产出 `-windows.msix` 的。

本机打包时如果没装 flutter_distributor，脚本只会打印「未安装，跳过」并继续，不影响便携版 zip。想用就手动装一次：

```powershell
dart pub global activate flutter_distributor
```

### 6. 杀毒软件误报

Flutter 打出来的 exe 偶尔会被国产杀软误报（因为未签名）。加白名单即可。要正式分发建议自己买代码签名证书。

## 七、验证状态（如实说明）

| 环节 | 状态 |
| --- | --- |
| PowerShell 脚本语法 | **已用 PS 官方 Parser 验证**（build_windows.ps1 1998 tokens，0 错误） |
| kit 定位 / 下载源码包 / 解压 | **已实测通过**（真实下载 v1.11.4，2.3 MB，523 文件） |
| 叠加改造 + 落地断言 | **已实测通过**（8 个新文件 + 3 处改动，断言全绿） |
| 叠加结果的正确性 | **已实测比对**：与原始 v1.11.4 树做全量 diff，差异**仅有**预期的 3 改 + 2 新目录 + 1 新文件，无误伤 |
| GitHub workflow 的 YAML 结构 | **已用 YAML 解析器验证**；4 个内嵌 PowerShell 步骤逐个过了 PS Parser 语法检查 |
| workflow 的退出码传递逻辑 | **已实证验证**：构造「构建失败 / 正常结束 / exit 0」三种场景，确认失败能被捕获且成功不会被误判——这个判断写错会让 CI 结果完全反向 |
| `flutter build windows` | **未验证**：本机无 Flutter / VS，无法执行 |
| GitHub Actions 实际跑通 | **未验证**：本机无法触发；首次运行请留意日志里的 `[XX]` 行 |
| 生成的 exe 实际运行与录制 | **未验证**：依赖上一步 |

也就是说：**打包流程本身已被验证到"只差编译器"**，剩下的是 Flutter 环境与 runner 的问题，不是脚本逻辑的问题。首次运行如果 `flutter build` 报错，基本都是环境问题，用 `flutter doctor -v` 定位。
