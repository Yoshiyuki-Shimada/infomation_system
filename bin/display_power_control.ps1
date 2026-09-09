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

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll")]
    public static extern ulong GetTickCount64();
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

function Get-LastInputTime {
    $info = [DisplayPowerNativeMethods+LASTINPUTINFO]::new()
    $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([DisplayPowerNativeMethods+LASTINPUTINFO])

    if (-not [DisplayPowerNativeMethods]::GetLastInputInfo([ref]$info)) {
        return $null
    }

    $tickCycle = [uint64]4294967296
    $currentTick = [uint64]([DisplayPowerNativeMethods]::GetTickCount64() % $tickCycle)
    $lastInputTick = [uint64]$info.dwTime
    $elapsedMilliseconds = if ($currentTick -ge $lastInputTick) {
        $currentTick - $lastInputTick
    } else {
        ($tickCycle - $lastInputTick) + $currentTick
    }

    return (Get-Date).AddMilliseconds(-1 * [double]$elapsedMilliseconds)
}

function Set-ManualDisplayAwake {
    [IO.File]::WriteAllText($manualAwakePath, (Get-Date).ToString("o"), [Text.UTF8Encoding]::new($false))
}

function Test-DisplayWakeInput {
    if (-not $script:MonitorIsOff -or -not $script:LastOffSignalAt) {
        return $false
    }

    $lastInputTime = Get-LastInputTime
    if (-not $lastInputTime) {
        return $false
    }

    return $lastInputTime -gt $script:LastOffSignalAt.AddSeconds(1)
}

function Get-ShouldTurnDisplayOff {
    param([datetime]$Now)

    $minutesFromMidnight = ($Now.Hour * 60) + $Now.Minute
    return $minutesFromMidnight -ge 5 -and $minutesFromMidnight -lt 355
}

function Test-ManualDisplayAwake {
    param([datetime]$Now)

    if (-not (Test-Path -LiteralPath $manualAwakePath -PathType Leaf)) {
        return $false
    }

    if (-not (Get-ShouldTurnDisplayOff -Now $Now)) {
        Remove-Item -LiteralPath $manualAwakePath -Force -ErrorAction SilentlyContinue
        return $false
    }

    return $true
}

function Invoke-DisplayPowerCheck {
    $now = Get-Date
    $shouldTurnOff = Get-ShouldTurnDisplayOff -Now $now

    if ($shouldTurnOff) {
        if (Test-DisplayWakeInput) {
            Set-ManualDisplayAwake
            Wake-Display
            $script:MonitorIsOff = $false
            $script:LastOffSignalAt = $null
            Write-DisplayPowerLog "manual display wake requested by touch or pointer input"
            return
        }

        if (Test-ManualDisplayAwake -Now $now) {
            if ($script:MonitorIsOff) {
                Wake-Display
                $script:MonitorIsOff = $false
                $script:LastOffSignalAt = $null
                Write-DisplayPowerLog "manual display wake held during quiet hours"
            }
            return
        }

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