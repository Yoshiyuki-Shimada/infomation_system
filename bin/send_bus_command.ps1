param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$CommandText
)

$ErrorActionPreference = "Stop"
$command = $CommandText.Trim()
$normalized = $command.ToLowerInvariant()
$isValid = (
    $normalized -match '^char (original|random)$' -or
    $normalized -match '^test bus suspension \d{4} [0-9a-z]+$' -or
    $normalized -match '^test bus delay departure \d{4} [0-9a-z]+ -\d{1,3}$' -or
    $normalized -match '^test bus delay \d{4} [0-9a-z]+ -\d{1,3}$' -or
    $normalized -match '^test bus location error \d{4} [0-9a-z]+$' -or
    $normalized -eq 'test bus clear'
)
if (-not $isValid) {
    throw "未対応のバス開発者コマンドです: $command"
}

$projectDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path $projectDir "temp"
$commandPath = Join-Path $tempDir "bus_developer_command.js"
$tempPath = "$commandPath.$([guid]::NewGuid().ToString('N')).tmp"
if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
}

$payload = [ordered]@{
    command = $command
    commandId = [guid]::NewGuid().ToString("N")
    updatedAt = (Get-Date).ToString("o")
} | ConvertTo-Json -Compress
$javascript = "window.busDeveloperRemoteCommand = $payload;"
[IO.File]::WriteAllText($tempPath, $javascript, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tempPath -Destination $commandPath -Force

Write-Host "コマンドを反映しました: $command" -ForegroundColor Green