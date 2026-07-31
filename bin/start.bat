@echo off
chcp 65001 > nul
cd /d %~dp0

:: スタートアップ起動時も現在の作業フォルダーに依存しない絶対パス
for %%i in ("%~dp0..") do set "PARENT_DIR=%%~fi"

:: モニター点灯
powershell -ExecutionPolicy Bypass -Command "(Add-Type '[DllImport(\"user32.dll\")]public static extern int SendMessage(int hWnd,int hMsg,int wParam,int lParam);' -Name a -Pas)::SendMessage(-1,0x0112,0xF170,-1)"

:: ニュース取得プログラムの重複起動を防止
:: 既に実行中の powershell.exe のうち、fetch_news.ps1 を含むものを強制終了させる
wmic process where "commandline like '%%fetch_news.ps1%%'" call terminate
wmic process where "commandline like '%%fetch_bus.ps1%%'" call terminate
wmic process where "commandline like '%%fetch_imazato_liner.ps1%%'" call terminate
wmic process where "commandline like '%%time_signal.ps1%%'" call terminate
wmic process where "commandline like '%%network_check.ps1%%'" call terminate
wmic process where "commandline like '%%earthquake_monitor.ps1%%'" call terminate
wmic process where "commandline like '%%play_eew_sequence.ps1%%'" call terminate

:: ニュース・気象情報などを自動取得プログラムを「隠しウィンドウ」でバックグラウンド起動
:: 5分おきにファイルを書き換え続けます
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\app\fetch_news.ps1"

:: 大阪シティバスのオンライン接近情報を30秒ごとに取得
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\app\fetch_bus.ps1"

:: Start Imazato Liner online data fetcher
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\app\fetch_imazato_liner.ps1"

:: 時報アプリ起動
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\time\time_signal.ps1"

:: [3] インターネット接続確認アプリ起動
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\network_check\network_check.ps1"

:: システムアップデート要求の常時監視
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\bin\update_agent.ps1"

:: 地震・津波・緊急地震速報の常時監視
start "" /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PARENT_DIR%\earthquake\earthquake_monitor.ps1"

:: [4] Edgeをキオスクモードで起動
rem Edge を起動！パスには PARENT_DIR を使うよ
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0start_displays.ps1"
exit
