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
    "monitor_css"
)

$sourceItems = Get-ChildItem -LiteralPath $projectDir -Force |
    Where-Object { $excludeRootNames -notcontains $_.Name }

Compress-Archive -Path $sourceItems.FullName -DestinationPath $zipPath -Force

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
