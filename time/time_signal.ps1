[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 実行ディレクトリ基準
Set-Location $PSScriptRoot
$basePath = Join-Path $PSScriptRoot "audio"
$projectDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path $projectDir "temp"
$eewPriorityPath = Join-Path $projectDir "temp\eew_audio_priority.lock"
$timeSignalPausePath = Join-Path $projectDir "temp\time_signal_pause_until.txt"
$timeSignalControlPort = 18765
$timeSignalControlListener = $null

function Get-TimeSignalResetTime {
    param([datetime]$Now)

    $reset = Get-Date -Year $Now.Year -Month $Now.Month -Day $Now.Day -Hour 5 -Minute 55 -Second 0
    if ($Now -ge $reset) {
        return $reset.AddDays(1)
    }
    return $reset
}

function Save-TimeSignalPauseUntil {
    param([datetime]$Until)

    if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    }
    [IO.File]::WriteAllText($timeSignalPausePath, $Until.ToString("o"), [Text.UTF8Encoding]::new($false))
}

function Clear-TimeSignalPause {
    Remove-Item -LiteralPath $timeSignalPausePath -Force -ErrorAction SilentlyContinue
}

function Get-TimeSignalPauseUntil {
    if (-not (Test-Path -LiteralPath $timeSignalPausePath -PathType Leaf)) {
        return $null
    }

    try {
        return [datetime]::Parse((Get-Content -LiteralPath $timeSignalPausePath -Raw).Trim())
    }
    catch {
        Clear-TimeSignalPause
        return $null
    }
}

function Test-TimeSignalPaused {
    param([datetime]$Now = (Get-Date))

    $until = Get-TimeSignalPauseUntil
    if (-not $until) { return $false }

    if ($Now -ge $until) {
        Clear-TimeSignalPause
        return $false
    }
    return $true
}
function Get-TimeSignalPauseStatusJson {
    $now = Get-Date
    $until = Get-TimeSignalPauseUntil
    $paused = $false
    if ($until -and $now -lt $until -and -not (Test-TimeSignalControlDisabled -Now $now)) {
        $paused = Test-TimeSignalPaused -Now $now
        $until = Get-TimeSignalPauseUntil
    }
    $disabled = Test-TimeSignalControlDisabled -Now $now

    $payload = [ordered]@{
        paused = $paused
        disabled = $disabled
        until = if ($paused -and $until) { $until.ToString("o") } else { $null }
        now = $now.ToString("o")
    }
    return ($payload | ConvertTo-Json -Compress)
}

function Start-TimeSignalControlServer {
    try {
        $endpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Parse("127.0.0.1"), $timeSignalControlPort)
        $script:timeSignalControlListener = [Net.Sockets.TcpListener]::new($endpoint)
        $script:timeSignalControlListener.Start()
        Write-Host "時報制御受付を開始: http://127.0.0.1:$timeSignalControlPort/"
    }
    catch {
        Write-Host "時報制御受付を開始できません: $($_.Exception.Message)"
        $script:timeSignalControlListener = $null
    }
}

function Send-TimeSignalControlResponse {
    param(
        [Net.Sockets.TcpClient]$Client,
        [string]$Body,
        [string]$Status = "200 OK"
    )

    $writer = [IO.StreamWriter]::new($Client.GetStream(), [Text.UTF8Encoding]::new($false))
    try {
        $bytes = [Text.Encoding]::UTF8.GetByteCount($Body)
        $writer.Write("HTTP/1.1 $Status`r`n")
        $writer.Write("Content-Type: application/json; charset=utf-8`r`n")
        $writer.Write("Access-Control-Allow-Origin: *`r`n")
        $writer.Write("Access-Control-Allow-Methods: GET, OPTIONS`r`n")
        $writer.Write("Access-Control-Allow-Headers: Content-Type`r`n")
        $writer.Write("Cache-Control: no-store`r`n")
        $writer.Write("Content-Length: $bytes`r`n")
        $writer.Write("Connection: close`r`n`r`n")
        $writer.Write($Body)
        $writer.Flush()
    }
    finally {
        $writer.Dispose()
        $Client.Close()
    }
}

function Invoke-TimeSignalControlRequest {
    param([string]$Target)

    $uri = [Uri]::new("http://127.0.0.1:$timeSignalControlPort$Target")
    if ($uri.AbsolutePath -eq "/time-signal/resume") {
        Clear-TimeSignalPause
        return Get-TimeSignalPauseStatusJson
    }

    if ($uri.AbsolutePath -eq "/time-signal/pause") {
        $minutesText = if ($uri.Query -match "minutes=([^&]+)") { [Uri]::UnescapeDataString($matches[1]) } else { "" }
        $untilMsText = if ($uri.Query -match "untilMs=([^&]+)") { [Uri]::UnescapeDataString($matches[1]) } else { "" }
        $now = Get-Date
        if (Test-TimeSignalQuietHours -Now $now) {
            Clear-TimeSignalPause
            return Get-TimeSignalPauseStatusJson
        }

        $reset = Get-TimeSignalResetTime -Now $now
        $until = $reset
        if ($untilMsText) {
            $until = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$untilMsText).LocalDateTime
            if ($until -le $now) { $until = $now.AddMinutes(1) }
            if ($until -gt $reset) { $until = $reset }
        }
        elseif ($minutesText -and $minutesText -ne "day") {
            $minutes = [int]$minutesText
            $until = $now.AddMinutes($minutes)
            if ($until -gt $reset) { $until = $reset }
        }
        Save-TimeSignalPauseUntil -Until $until
        return Get-TimeSignalPauseStatusJson
    }

    return Get-TimeSignalPauseStatusJson
}

function Process-TimeSignalControlRequests {
    if (-not $script:timeSignalControlListener) { return }

    while ($script:timeSignalControlListener.Pending()) {
        $client = $script:timeSignalControlListener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 1000
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            if (-not $requestLine) {
                Send-TimeSignalControlResponse -Client $client -Body "{}" -Status "400 Bad Request"
                continue
            }

            $parts = $requestLine.Split(" ")
            if ($parts[0] -eq "OPTIONS") {
                Send-TimeSignalControlResponse -Client $client -Body "{}"
                continue
            }
            if ($parts[0] -ne "GET" -or $parts.Count -lt 2) {
                Send-TimeSignalControlResponse -Client $client -Body "{}" -Status "405 Method Not Allowed"
                continue
            }

            $body = Invoke-TimeSignalControlRequest -Target $parts[1]
            Send-TimeSignalControlResponse -Client $client -Body $body
        }
        catch {
            try {
                Send-TimeSignalControlResponse -Client $client -Body '{"error":"request failed"}' -Status "500 Internal Server Error"
            }
            catch {}
        }
    }
}
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
# 再生関数（MP3対応・EEW割り込み・時報停止対応）
# 再生関数（MP3対応・EEW割り込み・時報停止対応）
function Play-Sound {
    param ([string]$filePath)

    if (Test-EewPriorityActive) {
        Write-Host "EEW優先中のため時報をスキップ"
        return $false
    }
    if (Test-TimeSignalPaused) {
        Write-Host "時報一時停止中のためスキップ"
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
        if (Test-EewPriorityActive -or (Test-TimeSignalPaused)) {
            $player.Stop()
            $player.Close()
            return $false
        }
        Start-Sleep -Milliseconds 50
    }

    $duration = [int]$player.NaturalDuration.TimeSpan.TotalMilliseconds
    $elapsed = 0
    while ($elapsed -lt $duration) {
        if (Test-EewPriorityActive -or (Test-TimeSignalPaused)) {
            Write-Host "EEW優先または時報一時停止のため時報再生を停止"
            $player.Stop()
            $player.Close()
            return $false
        }
        Process-TimeSignalControlRequests
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

function Test-TimeSignalQuietHours {
    param([datetime]$Now)

    $minutesFromMidnight = ($Now.Hour * 60) + $Now.Minute
    return $minutesFromMidnight -ge 5 -and $minutesFromMidnight -lt 355
}

function Test-TimeSignalControlDisabled {
    param([datetime]$Now)

    $minutesFromMidnight = ($Now.Hour * 60) + $Now.Minute
    return $minutesFromMidnight -ge 0 -and $minutesFromMidnight -lt 355
}
function Start-Time-Signal {
    $now = Get-Date
    $hour = $now.Hour
    $minute = $now.Minute
    $second = $now.Second

    if (Test-EewPriorityActive) { return }
    if ($second -ne 0) { return }
    if ($minute % 10 -ne 0) { return }
    if (Test-TimeSignalQuietHours -Now $now) {
        $script:lastPlayedMinute = -1
        Write-Host "夜間消音時間帯のため時報をスキップ"
        return
    }

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
Start-TimeSignalControlServer
while ($true) {
    Process-TimeSignalControlRequests
    Start-Time-Signal

    # 次の秒境界まで待つ
    $now = Get-Date
    $sleep = 1000 - $now.Millisecond
    Start-Sleep -Milliseconds $sleep
}