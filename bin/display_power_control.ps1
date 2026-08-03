param(
    [switch]$RunOnce,
    [switch]$WakeOnce
)

$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tempDir = Join-Path -Path $rootDir -ChildPath "temp"
$logPath = Join-Path -Path $tempDir -ChildPath "display_power_control.log"
$script:MonitorIsOff = $false
$script:LastOffSignalAt = $null

if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class DisplayPowerNativeMethods
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

function Write-DisplayPowerLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $logPath -Value "$timestamp $Message" -Encoding UTF8
}

function Send-MonitorOffCommand {
    $hwndBroadcast = [IntPtr]::new(0xffff)
    $wmSysCommand = 0x0112
    $scMonitorPower = 0xF170
    $monitorPowerOff = 2

    [DisplayPowerNativeMethods]::PostMessage(
        $hwndBroadcast,
        $wmSysCommand,
        [IntPtr]::new($scMonitorPower),
        [IntPtr]::new($monitorPowerOff)) | Out-Null
}

function Wake-Display {
    # A tiny mouse move wakes displays without waiting on window messages.
    [DisplayPowerNativeMethods]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [DisplayPowerNativeMethods]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero)
}

function Get-ShouldTurnDisplayOff {
    param([datetime]$Now)

    $minutesFromMidnight = ($Now.Hour * 60) + $Now.Minute
    return $minutesFromMidnight -ge 5 -and $minutesFromMidnight -lt 355
}

function Invoke-DisplayPowerCheck {
    $now = Get-Date
    $shouldTurnOff = Get-ShouldTurnDisplayOff -Now $now

    if ($shouldTurnOff) {
        $secondsSinceLastOff = if ($script:LastOffSignalAt) {
            ($now - $script:LastOffSignalAt).TotalSeconds
        } else {
            [double]::PositiveInfinity
        }

        if (-not $script:MonitorIsOff -or $secondsSinceLastOff -ge 60) {
            Send-MonitorOffCommand
            $script:MonitorIsOff = $true
            $script:LastOffSignalAt = $now
            Write-DisplayPowerLog "display off signal sent"
        }
        return
    }

    if ($script:MonitorIsOff) {
        Wake-Display
        $script:MonitorIsOff = $false
        $script:LastOffSignalAt = $null
        Write-DisplayPowerLog "display wake signal sent"
        return
    }

    if ($now.Hour -eq 5 -and $now.Minute -eq 55 -and $now.Second -lt 20) {
        Wake-Display
        Write-DisplayPowerLog "display wake keepalive sent"
    }
}

if ($WakeOnce) {
    Wake-Display
    Write-DisplayPowerLog "display wake once sent"
    exit 0
}

Write-DisplayPowerLog "display power control started"

while ($true) {
    try {
        Invoke-DisplayPowerCheck
    } catch {
        Write-DisplayPowerLog "error: $($_.Exception.Message)"
    }

    if ($RunOnce) {
        break
    }

    Start-Sleep -Seconds 10
}