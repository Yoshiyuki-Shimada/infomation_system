param(
    [switch]$RunOnce
)

$ErrorActionPreference = "Stop"

$parentDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path -Path $parentDir -ChildPath "temp"
$filePath = Join-Path -Path $tempDir -ChildPath "bus_online.js"
$temporaryPath = "$filePath.tmp"

$northUrl = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=676&poleCdSpecified=90&lang=0"
$southUrl = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=676&poleCdSpecified=80&lang=0"
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path -LiteralPath $tempDir)) {
    New-Item -Path $tempDir -ItemType Directory | Out-Null
}

while ($true) {
    try {
        $northHtml = (Invoke-WebRequest -Uri $northUrl -UserAgent $userAgent -UseBasicParsing -TimeoutSec 15).Content
        $southHtml = (Invoke-WebRequest -Uri $southUrl -UserAgent $userAgent -UseBasicParsing -TimeoutSec 15).Content

        if ([string]::IsNullOrWhiteSpace($northHtml) -or [string]::IsNullOrWhiteSpace($southHtml)) {
            throw "取得したHTMLが空です。"
        }

        $payload = @{
            fetchedAt = (Get-Date).ToUniversalTime().ToString("o")
            northHtml = $northHtml
            southHtml = $southHtml
        }
        $json = $payload | ConvertTo-Json -Compress
        $javascript = "registerOnlineBusHtml($json);"

        [IO.File]::WriteAllText(
            $temporaryPath,
            $javascript,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $filePath -Force
        Write-Host "$(Get-Date -Format 'HH:mm:ss') バスオンラインデータ更新完了"
    }
    catch {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') バスオンラインデータ取得失敗: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    if ($RunOnce) {
        break
    }

    Start-Sleep -Seconds 30
}

