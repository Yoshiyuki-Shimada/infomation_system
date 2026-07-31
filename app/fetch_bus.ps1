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
$timetableBaseUrl = "https://oc.bus-vision.jp/osakacitybus/view/"
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
$timetableCache = $null
$timetableCacheFetchedAt = $null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Ensure-TempDirectory {
    if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }
}

function Get-TimetableUrl {
    param(
        [string]$PoleCode,
        [string]$OperationDate
    )

    return "${timetableBaseUrl}diagram.html?stopCd=676&poleCd=$PoleCode&opeYmd=$OperationDate&timetableDateDivCd=-1&lang=0"
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
        foreach ($match in [regex]::Matches(
            $html,
            '(?is)<a\b(?=[^>]*\bid\s*=\s*["'']value["''])[^>]*\bhref\s*=\s*["'']([^"'']+)["''][^>]*>'
        )) {
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

    $northTimetableUrl = Get-TimetableUrl -PoleCode "90" -OperationDate $OperationDate
    $southTimetableUrl = Get-TimetableUrl -PoleCode "80" -OperationDate $OperationDate
    $northTimetableHtml = (Invoke-WebRequest -Uri $northTimetableUrl -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20).Content
    $southTimetableHtml = (Invoke-WebRequest -Uri $southTimetableUrl -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20).Content

    if ([string]::IsNullOrWhiteSpace($northTimetableHtml) -or [string]::IsNullOrWhiteSpace($southTimetableHtml)) {
        throw "公式時刻表のHTMLが空です。"
    }

    $routeDetails = @{}
    $detailLinks = Get-TimetableDetailLinks -HtmlList @($northTimetableHtml, $southTimetableHtml)
    foreach ($entry in $detailLinks.GetEnumerator()) {
        $detailUri = [Uri]::new([Uri]$timetableBaseUrl, $entry.Value).AbsoluteUri
        $detailHtml = (Invoke-WebRequest -Uri $detailUri -UserAgent $userAgent -UseBasicParsing -TimeoutSec 15).Content
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
        northHtml = $northTimetableHtml
        southHtml = $southTimetableHtml
        routeDetails = $routeDetails
    }
}

function Test-HasDelayAtLeastThreeMinutes {
    param(
        [string[]]$HtmlList
    )

    foreach ($html in $HtmlList) {
        foreach ($match in [regex]::Matches($html, '約?\s*(\d+)\s*分遅れ')) {
            if ([int]$match.Groups[1].Value -ge 3) {
                return $true
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
        $northHtml = (Invoke-WebRequest -Uri $northUrl -UserAgent $userAgent -UseBasicParsing -TimeoutSec 15).Content
        $southHtml = (Invoke-WebRequest -Uri $southUrl -UserAgent $userAgent -UseBasicParsing -TimeoutSec 15).Content

        if ([string]::IsNullOrWhiteSpace($northHtml) -or [string]::IsNullOrWhiteSpace($southHtml)) {
            throw "取得したHTMLが空です。"
        }

        $operationDate = Get-Date -Format "yyyyMMdd"
        $timetableCacheExpired = -not $timetableCacheFetchedAt -or
            ((Get-Date) - $timetableCacheFetchedAt).TotalMinutes -ge 30
        if (-not $timetableCache -or
            $timetableCache["operationDate"] -ne $operationDate -or
            $timetableCacheExpired) {
            try {
                $newTimetableCache = Get-OfficialTimetableData -OperationDate $operationDate
                $timetableCache = $newTimetableCache
                $timetableCacheFetchedAt = Get-Date
                Write-Host "$(Get-Date -Format 'HH:mm:ss') 公式時刻表更新完了（$operationDate）"
            }
            catch {
                if (-not $timetableCache -or $timetableCache["operationDate"] -ne $operationDate) {
                    throw
                }
                Write-Host "$(Get-Date -Format 'HH:mm:ss') 公式時刻表の再取得失敗。前回データを継続使用: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        if (Test-HasDelayAtLeastThreeMinutes -HtmlList @($northHtml, $southHtml)) {
            $normalFetchSeconds = 15
        }
        $nextFetchSeconds = Get-TimeBasedPollIntervalSeconds `
            -NormalIntervalSeconds $normalFetchSeconds
        $nextFetchWaitSeconds = Get-NextFetchWaitSeconds `
            -PollIntervalSeconds $nextFetchSeconds

        $payload = @{
            fetchedAt = (Get-Date).ToUniversalTime().ToString("o")
            northHtml = $northHtml
            southHtml = $southHtml
            timetableDate = $timetableCache["operationDate"]
            timetableNorthHtml = $timetableCache["northHtml"]
            timetableSouthHtml = $timetableCache["southHtml"]
            timetableRouteDetails = $timetableCache["routeDetails"]
            pollIntervalSeconds = $nextFetchSeconds
            reloadAfterSeconds = $nextFetchWaitSeconds
        }
        $json = $payload | ConvertTo-Json -Compress -Depth 8
        $javascript = "registerOnlineBusHtml($json);"

        # ネットワーク監視処理などによりtempが削除されていても再作成する
        Ensure-TempDirectory

        [IO.File]::WriteAllText(
            $temporaryPath,
            $javascript,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $filePath -Force
        Write-Host "$(Get-Date -Format 'HH:mm:ss') バスオンラインデータ更新完了（次回 $nextFetchSeconds 秒後）"
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

    $sleepSeconds = if ($nextFetchWaitSeconds) {
        $nextFetchWaitSeconds
    }
    else {
        $nextFetchSeconds
    }
    Start-Sleep -Seconds $sleepSeconds
}

