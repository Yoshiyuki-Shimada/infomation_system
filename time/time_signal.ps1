[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 実行ディレクトリ基準
Set-Location $PSScriptRoot
$basePath = Join-Path $PSScriptRoot "audio"
$projectDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path $projectDir "temp"
$informationLogDir = Join-Path $projectDir "logs\information"
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
$timeSignalTriggerGraceSeconds = 20
$newsFetcherLauncherPath = Join-Path $projectDir "bin\start_news_fetcher.ps1"

function Write-TimeSignalLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    try {
        if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
        }
        $logPath = Join-Path $tempDir ("time_signal_{0}.log" -f (Get-Date -Format "yyyyMMdd"))
        $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    }
    catch {
        Write-Host "時報ログの書き込みに失敗しました: $($_.Exception.Message)"
    }
}


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

function Read-JavaScriptJsonVariable {
    param(
        [string]$Path,
        [string]$VariableName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    try {
        $source = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $escapedName = [Regex]::Escape($VariableName)
        $pattern = "(?s)^\s*(?:var|let|const)\s+$escapedName\s*=\s*(.+?)\s*;\s*$"
        $match = [Regex]::Match($source, $pattern)
        if (-not $match.Success) { return $null }
        return $match.Groups[1].Value | ConvertFrom-Json
    }
    catch {
        Write-TimeSignalLog -Level "WARN" -Message "情報データを読み込めませんでした ($VariableName): $($_.Exception.Message)"
        return $null
    }
}

function Get-CurrentInformationDataJson {
    $payload = [ordered]@{
        fetchStatus = Read-JavaScriptJsonVariable `
            -Path (Join-Path $tempDir "news_status.js") `
            -VariableName "signageFetchStatus"
        signageData = Read-JavaScriptJsonVariable `
            -Path (Join-Path $tempDir "news_data.js") `
            -VariableName "signageData"
        earthquakeData = Read-JavaScriptJsonVariable `
            -Path (Join-Path $tempDir "earthquake_data.js") `
            -VariableName "earthquakeData"
    }
    return ($payload | ConvertTo-Json -Depth 100 -Compress)
}

function Start-NewsFetcherIfNeeded {
    $powershellProcesses = @(
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue
    )
    $launcherProcess = $powershellProcesses |
        Where-Object {
            ([string]$_.CommandLine).IndexOf(
                "start_news_fetcher.ps1",
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        } |
        Select-Object -First 1
    if ($launcherProcess) {
        return @{ ok = $true; running = $true; started = $false }
    }

    if (-not (Test-Path -LiteralPath $newsFetcherLauncherPath -PathType Leaf)) {
        return @{
            ok      = $false
            running = $false
            started = $false
            error   = "launcher not found"
        }
    }

    # ランチャーを使わない旧プロセスは、同一ファイルへの二重書き込みを防ぐため停止する。
    $powershellProcesses |
        Where-Object {
            $commandLine = [string]$_.CommandLine
            $commandLine.IndexOf(
                "fetch_news.ps1",
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$newsFetcherLauncherPath`"" `
        -WindowStyle Hidden
    Write-TimeSignalLog -Message "情報画面からの要求でニュース取得ランチャーを起動しました。"
    return @{ ok = $true; running = $true; started = $true }
}

function Write-InformationDisplayLog {
    param([object]$DisplayData)

    if (-not (Test-Path -LiteralPath $informationLogDir -PathType Container)) {
        New-Item -Path $informationLogDir -ItemType Directory -Force | Out-Null
    }

    $now = Get-Date
    $record = [ordered]@{
        loggedAt = $now.ToString("o")
        source   = "information-system"
        display  = $DisplayData
    }
    $json = $record | ConvertTo-Json -Depth 12 -Compress
    $logPath = Join-Path $informationLogDir ("displayed_{0}.jsonl" -f $now.ToString("yyyyMMdd"))
    [IO.File]::AppendAllText(
        $logPath,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
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

    if ($uri.AbsolutePath -eq "/time-signal/information/display-log") {
        $payloadText = Get-QueryValue -Uri $uri -Name "payload"
        if ([string]::IsNullOrWhiteSpace($payloadText) -or $payloadText.Length -gt 65536) {
            return Get-JsonResponse -Payload @{ ok = $false; error = "invalid payload" }
        }

        try {
            $displayData = $payloadText | ConvertFrom-Json
            Write-InformationDisplayLog -DisplayData $displayData
            return Get-JsonResponse -Payload @{ ok = $true }
        }
        catch {
            Write-TimeSignalLog -Level "WARN" -Message "表示情報ログの保存に失敗しました: $($_.Exception.Message)"
            return Get-JsonResponse -Payload @{ ok = $false; error = "log write failed" }
        }
    }

    if ($uri.AbsolutePath -eq "/time-signal/information/start-fetcher") {
        return Get-JsonResponse -Payload (Start-NewsFetcherIfNeeded)
    }

    if ($uri.AbsolutePath -eq "/time-signal/information/current") {
        return Get-CurrentInformationDataJson
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
    param([int]$MaxRequests = 8)

    if (-not $script:timeSignalControlListener) { return }

    $processedRequests = 0
    while ($processedRequests -lt $MaxRequests -and $script:timeSignalControlListener.Pending()) {
        $processedRequests++
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
        # 書き込み直後の一時的な不完全状態はEEW優先として扱う。
        $lockAgeSeconds = ((Get-Date) - (Get-Item -LiteralPath $eewPriorityPath).LastWriteTime).TotalSeconds
        if ($lockAgeSeconds -lt 2) { return $true }

        Write-TimeSignalLog -Level "WARN" -Message "不正なEEW優先ロックを削除しました: $($_.Exception.Message)"
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
        Write-TimeSignalLog -Level "WARN" -Message "EEW優先中のため音源をスキップしました: $filePath"
        return $false
    }
    if (Test-TimeSignalPaused) {
        Write-Host "時報一時停止中のためスキップ"
        Write-TimeSignalLog -Level "INFO" -Message "時報一時停止中のため音源をスキップしました: $filePath"
        return $false
    }

    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Host "ファイルなし:$filePath"
        Write-TimeSignalLog -Level "ERROR" -Message "音源ファイルがありません: $filePath"
        return $false
    }

    Write-Host "再生:$filePath"
    $player = $null

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $filePath -ErrorAction Stop).Path
        $player = New-Object System.Windows.Media.MediaPlayer
        $player.Open([Uri]$resolvedPath)
        $player.Volume = $timeSignalVolume
        $loadStartedAt = Get-Date
        $player.Play()

        while (-not $player.NaturalDuration.HasTimeSpan) {
            if (Test-EewPriorityActive -or (Test-TimeSignalPaused)) {
                return $false
            }
            if (((Get-Date) - $loadStartedAt).TotalSeconds -ge 5) {
                throw "音源の読み込みが5秒以内に完了しませんでした。"
            }
            Start-Sleep -Milliseconds 50
        }

        $duration = [int]$player.NaturalDuration.TimeSpan.TotalMilliseconds
        $playbackTimeoutAt = (Get-Date).AddMilliseconds($duration + 5000)

        while ($player.Position.TotalMilliseconds -lt ($duration - 20)) {
            if (Test-EewPriorityActive -or (Test-TimeSignalPaused)) {
                Write-Host "EEW優先または時報一時停止のため時報再生を停止"
                return $false
            }
            if ((Get-Date) -ge $playbackTimeoutAt) {
                throw "音源の再生が規定時間内に完了しませんでした。"
            }
            # HTTP処理にかかった時間も再生時間へ含め、音源間に余分な待機を作らない。
            Process-TimeSignalControlRequests -MaxRequests 1
            $remaining = $duration - $player.Position.TotalMilliseconds
            if ($remaining -le 0) { break }
            $sleep = [Math]::Min(100, $remaining)
            Start-Sleep -Milliseconds $sleep
        }

        Write-TimeSignalLog -Message "音源を再生しました: $resolvedPath"
        return $true
    }
    catch {
        Write-Host "音源再生エラー:$filePath $($_.Exception.Message)"
        Write-TimeSignalLog -Level "ERROR" -Message "音源再生に失敗しました: $filePath / $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($player) {
            try { $player.Stop() } catch {}
            try { $player.Close() } catch {}
        }
        Start-Sleep -Milliseconds 100
    }
}

# 同じ時報枠の二重再生を防止する。
$lastHandledTimeSignalSlot = ""
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
    param([datetime]$Now = (Get-Date))

    $now = $Now
    $hour = $now.Hour
    $minute = $now.Minute
    $second = $now.Second
    $intervalMinutes = Get-TimeSignalIntervalMinutes

    if ($minute % $intervalMinutes -ne 0) { return }
    if ($second -gt $timeSignalTriggerGraceSeconds) { return }

    $slotKey = $now.ToString("yyyyMMddHHmm")
    if ($slotKey -eq $script:lastHandledTimeSignalSlot) { return }
    $script:lastHandledTimeSignalSlot = $slotKey

    if (Test-TimeSignalQuietHours -Now $now) {
        Write-Host "夜間消音時間帯のため時報をスキップ"
        Write-TimeSignalLog -Message "夜間消音時間帯のため時報をスキップしました: $($now.ToString('HH:mm:ss'))"
        return
    }
    if (Test-EewPriorityActive) {
        Write-TimeSignalLog -Level "WARN" -Message "EEW優先中のため時報をスキップしました: $($now.ToString('HH:mm:ss'))"
        return
    }
    if (Test-TimeSignalPaused) {
        Write-TimeSignalLog -Message "一時停止中のため時報をスキップしました: $($now.ToString('HH:mm:ss'))"
        return
    }

    Write-Host "===="
    Write-Host $now
    Write-TimeSignalLog -Message "時報の再生を開始します: $($now.ToString('HH:mm:ss')) / ${intervalMinutes}分間隔"

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
try {
    # 表示画面のキャッシュ状態に依存せず、常駐APIの起動時に情報取得処理を保証する。
    $fetcherStartup = Start-NewsFetcherIfNeeded
    if (-not $fetcherStartup.ok) {
        Write-TimeSignalLog -Level "WARN" -Message "ニュース取得ランチャーを起動できませんでした: $($fetcherStartup.error)"
    }
}
catch {
    # 情報取得の起動失敗で、時報・通信監視APIまで停止させない。
    Write-TimeSignalLog -Level "WARN" -Message "ニュース取得ランチャーの起動確認に失敗しました: $($_.Exception.Message)"
}

Start-TimeSignalControlServer
while ($true) {
    # HTTP制御に待たされても時報枠を逃さないよう、時報判定を先に行う。
    Start-Time-Signal
    Process-TimeSignalControlRequests

    # 次の秒境界まで待つ
    $now = Get-Date
    $sleep = 1000 - $now.Millisecond
    Start-Sleep -Milliseconds $sleep
}
