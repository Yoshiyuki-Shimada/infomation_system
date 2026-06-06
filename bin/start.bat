@echo off
chcp 65001 > nul
cd /d %~dp0

:: モニター点灯
powershell -ExecutionPolicy Bypass -Command "(Add-Type '[DllImport(\"user32.dll\")]public static extern int SendMessage(int hWnd,int hMsg,int wParam,int lParam);' -Name a -Pas)::SendMessage(-1,0x0112,0xF170,-1)"

:: ニュース取得プログラムの重複起動を防止
:: 既に実行中の powershell.exe のうち、fetch_news.ps1 を含むものを強制終了させる
wmic process where "commandline like '%%fetch_news.ps1%%'" call terminate
wmic process where "commandline like '%%time_signal.ps1%%'" call terminate
wmic process where "commandline like '%%network_check.ps1%%'" call terminate

:: ニュース・気象情報などを自動取得プログラムを「隠しウィンドウ」でバックグラウンド起動
:: 5分おきにファイルを書き換え続けます
::start /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "../app/fetch_news.ps1"

:: 時報アプリ起動
start /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "../time/time_signal.ps1"

:: [3] インターネット接続確認アプリ起動
start /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "../network_check/network_check.ps1"

:: [4] Edgeをキオスクモードで起動
rem 1. バッチファイルがある場所の「一つ上」のフルパスを取得するよ
for %%i in ("%~dp0..") do set "PARENT_DIR=%%~fi"

rem 2. Edge を起動！パスには PARENT_DIR を使うよ
start "" "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" ^
    --kiosk "%PARENT_DIR%\index.html" ^
    --edge-kiosk-type=fullscreen ^
    --no-first-run ^
    --disable-infobars
exit