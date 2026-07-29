[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 実行ディレクトリ基準
Set-Location $PSScriptRoot
$basePath = Join-Path $PSScriptRoot "audio"
$projectDir = Split-Path -Path $PSScriptRoot -Parent
$eewPriorityPath = Join-Path $projectDir "temp\eew_audio_priority.lock"

# MediaPlayer読み込み
Add-Type -AssemblyName presentationCore

# 再生関数（MP3対応・安定版）
function Test-EewPriorityActive {
    if (-not (Test-Path -LiteralPath $eewPriorityPath)) { return $false }

    try {
        $untilText = Get-Content -LiteralPath $eewPriorityPath -Raw -ErrorAction Stop
        $until = [datetime]::Parse($untilText.Trim())
        if ((Get-Date) -lt $until) { return $true }
    }
    catch {
        return $true
    }

    Remove-Item -LiteralPath $eewPriorityPath -Force -ErrorAction SilentlyContinue
    return $false
}

# 再生関数（MP3対応・EEW割り込み対応）
function Play-Sound {
    param ([string]$filePath)

    if (Test-EewPriorityActive) {
        Write-Host "EEW優先中のため時報をスキップ"
        return $false
    }

    if (-not (Test-Path $filePath)) {
        Write-Host "ファイルなし:$filePath"
        return $false
    }

    Write-Host "再生:$filePath"

    $player = New-Object System.Windows.Media.MediaPlayer
    $player.Open([Uri]$filePath)
    Start-Sleep -Milliseconds 200
    $player.Play()

    while (-not $player.NaturalDuration.HasTimeSpan) {
        if (Test-EewPriorityActive) {
            $player.Stop()
            $player.Close()
            return $false
        }
        Start-Sleep -Milliseconds 50
    }

    $duration = [int]$player.NaturalDuration.TimeSpan.TotalMilliseconds
    $elapsed = 0
    while ($elapsed -lt $duration) {
        if (Test-EewPriorityActive) {
            Write-Host "EEW優先のため時報再生を停止"
            $player.Stop()
            $player.Close()
            return $false
        }
        $sleep = [Math]::Min(100, $duration - $elapsed)
        Start-Sleep -Milliseconds $sleep
        $elapsed += $sleep
    }

    $player.Close()
    Start-Sleep -Milliseconds 100
    return $true
}
# 二重再生防止
$lastPlayedMinute = -1
$announceTimeAtOtherTenMinutes = $false

function Start-Time-Signal {
    $now = Get-Date
    $hour = $now.Hour
    $minute = $now.Minute
    $second = $now.Second

    if (Test-EewPriorityActive) { return }
    if ($second -ne 0) { return }
    if ($minute % 10 -ne 0) { return }

    if ($minute -eq $lastPlayedMinute) { return }
    $script:lastPlayedMinute = $minute

    Write-Host "===="
    Write-Host $now

    $hourPath = Join-Path $basePath "hour_24h"
    $minPath = Join-Path $basePath "minutes_24h"

    $titleJustSound = Join-Path $hourPath "time_signal_just_title_sound.mp3"
    $title30Sound = Join-Path $hourPath "time_signal_30_title_sound.mp3"
    $titleSoundMap = @{
        10 = Join-Path $hourPath "time_signal_10_title_sound.mp3"
        20 = Join-Path $hourPath "time_signal_20_title_sound.mp3"
        40 = Join-Path $hourPath "time_signal_40_title_sound.mp3"
        50 = Join-Path $hourPath "time_signal_50_title_sound.mp3"
    }
    $titleVoice = Join-Path $hourPath "time_signal_title_voice.mp3"

    if ($minute -eq 0) {
        if (-not (Play-Sound $titleJustSound)) { return }
        if (-not (Play-Sound $titleVoice)) { return }

        $hourFile = Join-Path $hourPath "time_signal_${hour}_hour_just.mp3"
        Write-Host "時:$hourFile"
        [void](Play-Sound $hourFile)
        return
    }

    $hourFile = Join-Path $hourPath "time_signal_${hour}_hour.mp3"
    $minFile = Join-Path $minPath "time_signal_${minute}_min.mp3"

    if ($minute -eq 30) {
        if (-not (Play-Sound $title30Sound)) { return }
        if (-not (Play-Sound $titleVoice)) { return }

        Write-Host "時:$hourFile"
        Write-Host "分:$minFile"
        if (-not (Play-Sound $hourFile)) { return }
        [void](Play-Sound $minFile)
        return
    }

    $titleSound = $titleSoundMap[$minute]
    if (-not $titleSound) { return }
    if (-not (Play-Sound $titleSound)) { return }

    if ($announceTimeAtOtherTenMinutes) {
        if (-not (Play-Sound $titleVoice)) { return }

        Write-Host "時:$hourFile"
        Write-Host "分:$minFile"
        if (-not (Play-Sound $hourFile)) { return }
        [void](Play-Sound $minFile)
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