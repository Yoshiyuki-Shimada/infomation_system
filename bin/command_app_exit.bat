REM ニュース自動取得プログラムおよび時報、インターネット接続監視プログラムの終了
wmic process where "commandline like '%%fetch_news.ps1%%'" call terminate
wmic process where "commandline like '%%time_signal.ps1%%'" call terminate
wmic process where "commandline like '%%network_check.ps1%%'" call terminate

pause