# 大阪シティバス「いまどこ」の公式時刻表を管理画面用DBへ取り込む。
$controlTimetableBaseUrl = "https://oc.bus-vision.jp/osakacitybus/view/"
$controlTimetableUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"

function Get-ControlTimetablePage {
    param(
        [string]$Uri,
        [int]$TimeoutSeconds = 30
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd($controlTimetableUserAgent)
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $charset = [string]$response.Content.Headers.ContentType.CharSet
        $headerText = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min($bytes.Length, 4096))
        $metaMatch = [regex]::Match($headerText, '(?i)charset\s*=\s*["'']?([A-Za-z0-9_\-]+)')
        if (-not $charset -and $metaMatch.Success) { $charset = $metaMatch.Groups[1].Value }

        if ($charset -match '(?i)shift|sjis|windows-31j|cp932') {
            return [Text.Encoding]::GetEncoding(932).GetString($bytes)
        }
        try {
            return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
        catch {
            return [Text.Encoding]::GetEncoding(932).GetString($bytes)
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-ControlTimetableTarget {
    param(
        [string]$StopKey,
        [string]$Section
    )

    $targets = @{
        "tajima|oikebashi" = @{ stopCd = "676"; poleCd = "90"; direction = "北"; filter = "general-north" }
        "tajima|kumata" = @{ stopCd = "676"; poleCd = "80"; direction = "南"; filter = "general-south" }
        "tajima|abenobashi" = @{ stopCd = "676"; poleCd = "80"; direction = "南"; filter = "general-13" }
        "oikebashi|oikebashiNorth" = @{ stopCd = "632"; poleCd = "90"; direction = "北"; filter = "liner" }
        "oikebashi|oikebashiSouth" = @{ stopCd = "632"; poleCd = "30"; direction = "南"; filter = "liner" }
        "tajima5|tajimaNorth" = @{ stopCd = "677"; poleCd = "90"; direction = "北"; filter = "liner" }
        "tajima5|tajimaSouth" = @{ stopCd = "677"; poleCd = "80"; direction = "南"; filter = "liner" }
    }
    return $targets["$StopKey|$Section"]
}

function Get-ControlTimetableDateDivisionCode {
    param([string]$ScheduleType)

    $codes = @{ weekday = "1"; saturday = "2"; holiday = "3" }
    return $codes[$ScheduleType]
}

function Get-ControlTimetableUrl {
    param(
        [hashtable]$Target,
        [string]$ScheduleType
    )

    $dateDivisionCode = Get-ControlTimetableDateDivisionCode -ScheduleType $ScheduleType
    if (-not $dateDivisionCode) { throw "ダイヤ種別が不正です。" }

    $operationDate = Get-Date -Format "yyyyMMdd"
    return "${controlTimetableBaseUrl}diagram.html?stopCd=$($Target.stopCd)&poleCd=$($Target.poleCd)&opeYmd=$operationDate&timetableDateDivCd=$dateDivisionCode&lang=0"
}

function Convert-ControlHtmlToText {
    param([string]$Html)

    $text = [regex]::Replace([string]$Html, '<[^>]+>', ' ')
    $text = [Net.WebUtility]::HtmlDecode($text)
    return ([regex]::Replace($text, '\s+', ' ')).Trim()
}

function Get-ControlHtmlElementTextById {
    param(
        [string]$Html,
        [string]$Id
    )

    $pattern = '(?is)<[^>]*\bid\s*=\s*["'']' +
        [regex]::Escape($Id) +
        '["''][^>]*>(.*?)</[^>]+>'
    $match = [regex]::Match($Html, $pattern)
    if (-not $match.Success) { return "" }
    return Convert-ControlHtmlToText -Html $match.Groups[1].Value
}

function Get-ControlTimetableRouteKey {
    param([string]$Href)

    $lineMatch = [regex]::Match($Href, '(?:\?|&amp;|&)lineCd=([^&]+)')
    $routeMatch = [regex]::Match($Href, '(?:\?|&amp;|&)routeCd=([^&]+)')
    $updownMatch = [regex]::Match($Href, '(?:\?|&amp;|&)updownCd=([^&]+)')
    if (-not $lineMatch.Success -or -not $routeMatch.Success -or -not $updownMatch.Success) {
        return ""
    }
    return "$($lineMatch.Groups[1].Value)_$($routeMatch.Groups[1].Value)_$($updownMatch.Groups[1].Value)"
}

function Get-ControlTimetableRouteDetail {
    param(
        [string]$Href,
        [hashtable]$Cache
    )

    $routeKey = Get-ControlTimetableRouteKey -Href $Href
    if (-not $routeKey) { return $null }
    if ($Cache.ContainsKey($routeKey)) { return $Cache[$routeKey] }

    $detailUri = [Uri]::new([Uri]$controlTimetableBaseUrl, $Href).AbsoluteUri
    $detailHtml = Get-ControlTimetablePage -Uri $detailUri -TimeoutSeconds 20
    $line = (Get-ControlHtmlElementTextById -Html $detailHtml -Id "routeNm") -replace '\s*号\s*$', ''
    $destination = (Get-ControlHtmlElementTextById -Html $detailHtml -Id "destNm") -replace '\s*行き?\s*$', ''
    if (-not $line -or -not $destination) {
        throw "系統または行先を取得できませんでした。"
    }

    $detail = [pscustomobject]@{
        routeKey = $routeKey
        line = $line
        destination = $destination
    }
    $Cache[$routeKey] = $detail
    return $detail
}

function Test-ControlTimetableRouteIncluded {
    param(
        [string]$Filter,
        [string]$Line
    )

    $isLiner = $Line -in @("BRT1", "BRT2")
    switch ($Filter) {
        "liner" { return $isLiner }
        "general-north" { return -not $isLiner }
        "general-south" { return -not $isLiner -and $Line -ne "13" }
        "general-13" { return $Line -eq "13" }
        default { return $false }
    }
}

function Convert-ControlTimetableHtmlToEntries {
    param(
        [string]$Html,
        [hashtable]$Target
    )

    $entries = New-Object Collections.ArrayList
    $routeCache = @{}
    $linePattern = '(?is)<div\b[^>]*class=["''][^"'']*\btimetableLine\b[^"'']*["''][^>]*>(.*?)</div>\s*</div>'
    $anchorPattern = '(?is)<a\b(?=[^>]*\bid\s*=\s*["'']value["''])[^>]*\bhref\s*=\s*["'']([^"'']+)["''][^>]*>(.*?)</a>'

    foreach ($lineMatch in [regex]::Matches($Html, $linePattern)) {
        $hourMatch = [regex]::Match($lineMatch.Value, 'id\s*=\s*["'']hour["''][^>]*>\s*(\d{1,2})')
        if (-not $hourMatch.Success) { continue }
        $hour = [int]$hourMatch.Groups[1].Value

        foreach ($anchorMatch in [regex]::Matches($lineMatch.Value, $anchorPattern)) {
            $minuteText = Convert-ControlHtmlToText -Html $anchorMatch.Groups[2].Value
            $minuteMatch = [regex]::Match($minuteText, '\d{1,2}')
            if (-not $minuteMatch.Success) { continue }

            $href = [Net.WebUtility]::HtmlDecode($anchorMatch.Groups[1].Value)
            $detail = Get-ControlTimetableRouteDetail -Href $href -Cache $routeCache
            if (-not (Test-ControlTimetableRouteIncluded -Filter $Target.filter -Line $detail.line)) {
                continue
            }

            [void]$entries.Add([pscustomobject]@{
                departureTime = ("{0:D2}:{1:D2}" -f $hour, [int]$minuteMatch.Value)
                line = $detail.line
                direction = $Target.direction
                destination = $detail.destination
                routeKey = $detail.routeKey
                lastFlag = 0
            })
        }
    }
    return @($entries | Sort-Object departureTime, line, destination -Unique)
}

function Set-ControlTimetableLastFlags {
    param([object[]]$Entries)

    foreach ($group in $Entries | Group-Object line, direction, destination) {
        $lastEntry = @($group.Group | Sort-Object departureTime)[-1]
        $lastEntry.lastFlag = 1
    }
    return $Entries
}

function Get-ControlTimetableRouteId {
    param(
        [object]$Entry,
        [object[]]$Routes
    )

    $existing = $Routes | Where-Object {
        [string]$_.line -eq [string]$Entry.line -and
        [string]$_.direction -eq [string]$Entry.direction -and
        [string]$_.destination -eq [string]$Entry.destination
    } | Select-Object -First 1
    if ($existing) { return [string]$existing.id }
    return "auto_$($Entry.routeKey)"
}

function Invoke-ControlTimetableSqlScript {
    param([string]$Sql)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $sqliteExePath
    $startInfo.Arguments = '"' + $informationControlDbPath.Replace('"', '""') + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $process.StandardInput.Write($Sql)
    $process.StandardInput.Close()
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw ([string]::Join("`n", @($standardError, $standardOutput)).Trim())
    }
}

function Import-ControlOfficialTimetable {
    param(
        [string]$StopKey,
        [string]$Section,
        [string]$ScheduleType
    )

    $target = Get-ControlTimetableTarget -StopKey $StopKey -Section $Section
    if (-not $target) { throw "停留所と方面の組み合わせが不正です。" }
    if ($ScheduleType -notin @("weekday", "saturday", "holiday")) {
        throw "ダイヤ種別が不正です。"
    }

    $url = Get-ControlTimetableUrl -Target $target -ScheduleType $ScheduleType
    $html = Get-ControlTimetablePage -Uri $url -TimeoutSeconds 30
    if ([string]::IsNullOrWhiteSpace($html)) { throw "公式時刻表のHTMLが空です。" }

    $entries = @(Convert-ControlTimetableHtmlToEntries -Html $html -Target $target)
    if ($entries.Count -eq 0) {
        throw "選択した条件の時刻表を取得できませんでした。既存データは変更していません。"
    }
    $entries = @(Set-ControlTimetableLastFlags -Entries $entries)
    $routes = @(Invoke-ControlJsonQuery -Sql "SELECT id, line, direction, destination FROM route_master;")

    $sql = New-Object Collections.ArrayList
    [void]$sql.Add("PRAGMA foreign_keys=ON;")
    [void]$sql.Add("BEGIN IMMEDIATE;")
    [void]$sql.Add(@"
DELETE FROM timetable_entries
WHERE stop_key=$(ConvertTo-ControlSqlText $StopKey)
  AND section=$(ConvertTo-ControlSqlText $Section)
  AND schedule_type=$(ConvertTo-ControlSqlText $ScheduleType);
"@)

    foreach ($entry in $entries) {
        $routeId = Get-ControlTimetableRouteId -Entry $entry -Routes $routes
        [void]$sql.Add(@"
INSERT OR IGNORE INTO route_master (id, line, direction, destination)
VALUES (
    $(ConvertTo-ControlSqlText $routeId),
    $(ConvertTo-ControlSqlText $entry.line),
    $(ConvertTo-ControlSqlText $entry.direction),
    $(ConvertTo-ControlSqlText $entry.destination)
);
INSERT INTO timetable_entries (
    stop_key, section, schedule_type, departure_time, route_id, last_flag
) VALUES (
    $(ConvertTo-ControlSqlText $StopKey),
    $(ConvertTo-ControlSqlText $Section),
    $(ConvertTo-ControlSqlText $ScheduleType),
    $(ConvertTo-ControlSqlText $entry.departureTime),
    $(ConvertTo-ControlSqlText $routeId),
    $($entry.lastFlag)
);
"@)
    }
    [void]$sql.Add("COMMIT;")
    Invoke-ControlTimetableSqlScript -Sql ($sql -join "`n")
    return $entries.Count
}
