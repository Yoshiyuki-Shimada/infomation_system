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

$profileRoot = Join-Path -Path $env:TEMP -ChildPath "snow-link-drone-edge"
$indexProfile = Join-Path -Path $profileRoot -ChildPath "index"
$linerProfile = Join-Path -Path $profileRoot -ChildPath "imazato-liner"

# サイネージ用に起動したEdgeだけ閉じる。普段使いのEdgeは触らない。
Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -eq "msedge.exe" -and
        ($_.CommandLine -like "*$profileRoot*" -or
         $_.CommandLine -like "*infomation_system*" -or
         $_.CommandLine -like "*index.html*" -or
         $_.CommandLine -like "*imazato-liner.html*")
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Seconds 1

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

    # Edge kiosk は「--kiosk URL」の形で渡す。--kiosk="URL" だと環境によりURLを拾えずInPrivate開始画面になることがある。
    $argumentLine = @(
        "--kiosk `"$pageUrl`"",
        "--edge-kiosk-type=fullscreen",
        "--no-first-run",
        "--disable-infobars",
        "--noerrdialogs",
        "--disable-session-crashed-bubble",
        "--autoplay-policy=no-user-gesture-required",
        "--allow-file-access-from-files",
        "--window-position=$($bounds.X),$($bounds.Y)",
        "--window-size=$($bounds.Width),$($bounds.Height)",
        "--user-data-dir=`"$ProfilePath`""
    ) -join " "

    Start-Process `
        -FilePath $edgePath `
        -ArgumentList $argumentLine `
        -WindowStyle Normal
}

# テレビ/外部画面: メイン画面 index.html
Start-KioskWindow `
    -PagePath (Join-Path $projectDir "index.html") `
    -Screen $externalScreen `
    -ProfilePath $indexProfile

Start-Sleep -Seconds 2

# PC側: 今里ライナー画面
Start-KioskWindow `
    -PagePath (Join-Path $projectDir "imazato-liner.html") `
    -Screen $pcScreen `
    -ProfilePath $linerProfile