param(
    [switch]$RunOnce
)

$ErrorActionPreference = "Stop"

$parentDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path -Path $parentDir -ChildPath "temp"
$filePath = Join-Path -Path $tempDir -ChildPath "imazato_liner_online.js"
$temporaryPath = "$filePath.tmp"
$timetableBaseUrl = "https://oc.bus-vision.jp/osakacitybus/view/"
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
$timetableCache = $null
$timetableCacheFetchedAt = $null

$urls = @{
    oikebashiNorth = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=632&poleCdSpecified=90&lang=0"
    oikebashiSouth = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=632&poleCdSpecified=30&lang=0"
    tajimaNorth = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=677&poleCdSpecified=90&lang=0"
    tajimaSouth = "https://oc.bus-vision.jp/osakacitybus/view/approachSpecifiedStop.html?stopCdSpecified=677&poleCdSpecified=80&lang=0"
}

$timetableTargets = @{
    oikebashiNorth = @{ stopCd = "632"; poleCd = "90" }
    oikebashiSouth = @{ stopCd = "632"; poleCd = "30" }
    tajimaNorth = @{ stopCd = "677"; poleCd = "90" }
    tajimaSouth = @{ stopCd = "677"; poleCd = "80" }
}

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

function Get-OperationDate {
    param([datetime]$Now = (Get-Date))

    $operationDate = $Now.Date
    if ($Now.Hour -lt 4) {
        $operationDate = $operationDate.AddDays(-1)
    }

    return $operationDate.ToString("yyyyMMdd")
}

function Get-TimetableUrl {
    param(
        [string]$StopCode,
        [string]$PoleCode,
        [string]$OperationDate
    )

    return "${timetableBaseUrl}diagram.html?stopCd=$StopCode&poleCd=$PoleCode&opeYmd=$OperationDate&timetableDateDivCd=-1&lang=0"
}

function Get-RouteKeyFromUrl {
    param([string]$Url)

    $lineMatch = [regex]::Match($Url, '(?:\?|&amp;|&)lineCd=([^&]+)')
    $routeMatch = [regex]::Match($Url, '(?:\?|&amp;|&)routeCd=([^&]+)')
    $updownMatch = [regex]::Match($Url, '(?:\?|&amp;|&)updownCd=([^&]+)')
    if (-not $lineMatch.Success -or -not $routeMatch.Success -or -not $updownMatch.Success) {
        return $null
    }

    return "$($lineMatch.Groups[1].Value)_$($routeMatch.Groups[1].Value)_$($updownMatch.Groups[1].Value)"
}

function Get-TimetableDetailLinks {
    param([string[]]$HtmlList)

    $links = @{}
    foreach ($html in $HtmlList) {
        $matches = [regex]::Matches(
            $html,
            '(?is)<a\b(?=[^>]*\bid\s*=\s*["'']value["''])[^>]*\bhref\s*=\s*["'']([^"'']+)["''][^>]*>'
        )

        foreach ($match in $matches) {
            $href = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
            $key = Get-RouteKeyFromUrl $href
            if ($key -and -not $links.ContainsKey($key)) {
                $links[$key] = $href
            }
        }
    }

    return $links
}

function Get-HtmlElementTextById {
    param(
        [string]$Html,
        [string]$Id
    )

    $pattern = '(?is)<[^>]*\bid\s*=\s*["'']' +
        [regex]::Escape($Id) +
        '["''][^>]*>(.*?)</[^>]+>'
    $match = [regex]::Match($Html, $pattern)
    if (-not $match.Success) { return "" }

    $text = [regex]::Replace($match.Groups[1].Value, '<[^>]+>', ' ')
    return [Net.WebUtility]::HtmlDecode($text).Trim()
}

function Get-OfficialTimetableData {
    param([string]$OperationDate)

    $htmlData = @{}
    foreach ($entry in $timetableTargets.GetEnumerator()) {
        $url = Get-TimetableUrl `
            -StopCode $entry.Value.stopCd `
            -PoleCode $entry.Value.poleCd `
            -OperationDate $OperationDate
        $htmlData[$entry.Key] = (
            Invoke-WebRequest `
                -Uri $url `
                -UserAgent $userAgent `
                -UseBasicParsing `
                -TimeoutSec 20
        ).Content

        if ([string]::IsNullOrWhiteSpace($htmlData[$entry.Key])) {
            throw "公式時刻表のHTMLが空です: $($entry.Key)"
        }
    }

    $routeDetails = @{}
    $detailLinks = Get-TimetableDetailLinks -HtmlList @($htmlData.Values)
    foreach ($entry in $detailLinks.GetEnumerator()) {
        $detailUri = [Uri]::new([Uri]$timetableBaseUrl, $entry.Value).AbsoluteUri
        $detailHtml = (
            Invoke-WebRequest `
                -Uri $detailUri `
                -UserAgent $userAgent `
                -UseBasicParsing `
                -TimeoutSec 15
        ).Content
        $routeName = Get-HtmlElementTextById -Html $detailHtml -Id "routeNm"
        $destinationName = Get-HtmlElementTextById -Html $detailHtml -Id "destNm"
        if ($routeName -and $destinationName) {
            $routeDetails[$entry.Key] = @{
                routeName = $routeName
                destinationName = $destinationName
            }
        }
    }

    return @{
        operationDate = $OperationDate
        oikebashiNorthHtml = $htmlData.oikebashiNorth
        oikebashiSouthHtml = $htmlData.oikebashiSouth
        tajimaNorthHtml = $htmlData.tajimaNorth
        tajimaSouthHtml = $htmlData.tajimaSouth
        routeDetails = $routeDetails
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
            $routeText = ($routeText -replace '\s', '') -replace '号$', '' -replace '蜿ｷ$', ''
            if ($routeText -ne "BRT1" -and $routeText -ne "BRT2") {
                continue
            }

            foreach ($match in [regex]::Matches($approachBlock.Value, $delayPattern)) {
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

        $operationDate = Get-OperationDate
        $timetableCacheExpired = -not $timetableCacheFetchedAt -or
            ((Get-Date) - $timetableCacheFetchedAt).TotalMinutes -ge 30
        if (-not $timetableCache -or
            $timetableCache["operationDate"] -ne $operationDate -or
            $timetableCacheExpired) {
            try {
                $timetableCache = Get-OfficialTimetableData -OperationDate $operationDate
                $timetableCacheFetchedAt = Get-Date
                Write-Host "$(Get-Date -Format 'HH:mm:ss') Imazato Liner official timetable updated ($operationDate)"
            }
            catch {
                if (-not $timetableCache -or $timetableCache["operationDate"] -ne $operationDate) {
                    $timetableCache = @{
                        operationDate = $operationDate
                        oikebashiNorthHtml = ""
                        oikebashiSouthHtml = ""
                        tajimaNorthHtml = ""
                        tajimaSouthHtml = ""
                        routeDetails = @{}
                    }
                }
                Write-Host "$(Get-Date -Format 'HH:mm:ss') Imazato Liner official timetable failed: $($_.Exception.Message)" -ForegroundColor Yellow
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
            timetableDate = $timetableCache["operationDate"]
            timetableOikebashiNorthHtml = $timetableCache["oikebashiNorthHtml"]
            timetableOikebashiSouthHtml = $timetableCache["oikebashiSouthHtml"]
            timetableTajimaNorthHtml = $timetableCache["tajimaNorthHtml"]
            timetableTajimaSouthHtml = $timetableCache["tajimaSouthHtml"]
            timetableRouteDetails = $timetableCache["routeDetails"]
        }
        $json = $payload | ConvertTo-Json -Compress -Depth 8
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