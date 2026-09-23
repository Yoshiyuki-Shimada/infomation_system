# ============================================================================== 
# Snow Link Drone - Network Monitoring System
# File Name: network_check.ps1
# Description: PingとDNS名前解決でインターネット・ローカル通信を常時監視します。
# ============================================================================== 

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 同一DBへ複数の監視プロセスが記録しないよう、二重起動を防止する。
$monitorMutex = [Threading.Mutex]::new($false, "Global\InfomationSystemNetworkMonitor")
$monitorMutexAcquired = $false
try {
    $monitorMutexAcquired = $monitorMutex.WaitOne(0, $false)
}
catch [Threading.AbandonedMutexException] {
    $monitorMutexAcquired = $true
}
if (-not $monitorMutexAcquired) {
    $monitorMutex.Dispose()
    exit 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootPath = Split-Path -Parent $scriptDir
$tempPath = Join-Path $rootPath "temp"
$appPath = Join-Path $rootPath "app"
$sqliteHelperPath = Join-Path $scriptDir "network_sqlite.ps1"
. $sqliteHelperPath

$networkSqlitePaths = Get-NetworkSqlitePaths -ProjectDir $rootPath
$runtimeDbDir = $networkSqlitePaths.RuntimeDir
$networkDbPath = $networkSqlitePaths.DatabasePath
$legacyNetworkJsonlPath = $networkSqlitePaths.LegacyJsonlPath
$sqliteExePath = $networkSqlitePaths.SqliteExePath
$networkSummaryPath = Join-Path $runtimeDbDir "network_status_summary.json"
$monitorIntervalMs = 1000
$maxDbRows = 345600

$isOnline = $null
$lastDbTrimAt = Get-Date "2000-01-01"
$todayKey = (Get-Date).ToString("yyyy-MM-dd")
$todayStats = @{
    offlineCount = 0
    maxConsecutiveLoss = 0
    totalOfflineSeconds = 0
    lastLossAt = $null
}

function Ensure-RuntimeDirectory {
    if (-not (Test-Path -LiteralPath $runtimeDbDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $runtimeDbDir | Out-Null
    }
}

function Write-Utf8JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Trim-NetworkDatabase {
    $now = Get-Date
    if (($now - $script:lastDbTrimAt).TotalMinutes -lt 10) { return }
    $script:lastDbTrimAt = $now

    try {
        Trim-NetworkSqliteDatabase `
            -SqliteExePath $sqliteExePath `
            -DatabasePath $networkDbPath `
            -MaxRows $maxDbRows
    }
    catch {
        Write-Host "通信監視DBの整理に失敗: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Get-DefaultGatewayAddress {
    try {
        $configs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" -ErrorAction Stop
        foreach ($config in @($configs)) {
            foreach ($gateway in @($config.DefaultIPGateway)) {
                $gatewayText = [string]$gateway
                if ($gatewayText -match '^\d{1,3}(\.\d{1,3}){3}$') {
                    return $gatewayText
                }
            }
        }
    }
    catch {
        Write-Host "デフォルトゲートウェイ取得失敗: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    return ""
}
function Test-WiredNetworkConnected {
    try {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
        foreach ($adapter in $adapters) {
            if ([string]$adapter.Status -eq "Up") { return $true }
        }
    }
    catch {
        Write-Host "有線接続状態取得失敗: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    return $false
}

function Test-WifiNetworkConnected {
    try {
        $output = netsh wlan show interfaces 2>$null
        foreach ($line in @($output)) {
            $text = [string]$line
            if ($text -match '^\s*State\s*:\s*connected\s*$') { return $true }
            if ($text -match '^\s*状態\s*:\s*(connected|接続|接続済み|接続されました)\s*$') { return $true }
        }
    }
    catch {
        Write-Host "Wi-Fi接続状態取得失敗: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    return $false
}

function Get-NetworkLinkStatus {
    $wired = Test-WiredNetworkConnected
    $wifi = Test-WifiNetworkConnected

    return [ordered]@{
        wiredConnected = $wired
        wifiConnected = $wifi
        connected = ($wired -or $wifi)
    }
}

function New-TargetState {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Address,
        [string]$Kind = "ping",
        [string]$DnsServer = ""
    )

    return [ordered]@{
        id = $Id
        name = $Name
        address = $Address
        kind = $Kind
        dnsServer = $DnsServer
        consecutiveFailures = 0
        consecutiveTimeouts = 0
        recentResults = New-Object System.Collections.ArrayList
        lastResult = $null
    }
}

function Get-PacketLossPercent {
    param(
        [System.Collections.IList]$Results,
        [int]$Count
    )

    if (-not $Results -or $Results.Count -eq 0) { return 0.0 }

    $startIndex = [Math]::Max(0, $Results.Count - $Count)
    $sampleCount = $Results.Count - $startIndex
    if ($sampleCount -le 0) { return 0.0 }

    $failedCount = 0
    for ($index = $startIndex; $index -lt $Results.Count; $index++) {
        if (-not [bool]$Results[$index]) { $failedCount++ }
    }

    return [Math]::Round(($failedCount / $sampleCount) * 100, 1)
}

function Get-QualityLabel {
    param(
        [double]$LossPercent,
        [int]$ConsecutiveTimeouts,
        [int]$SampleCount
    )

    if ($ConsecutiveTimeouts -ge 5) { return "通信エラー" }
    if ($SampleCount -lt 600) { return "計測中" }
    if ($LossPercent -ge 10) { return "通信が非常に不安定" }
    if ($LossPercent -ge 5) { return "通信品質異常" }
    if ($LossPercent -ge 2) { return "通信品質低下" }
    if ($LossPercent -ge 1) { return "要観察" }
    return "正常"
}
function Test-BeforeSevenOClock {
    param([string]$Timestamp)

    try {
        $date = [datetimeoffset]::Parse($Timestamp)
        return $date.LocalDateTime.Hour -lt 7
    }
    catch {
        return $false
    }
}

function Get-OfflineQualityLabel {
    param([string]$Timestamp)

    if (Test-BeforeSevenOClock -Timestamp $Timestamp) { return "通信エラー" }
    return "オフライン"
}

function Convert-PingStatusToResultName {
    param([System.Net.NetworkInformation.IPStatus]$Status)

    switch ($Status) {
        ([System.Net.NetworkInformation.IPStatus]::Success) { return "OK" }
        ([System.Net.NetworkInformation.IPStatus]::TimedOut) { return "タイムアウト" }
        ([System.Net.NetworkInformation.IPStatus]::DestinationHostUnreachable) { return "宛先到達不能" }
        ([System.Net.NetworkInformation.IPStatus]::DestinationNetworkUnreachable) { return "宛先到達不能" }
        ([System.Net.NetworkInformation.IPStatus]::DestinationPortUnreachable) { return "宛先到達不能" }
        ([System.Net.NetworkInformation.IPStatus]::DestinationProhibited) { return "宛先到達不能" }
        ([System.Net.NetworkInformation.IPStatus]::HardwareError) { return "一般エラー" }
        ([System.Net.NetworkInformation.IPStatus]::BadRoute) { return "一般エラー" }
        ([System.Net.NetworkInformation.IPStatus]::BadDestination) { return "一般エラー" }
        default { return "その他エラー" }
    }
}

function Wait-UntilTimestamp {
    param([datetime]$Timestamp)

    while ($true) {
        $remainingMs = ($Timestamp - (Get-Date)).TotalMilliseconds
        if ($remainingMs -le 0) { return }
        Start-Sleep -Milliseconds ([Math]::Max(1, [Math]::Ceiling($remainingMs)))
    }
}

function Convert-NslookupOutputToResultName {
    param(
        [string]$Output,
        [int]$ExitCode
    )

    if ($Output -match '(?i)timed[ -]?out|timeout|タイムアウト|時間切れ') {
        return "タイムアウト"
    }
    if ($Output -match "(?i)can't find|non-existent domain|nxdomain|no response from server|server failed|到達できません|応答がありません|見つかりません") {
        return "宛先到達不能"
    }
    if ($ExitCode -ne 0) { return "一般エラー" }
    if ($Output -match '(?im)^\s*(Name|名前)\s*:') { return "OK" }
    return "その他エラー"
}

function Start-NslookupMeasurement {
    param(
        [string]$TargetId,
        [string]$TargetName,
        [string]$QueryName,
        [string]$DnsServer = "",
        [object]$MeasurementTimestamp = $null
    )

    $timestamp = if ($null -eq $MeasurementTimestamp) { Get-Date } else { [datetime]$MeasurementTimestamp }
    $arguments = @($QueryName)
    if (-not [string]::IsNullOrWhiteSpace($DnsServer)) {
        $arguments += $DnsServer
    }
    $commandText = "nslookup " + ($arguments -join " ")
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    $context = [pscustomobject]@{
        kind = "nslookup"
        targetId = $TargetId
        targetName = $TargetName
        address = if ([string]::IsNullOrWhiteSpace($DnsServer)) { $QueryName } else { "$QueryName / $DnsServer" }
        timestamp = $timestamp
        commandText = $commandText
        stopwatch = $stopwatch
        process = $null
        stdoutTask = $null
        stderrTask = $null
        immediateMeasurement = $null
    }

    try {
        # PowerShellのNativeCommandErrorを介さず、プロセスの出力を文字列として直接取得する。
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = "nslookup.exe"
        $startInfo.Arguments = $arguments -join " "
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $oemEncoding = [Text.Encoding]::GetEncoding(
            [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        )
        $startInfo.StandardOutputEncoding = $oemEncoding
        $startInfo.StandardErrorEncoding = $oemEncoding

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void]$process.Start()

        $context.process = $process
        $context.stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $context.stderrTask = $process.StandardError.ReadToEndAsync()
    }
    catch {
        $stopwatch.Stop()
        if ($null -ne $process) { $process.Dispose() }
        $context.immediateMeasurement = [ordered]@{
            timestamp = $timestamp.ToString("o")
            targetId = $TargetId
            targetName = $TargetName
            address = $context.address
            result = "一般エラー"
            ok = $false
            responseTimeMs = $null
            errorDetail = "$commandText`r`n$($_.Exception.Message)"
        }
    }

    return $context
}

function Complete-NslookupMeasurement {
    param([object]$Context)

    if ($null -ne $Context.immediateMeasurement) {
        return $Context.immediateMeasurement
    }

    if (-not $Context.process.HasExited -and ((Get-Date) - $Context.timestamp).TotalSeconds -lt 30) {
        return $null
    }

    $forcedTimeout = -not $Context.process.HasExited
    try {
        if ($forcedTimeout) { $Context.process.Kill() }

        $Context.process.WaitForExit()
        $stdout = $Context.stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $Context.stderrTask.GetAwaiter().GetResult().Trim()
        $exitCode = $Context.process.ExitCode
        $Context.stopwatch.Stop()

        $outputParts = New-Object System.Collections.ArrayList
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            [void]$outputParts.Add($stdout)
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            [void]$outputParts.Add($stderr)
        }
        $output = $outputParts -join "`r`n"
        $resultName = if ($forcedTimeout) {
            "タイムアウト"
        } else {
            Convert-NslookupOutputToResultName -Output $output -ExitCode $exitCode
        }
        $isOk = $resultName -eq "OK"

        $detailParts = New-Object System.Collections.ArrayList
        [void]$detailParts.Add($Context.commandText)
        [void]$detailParts.Add("Exit code: $exitCode")
        if ($forcedTimeout) {
            [void]$detailParts.Add("監視プロセスが30秒以内に終了しなかったため停止しました。")
        }
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            [void]$detailParts.Add("Standard output:`r`n$stdout")
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            [void]$detailParts.Add("Standard error:`r`n$stderr")
        }

        return [ordered]@{
            timestamp = $Context.timestamp.ToString("o")
            targetId = $Context.targetId
            targetName = $Context.targetName
            address = $Context.address
            result = $resultName
            ok = $isOk
            responseTimeMs = if ($isOk) { [int]$Context.stopwatch.ElapsedMilliseconds } else { $null }
            errorDetail = $detailParts -join "`r`n"
        }
    }
    catch {
        if ($Context.stopwatch.IsRunning) { $Context.stopwatch.Stop() }
        return [ordered]@{
            timestamp = $Context.timestamp.ToString("o")
            targetId = $Context.targetId
            targetName = $Context.targetName
            address = $Context.address
            result = "一般エラー"
            ok = $false
            responseTimeMs = $null
            errorDetail = "$($Context.commandText)`r`n$($_.Exception.Message)"
        }
    }
    finally {
        if ($Context.stopwatch.IsRunning) { $Context.stopwatch.Stop() }
        if ($null -ne $Context.process) { $Context.process.Dispose() }
    }
}

function Invoke-NslookupMeasurement {
    param(
        [string]$TargetId,
        [string]$TargetName,
        [string]$QueryName,
        [string]$DnsServer = ""
    )

    $context = Start-NslookupMeasurement `
        -TargetId $TargetId `
        -TargetName $TargetName `
        -QueryName $QueryName `
        -DnsServer $DnsServer
    while ($true) {
        $measurement = Complete-NslookupMeasurement -Context $context
        if ($null -ne $measurement) { return $measurement }
        Start-Sleep -Milliseconds 20
    }
}

function Start-PingMeasurement {
    param(
        [string]$TargetId,
        [string]$TargetName,
        [string]$Address,
        [object]$MeasurementTimestamp = $null
    )

    $timestamp = if ($null -eq $MeasurementTimestamp) { Get-Date } else { [datetime]$MeasurementTimestamp }
    $ping = $null
    $context = [pscustomobject]@{
        kind = "ping"
        targetId = $TargetId
        targetName = $TargetName
        address = $Address
        timestamp = $timestamp
        ping = $null
        task = $null
        immediateMeasurement = $null
    }

    if ([string]::IsNullOrWhiteSpace($Address)) {
        $context.immediateMeasurement = [ordered]@{
            timestamp = $timestamp.ToString("o")
            targetId = $TargetId
            targetName = $TargetName
            address = ""
            result = "一般エラー"
            ok = $false
            responseTimeMs = $null
            errorDetail = "監視対象のIPアドレスを取得できませんでした。"
        }
        return $context
    }

    try {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $context.ping = $ping
        $context.task = $ping.SendPingAsync($Address)
    }
    catch {
        if ($null -ne $ping) { $ping.Dispose() }
        $context.immediateMeasurement = [ordered]@{
            timestamp = $timestamp.ToString("o")
            targetId = $TargetId
            targetName = $TargetName
            address = $Address
            result = "一般エラー"
            ok = $false
            responseTimeMs = $null
            errorDetail = $_.Exception.Message
        }
    }

    return $context
}

function Complete-PingMeasurement {
    param([object]$Context)

    if ($null -ne $Context.immediateMeasurement) {
        return $Context.immediateMeasurement
    }
    if (-not $Context.task.IsCompleted) {
        if (((Get-Date) - $Context.timestamp).TotalSeconds -lt 30) {
            return $null
        }
        $Context.ping.Dispose()
        return [ordered]@{
            timestamp = $Context.timestamp.ToString("o")
            targetId = $Context.targetId
            targetName = $Context.targetName
            address = $Context.address
            result = "タイムアウト"
            ok = $false
            responseTimeMs = $null
            errorDetail = "Ping処理が30秒以内に終了しなかったため停止しました。"
        }
    }

    try {
        $reply = $Context.task.GetAwaiter().GetResult()
        $resultName = Convert-PingStatusToResultName -Status $reply.Status
        $responseTime = if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { [int]$reply.RoundtripTime } else { $null }

        return [ordered]@{
            timestamp = $Context.timestamp.ToString("o")
            targetId = $Context.targetId
            targetName = $Context.targetName
            address = $Context.address
            result = $resultName
            ok = ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
            responseTimeMs = $responseTime
            errorDetail = "Ping status: $($reply.Status)"
        }
    }
    catch [System.Net.NetworkInformation.PingException] {
        return [ordered]@{
            timestamp = $Context.timestamp.ToString("o")
            targetId = $Context.targetId
            targetName = $Context.targetName
            address = $Context.address
            result = "一般エラー"
            ok = $false
            responseTimeMs = $null
            errorDetail = $_.Exception.Message
        }
    }
    catch {
        return [ordered]@{
            timestamp = $Context.timestamp.ToString("o")
            targetId = $Context.targetId
            targetName = $Context.targetName
            address = $Context.address
            result = "その他エラー"
            ok = $false
            responseTimeMs = $null
            errorDetail = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $Context.ping) { $Context.ping.Dispose() }
    }
}

function Invoke-NetworkMeasurement {
    param(
        [string]$TargetId,
        [string]$TargetName,
        [string]$Address
    )

    $context = Start-PingMeasurement `
        -TargetId $TargetId `
        -TargetName $TargetName `
        -Address $Address
    while ($true) {
        $measurement = Complete-PingMeasurement -Context $context
        if ($null -ne $measurement) { return $measurement }
        Start-Sleep -Milliseconds 20
    }
}

function Stop-PendingMeasurementContexts {
    param([System.Collections.IList]$Contexts)

    foreach ($context in @($Contexts)) {
        try {
            if ($context.kind -eq "nslookup" -and $null -ne $context.process) {
                if (-not $context.process.HasExited) { $context.process.Kill() }
                $context.process.Dispose()
            }
            if ($context.kind -eq "ping" -and $null -ne $context.ping) {
                $context.ping.Dispose()
            }
        }
        catch {}
    }
    $Contexts.Clear()
}
function New-OfflineMeasurement {
    param(
        [string]$TargetId,
        [string]$TargetName,
        [string]$Address,
        [object]$MeasurementTimestamp = $null
    )

    $timestamp = if ($null -eq $MeasurementTimestamp) { Get-Date } else { [datetime]$MeasurementTimestamp }
    return [ordered]@{
        timestamp = $timestamp.ToString("o")
        targetId = $TargetId
        targetName = $TargetName
        address = $Address
        result = "オフライン"
        ok = $false
        responseTimeMs = $null
        errorDetail = "有線LANとWi-Fiがどちらも未接続です。"
    }
}

function Update-TargetState {
    param(
        [hashtable]$TargetStates,
        [object]$Measurement
    )

    $targetId = [string]$Measurement.targetId
    if (-not $TargetStates.ContainsKey($targetId)) {
        $TargetStates[$targetId] = New-TargetState `
            -Id $targetId `
            -Name ([string]$Measurement.targetName) `
            -Address ([string]$Measurement.address)
    }

    $state = $TargetStates[$targetId]
    $state.address = [string]$Measurement.address
    $state.lastResult = $Measurement

    if ([bool]$Measurement.ok) {
        $state.consecutiveFailures = 0
        $state.consecutiveTimeouts = 0
    }
    else {
        $state.consecutiveFailures = [int]$state.consecutiveFailures + 1
        if ([string]$Measurement.result -eq "タイムアウト") {
            $state.consecutiveTimeouts = [int]$state.consecutiveTimeouts + 1
        } else {
            $state.consecutiveTimeouts = 0
        }
    }

    if ([string]$Measurement.result -ne "オフライン") {
        [void]$state.recentResults.Add([bool]$Measurement.ok)
    }
    while ($state.recentResults.Count -gt 600) {
        $state.recentResults.RemoveAt(0)
    }

    $loss100 = Get-PacketLossPercent -Results $state.recentResults -Count 100
    $loss600 = Get-PacketLossPercent -Results $state.recentResults -Count 600
    $loss100SampleCount = [Math]::Min(100, $state.recentResults.Count)
    $loss600SampleCount = [Math]::Min(600, $state.recentResults.Count)
    $quality = Get-QualityLabel -LossPercent $loss600 -ConsecutiveTimeouts ([int]$state.consecutiveTimeouts) -SampleCount $loss600SampleCount
    if ([string]$Measurement.result -eq "オフライン") { $quality = Get-OfflineQualityLabel -Timestamp ([string]$Measurement.timestamp) }

    $Measurement.consecutiveFailures = [int]$state.consecutiveFailures
    $Measurement.consecutiveTimeouts = [int]$state.consecutiveTimeouts
    $Measurement.loss100Percent = $loss100
    $Measurement.loss600Percent = $loss600
    $Measurement.loss100SampleCount = $loss100SampleCount
    $Measurement.loss600SampleCount = $loss600SampleCount
    $Measurement.quality = $quality

    if (-not [bool]$Measurement.ok) {
        $script:todayStats.lastLossAt = $Measurement.timestamp
        $script:todayStats.maxConsecutiveLoss = [Math]::Max(
            [int]$script:todayStats.maxConsecutiveLoss,
            [int]$state.consecutiveFailures
        )
    }
}

function Get-OnlineDataIntervalText {
    param(
        [string]$FilePath,
        [string]$DefaultInterval
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $DefaultInterval
    }

    try {
        $content = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ($content -match '"pollIntervalSeconds"\s*:\s*(\d+)') {
            return "$($matches[1])秒"
        }
        if ($content -match 'pollIntervalSeconds\s*:\s*(\d+)') {
            return "$($matches[1])秒"
        }
    }
    catch {}

    return $DefaultInterval
}

function Get-DataUpdateInfo {
    $items = @(
        @{ name = "一般路線バス"; file = "bus_online.js"; interval = "30秒"; dynamicInterval = $true },
        @{ name = "いまざとライナー"; file = "imazato_liner_online.js"; interval = "30秒"; dynamicInterval = $true },
        @{ name = "オンラインインフォメーション情報"; file = "news_data.js"; interval = "300秒（5分）"; dynamicInterval = $false }
    )
    $result = New-Object System.Collections.ArrayList

    foreach ($item in $items) {
        $filePath = Join-Path $tempPath $item.file
        $lastUpdated = $null
        $interval = [string]$item.interval
        if (Test-Path -LiteralPath $filePath -PathType Leaf) {
            $lastUpdated = (Get-Item -LiteralPath $filePath).LastWriteTime.ToString("yyyy/MM/dd HH:mm:ss")
        }
        if ([bool]$item.dynamicInterval) {
            $interval = Get-OnlineDataIntervalText -FilePath $filePath -DefaultInterval $interval
        }

        [void]$result.Add([ordered]@{
            name = $item.name
            updateInterval = $interval
            lastUpdated = $lastUpdated
        })
    }

    return @($result)
}

function Get-TargetSummary {
    param([hashtable]$TargetStates)

    $result = New-Object System.Collections.ArrayList
    $targetOrder = @{
        internet = 0
        gateway = 1
        "dns-default" = 2
        "dns-google" = 3
    }
    $orderedStates = @($TargetStates.Values | Sort-Object {
        $id = [string]$_.id
        if ($targetOrder.ContainsKey($id)) { return [int]$targetOrder[$id] }
        return 99
    })
    $addedTargetIds = @{}

    foreach ($state in $orderedStates) {
        $targetId = [string]$state.id
        if ($addedTargetIds.ContainsKey($targetId)) { continue }
        $addedTargetIds[$targetId] = $true

        $loss100 = Get-PacketLossPercent -Results $state.recentResults -Count 100
        $loss600 = Get-PacketLossPercent -Results $state.recentResults -Count 600
        $loss100SampleCount = [Math]::Min(100, $state.recentResults.Count)
        $loss600SampleCount = [Math]::Min(600, $state.recentResults.Count)
        $quality = Get-QualityLabel -LossPercent $loss600 -ConsecutiveTimeouts ([int]$state.consecutiveTimeouts) -SampleCount $loss600SampleCount
        $last = $state.lastResult
        if ($last -and [string]$last.result -eq "オフライン") { $quality = Get-OfflineQualityLabel -Timestamp ([string]$last.timestamp) }

        [void]$result.Add([ordered]@{
            id = $targetId
            name = $state.name
            address = $state.address
            result = if ($last) { $last.result } else { "その他エラー" }
            ok = if ($last) { [bool]$last.ok } else { $false }
            responseTimeMs = if ($last) { $last.responseTimeMs } else { $null }
            consecutiveFailures = [int]$state.consecutiveFailures
            consecutiveTimeouts = [int]$state.consecutiveTimeouts
            loss100Percent = $loss100
            loss600Percent = $loss600
            loss100SampleCount = $loss100SampleCount
            loss600SampleCount = $loss600SampleCount
            quality = $quality
            errorDetail = if ($last) { $last.errorDetail } else { "測定前です。" }
            timestamp = if ($last) { $last.timestamp } else { $null }
        })
    }

    return @($result)
}

function Save-NetworkSummary {
    param(
        [hashtable]$TargetStates,
        [bool]$OfflineMode,
        [object]$LinkStatus
    )

    Ensure-RuntimeDirectory
    $summary = [ordered]@{
        updateTime = (Get-Date).ToString("o")
        online = -not $OfflineMode
        offlineMode = $OfflineMode
        linkStatus = $LinkStatus
        targets = Get-TargetSummary -TargetStates $TargetStates
        dataUpdates = Get-DataUpdateInfo
        today = [ordered]@{
            date = (Get-Date).ToString("yyyy-MM-dd")
            offlineCount = [int]$script:todayStats.offlineCount
            maxConsecutiveLoss = [int]$script:todayStats.maxConsecutiveLoss
            totalOfflineSeconds = [int]$script:todayStats.totalOfflineSeconds
            lastLossAt = $script:todayStats.lastLossAt
        }
    }

    Write-Utf8JsonFile -Path $networkSummaryPath -Value $summary
}

function Stop-OnlineDataFetchers {
    $scriptNames = @(
        "start_news_fetcher.ps1",
        "fetch_news.ps1",
        "fetch_bus.ps1",
        "fetch_imazato_liner.ps1"
    )
    foreach ($scriptName in $scriptNames) {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$scriptName*" } |
            ForEach-Object {
                Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
            }
    }
}

function Clear-OnlineTempData {
    if (-not (Test-Path -LiteralPath $tempPath -PathType Container)) { return }

    Get-ChildItem -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Start-OnlineDataFetchers {
    Stop-OnlineDataFetchers

    $newsLauncherPath = Join-Path $rootPath "bin\start_news_fetcher.ps1"
    if (Test-Path -LiteralPath $newsLauncherPath -PathType Leaf) {
        Start-Process powershell `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$newsLauncherPath`"" `
            -WindowStyle Hidden
    }

    foreach ($scriptName in @("fetch_bus.ps1", "fetch_imazato_liner.ps1")) {
        $scriptPath = Join-Path $appPath $scriptName
        if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
            Start-Process powershell `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" `
                -WindowStyle Hidden
        }
    }
}

function Test-SystemOffline {
    param([object]$LinkStatus)

    if (-not $LinkStatus) { return $true }
    return -not [bool]$LinkStatus.connected
}

Ensure-RuntimeDirectory
Initialize-NetworkSqliteDatabase `
    -RuntimeDir $runtimeDbDir `
    -DatabasePath $networkDbPath `
    -SqliteExePath $sqliteExePath
Import-LegacyNetworkJsonlToSqlite `
    -SqliteExePath $sqliteExePath `
    -DatabasePath $networkDbPath `
    -LegacyJsonlPath $legacyNetworkJsonlPath
Remove-InvalidDnsPingMeasurements `
    -SqliteExePath $sqliteExePath `
    -DatabasePath $networkDbPath

$gatewayAddress = Get-DefaultGatewayAddress
$targetStates = @{
    internet = New-TargetState -Id "internet" -Name "インターネット" -Address "8.8.8.8"
    "dns-default" = New-TargetState `
        -Id "dns-default" `
        -Name "DNS名前解決（システム既定）" `
        -Address "google.com" `
        -Kind "nslookup"
    "dns-google" = New-TargetState `
        -Id "dns-google" `
        -Name "DNS名前解決（Google DNS）" `
        -Address "google.com / 8.8.8.8" `
        -Kind "nslookup" `
        -DnsServer "8.8.8.8"
}
if (-not [string]::IsNullOrWhiteSpace($gatewayAddress)) {
    $targetStates.gateway = New-TargetState -Id "gateway" -Name "ローカルネットワーク（デフォルトゲートウェイ）" -Address $gatewayAddress
}

Write-Host "Snow Link Drone - Network monitoring started..." -ForegroundColor Cyan

$pendingMeasurements = New-Object System.Collections.ArrayList
$measurementOrder = @("internet", "gateway", "dns-default", "dns-google")
$lastTargetLaunchTimes = @{}
$previousLoopStartedAt = $null

while ($true) {
    if ($null -ne $previousLoopStartedAt) {
        Wait-UntilTimestamp -Timestamp $previousLoopStartedAt.AddMilliseconds($monitorIntervalMs)
    }
    $loopStartedAt = Get-Date
    $previousLoopStartedAt = $loopStartedAt
    $currentDayKey = $loopStartedAt.ToString("yyyy-MM-dd")
    if ($currentDayKey -ne $script:todayKey) {
        $script:todayKey = $currentDayKey
        $script:todayStats = @{
            offlineCount = 0
            maxConsecutiveLoss = 0
            totalOfflineSeconds = 0
            lastLossAt = $null
        }
    }

    $latestGatewayAddress = Get-DefaultGatewayAddress
    if (-not [string]::IsNullOrWhiteSpace($latestGatewayAddress)) {
        if (-not $targetStates.ContainsKey("gateway")) {
            $targetStates.gateway = New-TargetState `
                -Id "gateway" `
                -Name "ローカルネットワーク（デフォルトゲートウェイ）" `
                -Address $latestGatewayAddress
        }
        $targetStates.gateway.address = $latestGatewayAddress
    }

    $linkStatus = Get-NetworkLinkStatus
    $measurements = New-Object System.Collections.ArrayList
    $orderedTargetStates = @($targetStates.Values | Sort-Object {
        $index = [Array]::IndexOf($measurementOrder, [string]$_.id)
        if ($index -ge 0) { return $index }
        return 99
    })

    if ([bool]$linkStatus.connected) {
        # 各監視コマンドは毎秒開始し、完了待ちで次回の測定開始を遅らせない。
        foreach ($state in $orderedTargetStates) {
            $targetId = [string]$state.id
            if ($lastTargetLaunchTimes.ContainsKey($targetId)) {
                Wait-UntilTimestamp -Timestamp $lastTargetLaunchTimes[$targetId].AddMilliseconds($monitorIntervalMs)
            }
            $measurementTimestamp = Get-Date

            if ([string]$state.kind -eq "nslookup") {
                $context = Start-NslookupMeasurement `
                    -TargetId $targetId `
                    -TargetName ([string]$state.name) `
                    -QueryName "google.com" `
                    -DnsServer ([string]$state.dnsServer) `
                    -MeasurementTimestamp $measurementTimestamp
            }
            else {
                $context = Start-PingMeasurement `
                    -TargetId $targetId `
                    -TargetName ([string]$state.name) `
                    -Address ([string]$state.address) `
                    -MeasurementTimestamp $measurementTimestamp
            }
            $lastTargetLaunchTimes[$targetId] = $measurementTimestamp
            [void]$pendingMeasurements.Add($context)
        }

        # 同一対象は開始順に確定し、遅れて完了した結果で履歴の順序が逆転しないようにする。
        $blockedTargetIds = @{}
        $completedContexts = New-Object System.Collections.ArrayList
        foreach ($context in @($pendingMeasurements.ToArray())) {
            $targetId = [string]$context.targetId
            if ($blockedTargetIds.ContainsKey($targetId)) { continue }

            $measurement = if ([string]$context.kind -eq "nslookup") {
                Complete-NslookupMeasurement -Context $context
            }
            else {
                Complete-PingMeasurement -Context $context
            }
            if ($null -eq $measurement) {
                $blockedTargetIds[$targetId] = $true
                continue
            }

            [void]$measurements.Add($measurement)
            [void]$completedContexts.Add($context)
        }
        foreach ($context in @($completedContexts.ToArray())) {
            [void]$pendingMeasurements.Remove($context)
        }
    }
    else {
        # 切断時は実行中のコマンドを破棄し、各対象のオフライン結果を毎秒記録する。
        Stop-PendingMeasurementContexts -Contexts $pendingMeasurements
        foreach ($state in $orderedTargetStates) {
            $measurement = New-OfflineMeasurement `
                -TargetId ([string]$state.id) `
                -TargetName ([string]$state.name) `
                -Address ([string]$state.address) `
                -MeasurementTimestamp $loopStartedAt
            [void]$measurements.Add($measurement)
        }
    }

    $orderedMeasurements = @($measurements.ToArray() | Sort-Object {
        [DateTimeOffset]::Parse([string]$_.timestamp)
    })
    foreach ($measurement in $orderedMeasurements) {
        Update-TargetState -TargetStates $targetStates -Measurement $measurement
    }
    if ($orderedMeasurements.Count -gt 0) {
        Add-NetworkSqliteMeasurements `
            -SqliteExePath $sqliteExePath `
            -DatabasePath $networkDbPath `
            -Measurements $orderedMeasurements
    }

    $offlineMode = Test-SystemOffline -LinkStatus $linkStatus
    if ($offlineMode) {
        $script:todayStats.totalOfflineSeconds = [int]$script:todayStats.totalOfflineSeconds + 1
    }

    Save-NetworkSummary -TargetStates $targetStates -OfflineMode $offlineMode -LinkStatus $linkStatus
    Trim-NetworkDatabase

    if ($offlineMode -and $isOnline -ne $false) {
        Stop-OnlineDataFetchers
        Clear-OnlineTempData
        $script:todayStats.offlineCount = [int]$script:todayStats.offlineCount + 1
        $isOnline = $false
    }
    elseif ((-not $offlineMode) -and $isOnline -ne $true) {
        Start-OnlineDataFetchers
        $isOnline = $true
    }

}
