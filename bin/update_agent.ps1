param(
    [string]$WatchPath = "",
    [int]$PollSeconds = 0,
    [switch]$RunOnce,
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

$projectDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path -Path $projectDir -ChildPath "temp"
$updateRoot = Join-Path -Path $projectDir -ChildPath "_update"
$packageDir = Join-Path -Path $updateRoot -ChildPath "packages"
$stagingRoot = Join-Path -Path $updateRoot -ChildPath "staging"
$backupRoot = Join-Path -Path $updateRoot -ChildPath "backup"
$logDir = Join-Path -Path $updateRoot -ChildPath "logs"
$configPath = Join-Path -Path $PSScriptRoot -ChildPath "update_config.json"
$defaultWatchPath = "C:\infomation_system_updates\inbox"
$mutex = [Threading.Mutex]::new($false, "Global\InfomationSystemUpdateAgent")
$authToken = ""

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-IsChildPath {
    param(
        [string]$ParentPath,
        [string]$ChildPath
    )

    $parentFull = [IO.Path]::GetFullPath($ParentPath).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($ChildPath).TrimEnd('\') + '\'
    return $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)
}

function Remove-DirectorySafe {
    param(
        [string]$Path,
        [string]$AllowedParent
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-IsChildPath -ParentPath $AllowedParent -ChildPath $Path)) {
        throw "削除対象が許可範囲外です: $Path"
    }

    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Write-UpdateLog {
    param([string]$Message)

    Ensure-Directory $logDir
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Add-Content -LiteralPath (Join-Path $logDir "update_agent.log") -Value $line -Encoding UTF8
}

function Write-UpdateStatus {
    param(
        [string]$Message,
        [string]$Detail = ""
    )

    Ensure-Directory $tempDir
    $payload = [ordered]@{
        message = $Message
        detail = $Detail
        updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Compress
    $javascript = "window.systemUpdateStatus = $payload;"
    [IO.File]::WriteAllText(
        (Join-Path $tempDir "update_status.js"),
        $javascript,
        [Text.UTF8Encoding]::new($false)
    )
    Write-UpdateLog "$Message $Detail"
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return @{}
    }

    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath |
            ConvertFrom-Json
    }
    catch {
        Write-UpdateLog "update_config.json 縺ｮ隱ｭ縺ｿ霎ｼ縺ｿ縺ｫ螟ｱ謨励＠縺ｾ縺励◆: $($_.Exception.Message)"
        return @{}
    }
}

function Resolve-Setting {
    $config = Read-Config

    if ([string]::IsNullOrWhiteSpace($WatchPath)) {
        $script:WatchPath = if (-not [string]::IsNullOrWhiteSpace($config.watchPath)) {
            [string]$config.watchPath
        }
        else {
            $defaultWatchPath
        }
    }

    if ($PollSeconds -le 0) {
        $script:PollSeconds = if ([int]$config.pollSeconds -gt 0) {
            [int]$config.pollSeconds
        }
        else {
            5
        }
    }

    $script:authToken = [string]$config.authToken
}

function Get-SignatureText {
    param([object]$Value)

    return ($Value.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$($_.Value)"
    }) -join "`n"
}

function Get-HmacSha256Hex {
    param(
        [string]$Text,
        [string]$Secret
    )

    $keyBytes = [Text.Encoding]::UTF8.GetBytes($Secret)
    $textBytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hmac = [Security.Cryptography.HMACSHA256]::new($keyBytes)
    try {
        return (($hmac.ComputeHash($textBytes) | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    }
    finally {
        $hmac.Dispose()
    }
}

function Test-UpdateRequestSignature {
    param([object]$Request)

    if ([string]::IsNullOrWhiteSpace($authToken)) {
        throw "authToken が未設定のため、更新を適用しません。"
    }
    if ([string]::IsNullOrWhiteSpace($Request.signature)) {
        throw "更新要求に署名がありません。"
    }

    $signedValue = [ordered]@{
        schemaVersion = [int]$Request.schemaVersion
        package = [string]$Request.package
        sha256 = [string]$Request.sha256
        createdAt = [string]$Request.createdAt
        sourceComputer = [string]$Request.sourceComputer
        restartAfterUpdate = [bool]$Request.restartAfterUpdate
    }
    $expected = Get-HmacSha256Hex `
        -Text (Get-SignatureText -Value $signedValue) `
        -Secret $authToken

    if ($expected -ne [string]$Request.signature) {
        throw "更新要求の署名が一致しません。"
    }
}


function Add-TaskbarApiType {
    if ("InfomationSystemUpdateTaskbar" -as [type]) { return }

    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class InfomationSystemUpdateTaskbar {
    [DllImport("user32.dll")]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")]
    public static extern IntPtr FindWindowEx(IntPtr parentHandle, IntPtr childAfter, string className, string windowTitle);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
}

function Hide-WindowsTaskbar {
    Add-TaskbarApiType
    $hide = 0
    $primary = [InfomationSystemUpdateTaskbar]::FindWindow("Shell_TrayWnd", $null)
    if ($primary -ne [IntPtr]::Zero) {
        [void][InfomationSystemUpdateTaskbar]::ShowWindow($primary, $hide)
    }

    $secondary = [IntPtr]::Zero
    do {
        $secondary = [InfomationSystemUpdateTaskbar]::FindWindowEx([IntPtr]::Zero, $secondary, "Shell_SecondaryTrayWnd", $null)
        if ($secondary -ne [IntPtr]::Zero) {
            [void][InfomationSystemUpdateTaskbar]::ShowWindow($secondary, $hide)
        }
    } while ($secondary -ne [IntPtr]::Zero)
}
function Get-EdgePath {
    $candidates = @(
        (Get-Command "msedge.exe" -ErrorAction SilentlyContinue).Source,
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        (Test-Path -LiteralPath $_ -PathType Leaf)
    } | Select-Object -Unique

    return $candidates | Select-Object -First 1
}

function Stop-SignageProcesses {
    $scriptNames = @(
        "fetch_news.ps1",
        "fetch_bus.ps1",
        "fetch_imazato_liner.ps1",
        "time_signal.ps1",
        "network_check.ps1",
        "earthquake_monitor.ps1",
        "play_eew_sequence.ps1"
    )

    Get-CimInstance Win32_Process |
        Where-Object {
            $commandLine = [string]$_.CommandLine
            $_.Name -eq "powershell.exe" -and
            ($scriptNames | Where-Object { $commandLine -like "*$_*" }) -and
            $commandLine -notlike "*update_agent.ps1*"
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq "msedge.exe" -and
            ([string]$_.CommandLine -like "*infomation_system*" -or
             [string]$_.CommandLine -like "*snow-link-drone-edge*")
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Start-UpdateScreen {
    Hide-WindowsTaskbar
    $edgePath = Get-EdgePath
    if (-not $edgePath) { return }

    $pagePath = Join-Path -Path $projectDir -ChildPath "update.html"
    if (-not (Test-Path -LiteralPath $pagePath -PathType Leaf)) { return }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screens = @([System.Windows.Forms.Screen]::AllScreens)
    }
    catch {
        $screens = @()
    }

    if ($screens.Count -eq 0) {
        $screens = @($null)
    }

    $pageUrl = ([Uri](Resolve-Path -LiteralPath $pagePath).Path).AbsoluteUri
    for ($i = 0; $i -lt $screens.Count; $i++) {
        $profilePath = Join-Path `
            -Path $env:TEMP `
            -ChildPath "snow-link-drone-edge-update-$i"
        Ensure-Directory $profilePath

        $arguments = @(
            "--kiosk `"$pageUrl`"",
            "--edge-kiosk-type=fullscreen",
            "--no-first-run",
            "--disable-infobars",
            "--noerrdialogs",
            "--disable-session-crashed-bubble",
            "--allow-file-access-from-files",
            "--user-data-dir=`"$profilePath`""
        )

        if ($screens[$i]) {
            $bounds = $screens[$i].Bounds
            $arguments += "--window-position=$($bounds.X),$($bounds.Y)"
            $arguments += "--window-size=$($bounds.Width),$($bounds.Height)"
        }

        Start-Process `
            -FilePath $edgePath `
            -ArgumentList ($arguments -join " ") `
            -WindowStyle Normal
    }
}
function Backup-CurrentSystem {
    $backupDir = Join-Path -Path $backupRoot -ChildPath (Get-Date -Format "yyyyMMdd_HHmmss")
    Ensure-Directory $backupDir

    $excludeRootNames = @(".git", "_update", "temp")
    Get-ChildItem -LiteralPath $projectDir -Force |
        Where-Object { $excludeRootNames -notcontains $_.Name } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $backupDir -Recurse -Force
        }

    return $backupDir
}

function Apply-MonitorCss {
    $source = Join-Path -Path $projectDir -ChildPath "package\monitor_css"
    $destination = Join-Path -Path $projectDir -ChildPath "monitor_css"

    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        return
    }

    Remove-DirectorySafe -Path $destination -AllowedParent $projectDir
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

function Wait-PackageStable {
    param([string]$Path)

    $previousLength = -1
    for ($i = 0; $i -lt 12; $i++) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Start-Sleep -Seconds 1
            continue
        }

        $currentLength = (Get-Item -LiteralPath $Path).Length
        if ($currentLength -gt 0 -and $currentLength -eq $previousLength) {
            return
        }

        $previousLength = $currentLength
        Start-Sleep -Seconds 1
    }

    throw "更新パッケージのコピー完了を確認できませんでした: $Path"
}

function Complete-RequestFile {
    param(
        [string]$ReadyPath,
        [string]$Status
    )

    $targetPath = [IO.Path]::ChangeExtension($ReadyPath, "$Status.json")
    Move-Item -LiteralPath $ReadyPath -Destination $targetPath -Force
}

function Invoke-SystemUpdate {
    param([string]$ReadyPath)

    Write-UpdateStatus -Message "アップデート準備中" -Detail "更新要求を確認しています。"
    $request = Get-Content -Raw -Encoding UTF8 -LiteralPath $ReadyPath |
        ConvertFrom-Json

    if ([int]$request.schemaVersion -ne 1) {
        throw "未対応の更新要求バージョンです。"
    }
    if ([string]::IsNullOrWhiteSpace($request.package)) {
        throw "更新要求に package がありません。"
    }

    $packageName = [IO.Path]::GetFileName([string]$request.package)
    if ($packageName -ne [string]$request.package -or
        $packageName -notlike "infomation_system_update_*.zip") {
        throw "更新パッケージ名が不正です。"
    }
    Test-UpdateRequestSignature -Request $request

    $sourceZip = Join-Path -Path (Split-Path -Path $ReadyPath -Parent) -ChildPath $packageName
    Wait-PackageStable -Path $sourceZip

    if (-not [string]::IsNullOrWhiteSpace($request.sha256)) {
        $actualHash = (Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash
        if ($actualHash -ne [string]$request.sha256) {
            throw "更新パッケージのハッシュが一致しません。"
        }
    }

    Ensure-Directory $packageDir
    Ensure-Directory $stagingRoot
    Ensure-Directory $backupRoot

    $localZip = Join-Path -Path $packageDir -ChildPath $packageName
    Copy-Item -LiteralPath $sourceZip -Destination $localZip -Force

    Stop-SignageProcesses
    Write-UpdateStatus -Message "アップデート中" -Detail "画面と取得処理を停止しました。"
    Start-UpdateScreen

    $backupDir = Backup-CurrentSystem
    Write-UpdateStatus -Message "アップデート中" -Detail "現在のシステムをバックアップしました: $backupDir"

    $stagingDir = Join-Path -Path $stagingRoot -ChildPath ([IO.Path]::GetFileNameWithoutExtension($localZip))
    Remove-DirectorySafe -Path $stagingDir -AllowedParent $stagingRoot
    Ensure-Directory $stagingDir
    Expand-Archive -LiteralPath $localZip -DestinationPath $stagingDir -Force

    Write-UpdateStatus -Message "アップデート中" -Detail "新しいシステムファイルをコピーしています。"
    Get-ChildItem -LiteralPath $stagingDir -Force |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $projectDir -Recurse -Force
        }

    Apply-MonitorCss
    Remove-DirectorySafe -Path $tempDir -AllowedParent $projectDir
    Ensure-Directory $tempDir

    Write-UpdateStatus -Message "アップデート完了" -Detail "再起動しています。"
    Complete-RequestFile -ReadyPath $ReadyPath -Status "done"

    $shouldRestart = -not $NoRestart
    if ($request.PSObject.Properties.Name -contains "restartAfterUpdate") {
        $shouldRestart = $shouldRestart -and ([bool]$request.restartAfterUpdate)
    }

    if ($shouldRestart) {
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    }
}

try {
    if (-not $mutex.WaitOne(0, $false)) {
        exit 0
    }

    Resolve-Setting
    Ensure-Directory $WatchPath
    Ensure-Directory $updateRoot
    Write-UpdateLog "譖ｴ譁ｰ蠕・ｩ溘ｒ髢句ｧ九＠縺ｾ縺励◆: $WatchPath"
    if ([string]::IsNullOrWhiteSpace($authToken)) {
        Write-UpdateLog "authToken が未設定のため、更新適用は無効です。"
    }

    while ($true) {
        $requests = Get-ChildItem -LiteralPath $WatchPath -Filter "*.ready.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime

        foreach ($requestFile in $requests) {
            try {
                Invoke-SystemUpdate -ReadyPath $requestFile.FullName
            }
            catch {
                Write-UpdateStatus -Message "アップデート失敗" -Detail $_.Exception.Message
                Write-UpdateLog "譖ｴ譁ｰ螟ｱ謨・ $($_.Exception.Message)"
                Complete-RequestFile -ReadyPath $requestFile.FullName -Status "failed"
            }
        }

        if ($RunOnce) { break }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() | Out-Null } catch {}
        $mutex.Dispose()
    }
}
