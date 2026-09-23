<#
.SYNOPSIS
    把 dart_simple_live 打包成 Windows 版，并带上直播录制改造。

.DESCRIPTION
    流程：
      1. 检查前置环境（git / Flutter / Visual Studio C++ 工具链）
      2. 获取上游源码（默认 v1.11.4，与改造适配的版本一致）
      3. 叠加录制改造文件
      4. flutter build windows --release
      5. 收集产物 → dist\ 目录并压缩成可分发的 zip

    改造文件在 kit 里是按上游目录结构镜像存放的，所以"叠加"就是一次目录覆盖，
    不依赖 git apply，也就不会有换行符/空白导致的补丁失败。

    重要：本文件必须保持 UTF-8 BOM。Windows PowerShell 5.1 在没有 BOM 时会按
    系统 ANSI 码页读取 .ps1，中文会被误读并直接导致语法错误。用 build_windows.cmd
    启动会自动检查并补上 BOM。

.PARAMETER WorkDir
    工作目录，源码放在 <WorkDir>\src，产物在 <WorkDir>\dist。

.PARAMETER SourceDir
    已有源码目录。指定后跳过获取源码，直接用这个目录（若含 .git 会先重置到 Tag）。

.PARAMETER KitRoot
    改造文件所在目录（含 simple_live_core / simple_live_app 两层）。默认自动推断。

.PARAMETER Tag
    上游 tag，默认 v1.11.4。改造文件按此版本对齐，换版本可能冲突。

.PARAMETER UseTarball
    用 HTTPS 下载源码包而不是 git clone。适合 git 走不通（代理/防火墙）的环境。

.PARAMETER UseArchive
    用 HTTPS 下载源码包（zip）而不是 git clone。适合 git 走不通（代理/防火墙）的环境。
    解压走 PowerShell 自带的 Expand-Archive，不依赖外部 tar。

.PARAMETER Msix
    额外产出 .msix 安装包。需要 dart pub global activate flutter_distributor，
    失败不影响 zip 产物。

.PARAMETER SkipBuild
    只做源码准备与改造叠加，不执行 flutter build（用于先确认改造落地正确）。

.EXAMPLE
    .\build_windows.ps1
    .\build_windows.ps1 -UseArchive
    .\build_windows.ps1 -SourceDir D:\code\dart_simple_live -WorkDir D:\build
    .\build_windows.ps1 -SkipBuild
#>
[CmdletBinding()]
param(
    [string]$WorkDir = "$env:USERPROFILE\dart_simple_live_build",
    [string]$SourceDir = "",
    [string]$KitRoot = "",
    [string]$Tag = "v1.11.4",
    [string]$RepoUrl = "https://github.com/lostars/dart_simple_live.git",
    [string]$ArchiveUrl = "",
    [switch]$UseArchive,
    [switch]$Msix,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

# 本脚本的提示信息都是中文。Windows PowerShell 5.1 在输出被重定向（CI 日志、
# 管道捕获）时会按系统 ANSI 码页编码，中文会变成乱码 —— 而失败提示恰恰是排查
# 依据，乱码会拖慢定位。这里强制 UTF-8 输出。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}
function Write-Ok([string]$Text)    { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "    [!!] $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text)   { Write-Host "    [XX] $Text" -ForegroundColor Red }
function Write-Dim([string]$Text)   { Write-Host "    $Text" -ForegroundColor DarkGray }
function Fail([string]$Text) { Write-Err $Text; exit 1 }

function Test-Tool([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# 运行原生命令并检查退出码。
# 注意：PowerShell 的 $ErrorActionPreference 管不到原生 exe 的退出码，
# 不显式检查就会出现"git clone 失败但脚本继续跑"的假成功。
#
# 参数刻意全部具名、不用 ValueFromRemainingArguments：后者会让 PowerShell 把
# 位置参数贪婪地绑到 $What 上，调用时一旦漏传 -What 就会报出很难懂的参数转换错误。
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$What = ""
    )
    $display = if ($What) { $What } else { "$Exe $($Arguments -join ' ')" }
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$display 失败（退出码 $LASTEXITCODE）"
    }
}

# ---------------------------------------------------------------- 0. 定位 kit
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# kit 的完整性标记：这个文件在，说明 simple_live_core/lib/src/ 没被漏掉
$kitMarker = 'simple_live_core\lib\src\recorder\live_recorder.dart'

function Test-Kit([string]$Dir) {
    if (-not $Dir -or -not (Test-Path $Dir)) { return $false }
    return Test-Path (Join-Path $Dir $kitMarker)
}

# 定位失败时的提示。最常见的真实原因不是"目录找错了"，而是 .gitignore 里
# 有未加前导斜杠的 src/ 规则，把 simple_live_core/lib/src/ 整个排除掉，
# 于是 clone/checkout 出来的 kit 里根本没有这些文件。
function Fail-KitNotFound([string]$Where) {
    $hint = @"
找不到改造 kit 目录：缺少 $kitMarker
    查找位置: $Where

最可能的原因（按概率排序）：
  1. .gitignore 里有未加前导斜杠的 src/ 规则。git 的该模式会匹配**任意层级**的
     src 目录，于是 simple_live_core/lib/src/ 整个被排除、没被提交。
     正确写法是 /src/ 。本地可执行以下命令核对，应看到 5 个文件：
         git ls-files | findstr recorder
  2. 仓库推送不完整，或解压时漏了 simple_live_core 目录。
  3. 确实放错了位置，可用 -KitRoot 显式指定。
"@
    Fail $hint
}

if ($KitRoot -ne "") {
    if (-not (Test-Kit $KitRoot)) {
        Fail-KitNotFound $KitRoot
    }
} elseif (Test-Kit $scriptDir) {
    $KitRoot = $scriptDir
} elseif (Test-Kit (Split-Path -Parent $scriptDir)) {
    $KitRoot = Split-Path -Parent $scriptDir
} else {
    Fail-KitNotFound $scriptDir
}
$KitRoot = (Resolve-Path $KitRoot).Path

# 工作目录如果落在仓库内，脚本会把整份上游源码（500+ 文件）写进仓库，
# 之后 git add -A 就会把它们一起提交上去。默认值在用户目录下，不会有这个问题；
# 只有显式用相对路径（如 -WorkDir .\out）时才会踩到，所以这里提醒一句。
if (-not $SourceDir -and $WorkDir) {
    $workAbs = $null
    try { $workAbs = [System.IO.Path]::GetFullPath($WorkDir) } catch {}
    if ($workAbs -and $workAbs.StartsWith($KitRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Warn2 "工作目录在 kit 目录内部（$workAbs）。"
        Write-Warn2 "脚本会往里面写入整份上游源码，之后 git add -A 会把它们一起提交。"
        Write-Warn2 "建议改用仓库外的路径，例如 -WorkDir `$env:USERPROFILE\dart_simple_live_build"
    }
}

# ---------------------------------------------------------------- 1. 前置检查
Write-Step "检查前置环境"
Write-Dim "kit: $KitRoot"

if (-not (Test-Tool 'git') -and -not $UseArchive) {
    Fail "找不到 git。请安装 Git for Windows，或加 -UseArchive 改用 HTTPS 下载源码。"
}
if (Test-Tool 'git') { Write-Ok "git: $((git --version) -join '')" }

if (-not $SkipBuild) {
    if (-not (Test-Tool 'flutter')) {
        Fail "找不到 flutter。请先安装 Flutter SDK 并加入 PATH：https://docs.flutter.dev/get-started/install/windows`n本项目 .fvmrc 锁定 Flutter 3.38.3（Dart >= 3.10），建议用同版本。`n只想先确认改造落地的话，可以加 -SkipBuild 跳过构建。"
    }
    $flutterVersion = ""
    $dartVersion = ""
    try {
        $fv = (& flutter --version --machine 2>$null) | ConvertFrom-Json
        $flutterVersion = $fv.frameworkVersion
        $dartVersion = $fv.dartSdkVersion
    } catch {
        $flutterVersion = (& flutter --version 2>$null | Select-Object -First 1)
    }
    Write-Ok "flutter: $flutterVersion (dart $dartVersion)"

    if ($dartVersion) {
        $parts = $dartVersion.Split('.')
        if ([int]$parts[0] -lt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -lt 10)) {
            Fail "Dart 版本过低（$dartVersion）。simple_live_core 要求 Dart >= 3.10，请升级 Flutter 到 3.38.x。"
        }
    }

    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = ""
    if (Test-Path $vsWhere) {
        $vsPath = & $vsWhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
    }
    if ($vsPath) {
        Write-Ok "Visual Studio C++ 工具链: 已安装"
    } else {
        Write-Warn2 "未检测到 Visual Studio 的 C++ 桌面开发组件，flutter build windows 会失败。"
        Write-Warn2 "请安装 VS 2022 并勾选「使用 C++ 的桌面开发」，或用 flutter doctor 复核。"
    }
} else {
    Write-Warn2 "已指定 -SkipBuild，跳过 flutter 与 VS 检查"
}

# ---------------------------------------------------------------- 2. 获取源码
Write-Step "获取源码 ($Tag)"

function Assert-IsRepo([string]$Root) {
    foreach ($p in @('simple_live_app\pubspec.yaml', 'simple_live_core\pubspec.yaml')) {
        if (-not (Test-Path (Join-Path $Root $p))) {
            Fail "源码目录不完整（缺少 $p）: $Root"
        }
    }
}

if ($SourceDir -ne "") {
    if (-not (Test-Path $SourceDir)) { Fail "SourceDir 不存在: $SourceDir" }
    $SrcRoot = (Resolve-Path $SourceDir).Path
    Assert-IsRepo $SrcRoot
    if (Test-Path (Join-Path $SrcRoot '.git')) {
        # 安全阀：重置会用 git checkout -f + git clean -fd 把工作区拉回 tag 状态，
        # 这会冲掉未提交的改动。若传入的是已经提交过改造的 fork，工作区可能
        # 看起来是干净的但重置仍会回退已提交内容，所以这里只在工作区干净时重置，
        # 并明确告知；有改动就跳过（叠加覆盖照样生效）。
        $dirty = & git -C $SrcRoot status --porcelain 2>$null
        if ($dirty) {
            Write-Warn2 "工作区有未提交改动，跳过版本重置以免破坏你的改动"
            Write-Warn2 "改造文件仍会叠加覆盖；若要强制重置到 $Tag，请先 commit 或 stash"
        } else {
            Write-Dim "重置到 $Tag ..."
            Push-Location $SrcRoot
            try {
                Invoke-Native -Exe git -What "git fetch $Tag" -Arguments @('-c', 'core.autocrlf=false', 'fetch', '--tags', '--depth', '1', 'origin', $Tag)
                Invoke-Native -Exe git -What "git checkout $Tag" -Arguments @('-c', 'core.autocrlf=false', 'checkout', '-f', $Tag)
                & git -c core.autocrlf=false clean -fdq simple_live_app/lib simple_live_core/lib 2>&1 | Out-Null
            } finally { Pop-Location }
            Write-Ok "已重置到 $Tag"
        }
    } else {
        Write-Warn2 "目录不是 git 仓库，跳过版本重置（改造文件仍会覆盖）"
    }
} else {
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    $SrcRoot = Join-Path $WorkDir 'src'

    $haveGitRepo = Test-Path (Join-Path $SrcRoot '.git')
    $havePlainTree = (Test-Path $SrcRoot) -and (-not $haveGitRepo)

    if ($haveGitRepo -and -not $UseArchive) {
        Write-Dim "复用已有 git 源码: $SrcRoot"
        Push-Location $SrcRoot
        try {
            Invoke-Native -Exe git -What "git fetch $Tag" -Arguments @('-c', 'core.autocrlf=false', 'fetch', '--tags', '--depth', '1', 'origin', $Tag)
            Invoke-Native -Exe git -What "git checkout $Tag" -Arguments @('-c', 'core.autocrlf=false', 'checkout', '-f', $Tag)
            & git -c core.autocrlf=false clean -fdq simple_live_app/lib simple_live_core/lib 2>&1 | Out-Null
        } finally { Pop-Location }
        Write-Ok "源码就绪: $SrcRoot"
    } elseif ($havePlainTree) {
        Write-Dim "复用已有源码目录（非 git）: $SrcRoot"
        Assert-IsRepo $SrcRoot
        Write-Ok "源码就绪: $SrcRoot"
    } elseif ($UseArchive -or -not (Test-Tool 'git')) {
        if ($ArchiveUrl -eq "") {
            $m = [regex]::Match($RepoUrl, 'github\.com[/:]([^/]+)/([^/]+?)(\.git)?$')
            if (-not $m.Success) {
                Fail "无法从 RepoUrl 推导源码包地址，请用 -ArchiveUrl 显式指定。RepoUrl=$RepoUrl"
            }
            $ArchiveUrl = "https://codeload.github.com/$($m.Groups[1].Value)/$($m.Groups[2].Value)/zip/refs/tags/$Tag"
        }
        Write-Dim "下载源码包: $ArchiveUrl"
        $tmpZip = Join-Path $env:TEMP "dsl-$Tag.zip"
        $tmpDir = Join-Path $env:TEMP "dsl-$Tag-extract"
        try {
            Invoke-WebRequest -Uri $ArchiveUrl -OutFile $tmpZip -UseBasicParsing
        } catch {
            Fail "下载源码包失败：$($_.Exception.Message)"
        }
        Write-Ok "已下载 $([math]::Round((Get-Item $tmpZip).Length / 1MB, 1)) MB"

        # 用 Expand-Archive 而不是 tar：Windows 上 tar 可能是 MSYS 的 GNU tar，
        # 它会把 "C:\..." 里的冒号当成远程主机名而报错
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
        try {
            Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
        } catch {
            Fail "解压源码包失败：$($_.Exception.Message)"
        }
        $inner = Get-ChildItem -Path $tmpDir -Directory | Select-Object -First 1
        if (-not $inner) { Fail "源码包解压后没有顶层目录，包结构异常" }
        if (-not (Test-Path $SrcRoot)) { New-Item -ItemType Directory -Path $SrcRoot -Force | Out-Null }
        Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $SrcRoot -Recurse -Force
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        Assert-IsRepo $SrcRoot
        Write-Ok "源码就绪: $SrcRoot"
    } else {
        Write-Dim "克隆 $RepoUrl ($Tag) → $SrcRoot"
        Invoke-Native -Exe git -What "git clone $Tag" -Arguments @('-c', 'core.autocrlf=false', 'clone', '--branch', $Tag, '--depth', '1', $RepoUrl, $SrcRoot)
        Assert-IsRepo $SrcRoot
        Write-Ok "源码就绪: $SrcRoot"
    }
}
Assert-IsRepo $SrcRoot

# ---------------------------------------------------------------- 3. 叠加改造
Write-Step "叠加录制改造"

# 叠加的目录对。刻意写成显式列表而不是按包名推导：改造点不只在 lib 下，
# 还有 simple_live_app/windows（CMakeLists.txt 里要给新版 MSVC 加抑制宏）。
$overlays = @(
    @{ From = 'simple_live_core\lib';    To = 'simple_live_core\lib' },
    @{ From = 'simple_live_app\lib';     To = 'simple_live_app\lib' },
    @{ From = 'simple_live_app\windows'; To = 'simple_live_app\windows' }
)
foreach ($o in $overlays) {
    $from = Join-Path $KitRoot $o.From
    $to = Join-Path $SrcRoot $o.To
    if (-not (Test-Path $from)) { Fail "kit 缺少目录: $from" }
    if (-not (Test-Path $to)) { Fail "源码缺少目录: $to" }
    # 用 \* 通配符形式复制，语义是"合并内容"，不会把源目录名套进去
    Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
}

# 覆盖是否真的落地，逐一确认，避免"看起来成功实际没改"
$mustExist = @(
    'simple_live_core\lib\src\recorder\live_recorder.dart',
    'simple_live_core\lib\src\recorder\recorder_options.dart',
    'simple_live_core\lib\src\recorder\recorder.dart',
    'simple_live_app\lib\modules\live_room\recorder\room_recorder.dart',
    'simple_live_app\lib\modules\live_room\recorder\recorder_button.dart',
    'simple_live_app\lib\modules\settings\record\record_settings_page.dart',
    'simple_live_app\windows\CMakeLists.txt'
)
foreach ($f in $mustExist) {
    if (-not (Test-Path (Join-Path $SrcRoot $f))) { Fail "改造文件未落地: $f" }
}

$checks = @(
    @{ File = 'simple_live_core\lib\simple_live_core.dart';                        Pattern = 'src/recorder/recorder.dart' },
    @{ File = 'simple_live_app\lib\modules\live_room\live_room_controller.dart';   Pattern = 'RoomRecorderController' },
    @{ File = 'simple_live_app\lib\modules\live_room\player\player_controls.dart'; Pattern = 'RecorderButton' },
    @{ File = 'simple_live_app\windows\CMakeLists.txt';                            Pattern = '_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS' }
)
foreach ($c in $checks) {
    $path = Join-Path $SrcRoot $c.File
    if (-not (Test-Path $path)) { Fail "缺少文件: $($c.File)" }
    if (-not (Select-String -Path $path -Pattern $c.Pattern -Quiet)) {
        Fail "$($c.File) 未包含 $($c.Pattern)，覆盖失败"
    }
}
Write-Ok "7 个新文件 + 8 处改动全部落地"

if ($SkipBuild) {
    Write-Step "已指定 -SkipBuild，源码准备完成"
    Write-Host "    源码目录: $SrcRoot" -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- 4. 构建
$AppDir = Join-Path $SrcRoot 'simple_live_app'
Push-Location $AppDir
try {
    Write-Step "flutter pub get"
    Invoke-Native -Exe flutter -What "flutter pub get" -Arguments @('pub', 'get')
    Write-Ok "依赖就绪"

    Write-Step "flutter build windows --release"
    Write-Dim "首次构建需要下载 Windows 引擎产物，可能比较慢"
    Invoke-Native -Exe flutter -What "flutter build windows" -Arguments @('build', 'windows', '--release')
    Write-Ok "构建完成"
} finally {
    Pop-Location
}

# ---------------------------------------------------------------- 5. 收集产物
Write-Step "收集产物"

$releaseDir = @(
    (Join-Path $AppDir 'build\windows\x64\runner\Release'),
    (Join-Path $AppDir 'build\windows\runner\Release')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $releaseDir) {
    Fail "找不到构建产物目录，请检查 $AppDir\build\windows 下的实际输出路径"
}
$exe = Get-ChildItem -Path $releaseDir -Filter '*.exe' | Select-Object -First 1
if (-not $exe) { Fail "产物目录里没有 exe: $releaseDir" }
Write-Ok "产物目录: $releaseDir"
Write-Ok "主程序:   $($exe.Name)"

$distRoot = if ($SourceDir -ne "") { Join-Path $KitRoot 'dist' } else { Join-Path $WorkDir 'dist' }
if (-not (Test-Path $distRoot)) { New-Item -ItemType Directory -Path $distRoot -Force | Out-Null }

$verLine = Select-String -Path (Join-Path $AppDir 'pubspec.yaml') -Pattern '^version:\s*(\S+)' | Select-Object -First 1
$appVersion = if ($verLine) { $verLine.Matches[0].Groups[1].Value } else { 'dev' }
$stageName = "SimpleLive-recorder-$appVersion-windows"
$stageDir = Join-Path $distRoot $stageName
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

# Release 目录必须整份带走：exe 依赖同目录的 dll 和 data\ 文件夹
Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stageDir -Recurse -Force
Write-Ok "已收集到: $stageDir"

$zipPath = Join-Path $distRoot "$stageName.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Write-Dim "压缩中 ..."
Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Ok "便携版: $zipPath  ($([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB)"

# ---------------------------------------------------------------- 6. 可选 msix
if ($Msix) {
    Write-Step "构建 msix 安装包"
    if (-not (Test-Tool 'flutter_distributor')) {
        Write-Warn2 "未安装 flutter_distributor，跳过。安装：dart pub global activate flutter_distributor"
    } else {
        Push-Location $AppDir
        try {
            & flutter_distributor package --platform windows --targets msix --skip-clean
            if ($LASTEXITCODE -ne 0) {
                Write-Warn2 "msix 构建失败（常见原因是 pubspec 里缺 msix 依赖），便携版 zip 不受影响"
            } else {
                $msixDir = Join-Path $AppDir 'build\dist'
                if (Test-Path $msixDir) {
                    Get-ChildItem -Path $msixDir -Filter '*.msix' -Recurse |
                        ForEach-Object { Copy-Item $_.FullName $distRoot -Force; Write-Ok "msix: $($_.Name)" }
                }
            }
        } finally { Pop-Location }
    }
}

# ---------------------------------------------------------------- 完成
Write-Step "打包完成"
Write-Host "    分发目录: $distRoot" -ForegroundColor Green
Write-Host ""
Write-Dim "拿到 zip 后在 Windows 上解压即可直接运行，无需安装。"
Write-Dim "注意必须整个文件夹一起用，exe 依赖同目录的 dll 与 data\ 。"
Write-Host ""
Write-Dim "录制文件默认输出到："
Write-Dim "  %USERPROFILE%\Documents\SimpleLiveRecords"
Write-Dim "想确认录出来的文件是否正常（需要 ffmpeg）："
Write-Dim "  ffprobe -v error -show_entries format=duration,size -show_streams ""<文件.flv>"""
