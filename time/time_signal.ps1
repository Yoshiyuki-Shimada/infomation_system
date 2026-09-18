[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 実行ディレクトリ基準
Set-Location $PSScriptRoot
$basePath = Join-Path $PSScriptRoot "audio"
$projectDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path $projectDir "temp"
$eewPriorityPath = Join-Path $projectDir "temp\eew_audio_priority.lock"
$timeSignalPausePath = Join-Path $projectDir "temp\time_signal_pause_until.txt"
$timeSignalIntervalPath = Join-Path $projectDir "temp\time_signal_interval_minutes.txt"
$timeSignalVolume = 1.0
$displayManualAwakePath = Join-Path $projectDir "temp\display_manual_awake.flag"
$timeSignalControlPort = 18765
$timeSignalControlListener = $null
$sqliteHelperPath = Join-Path $projectDir "network_check\network_sqlite.ps1"
. $sqliteHelperPath
$networkSqlitePaths = Get-NetworkSqlitePaths -ProjectDir $projectDir
$runtimeDbDir = $networkSqlitePaths.RuntimeDir
$networkDbPath = $networkSqlitePaths.DatabasePath
$legacyNetworkJsonlPath = $networkSqlitePaths.LegacyJsonlPath
$sqliteExePath = $networkSqlitePaths.SqliteExePath
$networkSummaryPath = Join-Path $runtimeDbDir "network_status_summary.json"
$networkHistoryErrorMessage = ""


Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class TimeSignalDisplayPowerNativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(
        IntPtr hWnd,
        int Msg,
        IntPtr wParam,
        IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern void mouse_event(
        int dwFlags,
        int dx,
        int dy,
        int dwData,
        UIntPtr dwExtraInfo);
}
"@

function Send-DisplayPowerOffCommand {
    $hwndBroadcast = [IntPtr]::new(0xffff)
    $wmSysCommand = 0x0112
    $scMonitorPower = 0xF170
    $monitorPowerOff = 2

    [TimeSignalDisplayPowerNativeMethods]::PostMessage(
        $hwndBroadcast,
        $wmSysCommand,
        [IntPtr]::new($scMonitorPower),
        [IntPtr]::new($monitorPowerOff)) | Out-Null
}

function Send-DisplayWakeCommand {
    [TimeSignalDisplayPowerNativeMethods]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [TimeSignalDisplayPowerNativeMethods]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero)
}

function Set-DisplayManualAwake {
    if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    }
    [IO.File]::WriteAllText($displayManualAwakePath, (Get-Date).ToString("o"), [Text.UTF8Encoding]::new($false))
}

function Clear-DisplayManualAwake {
    Remove-Item -LiteralPath $displayManualAwakePath -Force -ErrorAction SilentlyContinue
}

function Get-DisplayPowerStatusJson {
    $payload = [ordered]@{
        ok = $true
        manualAwake = (Test-Path -LiteralPath $displayManualAwakePath -PathType Leaf)
        now = (Get-Date).ToString("o")
    }
    return ($payload | ConvertTo-Json -Compress)
}
function Get-JsonResponse {
    param([object]$Payload)

    return ($Payload | ConvertTo-Json -Depth 12 -Compress)
}


function Read-NetworkSummary {
    if (-not (Test-Path -LiteralPath $networkSummaryPath -PathType Leaf)) {
        return [ordered]@{
            updateTime = (Get-Date).ToString("o")
            online = $false
            offlineMode = $true
            targets = @()
            dataUpdates = @()
            today = [ordered]@{
                date = (Get-Date).ToString("yyyy-MM-dd")
                offlineCount = 0
                maxConsecutiveLoss = 0
                totalOfflineSeconds = 0
                lastLossAt = $null
            }
        }
    }

    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $networkSummaryPath | ConvertFrom-Json
    }
    catch {
        return [ordered]@{
            updateTime = (Get-Date).ToString("o")
            online = $false
            offlineMode = $true
            targets = @()
            dataUpdates = @()
            today = [ordered]@{
                date = (Get-Date).ToString("yyyy-MM-dd")
                offlineCount = 0
                maxConsecutiveLoss = 0
                totalOfflineSeconds = 0
                lastLossAt = $null
            }
            error = $_.Exception.Message
        }
    }
}

function Get-QueryValue {
    param(
        [Uri]$Uri,
        [string]$Name
    )

    $escapedName = [regex]::Escape($Name)
    if ($Uri.Query -match "(?:\?|&)$escapedName=([^&]+)") {
        return [Uri]::UnescapeDataString($matches[1])
    }

    return ""
}

function ConvertTo-NetworkDateTime {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $text = $Value.Trim()
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $formats = @(
        "yyyy-MM-ddTHH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy/MM/dd HH:mm:ss",
        "yyyy-MM-ddTHH:mm:ss.fffK",
        "yyyy-MM-ddTHH:mm:ssK",
        "o",
        "s"
    )

    foreach ($format in $formats) {
        $parsedExact = [datetime]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeLocal
        if ($format -eq "o" -or $format.EndsWith("K")) {
            $styles = [Globalization.DateTimeStyles]::RoundtripKind
        }
        if ([datetime]::TryParseExact($text, $format, $culture, $styles, [ref]$parsedExact)) {
            return $parsedExact
        }
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, $culture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        return $parsed
    }

    return $null
}
function Read-NetworkHistory {
    param(
        [string]$TargetId,
        [int]$Limit = 1200,
        [int]$Offset = 0,
        [string]$SortOrder = "desc",
        [string]$ResultFilter,
        [string]$Start,
        [string]$End
    )

    if (-not (Test-Path -LiteralPath $runtimeDbDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $runtimeDbDir | Out-Null
    }

    Initialize-NetworkSqliteDatabase `
        -RuntimeDir $runtimeDbDir `
        -DatabasePath $networkDbPath `
        -SqliteExePath $sqliteExePath
    Import-LegacyNetworkJsonlToSqlite `
        -SqliteExePath $sqliteExePath `
        -DatabasePath $networkDbPath `
        -LegacyJsonlPath $legacyNetworkJsonlPath

    $safeLimit = [Math]::Min(50000, [Math]::Max(1, $Limit))
    $safeOffset = [Math]::Max(0, $Offset)
    $safeSortOrder = if ($SortOrder -eq "asc") { "asc" } else { "desc" }
    $startDate = ConvertTo-NetworkDateTime -Value $Start
    $endDate = ConvertTo-NetworkDateTime -Value $End
    if ($startDate -and $endDate -and $endDate -lt $startDate) { return @() }

    $script:networkHistoryErrorMessage = ""
    try {
        return @(Read-NetworkSqliteHistory `
            -SqliteExePath $sqliteExePath `
            -DatabasePath $networkDbPath `
            -TargetId $TargetId `
            -Limit $safeLimit `
            -Offset $safeOffset `
            -SortOrder $safeSortOrder `
            -ResultFilter $ResultFilter `
            -StartDate $startDate `
            -EndDate $endDate)
    }
    catch {
        $script:networkHistoryErrorMessage = $_.Exception.Message
        return @()
    }
}

function Get-NetworkStatusJson {
    param([Uri]$Uri)

    $limitText = Get-QueryValue -Uri $Uri -Name "limit"
    $offsetText = Get-QueryValue -Uri $Uri -Name "offset"
    $orderText = Get-QueryValue -Uri $Uri -Name "order"
    $targetId = Get-QueryValue -Uri $Uri -Name "target"
    $filterText = Get-QueryValue -Uri $Uri -Name "filter"
    $startText = Get-QueryValue -Uri $Uri -Name "start"
    $endText = Get-QueryValue -Uri $Uri -Name "end"
    $limit = 1200
    $offset = 0
    if ($limitText -match '^\d+$') { $limit = [int]$limitText }
    if ($offsetText -match '^\d+$') { $offset = [int]$offsetText }
    if ($orderText -ne "asc") { $orderText = "desc" }

    $historyRows = @(Read-NetworkHistory `
        -TargetId $targetId `
        -Limit $limit `
        -Offset $offset `
        -SortOrder $orderText `
        -ResultFilter $filterText `
        -Start $startText `
        -End $endText)
    $availableYears = @()
    try {
        $availableYears = @(Read-NetworkSqliteAvailableYears `
            -SqliteExePath $sqliteExePath `
            -DatabasePath $networkDbPath `
            -TargetId $targetId)
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($script:networkHistoryErrorMessage)) {
            $script:networkHistoryErrorMessage = $_.Exception.Message
        }
    }
    return Get-JsonResponse ([ordered]@{
        ok = $true
        summary = Read-NetworkSummary
        history = @($historyRows)
        hasMore = ($historyRows.Count -ge $limit)
        historyError = $script:networkHistoryErrorMessage
        availableYears = @($availableYears)
        database = [ordered]@{
            type = "SQLite"
            path = $networkDbPath
            table = "network_measurements"
            sqlite = $sqliteExePath
            exists = (Test-Path -LiteralPath $networkDbPath -PathType Leaf)
        }
    })
}

function Get-RestartAcceptedJson {
    Start-Process shutdown.exe -ArgumentList "/r /t 0" -WindowStyle Hidden
    return Get-JsonResponse ([ordered]@{
        ok = $true
        restarting = $true
        now = (Get-Date).ToString("o")
    })
}

function Get-TimeSignalIntervalMinutes {
    if (-not (Test-Path -LiteralPath $timeSignalIntervalPath -PathType Leaf)) {
        return 30
    }

    $value = 0
    if ([int]::TryParse((Get-Content -LiteralPath $timeSignalIntervalPath -Raw).Trim(), [ref]$value) -and $value -in @(10, 30)) {
        return $value
    }

    return 30
}

function Set-TimeSignalIntervalMinutes {
    param([int]$Minutes)

    if ($Minutes -notin @(10, 30)) {
        throw "時報間隔は10分または30分で指定してください。"
    }

    if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    }
    [IO.File]::WriteAllText(
        $timeSignalIntervalPath,
        [string]$Minutes,
        [Text.UTF8Encoding]::new($false)
    )
}
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
        intervalMinutes = Get-TimeSignalIntervalMinutes
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
    if ($uri.AbsolutePath -eq "/time-signal/display/off") {
        Clear-DisplayManualAwake
        Send-DisplayPowerOffCommand
        return Get-DisplayPowerStatusJson
    }

    if ($uri.AbsolutePath -eq "/time-signal/display/wake") {
        Set-DisplayManualAwake
        Send-DisplayWakeCommand
        return Get-DisplayPowerStatusJson
    }

    if ($uri.AbsolutePath -eq "/time-signal/network/status") {
        return Get-NetworkStatusJson -Uri $uri
    }


    if ($uri.AbsolutePath -eq "/time-signal/system/restart") {
        return Get-RestartAcceptedJson
    }

    if ($uri.AbsolutePath -eq "/time-signal/interval") {
        if (Test-TimeSignalControlDisabled -Now (Get-Date)) {
            return Get-TimeSignalPauseStatusJson
        }

        $minutesText = Get-QueryValue -Uri $uri -Name "minutes"
        $minutes = 0
        if (-not [int]::TryParse($minutesText, [ref]$minutes) -or $minutes -notin @(10, 30)) {
            return Get-TimeSignalPauseStatusJson
        }

        Set-TimeSignalIntervalMinutes -Minutes $minutes
        return Get-TimeSignalPauseStatusJson
    }
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
    $player.Volume = $timeSignalVolume
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
    $intervalMinutes = Get-TimeSignalIntervalMinutes

    if (Test-EewPriorityActive) { return }
    if ($second -ne 0) { return }
    if ($minute % $intervalMinutes -ne 0) { return }
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
    $titleVoice = Join-Path $hourPath "time_signal_title_voice.mp3"
    $hourJustFile = Join-Path $hourPath "time_signal_${hour}_hour_just.mp3"
    $hourFile = Join-Path $hourPath "time_signal_${hour}_hour.mp3"
    $minFile = Join-Path $minPath "time_signal_${minute}_min.mp3"

    if ($minute -eq 0) {
        if ($intervalMinutes -eq 30) {
            $random30Path = Join-Path $hourPath "random_30"
            $randomFiles = @(
                [IO.Directory]::GetFiles($random30Path, "*.mp3", [IO.SearchOption]::TopDirectoryOnly)
            )
            if ($randomFiles.Count -gt 0) {
                $randomIndex = Get-Random -Minimum 0 -Maximum $randomFiles.Count
                $randomFilePath = $randomFiles[$randomIndex]
                Write-Host "30分間隔ランダム音源: $randomFilePath"
                if (-not (Play-Sound $randomFilePath)) { return }
            }
        }
        else {
            if (-not (Play-Sound $titleJustSound)) { return }
        }

        if (-not (Play-Sound $titleVoice)) { return }
        [void](Play-Sound $hourJustFile)
        return
    }

    if ($minute -eq 30) {
        if ($intervalMinutes -eq 30) {
            $random30Path = Join-Path $hourPath "random_30"
            $randomFiles = @(
                [IO.Directory]::GetFiles($random30Path, "*.mp3", [IO.SearchOption]::TopDirectoryOnly)
            )
            if ($randomFiles.Count -gt 0) {
                $randomIndex = Get-Random -Minimum 0 -Maximum $randomFiles.Count
                $randomFilePath = $randomFiles[$randomIndex]
                Write-Host "30分間隔ランダム音源: $randomFilePath"
                if (-not (Play-Sound $randomFilePath)) { return }
            }
        }
        else {
            $title30Sound = Join-Path $hourPath "time_signal_30_title_sound.mp3"
            if (-not (Play-Sound $title30Sound)) { return }
        }

        if (-not (Play-Sound $titleVoice)) { return }
        if (-not (Play-Sound $hourFile)) { return }
        [void](Play-Sound $minFile)
        return
    }

    if ($intervalMinutes -ne 10) { return }

    $titleSoundMap = @{
        10 = Join-Path $hourPath "time_signal_10_title_sound.mp3"
        20 = Join-Path $hourPath "time_signal_20_title_sound.mp3"
        40 = Join-Path $hourPath "time_signal_40_title_sound.mp3"
        50 = Join-Path $hourPath "time_signal_50_title_sound.mp3"
    }
    $titleSound = $titleSoundMap[$minute]
    if (-not $titleSound) { return }
    if (-not (Play-Sound $titleSound)) { return }
    if (-not (Play-Sound $titleVoice)) { return }
    if (-not (Play-Sound $hourFile)) { return }
    [void](Play-Sound $minFile)
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
