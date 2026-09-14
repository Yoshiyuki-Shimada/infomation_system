@echo off
chcp 65001 > nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\send_bus_command.ps1" "char %*"
exit /b %errorlevel%