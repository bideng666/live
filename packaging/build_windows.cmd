@echo off
rem ===================================================================
rem  dart_simple_live - Windows one-click build
rem
rem  Just double-click this file. All arguments are passed through to
rem  build_windows.ps1, for example:
rem      build_windows.cmd -SkipBuild
rem      build_windows.cmd -UseArchive
rem      build_windows.cmd -WorkDir D:\build -Msix
rem
rem  Why this wrapper exists:
rem  Windows PowerShell 5.1 reads .ps1 files using the system ANSI code
rem  page unless the file starts with a UTF-8 BOM. build_windows.ps1
rem  contains Chinese text, so without the BOM it fails to parse. Some
rem  editors strip the BOM on save, so we check it on every run.
rem
rem  NOTE: This file is intentionally ASCII-only. cmd.exe reads batch
rem  files using the OEM code page, and a GBK double-byte sequence can
rem  swallow characters like | or %, which breaks command parsing.
rem ===================================================================
setlocal
set "PS1=%~dp0build_windows.ps1"

if not exist "%PS1%" (
    echo [XX] build_windows.ps1 not found next to this file.
    pause
    exit /b 1
)

where powershell >nul 2>&1
if errorlevel 1 (
    echo [XX] powershell not found. Windows PowerShell 5.1 or newer is required.
    pause
    exit /b 1
)

echo Checking encoding of build_windows.ps1 ...
powershell -NoProfile -Command "$p='%PS1%'; $b=[IO.File]::ReadAllBytes($p); if(-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); [IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding $true)); Write-Host '  [i] UTF-8 BOM restored' }"
if errorlevel 1 (
    echo [XX] Could not fix script encoding. Make sure build_windows.ps1 is UTF-8.
    pause
    exit /b 1
)

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo Build finished. See the dist folder reported above.
) else (
    echo Build FAILED with exit code %RC%. Check the [XX] lines above.
)
echo.
pause
endlocal
exit /b %RC%
