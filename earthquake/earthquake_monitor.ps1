param(
    [ValidateRange(1, 60)]
    [int]$RestartDelaySeconds = 3
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

$projectDir = Split-Path -Path $PSScriptRoot -Parent
$runtimeDir = Join-Path $PSScriptRoot "SignageBridgeRuntime"
$bridgePath = Join-Path $runtimeDir "EarthquakeSignageBridge.exe"
$logDir = Join-Path $projectDir "logs"
$logPath = Join-Path $logDir "earthquake_bridge.log"

if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

function Write-MonitorLog {
    param([string]$Message)

    $line = "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss.fff') $Message"
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
    Write-MonitorLog "P2P地震速報ブリッジが見つかりません: $bridgePath"
    exit 1
}

Write-MonitorLog "P2P地震速報ブリッジの監視を開始します。"

while ($true) {
    try {
        $process = Start-Process `
            -FilePath $bridgePath `
            -ArgumentList @($projectDir) `
            -WorkingDirectory $runtimeDir `
            -WindowStyle Hidden `
            -PassThru

        Write-MonitorLog "P2P地震速報ブリッジを起動しました。PID=$($process.Id)"
        $process.WaitForExit()
        Write-MonitorLog "P2P地震速報ブリッジが終了しました。終了コード=$($process.ExitCode)"
    }
    catch {
        Write-MonitorLog "P2P地震速報ブリッジの起動または監視に失敗しました: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $RestartDelaySeconds
}
