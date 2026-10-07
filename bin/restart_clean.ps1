$ErrorActionPreference = "Stop"

$projectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tempDir = Join-Path $projectDir "temp"
$currentProcessId = $PID

function Stop-RuntimeProcesses {
    $scriptNames = @(
        "start_news_fetcher.ps1",
        "fetch_news.ps1",
        "fetch_bus.ps1",
        "fetch_imazato_liner.ps1",
        "time_signal.ps1",
        "network_check.ps1",
        "display_power_control.ps1",
        "earthquake_monitor.ps1",
        "play_eew_sequence.ps1"
    )

    Get-CimInstance Win32_Process |
        Where-Object {
            $commandLine = [string]$_.CommandLine
            $_.ProcessId -ne $currentProcessId -and
            $_.Name -eq "powershell.exe" -and
            ($scriptNames | Where-Object { $commandLine -like "*$_*" })
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

    Get-Process -Name "EarthquakeSignageBridge", "WpfClient" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Clear-RuntimeData {
    if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        return
    }

    Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 1
Stop-RuntimeProcesses
Clear-RuntimeData
Start-Process shutdown.exe -ArgumentList "/r /t 0" -WindowStyle Hidden
