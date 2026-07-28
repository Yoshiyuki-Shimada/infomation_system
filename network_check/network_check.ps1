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

# オンラインデータ取得スクリプトを終了する
function Stop-OnlineDataFetchers {
    foreach (
        $scriptName in @(
            "fetch_news.ps1",
            "fetch_bus.ps1",
            "fetch_imazato_liner.ps1"
        )
    ) {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$scriptName*" } |
            ForEach-Object {
                Invoke-CimMethod -InputObject $_ -MethodName Terminate `
                    -ErrorAction SilentlyContinue | Out-Null
            }
    }
}

# tempフォルダー内のオンライン取得データをすべて削除する
function Clear-OnlineTempData {
    if (-not (Test-Path -LiteralPath $tempPath -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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
        
        
        # オンラインデータ取得処理を終了してから、temp内を空にする
        Stop-OnlineDataFetchers
        Clear-OnlineTempData

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
        
        # 2. 多重起動防止：既存のオンライン取得処理を終了
        Stop-OnlineDataFetchers
        
        # 3. ニュース取得プログラムを隠しウィンドウで再開
        $fetchNewsScript = Join-Path $appPath "fetch_news.ps1"
        if (Test-Path $fetchNewsScript) {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""$fetchNewsScript""" -WindowStyle Hidden
        }

        # 4. バスオンライン情報取得プログラムを再開
        $fetchBusScript = Join-Path $appPath "fetch_bus.ps1"
        if (Test-Path $fetchBusScript) {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""$fetchBusScript""" -WindowStyle Hidden
        }

        # 5. いまざとライナーオンライン情報取得プログラムを再開
        $fetchImazatoLinerScript = Join-Path $appPath "fetch_imazato_liner.ps1"
        if (Test-Path $fetchImazatoLinerScript) {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""$fetchImazatoLinerScript""" -WindowStyle Hidden
        }
        
        $isOnline = $true
    }

    # 5秒おきにチェック
    Start-Sleep -Seconds 5
}
