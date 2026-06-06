@echo off

REM Edgeだけ閉じる
taskkill /f /im msedge.exe >nul 2>&1

REM ニュース自動取得プログラムおよび時報、インターネット接続監視プログラムの終了
wmic process where "commandline like '%%fetch_news.ps1%%'" call terminate
wmic process where "commandline like '%%time_signal.ps1%%'" call terminate
wmic process where "commandline like '%%network_check.ps1%%'" call terminate


REM 10秒待ってスリープ状態
timeout /t 10
powershell -command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)"

