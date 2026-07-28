@echo off
chcp 65001 > nul
cd /d %~dp0

for %%i in ("%~dp0..") do set "PARENT_DIR=%%~fi"

wmic process where "commandline like '%%fetch_imazato_liner.ps1%%'" call terminate
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\app\fetch_imazato_liner.ps1"

start "" "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" ^
    --kiosk "%PARENT_DIR%\imazato-liner.html" ^
    --edge-kiosk-type=fullscreen ^
    --no-first-run ^
    --disable-infobars
exit
