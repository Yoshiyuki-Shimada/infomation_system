@echo off
chcp 65001 > nul
cd /d %~dp0

for %%i in ("%~dp0..") do set "PARENT_DIR=%%~fi"

powershell -ExecutionPolicy Bypass -File "%PARENT_DIR%\bin\display_power_control.ps1" -WakeOnce

wmic process where "commandline like '%%fetch_news.ps1%%'" call terminate
wmic process where "commandline like '%%fetch_bus.ps1%%'" call terminate
wmic process where "commandline like '%%fetch_imazato_liner.ps1%%'" call terminate
wmic process where "commandline like '%%time_signal.ps1%%'" call terminate
wmic process where "commandline like '%%network_check.ps1%%'" call terminate
wmic process where "commandline like '%%display_power_control.ps1%%'" call terminate
wmic process where "commandline like '%%earthquake_monitor.ps1%%'" call terminate
wmic process where "commandline like '%%play_eew_sequence.ps1%%'" call terminate

rem Start news, weather, railway, and warning fetcher.
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\app\fetch_news.ps1"

rem Start Osaka City Bus online data fetcher.
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\app\fetch_bus.ps1"

rem Start Imazato Liner online data fetcher.
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\app\fetch_imazato_liner.ps1"

rem Start time signal.
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\time\time_signal.ps1"

rem Start network monitor.
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\network_check\network_check.ps1"

rem Start display power controller.
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\bin\display_power_control.ps1"

rem Start system update agent.
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\bin\update_agent.ps1"

rem Start earthquake, tsunami, and EEW monitor.
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\earthquake\earthquake_monitor.ps1"

rem Start two signage windows.
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0start_displays.ps1"
exit
