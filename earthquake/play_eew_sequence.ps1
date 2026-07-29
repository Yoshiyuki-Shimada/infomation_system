param(
    [ValidateSet("Alert", "FollowUp", "Cancel")]
    [string]$Mode = "Alert",
    [string[]]$Prefs = @()
)

$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-Location $PSScriptRoot
$audioPath = Join-Path $PSScriptRoot "audio"
$projectDir = Split-Path -Path $PSScriptRoot -Parent
$eewPriorityPath = Join-Path $projectDir "temp\eew_audio_priority.lock"
Add-Type -AssemblyName presentationCore

function Play-Sound {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $player = New-Object System.Windows.Media.MediaPlayer
    $player.Open([Uri](Resolve-Path -LiteralPath $Path).Path)
    Start-Sleep -Milliseconds 120
    $player.Play()
    while (-not $player.NaturalDuration.HasTimeSpan) {
        Start-Sleep -Milliseconds 30
    }
    Start-Sleep -Milliseconds ([int]$player.NaturalDuration.TimeSpan.TotalMilliseconds)
    $player.Close()
    Start-Sleep -Milliseconds 80
}

if ($Mode -eq "Cancel") {
    Play-Sound (Join-Path $audioPath "EEW_CANCEL.mp3")
    exit
}

Play-Sound (Join-Path $audioPath "EEW_ALERT.mp3")
if ($Mode -eq "FollowUp") {
    Play-Sound (Join-Path $audioPath "EEW_OP_N.mp3")
}
else {
    Play-Sound (Join-Path $audioPath "EEW_OP.mp3")
}

$played = @{}
foreach ($pref in $Prefs) {
    $name = [string]$pref
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $candidates = @(
        $name,
        ($name -replace "[都道府県]$", ""),
        ($name -replace "地方$", "")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if ($played.ContainsKey($candidate)) { continue }
        $file = Join-Path $audioPath "$candidate.mp3"
        if (Test-Path -LiteralPath $file) {
            $played[$candidate] = $true
            Play-Sound $file
            break
        }
    }
}
Remove-Item -LiteralPath $eewPriorityPath -Force -ErrorAction SilentlyContinue
