[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 実行ディレクトリ基準
Set-Location $PSScriptRoot
$basePath = Join-Path $PSScriptRoot "audio"

# MediaPlayer読み込み
Add-Type -AssemblyName presentationCore

# 再生関数（MP3対応・安定版）
function Play-Sound {
    param ([string]$filePath)

    if (-not (Test-Path $filePath)) {
        Write-Output "ファイルなし:$filePath"
        return
    }

    Write-Output "再生:$filePath"

    $player = New-Object System.Windows.Media.MediaPlayer
    $player.Open([Uri]$filePath)

    # 読み込み待ち
    Start-Sleep -Milliseconds 200

    $player.Play()

    # 再生時間取得待ち
    while (-not $player.NaturalDuration.HasTimeSpan) {
        Start-Sleep -Milliseconds 50
    }

    $duration = $player.NaturalDuration.TimeSpan.TotalMilliseconds

    # 再生待機
    Start-Sleep -Milliseconds $duration

    $player.Close()

    # 少し間を入れる（自然化）
    Start-Sleep -Milliseconds 100
}

# 二重再生防止
$lastPlayedMinute = -1

function Start-Time-Signal {
    $now = Get-Date
    $hour = $now.Hour
    $minute = $now.Minute
    $second = $now.Second

    # 秒ピッタリ（少し余裕持たせてもOKなら <=1 にしてもいい）
    if ($second -ne 0) { return }

    # 10分単位のみ
    if ($minute % 10 -ne 0) { return }

    # 二重再生防止
    if ($minute -eq $lastPlayedMinute) { return }
    $script:lastPlayedMinute = $minute

    Write-Output "===="
    Write-Output $now

    $hourPath = Join-Path $basePath "hour_24h"
    $minPath = Join-Path $basePath "minutes_24h"

    # ファイルパス
    $titleSound = Join-Path $hourPath "time_signal_title_sound.mp3"
    $titleVoice = Join-Path $hourPath "time_signal_title_voice.mp3"

    # ① ピロリン
    Play-Sound $titleSound

    # ② 時刻は
    Play-Sound $titleVoice

    # 正時
    if ($minute -eq 0) {
        $hourFile = Join-Path $hourPath "time_signal_${hour}_hour_just.mp3"
        Write-Output "時:$hourFile"
        Play-Sound $hourFile
    }
    else {
        $hourFile = Join-Path $hourPath "time_signal_${hour}_hour.mp3"
        $minFile = Join-Path $minPath "time_signal_${minute}_min.mp3"

        Write-Output "時:$hourFile"
        Write-Output "分:$minFile"

        Play-Sound $hourFile
        Play-Sound $minFile
    }
}

# メインループ（秒同期）
while ($true) {
    Start-Time-Signal

    # 次の秒境界まで待つ
    $now = Get-Date
    $sleep = 1000 - $now.Millisecond
    Start-Sleep -Milliseconds $sleep
}