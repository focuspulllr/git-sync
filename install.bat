@echo off
chcp 65001 >nul
setlocal

set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "VBS=%~dp0git-sync-tray.vbs"

echo ============================================
echo  Git Sync Tray - Install
echo ============================================
echo.

powershell -Command "$s=(New-Object -COM WScript.Shell).CreateShortcut('%STARTUP%\Git-Sync-Tray.lnk'); $s.TargetPath='wscript.exe'; $s.Arguments='\""%VBS%"\"'; $s.WorkingDirectory='%~dp0'; $s.Description='Git Sync Tray'; $s.Save()"

if exist "%STARTUP%\Git-Sync-Tray.lnk" (
    echo [OK] Added to startup.
    echo.
    echo Starting now...
    start "" wscript.exe "%VBS%"
) else (
    echo [ERROR] Failed.
)

echo.
pause
