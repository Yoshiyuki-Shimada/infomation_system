param(
    [switch]$Force
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$projectDir = Split-Path -Path $PSScriptRoot -Parent
$runtimeDir = Join-Path $projectDir "database\runtime"
$tempDir = Join-Path $projectDir "temp"
$cachePath = Join-Path $projectDir "database\japanese_holidays.json"
$scriptPath = Join-Path $tempDir "holidays.js"
$sourceUrl = "https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv"

function Ensure-HolidayDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-HolidayJavaScript {
    param([object]$Payload)

    Ensure-HolidayDirectory -Path $tempDir
    $json = $Payload | ConvertTo-Json -Depth 8 -Compress
    $source = "window.japaneseHolidayData = $json;"
    [IO.File]::WriteAllText($scriptPath, $source, [Text.UTF8Encoding]::new($false))
}

function Read-HolidayCache {
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $null }

    try {
        return Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Test-HolidayCacheFresh {
    if ($Force -or -not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        return $false
    }

    return (Get-Item -LiteralPath $cachePath).LastWriteTime -ge (Get-Date).AddHours(-24)
}

function ConvertFrom-CabinetOfficeHolidayCsv {
    param([byte[]]$Bytes)

    $encoding = [Text.Encoding]::GetEncoding(932)
    $csvText = $encoding.GetString($Bytes)
    $rows = @($csvText | ConvertFrom-Csv)
    $holidays = [ordered]@{}

    foreach ($row in $rows) {
        $properties = @($row.PSObject.Properties)
        if ($properties.Count -lt 2) { continue }
        $dateText = [string]$properties[0].Value
        $name = [string]$properties[1].Value
        $date = [datetime]::MinValue
        if (-not [datetime]::TryParse($dateText, [ref]$date)) { continue }
        $holidays[$date.ToString("yyyy-MM-dd")] = $name.Trim()
    }

    return [ordered]@{
        source = $sourceUrl
        fetchedAt = (Get-Date).ToString("o")
        holidays = $holidays
    }
}

Ensure-HolidayDirectory -Path $runtimeDir
Ensure-HolidayDirectory -Path $tempDir

$payload = Read-HolidayCache
if (-not (Test-HolidayCacheFresh)) {
    try {
        $webClient = New-Object Net.WebClient
        try {
            $webClient.Headers["User-Agent"] = "InfomationSystem/1.0"
            $downloadedBytes = $webClient.DownloadData($sourceUrl)
        }
        finally {
            $webClient.Dispose()
        }
        $payload = ConvertFrom-CabinetOfficeHolidayCsv -Bytes $downloadedBytes
        $json = $payload | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($cachePath, $json, [Text.UTF8Encoding]::new($false))
    }
    catch {
        if (-not $payload) { throw }
        Write-Warning "祝日データを更新できないためキャッシュを使用します: $($_.Exception.Message)"
    }
}

if ($payload) {
    Write-HolidayJavaScript -Payload $payload
}
