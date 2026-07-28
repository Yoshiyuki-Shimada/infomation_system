param(
    [switch]$RunOnce
)

$ErrorActionPreference = "Stop"

$parentDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path -Path $parentDir -ChildPath "temp"
$filePath = Join-Path -Path $tempDir -ChildPath "imazato_liner_online.js"
$temporaryPath = "$filePath.tmp"

$urls = @{
    oikebashiNorth = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=632&poleCdSpecified=90&lang=0"
    oikebashiSouth = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=632&poleCdSpecified=30&lang=0"
    tajimaNorth = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=677&poleCdSpecified=90&lang=0"
    tajimaSouth = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=677&poleCdSpecified=80&lang=0"
}
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
$delayPattern =
    ([string][char]0x7D04) + '?\s*(\d+)\s*' +
    ([string][char]0x5206) +
    ([string][char]0x9045) +
    ([string][char]0x308C)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Ensure-TempDirectory {
    if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }
}

function Test-HasDelayAtLeastTwoMinutes {
    param([string[]]$HtmlList)

    foreach ($html in $HtmlList) {
        $approachBlocks = [regex]::Matches(
            $html,
            '(?is)<div\b[^>]*class=["''][^"'']*\bapproachData\b[^"'']*["''][^>]*>.*?(?=<div\b[^>]*class=["''][^"'']*\bapproachData\b|\z)'
        )

        foreach ($approachBlock in $approachBlocks) {
            $routeMatch = [regex]::Match(
                $approachBlock.Value,
                '(?is)id=["'']routeNm["''][^>]*>(?<route>.*?)</'
            )
            if (-not $routeMatch.Success) {
                continue
            }

            $routeText = [regex]::Replace(
                $routeMatch.Groups["route"].Value,
                '<[^>]+>',
                ''
            )
            $routeText = [Net.WebUtility]::HtmlDecode($routeText)
            $routeText = ($routeText -replace '\s', '') -replace '号$', ''
            if ($routeText -ne "BRT1" -and $routeText -ne "BRT2") {
                continue
            }

            foreach (
                $match in [regex]::Matches(
                    $approachBlock.Value,
                    $delayPattern
                )
            ) {
                if ([int]$match.Groups[1].Value -ge 2) {
                    return $true
                }
            }
        }
    }
    return $false
}

function Get-TimeBasedPollIntervalSeconds {
    param([int]$NormalIntervalSeconds)

    $now = Get-Date
    $hour = $now.Hour
    $minute = $now.Minute

    if ($hour -eq 0 -and $minute -ge 31) { return 60 }
    if ($hour -eq 1 -and $minute -le 29) { return 600 }
    if (($hour -eq 1 -and $minute -ge 30) -or $hour -in @(2, 3)) {
        return 3600
    }
    if ($hour -eq 4) { return 600 }
    if ($hour -eq 5 -and $minute -le 29) { return 60 }
    if ($hour -eq 5 -and $minute -le 44) { return 40 }

    return $NormalIntervalSeconds
}

function Get-NextFetchWaitSeconds {
    param([int]$PollIntervalSeconds)

    $now = Get-Date
    $boundaries = @(
        $now.Date.AddMinutes(31),
        $now.Date.AddHours(1),
        $now.Date.AddHours(1).AddMinutes(30),
        $now.Date.AddHours(4),
        $now.Date.AddHours(5),
        $now.Date.AddHours(5).AddMinutes(30),
        $now.Date.AddHours(5).AddMinutes(45),
        $now.Date.AddDays(1).AddMinutes(31)
    )
    $nextBoundary = $boundaries |
        Where-Object { $_ -gt $now } |
        Select-Object -First 1
    $secondsToBoundary = [Math]::Max(
        1,
        [Math]::Ceiling(($nextBoundary - $now).TotalSeconds)
    )
    return [Math]::Min($PollIntervalSeconds, $secondsToBoundary)
}

Ensure-TempDirectory

while ($true) {
    $normalFetchSeconds = 30
    $nextFetchSeconds = 30
    $nextFetchWaitSeconds = $null

    try {
        $htmlData = @{}
        foreach ($key in $urls.Keys) {
            $htmlData[$key] = (
                Invoke-WebRequest `
                    -Uri $urls[$key] `
                    -UserAgent $userAgent `
                    -UseBasicParsing `
                    -TimeoutSec 15
            ).Content

            if ([string]::IsNullOrWhiteSpace($htmlData[$key])) {
                throw "Empty HTML response: $key"
            }
        }

        if (Test-HasDelayAtLeastTwoMinutes -HtmlList @($htmlData.Values)) {
            $normalFetchSeconds = 15
        }
        $nextFetchSeconds = Get-TimeBasedPollIntervalSeconds `
            -NormalIntervalSeconds $normalFetchSeconds
        $nextFetchWaitSeconds = Get-NextFetchWaitSeconds `
            -PollIntervalSeconds $nextFetchSeconds

        $payload = @{
            fetchedAt = (Get-Date).ToUniversalTime().ToString("o")
            pollIntervalSeconds = $nextFetchSeconds
            reloadAfterSeconds = $nextFetchWaitSeconds
            oikebashiNorthHtml = $htmlData.oikebashiNorth
            oikebashiSouthHtml = $htmlData.oikebashiSouth
            tajimaNorthHtml = $htmlData.tajimaNorth
            tajimaSouthHtml = $htmlData.tajimaSouth
        }
        $json = $payload | ConvertTo-Json -Compress
        $javascript = "registerImazatoLinerHtml($json);"

        Ensure-TempDirectory
        [IO.File]::WriteAllText(
            $temporaryPath,
            $javascript,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $filePath -Force
        Write-Host "$(Get-Date -Format 'HH:mm:ss') Imazato Liner update completed (next: $nextFetchSeconds sec)"
    }
    catch {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') Imazato Liner update failed: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $filePath) {
            Remove-Item -LiteralPath $filePath -Force
        }
    }

    if ($RunOnce) {
        break
    }

    $sleepSeconds = if ($nextFetchWaitSeconds) {
        $nextFetchWaitSeconds
    }
    else {
        $nextFetchSeconds
    }
    Start-Sleep -Seconds $sleepSeconds
}
