@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Git Sync Tray - Debug (창을 닫지 마세요, 에러 확인용)
echo.
powershell -ExecutionPolicy Bypass -NoExit -File "%~dp0git-sync-tray.ps1"
pause

