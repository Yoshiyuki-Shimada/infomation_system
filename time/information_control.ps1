# LAN内管理画面の永続化・API処理。time_signal.ps1 から読み込んで使用する。
$informationControlDbPath = Join-Path $runtimeDbDir "information_control.sqlite3"
$informationControlStatePath = Join-Path $tempDir "control_data.js"
$informationControlWebRoot = Join-Path $projectDir "infomation_control"
$informationControlUploadRoot = Join-Path $projectDir "_update\uploads"
$informationControlUpdateInbox = Join-Path $projectDir "_update\management_inbox"
$informationControlUpdateConfigPath = Join-Path $projectDir "bin\update_config.json"
$informationControlMaximumUpdateBytes = 536870912
$script:informationControlInitialized = $false
$script:disasterReferenceData = $null
$script:japanesePrefectureOrder = @(
    "北海道", "青森県", "岩手県", "宮城県", "秋田県", "山形県", "福島県",
    "茨城県", "栃木県", "群馬県", "埼玉県", "千葉県", "東京都", "神奈川県",
    "新潟県", "富山県", "石川県", "福井県", "山梨県", "長野県", "岐阜県",
    "静岡県", "愛知県", "三重県", "滋賀県", "京都府", "大阪府", "兵庫県",
    "奈良県", "和歌山県", "鳥取県", "島根県", "岡山県", "広島県", "山口県",
    "徳島県", "香川県", "愛媛県", "高知県", "福岡県", "佐賀県", "長崎県",
    "熊本県", "大分県", "宮崎県", "鹿児島県", "沖縄県"
)
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

function Get-ConverterDictionaryOptions {
    param([string]$DictionaryName)

    $path = Join-Path $projectDir "earthquake\Map\Model\EEWConverter.cs"
    $source = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $dictionaryPattern = "(?s)$([regex]::Escape($DictionaryName))\s*=\s*new\(\)\s*\{(?<body>.*?)\n\s*\};"
    $dictionaryMatch = [regex]::Match($source, $dictionaryPattern)
    if (-not $dictionaryMatch.Success) { return @() }

    return @([regex]::Matches($dictionaryMatch.Groups["body"].Value, '\{\s*(?<code>\d+)\s*,\s*"(?<name>[^"]+)"\s*\}') | ForEach-Object {
        [ordered]@{
            code = [int]$_.Groups["code"].Value
            name = $_.Groups["name"].Value
        }
    })
}

function Get-PrefectureOrder {
    param([string]$Prefecture)

    $index = [array]::IndexOf($script:japanesePrefectureOrder, $Prefecture)
    return $(if ($index -ge 0) { $index } else { [int]::MaxValue })
}

function Get-ObservationPointOptions {
    $path = Join-Path $projectDir "earthquake\Map\Resources\Points\Stations.csv"
    $rows = Get-Content -LiteralPath $path -Encoding UTF8 |
        ConvertFrom-Csv -Header "pref", "name", "latitude", "longitude", "source"
    $unique = @{}
    foreach ($row in $rows) {
        $key = "$($row.pref)|$($row.name)"
        if (-not $unique.ContainsKey($key)) {
            $unique[$key] = [ordered]@{ pref = [string]$row.pref; name = [string]$row.name }
        }
    }
    return @($unique.Values | Sort-Object { Get-PrefectureOrder $_.pref }, { $_.name })
}

function Get-ObservationAreaOptions {
    $path = Join-Path $projectDir "earthquake\Map\Resources\Points\Areas.csv"
    $rows = Get-Content -LiteralPath $path -Encoding UTF8 |
        Select-Object -Skip 1 |
        ConvertFrom-Csv -Header "pref", "name", "latitude", "longitude"
    return @($rows | ForEach-Object {
        [ordered]@{ pref = [string]$_.pref; name = [string]$_.name }
    } | Sort-Object { Get-PrefectureOrder $_.pref }, { $_.name })
}

function Get-HypocenterOptions {
    $hypocenters = @(Get-ConverterDictionaryOptions -DictionaryName "code2Hypocenter")
    $areaPath = Join-Path $projectDir "earthquake\Map\Resources\Points\Areas.csv"
    $areaRows = @(Get-Content -LiteralPath $areaPath -Encoding UTF8 |
        Select-Object -Skip 1 |
        ConvertFrom-Csv -Header "pref", "name", "latitude", "longitude")
    $aliases = @{
        "紀伊水道" = "和歌山県"
        "大阪湾" = "大阪府"
        "播磨灘" = "兵庫県"
        "淡路島付近" = "兵庫県"
        "若狭湾" = "福井県"
        "瀬戸内海" = "岡山県"
        "安芸灘" = "広島県"
        "周防灘" = "山口県"
        "伊予灘" = "愛媛県"
        "豊後水道" = "大分県"
        "土佐湾" = "高知県"
        "東京湾" = "東京都"
        "相模湾" = "神奈川県"
        "三河湾" = "愛知県"
        "伊勢湾" = "三重県"
        "富山湾" = "富山県"
        "有明海" = "熊本県"
        "橘湾" = "長崎県"
        "鹿児島湾" = "鹿児島県"
    }

    return @($hypocenters | ForEach-Object {
        $hypocenter = $_
        $targetPref = $null
        foreach ($pref in $script:japanesePrefectureOrder) {
            $stem = $pref -replace "[都道府県]$", ""
            if ($hypocenter.name -like "*$stem*") {
                $targetPref = $pref
                break
            }
        }
        if (-not $targetPref -and $aliases.ContainsKey([string]$hypocenter.name)) {
            $targetPref = $aliases[[string]$hypocenter.name]
        }

        $coordinateRows = @($areaRows | Where-Object pref -eq $targetPref)
        $latitude = $null
        $longitude = $null
        if ($coordinateRows.Count -gt 0) {
            $latitude = ($coordinateRows | Measure-Object -Property latitude -Average).Average
            $longitude = ($coordinateRows | Measure-Object -Property longitude -Average).Average
        }

        [ordered]@{
            code = [int]$hypocenter.code
            name = [string]$hypocenter.name
            latitude = $latitude
            longitude = $longitude
        }
    })
}

function Get-TsunamiAreaOptions {
    $path = Join-Path $projectDir "earthquake\Map\Resources\Points\TsunamiAreaCodes.csv"
    return @(Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object {
        $parts = $_ -split ",", 2
        if ($parts.Count -eq 2) {
            [ordered]@{ code = [int]$parts[0]; name = [string]$parts[1] }
        }
    })
}

function Get-DisasterReferenceData {
    if ($script:disasterReferenceData) { return $script:disasterReferenceData }

    $script:disasterReferenceData = [ordered]@{
        eewAreas = @(Get-ConverterDictionaryOptions -DictionaryName "code2AreaName")
        hypocenters = @(Get-HypocenterOptions)
        observationAreas = @(Get-ObservationAreaOptions)
        observationPoints = @(Get-ObservationPointOptions)
        tsunamiAreas = @(Get-TsunamiAreaOptions)
    }
    return $script:disasterReferenceData
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

function Get-ControlScreenList {
    Add-Type -AssemblyName System.Windows.Forms
    $screens = @([Windows.Forms.Screen]::AllScreens | Sort-Object `
        @{ Expression = { if ($_.Primary) { 0 } else { 1 } } }, `
        @{ Expression = { $_.Bounds.X } }, `
        @{ Expression = { $_.Bounds.Y } })

    $result = for ($index = 0; $index -lt $screens.Count; $index++) {
        $screen = $screens[$index]
        [ordered]@{
            number = $index + 1
            deviceName = $screen.DeviceName
            primary = $screen.Primary
            x = $screen.Bounds.X
            y = $screen.Bounds.Y
            width = $screen.Bounds.Width
            height = $screen.Bounds.Height
        }
    }
    return @($result)
}

function Get-ControlScreenshot {
    param([int]$ScreenNumber)

    Add-Type -AssemblyName System.Drawing
    $screens = @(Get-ControlScreenList)
    if ($ScreenNumber -lt 1 -or $ScreenNumber -gt $screens.Count) {
        throw "指定した画面は接続されていません。"
    }

    $screen = $screens[$ScreenNumber - 1]
    $bitmap = [Drawing.Bitmap]::new([int]$screen.width, [int]$screen.height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $stream = [IO.MemoryStream]::new()
    try {
        $graphics.CopyFromScreen(
            [int]$screen.x,
            [int]$screen.y,
            0,
            0,
            $bitmap.Size,
            [Drawing.CopyPixelOperation]::SourceCopy)
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return [ordered]@{
            ok = $true
            screen = $screen
            capturedAt = (Get-Date).ToString("o")
            mimeType = "image/png"
            dataBase64 = [Convert]::ToBase64String($stream.ToArray())
        }
    }
    finally {
        $stream.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Write-ControlJsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-ControlUpdateSignatureText {
    param([object]$Value)

    return ($Value.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$($_.Value)"
    }) -join "`n"
}

function Get-ControlUpdateHmac {
    param(
        [string]$Text,
        [string]$Secret
    )

    $keyBytes = [Text.Encoding]::UTF8.GetBytes($Secret)
    $textBytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hmac = [Security.Cryptography.HMACSHA256]::new($keyBytes)
    try {
        return (($hmac.ComputeHash($textBytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $hmac.Dispose()
    }
}

function Get-ControlUpdateAuthToken {
    if (-not (Test-Path -LiteralPath $informationControlUpdateConfigPath -PathType Leaf)) {
        throw "更新設定ファイルがありません。"
    }

    $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $informationControlUpdateConfigPath |
        ConvertFrom-Json
    $token = [string]$config.authToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "更新用の認証情報が設定されていません。"
    }
    return $token
}

function Test-ControlUpdateArchive {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($archive.Entries.Count -eq 0) {
            throw "更新ZIPにファイルがありません。"
        }

        $forbiddenPrefixes = @(".git/", "_update/", "temp/", "logs/", "database/runtime/")
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace("\", "/").Trim()
            $segments = @($entryName.Split("/") | Where-Object { $_ })
            $isInvalidPath = $entryName.StartsWith("/") -or
                $entryName -match '^[A-Za-z]:' -or
                $segments -contains ".."
            if ($isInvalidPath) {
                throw "更新ZIPに使用できないパスがあります: $entryName"
            }
            foreach ($prefix in $forbiddenPrefixes) {
                if ($entryName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "更新対象外のパスが含まれています: $entryName"
                }
            }
            if ($entryName.Equals("bin/update_config.json", [StringComparison]::OrdinalIgnoreCase)) {
                throw "更新設定ファイルは管理画面から変更できません。"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Start-ControlUpdateUpload {
    param([object]$Request)

    $size = [int64]$Request.size
    if ($size -le 0 -or $size -gt $informationControlMaximumUpdateBytes) {
        throw "更新ZIPのサイズが不正です。上限は512MBです。"
    }
    if ([IO.Path]::GetExtension([string]$Request.fileName) -ne ".zip") {
        throw "ZIPファイルを選択してください。"
    }

    New-Item -ItemType Directory -Path $informationControlUploadRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $informationControlUploadRoot -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt (Get-Date).AddHours(-24) |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $uploadId = [guid]::NewGuid().ToString("N")
    $metadata = [ordered]@{
        uploadId = $uploadId
        fileName = [IO.Path]::GetFileName([string]$Request.fileName)
        expectedSize = $size
        receivedSize = 0L
        nextChunk = 0
        createdAt = (Get-Date).ToString("o")
    }
    Write-ControlJsonFile -Path (Join-Path $informationControlUploadRoot "$uploadId.json") -Value $metadata
    [IO.File]::WriteAllBytes((Join-Path $informationControlUploadRoot "$uploadId.part"), [byte[]]@())
    return [ordered]@{ ok = $true; uploadId = $uploadId; nextChunk = 0 }
}

function Add-ControlUpdateUploadChunk {
    param([object]$Request)

    $uploadId = [string]$Request.uploadId
    if ($uploadId -notmatch '^[a-f0-9]{32}$') { throw "アップロードIDが不正です。" }
    $metadataPath = Join-Path $informationControlUploadRoot "$uploadId.json"
    $partPath = Join-Path $informationControlUploadRoot "$uploadId.part"
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw "アップロード情報がありません。" }

    $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath | ConvertFrom-Json
    $chunkIndex = [int]$Request.index
    if ($chunkIndex -ne [int]$metadata.nextChunk) { throw "更新データの送信順序が不正です。" }
    $bytes = [Convert]::FromBase64String([string]$Request.dataBase64)
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 1048576) { throw "更新データの分割サイズが不正です。" }
    if (([int64]$metadata.receivedSize + $bytes.Length) -gt [int64]$metadata.expectedSize) {
        throw "更新データが予定サイズを超えています。"
    }

    $stream = [IO.File]::Open($partPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
    $metadata.receivedSize = [int64]$metadata.receivedSize + $bytes.Length
    $metadata.nextChunk = $chunkIndex + 1
    Write-ControlJsonFile -Path $metadataPath -Value $metadata
    return [ordered]@{
        ok = $true
        uploadId = $uploadId
        nextChunk = $metadata.nextChunk
        receivedSize = $metadata.receivedSize
    }
}

function Complete-ControlUpdateUpload {
    param([object]$Request)

    $uploadId = [string]$Request.uploadId
    if ($uploadId -notmatch '^[a-f0-9]{32}$') { throw "アップロードIDが不正です。" }
    $metadataPath = Join-Path $informationControlUploadRoot "$uploadId.json"
    $partPath = Join-Path $informationControlUploadRoot "$uploadId.part"
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $partPath -PathType Leaf)) {
        throw "アップロード済みの更新データがありません。"
    }

    $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath | ConvertFrom-Json
    $actualSize = (Get-Item -LiteralPath $partPath).Length
    if ($actualSize -ne [int64]$metadata.expectedSize -or $actualSize -ne [int64]$metadata.receivedSize) {
        throw "更新データのサイズが一致しません。"
    }
    Test-ControlUpdateArchive -Path $partPath

    New-Item -ItemType Directory -Path $informationControlUpdateInbox -Force | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $packageName = "infomation_system_update_${timestamp}_management.zip"
    $packagePath = Join-Path $informationControlUpdateInbox $packageName
    $authToken = Get-ControlUpdateAuthToken
    Move-Item -LiteralPath $partPath -Destination $packagePath -Force -ErrorAction Stop
    $createdAt = (Get-Date).ToUniversalTime().ToString("o")
    $signedValue = [ordered]@{
        schemaVersion = 1
        package = $packageName
        sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256 -ErrorAction Stop).Hash
        createdAt = $createdAt
        sourceComputer = "MANAGEMENT-WEB"
        restartAfterUpdate = $true
    }
    $manifest = [ordered]@{}
    foreach ($item in $signedValue.GetEnumerator()) { $manifest[$item.Key] = $item.Value }
    $manifest.signature = Get-ControlUpdateHmac `
        -Text (Get-ControlUpdateSignatureText -Value $signedValue) `
        -Secret $authToken
    $readyPath = Join-Path $informationControlUpdateInbox "infomation_system_update_${timestamp}_management.ready.json"
    Write-ControlJsonFile -Path "$readyPath.tmp" -Value $manifest
    Move-Item -LiteralPath "$readyPath.tmp" -Destination $readyPath -Force -ErrorAction Stop
    Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
    return [ordered]@{ ok = $true; accepted = $true; package = $packageName }
}

function Stop-ControlUpdateUpload {
    param([object]$Request)

    $uploadId = [string]$Request.uploadId
    if ($uploadId -match '^[a-f0-9]{32}$') {
        Remove-Item -LiteralPath (Join-Path $informationControlUploadRoot "$uploadId.json") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $informationControlUploadRoot "$uploadId.part") -Force -ErrorAction SilentlyContinue
    }
    return [ordered]@{ ok = $true; cancelled = $true }
}

function Invoke-ControlUpdateUpload {
    param([object]$Request)

    switch ([string]$Request.operation) {
        "start" { return Start-ControlUpdateUpload -Request $Request }
        "chunk" { return Add-ControlUpdateUploadChunk -Request $Request }
        "finish" { return Complete-ControlUpdateUpload -Request $Request }
        "cancel" { return Stop-ControlUpdateUpload -Request $Request }
        default { throw "更新操作が不正です。" }
    }
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
    elseif ($type -eq "earthquake_bridge") {
        $bridgeLogFiles = @(
            [ordered]@{ path = (Join-Path $projectDir "logs\earthquake_bridge.log"); source = "monitor" },
            [ordered]@{ path = (Join-Path $projectDir "logs\earthquake_bridge_events.log"); source = "bridge" }
        )
        foreach ($logFile in $bridgeLogFiles) {
            if (-not (Test-Path -LiteralPath $logFile.path -PathType Leaf)) { continue }
            foreach ($line in @(Get-Content -LiteralPath $logFile.path -Encoding UTF8 | Select-Object -Last $limit)) {
                $match = [regex]::Match([string]$line, '^(?<timestamp>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+(?<message>.*)$')
                if (-not $match.Success) { continue }
                if ($subtype -and $match.Groups['message'].Value -notmatch [regex]::Escape($subtype)) { continue }
                [void]$rows.Add([ordered]@{
                    timestamp = $match.Groups['timestamp'].Value
                    source = $logFile.source
                    message = $match.Groups['message'].Value
                })
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
        hypocenterLatitude = [string]$Request.hypocenterLatitude
        hypocenterLongitude = [string]$Request.hypocenterLongitude
        occurredAt = [string]$Request.occurredAt
        earthquakeType = [string]$Request.earthquakeType
        eewType = if ($Request.eewType) { [string]$Request.eewType } else { "announcement" }
        magnitude = [string]$Request.magnitude
        depth = [string]$Request.depth
        tsunamiType = [string]$Request.tsunamiType
        eewAreas = @($Request.eewAreas)
        earthquakeAreas = @($Request.earthquakeAreas)
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
    if ($path -eq "/infomation_control/api/disaster-reference" -and $Method -eq "GET") {
        return Get-ControlJsonResponse -Payload ([ordered]@{ ok = $true; data = Get-DisasterReferenceData })
    }
    if ($path -eq "/infomation_control/api/logs" -and $Method -eq "GET") {
        return Get-ControlInformationLogs -Uri $Uri
    }
    if ($path -eq "/infomation_control/api/screens" -and $Method -eq "GET") {
        try {
            return Get-ControlJsonResponse -Payload ([ordered]@{ ok = $true; screens = @(Get-ControlScreenList) })
        }
        catch {
            return New-ControlResponse -Body (([ordered]@{ ok = $false; error = $_.Exception.Message }) | ConvertTo-Json -Compress) -Status "500 Internal Server Error"
        }
    }
    if ($path -eq "/infomation_control/api/screenshot" -and $Method -eq "GET") {
        try {
            $screenNumber = 0
            [void][int]::TryParse((Get-QueryValue -Uri $Uri -Name "screen"), [ref]$screenNumber)
            return Get-ControlJsonResponse -Payload (Get-ControlScreenshot -ScreenNumber $screenNumber)
        }
        catch {
            return New-ControlResponse -Body (([ordered]@{ ok = $false; error = $_.Exception.Message }) | ConvertTo-Json -Compress) -Status "400 Bad Request"
        }
    }
    if ($path -eq "/infomation_control/api/update-upload" -and $Method -eq "POST") {
        try {
            $request = $Body | ConvertFrom-Json
            return Get-ControlJsonResponse -Payload (Invoke-ControlUpdateUpload -Request $request)
        }
        catch {
            return New-ControlResponse -Body (([ordered]@{ ok = $false; error = $_.Exception.Message }) | ConvertTo-Json -Compress) -Status "400 Bad Request"
        }
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
