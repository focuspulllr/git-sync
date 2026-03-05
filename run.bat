@echo off
chcp 65001 >nul
cd /d "%~dp0"
start "" powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0git-sync-tray.ps1"
