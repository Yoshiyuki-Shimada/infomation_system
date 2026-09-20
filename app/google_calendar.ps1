# Google Calendarの「予定あり」時間帯だけを取得し、表示用に集計する。

function New-UnavailableCalendarSchedule {
    return [ordered]@{
        status      = "unavailable"
        updateTime  = (Get-Date -Format "yyyy/MM/dd HH:mm:ss")
        hasConflict = $false
        days        = @()
    }
}

function Unprotect-GoogleCalendarValue {
    param([Parameter(Mandatory = $true)][string]$ProtectedValue)

    $secureValue = ConvertTo-SecureString -String $ProtectedValue
    $credential = New-Object System.Management.Automation.PSCredential("calendar", $secureValue)
    return $credential.GetNetworkCredential().Password
}

function Get-GoogleCalendarRuntimeConfig {
    $rootDir = Split-Path -Path $PSScriptRoot -Parent
    $configPath = Join-Path $rootDir "database\runtime\google_calendar_auth.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Warning "Google Calendar認証設定を読み込めません: $($_.Exception.Message)"
        return $null
    }
}

function Get-GoogleCalendarAccessToken {
    param([Parameter(Mandatory = $true)]$Config)

    $clientSecret = Unprotect-GoogleCalendarValue -ProtectedValue $Config.clientSecretProtected
    $refreshToken = Unprotect-GoogleCalendarValue -ProtectedValue $Config.refreshTokenProtected
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -ContentType "application/x-www-form-urlencoded" -Body @{
        client_id     = [string]$Config.clientId
        client_secret = $clientSecret
        refresh_token = $refreshToken
        grant_type    = "refresh_token"
    } -TimeoutSec 30

    return [string]$tokenResponse.access_token
}

function ConvertTo-GoogleCalendarMunicipality {
    param([string]$Location)

    if ([string]::IsNullOrWhiteSpace($Location)) {
        return ""
    }

    $normalized = $Location -replace "〒?\d{3}-?\d{4}", "" -replace "\s+", ""
    $normalized = $normalized -replace "^(東京都|北海道|(?:京都|大阪)府|.{2,3}県)", ""
    if ($normalized -match "^([^,、]{1,12}市[^,、]{1,8}区)") {
        return $Matches[1]
    }
    if ($normalized -match "^([^,、]{1,12}(?:市|区|町|村))") {
        return $Matches[1]
    }
    return ""
}

function ConvertTo-CalendarDateTime {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value.dateTime) {
        return [DateTimeOffset]::Parse([string]$Value.dateTime).LocalDateTime
    }
    if ($Value.date) {
        return [datetime]::ParseExact([string]$Value.date, "yyyy-MM-dd", $null)
    }
    return $null
}

function Get-GoogleCalendarEvents {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$CalendarId,
        [Parameter(Mandatory = $true)][datetime]$TimeMin,
        [Parameter(Mandatory = $true)][datetime]$TimeMax
    )

    $events = @()
    $pageToken = ""
    do {
        $query = @{
            timeMin      = $TimeMin.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            timeMax      = $TimeMax.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            timeZone     = "Asia/Tokyo"
            singleEvents = "true"
            orderBy      = "startTime"
            maxResults   = "2500"
            fields       = "nextPageToken,items(status,transparency,start,end,location)"
        }
        if ($pageToken) {
            $query.pageToken = $pageToken
        }

        $queryText = ($query.GetEnumerator() | ForEach-Object {
            "{0}={1}" -f [Uri]::EscapeDataString([string]$_.Key), [Uri]::EscapeDataString([string]$_.Value)
        }) -join "&"
        $encodedCalendarId = [Uri]::EscapeDataString($CalendarId)
        $uri = "https://www.googleapis.com/calendar/v3/calendars/$encodedCalendarId/events?$queryText"
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $AccessToken" } -TimeoutSec 30
        $events += @($response.items)
        $pageToken = [string]$response.nextPageToken
    } while ($pageToken)

    return @($events)
}

function ConvertTo-CalendarBusyEvents {
    param([array]$Events)

    $result = @()
    foreach ($event in $Events) {
        if ($event.status -eq "cancelled" -or $event.transparency -eq "transparent") {
            continue
        }

        $isAllDay = [bool]$event.start.date
        $start = ConvertTo-CalendarDateTime -Value $event.start
        $end = ConvertTo-CalendarDateTime -Value $event.end
        if ($null -eq $start -or $null -eq $end -or $end -le $start) {
            continue
        }

        $result += [pscustomobject]@{
            IsAllDay     = $isAllDay
            Start        = $start
            End          = $end
            PaddedStart  = if ($isAllDay) { $start } else { $start.AddMinutes(-30) }
            PaddedEnd    = if ($isAllDay) { $end } else { $end.AddMinutes(30) }
            Municipality = ConvertTo-GoogleCalendarMunicipality -Location ([string]$event.location)
        }
    }
    return @($result)
}

function Test-CalendarRangeOverlap {
    param(
        [datetime]$StartA,
        [datetime]$EndA,
        [datetime]$StartB,
        [datetime]$EndB
    )
    return $StartA -lt $EndB -and $StartB -lt $EndA
}

function Get-CalendarSlotSummary {
    param(
        [array]$Events,
        [datetime]$Start,
        [datetime]$End,
        [string]$Label,
        [bool]$IncludeMunicipality
    )

    $matching = @($Events | Where-Object {
        -not $_.IsAllDay -and (Test-CalendarRangeOverlap $_.PaddedStart $_.PaddedEnd $Start $End)
    })
    $municipality = ""
    if ($IncludeMunicipality -and $matching.Count -eq 1) {
        $municipality = [string]$matching[0].Municipality
    }

    return [ordered]@{
        label        = $Label
        count        = $matching.Count
        municipality = $municipality
    }
}

function Get-CalendarAllDaySummary {
    param(
        [array]$Events,
        [datetime]$DayStart,
        [bool]$IncludeMunicipality
    )

    $dayEnd = $DayStart.AddDays(1)
    $matching = @($Events | Where-Object {
        $_.IsAllDay -and (Test-CalendarRangeOverlap $_.Start $_.End $DayStart $dayEnd)
    })
    $municipality = ""
    if ($IncludeMunicipality -and $matching.Count -eq 1) {
        $municipality = [string]$matching[0].Municipality
    }

    return [ordered]@{
        label        = "終日"
        count        = $matching.Count
        municipality = $municipality
    }
}

function Get-TodayCalendarSlots {
    param([array]$Events, [datetime]$DayStart)

    $slots = @()
    $slots += Get-CalendarAllDaySummary -Events $Events -DayStart $DayStart -IncludeMunicipality $true
    $slots += Get-CalendarSlotSummary -Events $Events -Start $DayStart -End $DayStart.AddHours(9) -Label "～09:00" -IncludeMunicipality $true
    for ($hour = 9; $hour -lt 21; $hour++) {
        $slots += Get-CalendarSlotSummary -Events $Events -Start $DayStart.AddHours($hour) -End $DayStart.AddHours($hour + 1) -Label ("{0:D2}:00" -f $hour) -IncludeMunicipality $true
    }
    $slots += Get-CalendarSlotSummary -Events $Events -Start $DayStart.AddHours(21) -End $DayStart.AddDays(1) -Label "21:00～" -IncludeMunicipality $true
    return @($slots)
}

function Get-WeeklyCalendarSlots {
    param([array]$Events, [datetime]$DayStart)

    $slots = @()
    $slots += Get-CalendarAllDaySummary -Events $Events -DayStart $DayStart -IncludeMunicipality $false
    $slots += Get-CalendarSlotSummary -Events $Events -Start $DayStart -End $DayStart.AddHours(9) -Label "～09:00" -IncludeMunicipality $false
    foreach ($hour in @(9, 12, 15, 18)) {
        $slots += Get-CalendarSlotSummary -Events $Events -Start $DayStart.AddHours($hour) -End $DayStart.AddHours($hour + 3) -Label ("{0:D2}:00" -f $hour) -IncludeMunicipality $false
    }
    $slots += Get-CalendarSlotSummary -Events $Events -Start $DayStart.AddHours(21) -End $DayStart.AddDays(1) -Label "21:00～" -IncludeMunicipality $false
    return @($slots)
}

function Test-GoogleCalendarConflict {
    param([array]$Events, [datetime]$StartDate, [int]$DayCount)

    for ($offset = 0; $offset -lt $DayCount; $offset++) {
        $dayStart = $StartDate.AddDays($offset)
        $dayEnd = $dayStart.AddDays(1)
        $allDay = @($Events | Where-Object { $_.IsAllDay -and (Test-CalendarRangeOverlap $_.Start $_.End $dayStart $dayEnd) })
        $timed = @($Events | Where-Object { -not $_.IsAllDay -and (Test-CalendarRangeOverlap $_.PaddedStart $_.PaddedEnd $dayStart $dayEnd) })
        if ($allDay.Count -ge 2 -or ($allDay.Count -ge 1 -and $timed.Count -ge 1)) {
            return $true
        }
        for ($left = 0; $left -lt $timed.Count; $left++) {
            for ($right = $left + 1; $right -lt $timed.Count; $right++) {
                $leftEvent = $timed[$left]
                $rightEvent = $timed[$right]
                $isWithinBuffer = `
                    $leftEvent.Start -le $rightEvent.End.AddMinutes(30) -and `
                    $rightEvent.Start -le $leftEvent.End.AddMinutes(30)
                if ($isWithinBuffer) {
                    return $true
                }
            }
        }
    }
    return $false
}

function Get-GoogleCalendarSchedule {
    $config = Get-GoogleCalendarRuntimeConfig
    if ($null -eq $config) {
        return New-UnavailableCalendarSchedule
    }

    try {
        $today = (Get-Date).Date
        $accessToken = Get-GoogleCalendarAccessToken -Config $config
        $calendarId = if ($config.calendarId) { [string]$config.calendarId } else { "primary" }
        $rawEvents = Get-GoogleCalendarEvents -AccessToken $accessToken -CalendarId $calendarId -TimeMin $today.AddMinutes(-30) -TimeMax $today.AddDays(8).AddMinutes(30)
        $events = ConvertTo-CalendarBusyEvents -Events $rawEvents
        $days = @()
        for ($offset = 0; $offset -lt 8; $offset++) {
            $dayStart = $today.AddDays($offset)
            $days += [ordered]@{
                date    = $dayStart.ToString("yyyy-MM-dd")
                label   = $dayStart.ToString("M月d日（ddd）", [Globalization.CultureInfo]::GetCultureInfo("ja-JP"))
                isToday = ($offset -eq 0)
                slots   = if ($offset -eq 0) { @(Get-TodayCalendarSlots -Events $events -DayStart $dayStart) } else { @(Get-WeeklyCalendarSlots -Events $events -DayStart $dayStart) }
            }
        }

        return [ordered]@{
            status      = "ok"
            updateTime  = (Get-Date -Format "yyyy/MM/dd HH:mm:ss")
            hasConflict = Test-GoogleCalendarConflict -Events $events -StartDate $today -DayCount 8
            days        = $days
        }
    }
    catch {
        Write-Warning "Google Calendar取得に失敗しました: $($_.Exception.Message)"
        return New-UnavailableCalendarSchedule
    }
}
