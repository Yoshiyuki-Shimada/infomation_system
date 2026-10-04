# LAN内管理画面の永続化・API処理。time_signal.ps1 から読み込んで使用する。
$informationControlDbPath = Join-Path $runtimeDbDir "information_control.sqlite3"
$informationControlStatePath = Join-Path $tempDir "control_data.js"
$informationControlWebRoot = Join-Path $projectDir "infomation_control"
$script:informationControlInitialized = $false
$timetableImportModulePath = Join-Path $PSScriptRoot "timetable_import.ps1"
if (Test-Path -LiteralPath $timetableImportModulePath -PathType Leaf) {
    . $timetableImportModulePath
}

function ConvertTo-ControlSqlText {
    param([object]$Value)

    return ConvertTo-NetworkSqliteTextLiteral -Value $Value
}

function Invoke-ControlSql {
    param([string]$Sql)

    return Invoke-NetworkSqliteCommand `
        -SqliteExePath $sqliteExePath `
        -DatabasePath $informationControlDbPath `
        -Sql $Sql
}

function Invoke-ControlJsonQuery {
    param([string]$Sql)

    return @(Invoke-NetworkSqliteJsonQuery `
        -SqliteExePath $sqliteExePath `
        -DatabasePath $informationControlDbPath `
        -Sql $Sql)
}

function ConvertFrom-ControlJavaScriptObject {
    param(
        [string]$Path,
        [string]$VariableName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $source = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $match = [regex]::Match(
        $source,
        "(?s)const\s+$([regex]::Escape($VariableName))\s*=\s*(\{.*\})\s*;"
    )
    if (-not $match.Success) { return $null }

    $json = $match.Groups[1].Value
    $json = [regex]::Replace($json, '(?m)^\s*//.*$', '')
    $json = [regex]::Replace($json, '(?m)(^\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)', '$1"$2"$3')
    $json = [regex]::Replace($json, ',\s*([}\]])', '$1')
    return $json | ConvertFrom-Json
}

function Import-ControlDefaultRoutes {
    $routeCount = Invoke-ControlJsonQuery -Sql "SELECT COUNT(*) AS count FROM route_master;"
    if ($routeCount.Count -gt 0 -and [int]$routeCount[0].count -gt 0) { return }

    $path = Join-Path $projectDir "database\routeMaster.js"
    $routes = ConvertFrom-ControlJavaScriptObject -Path $path -VariableName "routeMaster"
    if (-not $routes) { return }

    $sql = New-Object Collections.ArrayList
    [void]$sql.Add("BEGIN IMMEDIATE;")
    foreach ($property in $routes.PSObject.Properties) {
        $id = [string]$property.Name
        $route = $property.Value
        $separator = $id.LastIndexOf("_")
        $line = if ($separator -gt 0) { $id.Substring(0, $separator) } else { $id }
        $direction = if ($separator -gt 0) { $id.Substring($separator + 1) } else { "" }
        $transferGuide = ([string]$route.msg1) + ([string]$route.msg2)
        [void]$sql.Add(@"
INSERT OR IGNORE INTO route_master (
    id, line, direction, via, via_eng, destination, destination_eng,
    destination_kana, transfer_guide_1, transfer_guide_2, transfer_guide
) VALUES (
    $(ConvertTo-ControlSqlText $id),
    $(ConvertTo-ControlSqlText $line),
    $(ConvertTo-ControlSqlText $direction),
    $(ConvertTo-ControlSqlText $route.via),
    $(ConvertTo-ControlSqlText $route.viaEng),
    $(ConvertTo-ControlSqlText $route.dest),
    $(ConvertTo-ControlSqlText $route.destEng),
    $(ConvertTo-ControlSqlText $route.destKana),
    NULL,
    NULL,
    $(ConvertTo-ControlSqlText $transferGuide)
);
"@)
    }
    [void]$sql.Add("COMMIT;")
    Invoke-ControlSql -Sql ($sql -join "`n") | Out-Null
}

function Import-ControlDefaultTimetable {
    $countRows = Invoke-ControlJsonQuery -Sql "SELECT COUNT(*) AS count FROM timetable_entries;"
    if ($countRows.Count -gt 0 -and [int]$countRows[0].count -gt 0) { return }

    $path = Join-Path $projectDir "database\schedule_2026.js"
    $master = ConvertFrom-ControlJavaScriptObject -Path $path -VariableName "masterScheduleData"
    if (-not $master) { return }

    $sql = New-Object Collections.ArrayList
    $batchSize = 10
    $batchCount = 0
    [void]$sql.Add("BEGIN IMMEDIATE;")
    foreach ($scheduleType in @("weekday", "saturday", "holiday")) {
        $daySchedule = $master.$scheduleType
        if (-not $daySchedule) { continue }
        foreach ($sectionProperty in $daySchedule.PSObject.Properties) {
            $section = [string]$sectionProperty.Name
            foreach ($bus in @($sectionProperty.Value)) {
                $routeId = "$($bus.line)_$($bus.dir)"
                [void]$sql.Add(@"
INSERT INTO timetable_entries (
    stop_key, section, schedule_type, departure_time, route_id, last_flag
) VALUES (
    'tajima',
    $(ConvertTo-ControlSqlText $section),
    $(ConvertTo-ControlSqlText $scheduleType),
    $(ConvertTo-ControlSqlText $bus.time),
    $(ConvertTo-ControlSqlText $routeId),
    $(if ([bool]$bus.lastFlg) { 1 } else { 0 })
);
"@)
                $batchCount++
                if ($batchCount -ge $batchSize) {
                    [void]$sql.Add("COMMIT;")
                    Invoke-ControlSql -Sql ($sql -join "`n") | Out-Null
                    $sql = New-Object Collections.ArrayList
                    [void]$sql.Add("BEGIN IMMEDIATE;")
                    $batchCount = 0
                }
            }
        }
    }
    if ($batchCount -gt 0) {
        [void]$sql.Add("COMMIT;")
        Invoke-ControlSql -Sql ($sql -join "`n") | Out-Null
    }
}

function Add-ControlRouteColumnIfMissing {
    param(
        [string]$Name,
        [string]$Definition
    )

    $columns = @(Invoke-ControlJsonQuery -Sql "PRAGMA table_info(route_master);")
    if ($columns.name -contains $Name) { return }
    Invoke-ControlSql -Sql "ALTER TABLE route_master ADD COLUMN $Name $Definition;" | Out-Null
}

function Ensure-ControlLinerRoutes {
    $routes = @(
        @{ id = "BRT1_北"; line = "BRT1"; direction = "北"; destination = "今里・神路公園"; via = "中川西公園前方面"; stops = "中川西公園前、地下鉄今里、神路公園"; transfer = "地下鉄千日前線・今里筋線は「地下鉄今里」でお乗り換えください。" },
        @{ id = "BRT2_北"; line = "BRT2"; direction = "北"; destination = "地下鉄今里"; via = "中川西公園前・地下鉄今里方面"; stops = "中川西公園前、地下鉄今里"; transfer = "地下鉄千日前線・今里筋線は「地下鉄今里」でお乗り換えください。" },
        @{ id = "BRT1_南"; line = "BRT1"; direction = "南"; destination = "JR長居駅前"; via = "杭全・湯里六丁目・地下鉄長居方面"; stops = "杭全、湯里六丁目、地下鉄長居、JR長居駅前"; transfer = "JR大和路線は「杭全」、地下鉄御堂筋線は「地下鉄長居」でお乗り換えください。" },
        @{ id = "BRT2_南"; line = "BRT2"; direction = "南"; destination = "あべの橋"; via = "杭全方面"; stops = "杭全、あべの橋"; transfer = "JR大和路線は「杭全」でお乗り換えください。" }
    )
    foreach ($route in $routes) {
        $sql = @"
INSERT OR IGNORE INTO route_master (
    id, line, direction, via, destination, transfer_guide, liner_stops
) VALUES (
    $(ConvertTo-ControlSqlText $route.id),
    $(ConvertTo-ControlSqlText $route.line),
    $(ConvertTo-ControlSqlText $route.direction),
    $(ConvertTo-ControlSqlText $route.via),
    $(ConvertTo-ControlSqlText $route.destination),
    $(ConvertTo-ControlSqlText $route.transfer),
    $(ConvertTo-ControlSqlText $route.stops)
);
"@
        Invoke-ControlSql -Sql $sql | Out-Null
    }
}

function Update-ControlLegacyTransferGuides {
    $sql = @"
UPDATE route_master
SET transfer_guide = COALESCE(transfer_guide_1, '') || COALESCE(transfer_guide_2, '')
WHERE transfer_guide IS NULL
  AND (COALESCE(transfer_guide_1, '') <> '' OR COALESCE(transfer_guide_2, '') <> '');
"@
    Invoke-ControlSql -Sql $sql | Out-Null
}

function Initialize-InformationControl {
    if ($script:informationControlInitialized) { return }
    if (-not (Test-Path -LiteralPath $runtimeDbDir -PathType Container)) {
        New-Item -ItemType Directory -Path $runtimeDbDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    $schema = @"
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS route_master (
    id TEXT PRIMARY KEY,
    line TEXT NOT NULL,
    direction TEXT NOT NULL,
    via TEXT,
    via_eng TEXT,
    destination TEXT NOT NULL,
    destination_eng TEXT,
    destination_kana TEXT,
    transfer_guide_1 TEXT,
    transfer_guide_2 TEXT,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS timetable_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    stop_key TEXT NOT NULL,
    section TEXT NOT NULL,
    schedule_type TEXT NOT NULL CHECK(schedule_type IN ('weekday','saturday','holiday')),
    departure_time TEXT NOT NULL,
    route_id TEXT NOT NULL,
    last_flag INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(route_id) REFERENCES route_master(id) ON UPDATE CASCADE ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_timetable_section_type_time
    ON timetable_entries(stop_key, section, schedule_type, departure_time);
CREATE TABLE IF NOT EXISTS control_settings (
    name TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
"@
    Invoke-ControlSql -Sql $schema | Out-Null
    Add-ControlRouteColumnIfMissing -Name "transfer_guide" -Definition "TEXT"
    Add-ControlRouteColumnIfMissing -Name "liner_stops" -Definition "TEXT"
    Import-ControlDefaultRoutes
    Update-ControlLegacyTransferGuides
    Ensure-ControlLinerRoutes
    Import-ControlDefaultTimetable
    Set-ControlSettingIfMissing -Name "managedTimetableEnabled" -Value "true"
    Set-ControlSettingIfMissing -Name "fallbackScheduleType" -Value '"auto"'
    Set-ControlSettingIfMissing -Name "displayOverrides" -Value "[]"
    Set-ControlSettingIfMissing -Name "busTests" -Value "[]"
    $script:informationControlInitialized = $true
    Write-InformationControlState
}

function Set-ControlSettingIfMissing {
    param(
        [string]$Name,
        [string]$Value
    )

    $encodedValue = "base64:" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    $sql = @"
INSERT OR IGNORE INTO control_settings (name, value)
VALUES ($(ConvertTo-ControlSqlText $Name), $(ConvertTo-ControlSqlText $encodedValue));
"@
    Invoke-ControlSql -Sql $sql | Out-Null
}

function Set-ControlSetting {
    param(
        [string]$Name,
        [object]$Value
    )

    $json = if ($null -eq $Value) {
        "null"
    }
    else {
        ConvertTo-Json -InputObject $Value -Depth 20 -Compress
    }
    $storedValue = "base64:" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $sql = @"
INSERT INTO control_settings (name, value, updated_at)
VALUES ($(ConvertTo-ControlSqlText $Name), $(ConvertTo-ControlSqlText $storedValue), datetime('now'))
ON CONFLICT(name) DO UPDATE SET value=excluded.value, updated_at=datetime('now');
"@
    Invoke-ControlSql -Sql $sql | Out-Null
}

function Get-ControlSettings {
    $settings = [ordered]@{}
    foreach ($row in Invoke-ControlJsonQuery -Sql "SELECT name, value FROM control_settings;") {
        $storedValue = [string]$row.value
        if ($storedValue.StartsWith("base64:")) {
            try {
                $storedValue = [Text.Encoding]::UTF8.GetString(
                    [Convert]::FromBase64String($storedValue.Substring(7))
                )
            }
            catch {
                $storedValue = "null"
            }
        }
        try {
            $settings[[string]$row.name] = ($storedValue | ConvertFrom-Json)
        }
        catch {
            $settings[[string]$row.name] = $storedValue
        }
    }
    return $settings
}

function Remove-ExpiredControlEntries {
    param([object[]]$Entries)

    $now = Get-Date
    return @($Entries | Where-Object {
        if (-not $_.expiresAt) { return $true }
        $expiresAt = [datetime]::MinValue
        return [datetime]::TryParse([string]$_.expiresAt, [ref]$expiresAt) -and $expiresAt -gt $now
    })
}

function Get-InformationControlState {
    Initialize-InformationControl
    $settings = Get-ControlSettings
    if ($settings.displayOverrides -is [string]) {
        Set-ControlSetting -Name "displayOverrides" -Value @()
        $settings.displayOverrides = @()
    }
    if ($settings.busTests -is [string]) {
        Set-ControlSetting -Name "busTests" -Value @()
        $settings.busTests = @()
    }
    $displayOverrides = Remove-ExpiredControlEntries -Entries @($settings.displayOverrides)
    $busTests = Remove-ExpiredControlEntries -Entries @($settings.busTests)
    if (@($displayOverrides).Count -ne @($settings.displayOverrides).Count) {
        Set-ControlSetting -Name "displayOverrides" -Value @($displayOverrides)
    }
    if (@($busTests).Count -ne @($settings.busTests).Count) {
        Set-ControlSetting -Name "busTests" -Value @($busTests)
    }
    $settings.displayOverrides = @($displayOverrides)
    $settings.busTests = @($busTests)
    $disasterTestUntil = [datetime]::MinValue
    $disasterTestActive = [datetime]::TryParse(
        [string]$settings.disasterTestUntil,
        [ref]$disasterTestUntil
    ) -and $disasterTestUntil -gt (Get-Date)
    if (-not $disasterTestActive -and $settings.disasterTestUntil) {
        Set-ControlSetting -Name "disasterTestUntil" -Value $null
        $settings.disasterTestUntil = $null
    }

    $routes = Invoke-ControlJsonQuery -Sql @"
SELECT
    id, line, direction, via, via_eng AS viaEng,
    destination, destination_eng AS destinationEng,
    destination_kana AS destinationKana,
    COALESCE(transfer_guide, COALESCE(transfer_guide_1, '') || COALESCE(transfer_guide_2, ''), '') AS transferGuide,
    COALESCE(liner_stops, '') AS linerStops
FROM route_master
ORDER BY line, direction;
"@
    $timetable = Invoke-ControlJsonQuery -Sql @"
SELECT
    t.id, t.stop_key AS stopKey, t.section, t.schedule_type AS scheduleType,
    t.departure_time AS departureTime, t.route_id AS routeId,
    t.last_flag AS lastFlag, r.line, r.direction
FROM timetable_entries t
INNER JOIN route_master r ON r.id = t.route_id
ORDER BY t.schedule_type, t.section, t.departure_time, r.line;
"@
    return [ordered]@{
        updatedAt = (Get-Date).ToString("o")
        settings = $settings
        displayOverrides = @($displayOverrides)
        busTests = @($busTests)
        testMode = (@($busTests).Count -gt 0 -or $disasterTestActive)
        routes = @($routes)
        timetable = @($timetable)
    }
}

function Write-InformationControlState {
    $state = Get-InformationControlState
    $json = $state | ConvertTo-Json -Depth 30 -Compress
    $source = "window.informationControlData = $json;"
    $temporaryPath = "$informationControlStatePath.tmp"
    [IO.File]::WriteAllText($temporaryPath, $source, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $informationControlStatePath -Force
}

function New-ControlResponse {
    param(
        [string]$Body,
        [string]$ContentType = "application/json; charset=utf-8",
        [string]$Status = "200 OK"
    )

    return [pscustomobject]@{
        Handled = $true
        Body = $Body
        ContentType = $ContentType
        Status = $Status
    }
}

function Get-ControlJsonResponse {
    param([object]$Payload)

    return New-ControlResponse -Body ($Payload | ConvertTo-Json -Depth 30 -Compress)
}

function Get-ControlStaticResponse {
    param([string]$RelativePath)

    $allowedFiles = @{
        "index.html" = "text/html; charset=utf-8"
        "control.css" = "text/css; charset=utf-8"
        "control.js" = "application/javascript; charset=utf-8"
    }
    if (-not $allowedFiles.ContainsKey($RelativePath)) {
        return New-ControlResponse -Body "Not Found" -ContentType "text/plain; charset=utf-8" -Status "404 Not Found"
    }

    $path = Join-Path $informationControlWebRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return New-ControlResponse -Body "Not Found" -ContentType "text/plain; charset=utf-8" -Status "404 Not Found"
    }
    return New-ControlResponse `
        -Body (Get-Content -LiteralPath $path -Raw -Encoding UTF8) `
        -ContentType $allowedFiles[$RelativePath]
}

function Save-ControlRoute {
    param([object]$Request)

    $id = ([string]$Request.id).Trim()
    $line = ([string]$Request.line).Trim()
    $direction = ([string]$Request.direction).Trim()
    $destination = ([string]$Request.destination).Trim()
    if (-not $id -or -not $line -or -not $direction -or -not $destination) {
        throw "系統ID・系統番号・方向・行先は必須です。"
    }

    $sql = @"
PRAGMA foreign_keys=ON;
INSERT INTO route_master (
    id, line, direction, via, via_eng, destination, destination_eng,
    destination_kana, transfer_guide, liner_stops, updated_at
) VALUES (
    $(ConvertTo-ControlSqlText $id), $(ConvertTo-ControlSqlText $line),
    $(ConvertTo-ControlSqlText $direction), $(ConvertTo-ControlSqlText $Request.via),
    $(ConvertTo-ControlSqlText $Request.viaEng), $(ConvertTo-ControlSqlText $destination),
    $(ConvertTo-ControlSqlText $Request.destinationEng), $(ConvertTo-ControlSqlText $Request.destinationKana),
    $(ConvertTo-ControlSqlText $Request.transferGuide), $(ConvertTo-ControlSqlText $Request.linerStops), datetime('now')
)
ON CONFLICT(id) DO UPDATE SET
    line=excluded.line, direction=excluded.direction, via=excluded.via,
    via_eng=excluded.via_eng, destination=excluded.destination,
    destination_eng=excluded.destination_eng, destination_kana=excluded.destination_kana,
    transfer_guide=excluded.transfer_guide, liner_stops=excluded.liner_stops,
    updated_at=datetime('now');
"@
    Invoke-ControlSql -Sql $sql | Out-Null
}

function Save-ControlTimetableEntry {
    param([object]$Request)

    $stopKey = ([string]$Request.stopKey).Trim()
    $scheduleType = [string]$Request.scheduleType
    $section = ([string]$Request.section).Trim()
    $departureTime = ([string]$Request.departureTime).Trim()
    $routeId = ([string]$Request.routeId).Trim()
    if ($scheduleType -notin @("weekday", "saturday", "holiday")) { throw "ダイヤ種別が不正です。" }
    if (-not $section -or $departureTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$' -or -not $routeId) {
        throw "方面・時刻・路線を正しく指定してください。"
    }

    # 停留所と方面の対応を固定し、異なる停留所の時刻表が混ざることを防ぐ。
    $validSectionsByStop = @{
        tajima = @("oikebashi", "kumata", "abenobashi")
        oikebashi = @("oikebashiNorth", "oikebashiSouth")
        tajima5 = @("tajimaNorth", "tajimaSouth")
    }
    if (-not $validSectionsByStop.ContainsKey($stopKey) -or
        $section -notin $validSectionsByStop[$stopKey]) {
        throw "停留所と方面の組み合わせが不正です。"
    }

    $id = 0
    [void][int]::TryParse([string]$Request.id, [ref]$id)
    if ($id -gt 0) {
        $sql = @"
PRAGMA foreign_keys=ON;
UPDATE timetable_entries SET
    stop_key=$(ConvertTo-ControlSqlText $stopKey),
    section=$(ConvertTo-ControlSqlText $section),
    schedule_type=$(ConvertTo-ControlSqlText $scheduleType),
    departure_time=$(ConvertTo-ControlSqlText $departureTime),
    route_id=$(ConvertTo-ControlSqlText $routeId),
    last_flag=$(if ([bool]$Request.lastFlag) { 1 } else { 0 }),
    updated_at=datetime('now')
WHERE id=$id;
"@
    }
    else {
        $sql = @"
PRAGMA foreign_keys=ON;
INSERT INTO timetable_entries (stop_key, section, schedule_type, departure_time, route_id, last_flag)
VALUES (
    $(ConvertTo-ControlSqlText $stopKey),
    $(ConvertTo-ControlSqlText $section),
    $(ConvertTo-ControlSqlText $scheduleType),
    $(ConvertTo-ControlSqlText $departureTime),
    $(ConvertTo-ControlSqlText $routeId),
    $(if ([bool]$Request.lastFlag) { 1 } else { 0 })
);
"@
    }
    Invoke-ControlSql -Sql $sql | Out-Null
}

function Import-ControlTimetableEntrySet {
    param([object]$Request)

    if (-not (Get-Command Import-ControlOfficialTimetable -ErrorAction SilentlyContinue)) {
        throw "時刻表自動取得モジュールを読み込めません。"
    }
    $count = Import-ControlOfficialTimetable `
        -StopKey ([string]$Request.stopKey) `
        -Section ([string]$Request.section) `
        -ScheduleType ([string]$Request.scheduleType)
    $script:lastControlActionMessage = "公式時刻表から $count 件を取得しました。"
}

function Remove-ControlTimetableEntries {
    param([object]$Request)

    $ids = @($Request.ids | ForEach-Object {
        $parsed = 0
        if ([int]::TryParse([string]$_, [ref]$parsed) -and $parsed -gt 0) { $parsed }
    })
    if ($ids.Count -eq 0) { throw "削除する時刻表データを選択してください。" }
    Invoke-ControlSql -Sql ("DELETE FROM timetable_entries WHERE id IN ({0});" -f ($ids -join ",")) | Out-Null
}

function Remove-ControlTimetableFilter {
    param([object]$Request)

    $stopKey = [string]$Request.stopKey
    $section = [string]$Request.section
    $scheduleType = [string]$Request.scheduleType
    if (-not $stopKey -or -not $section -or $scheduleType -notin @("weekday", "saturday", "holiday")) {
        throw "削除対象の停留所・方面・ダイヤを正しく指定してください。"
    }
    $sql = @"
DELETE FROM timetable_entries
WHERE stop_key=$(ConvertTo-ControlSqlText $stopKey)
  AND section=$(ConvertTo-ControlSqlText $section)
  AND schedule_type=$(ConvertTo-ControlSqlText $scheduleType);
"@
    Invoke-ControlSql -Sql $sql | Out-Null
}

function ConvertTo-ControlLogTimestamp {
    param([object]$Value)

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToString("yyyy-MM-dd'T'HH:mm:ss.fffK", [Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Get-ControlInformationLogs {
    param([Uri]$Uri)

    $type = Get-QueryValue -Uri $Uri -Name "type"
    $subtype = Get-QueryValue -Uri $Uri -Name "subtype"
    $limitText = Get-QueryValue -Uri $Uri -Name "limit"
    $limit = if ($limitText -match '^\d+$') { [Math]::Min(2000, [int]$limitText) } else { 500 }
    $rows = New-Object Collections.ArrayList

    if ($type -eq "earthquake") {
        $path = Join-Path $projectDir "logs\earthquake_information.jsonl"
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8 | Select-Object -Last $limit)) {
                try {
                    $item = $line | ConvertFrom-Json
                    if ($subtype -and [string]$item.type -ne $subtype) { continue }
                    # C#が保存した既存のPascalCaseログも、管理画面用のcamelCaseへ統一する。
                    [void]$rows.Add([ordered]@{
                        type = [string]$item.type
                        isTest = [bool]$item.isTest
                        jmaIssueAt = ConvertTo-ControlLogTimestamp -Value $item.jmaIssueAt
                        receivedAt = ConvertTo-ControlLogTimestamp -Value $item.receivedAt
                        displayedAt = ConvertTo-ControlLogTimestamp -Value $item.displayedAt
                        details = $item.details
                    })
                }
                catch { }
            }
        }
    }
    elseif ($type -eq "api") {
        $paths = @(Get-ChildItem -Path (Join-Path $projectDir "logs\information") -Filter "fetcher_*.jsonl" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        foreach ($path in $paths) {
            foreach ($line in @(Get-Content -LiteralPath $path.FullName -Encoding UTF8)) {
                try {
                    $item = $line | ConvertFrom-Json
                    $text = $item | ConvertTo-Json -Depth 10 -Compress
                    if ($subtype -and $text -notmatch [regex]::Escape($subtype)) { continue }
                    [void]$rows.Add($item)
                }
                catch { }
            }
            if ($rows.Count -ge $limit) { break }
        }
    }

    return Get-ControlJsonResponse -Payload ([ordered]@{
        ok = $true
        type = $type
        subtype = $subtype
        rows = @($rows | Select-Object -Last $limit)
    })
}

function Set-ControlDisplayOverride {
    param([object]$Request)

    $status = [string]$Request.status
    if ($status -eq "運転見合わせ") { $status = "運行停止中" }
    $settings = Get-ControlSettings
    $entries = @(Remove-ExpiredControlEntries -Entries @($settings.displayOverrides) | Where-Object {
        $_.targetId -ne [string]$Request.targetId
    })
    if ($status -ne "normal") {
        $entries += [pscustomobject]@{
            targetId = [string]$Request.targetId
            status = $status
            expiresAt = [string]$Request.expiresAt
            enabled = $true
        }
    }
    Set-ControlSetting -Name "displayOverrides" -Value @($entries)
}

function Set-ControlBusTest {
    param([object]$Request)

    $settings = Get-ControlSettings
    $entries = @(Remove-ExpiredControlEntries -Entries @($settings.busTests))
    $entries += [pscustomobject]@{
        id = [guid]::NewGuid().ToString("N")
        surface = [string]$Request.surface
        section = [string]$Request.section
        type = [string]$Request.type
        time = [string]$Request.time
        line = [string]$Request.line
        delayMinutes = [int]$Request.delayMinutes
        expiresAt = [string]$Request.expiresAt
        enabled = $true
    }
    Set-ControlSetting -Name "busTests" -Value @($entries)
}

function Write-EarthquakeTestCommand {
    param([object]$Request)

    $kind = [string]$Request.kind
    $payload = [ordered]@{
        id = [guid]::NewGuid().ToString("N")
        kind = $kind
        scale = if ($Request.scale) { [string]$Request.scale } else { "3" }
        hypocenter = [string]$Request.hypocenter
        eewAreas = @($Request.eewAreas)
        earthquakePoints = @($Request.earthquakePoints)
        tsunamiAreas = @($Request.tsunamiAreas)
        requestedAt = (Get-Date).ToString("o")
    }
    $path = Join-Path $tempDir "earthquake_test_command.json"

    if ($kind -eq "clear") {
        Set-ControlSetting -Name "disasterTestUntil" -Value $null
    }
    else {
        # 画面に災害データが届く前に試験中表示を確定し、表示状態の競合を防ぐ。
        Set-ControlSetting -Name "disasterTestUntil" -Value (Get-Date).AddMinutes(10).ToString("o")
    }

    # 常駐ブリッジとの書き込み競合を避け、本番受信と同じイベント処理を排他的に実行する。
    Write-EarthquakeTestCommandFile -Path $path -Payload $payload
    Invoke-P2PEarthquakeBuiltInTest -CommandPath $path
}

function Write-EarthquakeTestCommandFile {
    param(
        [string]$Path,
        [object]$Payload
    )

    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    $temporaryPath = "$Path.tmp"
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Invoke-P2PEarthquakeBuiltInTest {
    param([string]$CommandPath)

    $bridgePath = Join-Path $projectDir "earthquake\SignageBridgeRuntime\EarthquakeSignageBridge.exe"
    if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
        throw "P2P地震速報ブリッジが見つかりません。"
    }

    Stop-EarthquakeMonitorForTest
    try {
        $process = Start-Process `
            -FilePath $bridgePath `
            -ArgumentList @($projectDir, "--exit-after-test") `
            -WorkingDirectory (Split-Path -Path $bridgePath -Parent) `
            -WindowStyle Hidden `
            -PassThru
        if (-not $process.WaitForExit(45000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "P2P内蔵テストが45秒以内に完了しませんでした。"
        }
        if ($process.ExitCode -ne 0) {
            throw "P2P内蔵テストが終了コード $($process.ExitCode) で失敗しました。"
        }
    }
    finally {
        Remove-Item -LiteralPath $CommandPath -Force -ErrorAction SilentlyContinue
        Start-EarthquakeMonitorIfNeeded
    }
}

function Stop-EarthquakeMonitorForTest {
    $monitorProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "powershell.exe" -and
            [string]$_.CommandLine -like "*earthquake_monitor.ps1*"
        })
    foreach ($monitor in $monitorProcesses) {
        Stop-Process -Id $monitor.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Get-Process -Name "EarthquakeSignageBridge" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Start-EarthquakeMonitorIfNeeded {
    $bridge = Get-Process -Name "EarthquakeSignageBridge" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($bridge) { return }

    $monitorPath = Join-Path $projectDir "earthquake\earthquake_monitor.ps1"
    if (-not (Test-Path -LiteralPath $monitorPath -PathType Leaf)) {
        throw "P2P地震速報ブリッジの監視スクリプトが見つかりません。"
    }

    $monitor = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "powershell.exe" -and
            [string]$_.CommandLine -like "*earthquake_monitor.ps1*"
        } |
        Select-Object -First 1
    if ($monitor) {
        # 監視だけ残ってブリッジが存在しない場合は、監視を再生成して直ちに復旧させる。
        Stop-Process -Id $monitor.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitorPath`"" `
        -WindowStyle Hidden
}

function Invoke-InformationControlAction {
    param([object]$Request)

    $script:lastControlActionMessage = "設定を反映しました。"
    switch ([string]$Request.action) {
        "saveRoute" { Save-ControlRoute -Request $Request }
        "deleteRoute" {
            Invoke-ControlSql -Sql "PRAGMA foreign_keys=ON; DELETE FROM route_master WHERE id=$(ConvertTo-ControlSqlText ([string]$Request.id));" | Out-Null
        }
        "saveTimetable" { Save-ControlTimetableEntry -Request $Request }
        "importTimetable" { Import-ControlTimetableEntrySet -Request $Request }
        "deleteTimetable" {
            $id = [int]$Request.id
            Invoke-ControlSql -Sql "DELETE FROM timetable_entries WHERE id=$id;" | Out-Null
        }
        "deleteTimetableMany" { Remove-ControlTimetableEntries -Request $Request }
        "deleteTimetableFilter" { Remove-ControlTimetableFilter -Request $Request }
        "displayOverride" { Set-ControlDisplayOverride -Request $Request }
        "busTest" { Set-ControlBusTest -Request $Request }
        "clearBusTests" { Set-ControlSetting -Name "busTests" -Value @() }
        "fallbackSchedule" {
            $value = [string]$Request.value
            if ($value -notin @("auto", "weekday", "saturday", "holiday")) { throw "ダイヤ指定が不正です。" }
            Set-ControlSetting -Name "fallbackScheduleType" -Value $value
        }
        "earthquakeTest" { Write-EarthquakeTestCommand -Request $Request }
        default { throw "未対応の操作です。" }
    }
    Write-InformationControlState
    return Get-InformationControlState
}

function Invoke-InformationControlRequest {
    param(
        [Uri]$Uri,
        [string]$Method,
        [string]$Body
    )

    $path = $Uri.AbsolutePath.TrimEnd("/")
    if ($path -eq "/infomation_control") {
        return Get-ControlStaticResponse -RelativePath "index.html"
    }
    if ($path -eq "/infomation_control/control.css") {
        return Get-ControlStaticResponse -RelativePath "control.css"
    }
    if ($path -eq "/infomation_control/control.js") {
        return Get-ControlStaticResponse -RelativePath "control.js"
    }
    if ($path -eq "/infomation_control/api/state" -and $Method -eq "GET") {
        Write-InformationControlState
        return Get-ControlJsonResponse -Payload ([ordered]@{ ok = $true; state = Get-InformationControlState })
    }
    if ($path -eq "/infomation_control/api/logs" -and $Method -eq "GET") {
        return Get-ControlInformationLogs -Uri $Uri
    }
    if ($path -eq "/infomation_control/api/action" -and $Method -eq "POST") {
        try {
            $request = $Body | ConvertFrom-Json
            $state = Invoke-InformationControlAction -Request $request
            return Get-ControlJsonResponse -Payload ([ordered]@{
                ok = $true
                state = $state
                message = $script:lastControlActionMessage
            })
        }
        catch {
            return New-ControlResponse `
                -Body (([ordered]@{ ok = $false; error = $_.Exception.Message }) | ConvertTo-Json -Compress) `
                -Status "400 Bad Request"
        }
    }

    return [pscustomobject]@{ Handled = $false }
}
