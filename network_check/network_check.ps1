# ==============================================================================
# Snow Link Drone - Network Monitoring System
# File Name: network_check.ps1
# Description: インターネット接続を常時監視し、接続状況に応じてシステムを制御します。
# ==============================================================================

# スクリプトの場所を基準にパスを設定
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootPath = Split-Path -Parent $scriptDir
$tempPath = Join-Path $rootPath "temp"
$appPath = Join-Path $rootPath "app"
$soundPath = Join-Path $scriptDir "sound"

# 音源ファイルのパス
$disconnectionSound = Join-Path $soundPath "internet_disconnection_sound.mp3"
$disconnectionVoice = Join-Path $soundPath "internet_disconnection_voice.mp3"
$connectionSound = Join-Path $soundPath "network_connection_sound.mp3"
$connectionVoice = Join-Path $soundPath "network_connection_voice.mp3"

# 状態管理フラグ
$isOnline = $null

# .mp3再生用のライブラリ読み込み
Add-Type -AssemblyName PresentationCore

# ------------------------------------------------------------------------------
# 関数定義
# ------------------------------------------------------------------------------

# インターネット接続を確認する関数
function Test-InternetConnection {
    return Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet
}

# 音声を再生する関数 (WAV用)
function Play-Wav {
    param([string]$FilePath)
    # パスが空でなく、かつファイルが存在する場合のみ実行
    if (![string]::IsNullOrEmpty($FilePath) -and (Test-Path $FilePath)) {
        $player = New-Object System.Media.SoundPlayer
        $player.SoundLocation = $FilePath
        $player.Play()
    }
}

# 音声を再生する関数 (MP3用)
function Play-Mp3 {
    param([string]$FilePath)
    # パスが空でなく、かつファイルが存在する場合のみ実行
    if (![string]::IsNullOrEmpty($FilePath) -and (Test-Path $FilePath)) {
        $mediaPlayer = New-Object System.Windows.Media.MediaPlayer
        $mediaPlayer.Open((New-Object System.Uri($FilePath)))
        $mediaPlayer.Play()
        # 再生が終わるまで少し待機
        Start-Sleep -Seconds 5
    }
}

# ------------------------------------------------------------------------------
# 監視メインループ
# ------------------------------------------------------------------------------

Write-Host "Snow Link Drone - Network monitoring started..." -ForegroundColor Cyan

while ($true) {
    $currentStatus = Test-InternetConnection

    if ($currentStatus -eq $false -and $isOnline -ne $false) {
        # ---------------------------------------------------------
        # 【切断時：初回のみ実行】
        # ---------------------------------------------------------
        # Snow Red Strong (#FF4A5A)
        # Write-Host "[OFFLINE] 接続が切断されました。タスクを実行します。" -ForegroundColor "#FF4A5A"
        
        
        # ニュースの取得の終了
        cmd /c "wmic process where ""caption='powershell.exe' and commandline like '%%fetch_news.ps1%%'"" call terminate >nul 2>&1"
        

        # tempフォルダの削除
        if (Test-Path $tempPath) {
            Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        # 切断音の再生
        Play-Mp3 -FilePath $disconnectionSound
        Play-Mp3 -FilePath $disconnectionVoice
        
        $isOnline = $false
    }
    elseif ($currentStatus -eq $true -and $isOnline -ne $true) {
        # ---------------------------------------------------------
        # 【接続時：初回のみ実行】
        # ---------------------------------------------------------
        # Forest Green (#4CCB8A)
        # Write-Host "[ONLINE] インターネットに接続されました。" -ForegroundColor "#4CCB8A"
        
        # 1. 接続音の再生
        Play-Mp3 -FilePath $connectionSound
        Play-Mp3 -FilePath $connectionVoice
        
        # 2. 多重起動防止：既存の fetch_news.ps1 を終了
        cmd /c "wmic process where ""caption='powershell.exe' and commandline like '%%fetch_news.ps1%%'"" call terminate >nul 2>&1"
        
        # 3. ニュース取得プログラムを隠しウィンドウで再開
        $fetchNewsScript = Join-Path $appPath "fetch_news.ps1"
        if (Test-Path $fetchNewsScript) {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""$fetchNewsScript""" -WindowStyle Hidden
        }
        
        $isOnline = $true
    }

    # 5秒おきにチェック
    Start-Sleep -Seconds 5
}