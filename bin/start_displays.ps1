$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

$projectDir = Split-Path -Path $PSScriptRoot -Parent
$edgeCandidates = @(
    (Get-Command "msedge.exe" -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and
    (Test-Path -LiteralPath $_ -PathType Leaf)
} | Select-Object -Unique
$edgePath = $edgeCandidates | Select-Object -First 1

if (-not $edgePath) {
    throw "Microsoft Edge was not found."
}

$screens = @([System.Windows.Forms.Screen]::AllScreens)
$pcScreen = $screens | Where-Object { $_.Primary } | Select-Object -First 1
$externalScreen = $screens |
    Where-Object { -not $_.Primary } |
    Select-Object -First 1

if (-not $pcScreen) {
    $pcScreen = $screens | Select-Object -First 1
}
if (-not $externalScreen) {
    $externalScreen = $pcScreen
}

$profileRoot = Join-Path -Path $env:TEMP -ChildPath "snow-link-drone-edge"
$indexProfile = Join-Path -Path $profileRoot -ChildPath "index"
$linerProfile = Join-Path -Path $profileRoot -ChildPath "imazato-liner"
New-Item -Path $indexProfile -ItemType Directory -Force | Out-Null
New-Item -Path $linerProfile -ItemType Directory -Force | Out-Null

function Start-KioskWindow {
    param(
        [string]$PagePath,
        [System.Windows.Forms.Screen]$Screen,
        [string]$ProfilePath
    )

    $pageUrl = ([Uri](Resolve-Path -LiteralPath $PagePath).Path).AbsoluteUri
    $bounds = $Screen.Bounds
    $arguments = @(
        "--kiosk=`"$pageUrl`"",
        "--edge-kiosk-type=fullscreen",
        "--no-first-run",
        "--disable-infobars",
        "--window-position=$($bounds.X),$($bounds.Y)",
        "--window-size=$($bounds.Width),$($bounds.Height)",
        "--user-data-dir=`"$ProfilePath`""
    )

    Start-Process `
        -FilePath $edgePath `
        -ArgumentList $arguments `
        -WindowStyle Normal
}

Start-KioskWindow `
    -PagePath (Join-Path $projectDir "index.html") `
    -Screen $externalScreen `
    -ProfilePath $indexProfile

Start-Sleep -Seconds 2

Start-KioskWindow `
    -PagePath (Join-Path $projectDir "imazato-liner.html") `
    -Screen $pcScreen `
    -ProfilePath $linerProfile
