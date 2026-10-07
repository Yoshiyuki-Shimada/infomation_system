param(
    [switch]$RunOnce,
    [switch]$WakeOnce
)

$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tempDir = Join-Path -Path $rootDir -ChildPath "temp"
$logPath = Join-Path -Path $tempDir -ChildPath "display_power_control.log"
$manualAwakePath = Join-Path -Path $tempDir -ChildPath "display_manual_awake.flag"
$emergencyAwakeUntilPath = Join-Path -Path $tempDir -ChildPath "display_emergency_awake_until.txt"
$emergencyWakeRequestPath = Join-Path -Path $tempDir -ChildPath "display_emergency_wake_request.txt"
$script:MonitorIsOff = $false
$script:LastOffSignalAt = $null
$script:LastEmergencyWakeSignalAt = $null
$script:LastEmergencyWakeRequestId = ""

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

    [DllImport("user32.dll")]
    public static extern void keybd_event(
        byte bVk,
        byte bScan,
        uint dwFlags,
        UIntPtr dwExtraInfo);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

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
    $hwndBroadcast = [IntPtr]::new(0xffff)
    $wmSysCommand = 0x0112
    $scMonitorPower = 0xF170
    $monitorPowerOn = -1
    $esContinuous = [uint32]2147483648
    $esSystemRequired = [uint32]0x00000001
    $esDisplayRequired = [uint32]0x00000002
    $virtualKeyShift = [byte]0x10
    $keyEventKeyUp = [uint32]0x0002

    # Windowsへ表示必須を通知し、モニター復帰と入力の両方を送る。
    [DisplayPowerNativeMethods]::SetThreadExecutionState(
        $esContinuous -bor $esSystemRequired -bor $esDisplayRequired) | Out-Null
    [DisplayPowerNativeMethods]::PostMessage(
        $hwndBroadcast,
        $wmSysCommand,
        [IntPtr]::new($scMonitorPower),
        [IntPtr]::new($monitorPowerOn)) | Out-Null
    [DisplayPowerNativeMethods]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [DisplayPowerNativeMethods]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero)
    [DisplayPowerNativeMethods]::keybd_event($virtualKeyShift, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [DisplayPowerNativeMethods]::keybd_event($virtualKeyShift, 0, $keyEventKeyUp, [UIntPtr]::Zero)
}

function Wake-DisplayBurst {
    param([int]$Count = 3)

    for ($index = 0; $index -lt $Count; $index++) {
        Wake-Display
        if ($index -lt ($Count - 1)) {
            Start-Sleep -Milliseconds 250
        }
    }
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

function Test-EmergencyDisplayAwake {
    param([datetime]$Now)

    if (-not (Test-Path -LiteralPath $emergencyAwakeUntilPath -PathType Leaf)) {
        return $false
    }

    try {
        $untilText = Get-Content -Raw -Encoding UTF8 -LiteralPath $emergencyAwakeUntilPath
        $until = [datetime]::MinValue
        if ([datetime]::TryParse($untilText.Trim(), [ref]$until) -and $Now -lt $until) {
            return $true
        }
    }
    catch {
        Write-DisplayPowerLog "emergency wake state read error: $($_.Exception.Message)"
    }

    Remove-Item -LiteralPath $emergencyAwakeUntilPath -Force -ErrorAction SilentlyContinue
    return $false
}

function Get-EmergencyWakeRequestId {
    if (-not (Test-Path -LiteralPath $emergencyWakeRequestPath -PathType Leaf)) {
        return ""
    }

    try {
        return (Get-Content -Raw -Encoding UTF8 -LiteralPath $emergencyWakeRequestPath).Trim()
    }
    catch {
        Write-DisplayPowerLog "emergency wake request read error: $($_.Exception.Message)"
        return ""
    }
}

function Invoke-DisplayPowerCheck {
    $now = Get-Date
    $shouldTurnOff = Get-ShouldTurnDisplayOff -Now $now

    if ($shouldTurnOff) {
        if (Test-EmergencyDisplayAwake -Now $now) {
            $requestId = Get-EmergencyWakeRequestId
            $isNewRequest = $requestId -and $requestId -ne $script:LastEmergencyWakeRequestId
            $secondsSinceEmergencyWake = if ($script:LastEmergencyWakeSignalAt) {
                ($now - $script:LastEmergencyWakeSignalAt).TotalSeconds
            } else {
                [double]::PositiveInfinity
            }

            # 手動消灯は別プロセスから実行されるため、内部状態に依存せず再点灯する。
            if ($isNewRequest -or $script:MonitorIsOff -or $secondsSinceEmergencyWake -ge 5) {
                if ($isNewRequest) {
                    Wake-DisplayBurst
                }
                else {
                    Wake-Display
                }
                $script:MonitorIsOff = $false
                $script:LastOffSignalAt = $null
                $script:LastEmergencyWakeSignalAt = $now
                if ($requestId) {
                    $script:LastEmergencyWakeRequestId = $requestId
                }
                Write-DisplayPowerLog "emergency information display wake signal sent request=$requestId new=$isNewRequest"
            }
            return
        }

        $script:LastEmergencyWakeSignalAt = $null

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

    Start-Sleep -Seconds 2
}
