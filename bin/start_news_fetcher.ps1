param(
    [int]$NetworkRetrySeconds = 5,
    [int]$ProcessRetrySeconds = 10
)

$ErrorActionPreference = "Stop"

$projectDir = Split-Path -Path $PSScriptRoot -Parent
$fetchScriptPath = Join-Path $projectDir "app\fetch_news.ps1"
$logDir = Join-Path $projectDir "logs\information"
$logPath = Join-Path $logDir ("fetcher_{0}.jsonl" -f (Get-Date -Format "yyyyMMdd"))
$networkProbeHost = "api.open-meteo.com"

function Ensure-LogDirectory {
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
}

function Write-LauncherLog {
    param([string]$Message)

    Ensure-LogDirectory
    $record = [ordered]@{
        loggedAt = (Get-Date).ToString("o")
        source   = "start_news_fetcher.ps1"
        message  = $Message
    }
    $line = $record | ConvertTo-Json -Compress
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Test-InternetReady {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($networkProbeHost, 443)
        if (-not $connectTask.Wait(5000)) { return $false }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Wait-ForInternet {
    $waitingLogged = $false
    while (-not (Test-InternetReady)) {
        if (-not $waitingLogged) {
            Write-LauncherLog "インターネット接続待機中"
            $waitingLogged = $true
        }
        Start-Sleep -Seconds $NetworkRetrySeconds
    }

    if ($waitingLogged) {
        Write-LauncherLog "インターネット接続を確認"
    }
}

if (-not (Test-Path -LiteralPath $fetchScriptPath -PathType Leaf)) {
    throw "情報取得スクリプトが見つかりません: $fetchScriptPath"
}

while ($true) {
    Wait-ForInternet
    Write-LauncherLog "fetch_news.ps1 を起動"

    try {
        & $fetchScriptPath
        Write-LauncherLog "fetch_news.ps1 が終了したため再起動します"
    }
    catch {
        Write-LauncherLog "fetch_news.ps1 が異常終了しました: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $ProcessRetrySeconds
}
