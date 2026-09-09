param(
    [string]$Destination = "",
    [string]$AuthToken = "",
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

$projectDir = Split-Path -Path $PSScriptRoot -Parent
$updateRoot = Join-Path -Path $projectDir -ChildPath "_update"
$outDir = Join-Path -Path $updateRoot -ChildPath "out"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$packageName = "infomation_system_update_$timestamp.zip"
$readyName = "infomation_system_update_$timestamp.ready.json"
$zipPath = Join-Path -Path $outDir -ChildPath $packageName
$configPath = Join-Path -Path $PSScriptRoot -ChildPath "update_config.json"

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Write-Utf8JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Read-AuthTokenFromConfig {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return ""
    }

    try {
        $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath |
            ConvertFrom-Json
        return [string]$config.authToken
    }
    catch {
        return ""
    }
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

if ([string]::IsNullOrWhiteSpace($AuthToken)) {
    $AuthToken = Read-AuthTokenFromConfig
}

if ([string]::IsNullOrWhiteSpace($AuthToken)) {
    throw "AuthToken が未設定です。bin\update_config.json に authToken を設定するか、-AuthToken を指定してください。"
}

Ensure-Directory $outDir
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

$excludeRootNames = @(
    ".git",
    "_update",
    "temp",
    "monitor_css",
    "document"
)

$excludeZipEntryPrefixes = @(
    "database/runtime/"
)

$excludeZipEntryNames = @(
    "bin/update_config.json"
)

function Remove-ExcludedZipEntries {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entriesToDelete = New-Object System.Collections.ArrayList
        foreach ($entry in @($zip.Entries)) {
            $entryName = $entry.FullName.Replace("\", "/")
            $isExcluded = $false

            foreach ($prefix in $excludeZipEntryPrefixes) {
                if ($entryName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isExcluded = $true
                    break
                }
            }

            if (-not $isExcluded) {
                foreach ($name in $excludeZipEntryNames) {
                    if ($entryName.Equals($name, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $isExcluded = $true
                        break
                    }
                }
            }

            if (-not $isExcluded -and $entryName -like 'document/~$*') {
                $isExcluded = $true
            }

            if ($isExcluded) {
                [void]$entriesToDelete.Add($entry)
            }
        }

        foreach ($entry in @($entriesToDelete)) {
            $entry.Delete()
        }
    }
    finally {
        $zip.Dispose()
    }
}

$stagingDir = Join-Path $updateRoot ("staging_" + $timestamp)
Ensure-Directory $stagingDir

$robocopyArgs = @(
    $projectDir,
    $stagingDir,
    "/E",
    "/COPY:DAT",
    "/DCOPY:DAT",
    "/R:1",
    "/W:1",
    "/XD",
    (Join-Path $projectDir ".git"),
    (Join-Path $projectDir "_update"),
    (Join-Path $projectDir "temp"),
    (Join-Path $projectDir "monitor_css"),
    (Join-Path $projectDir "document"),
    (Join-Path $projectDir "database\runtime"),
    "/XF",
    (Join-Path $projectDir "bin\update_config.json")
)
& robocopy.exe @robocopyArgs | Out-Null
if ($LASTEXITCODE -gt 7) {
    throw "更新パッケージ用ファイルコピーに失敗しました。robocopy exit code: $LASTEXITCODE"
}

Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $zipPath -Force
Remove-Item -LiteralPath $stagingDir -Recurse -Force
Remove-ExcludedZipEntries -Path $zipPath

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$manifest = [ordered]@{
    schemaVersion = 1
    package = $packageName
    sha256 = $hash
    createdAt = (Get-Date).ToUniversalTime().ToString("o")
    sourceComputer = $env:COMPUTERNAME
    restartAfterUpdate = -not $NoRestart
}
$manifest.signature = Get-HmacSha256Hex `
    -Text (Get-SignatureText -Value $manifest) `
    -Secret $AuthToken

$manifestPath = Join-Path -Path $outDir -ChildPath $readyName
Write-Utf8JsonFile -Path $manifestPath -Value $manifest

if (-not [string]::IsNullOrWhiteSpace($Destination)) {
    Ensure-Directory $Destination

    $destinationZip = Join-Path -Path $Destination -ChildPath $packageName
    $destinationReady = Join-Path -Path $Destination -ChildPath $readyName
    $destinationZipPart = "$destinationZip.part"
    $destinationReadyPart = "$destinationReady.part"

    Copy-Item -LiteralPath $zipPath -Destination $destinationZipPart -Force
    Move-Item -LiteralPath $destinationZipPart -Destination $destinationZip -Force

    Copy-Item -LiteralPath $manifestPath -Destination $destinationReadyPart -Force
    Move-Item -LiteralPath $destinationReadyPart -Destination $destinationReady -Force

    Write-Host "更新パッケージを送信しました: $destinationZip"
    Write-Host "更新要求を送信しました: $destinationReady"
}
else {
    Write-Host "更新パッケージを作成しました: $zipPath"
    Write-Host "更新要求ファイルを作成しました: $manifestPath"
}
