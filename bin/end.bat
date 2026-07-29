@echo off

REM Edgeだけ閉じる
taskkill /f /im msedge.exe >nul 2>&1

REM ニュース自動取得プログラムおよび時報、インターネット接続監視プログラムの終了
wmic process where "commandline like '%%fetch_news.ps1%%'" call terminate
wmic process where "commandline like '%%fetch_bus.ps1%%'" call terminate
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*fetch_bus.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
wmic process where "commandline like '%%fetch_imazato_liner.ps1%%'" call terminate
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*fetch_imazato_liner.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
wmic process where "commandline like '%%time_signal.ps1%%'" call terminate
wmic process where "commandline like '%%network_check.ps1%%'" call terminate
wmic process where "commandline like '%%earthquake_monitor.ps1%%'" call terminate
wmic process where "commandline like '%%play_eew_sequence.ps1%%'" call terminate


REM 10秒待ってスリープ状態
timeout /t 10
powershell -command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)"

