# ============================================================================== 
# Network monitoring SQLite helpers
# Description: 通信監視履歴を同梱SQLiteで保存・取得します。
# ============================================================================== 

function Get-NetworkSqlitePaths {
    param([string]$ProjectDir)

    $runtimeDir = Join-Path $ProjectDir "database\runtime"
    return [ordered]@{
        RuntimeDir = $runtimeDir
        DatabasePath = Join-Path $runtimeDir "network_monitor.sqlite3"
        LegacyJsonlPath = Join-Path $runtimeDir "network_monitor.jsonl"
        SqliteExePath = Join-Path $ProjectDir "bin\sqlite\sqlite3.exe"
    }
}

function Assert-NetworkSqliteTool {
    param([string]$SqliteExePath)

    if (-not (Test-Path -LiteralPath $SqliteExePath -PathType Leaf)) {
        throw "SQLite実行ファイルが見つかりません: $SqliteExePath"
    }
}

function ConvertTo-NetworkSqliteTextLiteral {
    param([object]$Value)

    if ($null -eq $Value) { return "NULL" }
    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) { return "NULL" }
    return "'" + $text.Replace("'", "''") + "'"
}

function ConvertTo-NetworkSqliteIntegerLiteral {
    param([object]$Value)

    if ($null -eq $Value) { return "NULL" }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return "NULL" }
    return ([int]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-NetworkSqliteRealLiteral {
    param([object]$Value)

    if ($null -eq $Value) { return "NULL" }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return "NULL" }
    return ([double]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-NetworkSqliteBoolLiteral {
    param([object]$Value)

    if ([bool]$Value) { return "1" }
    return "0"
}

function Invoke-NetworkSqliteCommand {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath,
        [string]$Sql
    )

    Assert-NetworkSqliteTool -SqliteExePath $SqliteExePath
    $maximumAttempts = 3
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        $output = & $SqliteExePath $DatabasePath $Sql 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) { return $output }

        $message = (($output | Out-String).Trim())
        if ($message -notmatch "database is locked|database table is locked" -or $attempt -eq $maximumAttempts) {
            throw $message
        }
        Start-Sleep -Milliseconds 150
    }
}

function Invoke-NetworkSqliteJsonQuery {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath,
        [string]$Sql
    )

    Assert-NetworkSqliteTool -SqliteExePath $SqliteExePath
    $output = $null
    $maximumAttempts = 3
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        $output = & $SqliteExePath -json $DatabasePath $Sql 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) { break }

        $message = (($output | Out-String).Trim())
        if ($message -notmatch "database is locked|database table is locked" -or $attempt -eq $maximumAttempts) {
            throw $message
        }
        Start-Sleep -Milliseconds 150
    }
    $json = (($output | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }
    return @(($json | ConvertFrom-Json))
}

function Add-NetworkSqliteColumnIfMissing {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath,
        [string]$ColumnName,
        [string]$ColumnDefinition
    )

    $columnRows = Invoke-NetworkSqliteJsonQuery `
        -SqliteExePath $SqliteExePath `
        -DatabasePath $DatabasePath `
        -Sql "PRAGMA table_info(network_measurements);"
    foreach ($column in @($columnRows)) {
        if ([string]$column.name -eq $ColumnName) { return }
    }

    Invoke-NetworkSqliteCommand `
        -SqliteExePath $SqliteExePath `
        -DatabasePath $DatabasePath `
        -Sql "ALTER TABLE network_measurements ADD COLUMN $ColumnName $ColumnDefinition;" | Out-Null
}

function Initialize-NetworkSqliteDatabase {
    param(
        [string]$RuntimeDir,
        [string]$DatabasePath,
        [string]$SqliteExePath
    )

    if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    }

    $schemaSql = @"
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS network_measurements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    target_id TEXT NOT NULL,
    target_name TEXT,
    address TEXT,
    result TEXT NOT NULL,
    ok INTEGER NOT NULL,
    response_time_ms INTEGER,
    error_detail TEXT,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    loss100_percent REAL NOT NULL DEFAULT 0,
    loss600_percent REAL NOT NULL DEFAULT 0,
    loss3600_percent REAL NOT NULL DEFAULT 0,
    loss21600_percent REAL NOT NULL DEFAULT 0,
    loss100_sample_count INTEGER,
    loss600_sample_count INTEGER,
    loss3600_sample_count INTEGER,
    loss21600_sample_count INTEGER,
    quality TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_network_measurements_target_timestamp
    ON network_measurements(target_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_network_measurements_timestamp
    ON network_measurements(timestamp);
"@
    Invoke-NetworkSqliteCommand -SqliteExePath $SqliteExePath -DatabasePath $DatabasePath -Sql $schemaSql | Out-Null
    Add-NetworkSqliteColumnIfMissing -SqliteExePath $SqliteExePath -DatabasePath $DatabasePath -ColumnName "loss100_sample_count" -ColumnDefinition "INTEGER"
    Add-NetworkSqliteColumnIfMissing -SqliteExePath $SqliteExePath -DatabasePath $DatabasePath -ColumnName "loss600_sample_count" -ColumnDefinition "INTEGER"
    Add-NetworkSqliteColumnIfMissing -SqliteExePath $SqliteExePath -DatabasePath $DatabasePath -ColumnName "loss3600_percent" -ColumnDefinition "REAL NOT NULL DEFAULT 0"
    Add-NetworkSqliteColumnIfMissing -SqliteExePath $SqliteExePath -DatabasePath $DatabasePath -ColumnName "loss21600_percent" -ColumnDefinition "REAL NOT NULL DEFAULT 0"
    Add-NetworkSqliteColumnIfMissing -SqliteExePath $SqliteExePath -DatabasePath $DatabasePath -ColumnName "loss3600_sample_count" -ColumnDefinition "INTEGER"
    Add-NetworkSqliteColumnIfMissing -SqliteExePath $SqliteExePath -DatabasePath $DatabasePath -ColumnName "loss21600_sample_count" -ColumnDefinition "INTEGER"
}

function Get-NetworkSqliteCount {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath
    )

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) { return 0 }

    try {
        $rows = Invoke-NetworkSqliteJsonQuery `
            -SqliteExePath $SqliteExePath `
            -DatabasePath $DatabasePath `
            -Sql "SELECT COUNT(*) AS count FROM network_measurements;"
        if ($rows.Count -eq 0) { return 0 }
        return [int]$rows[0].count
    }
    catch {
        return 0
    }
}

function Read-NetworkSqliteMeasurementCountsSince {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath,
        [datetime]$StartDate
    )

    $counts = @{}
    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) { return $counts }

    # オフライン判定はパケットロス率へ含めないため、累計検証回数からも除外します。
    $startText = $StartDate.ToString("yyyy-MM-ddTHH:mm:ss")
    $sql = @"
SELECT
    target_id AS targetId,
    COUNT(*) AS measurementCount
FROM network_measurements
WHERE result <> 'オフライン'
  AND substr(timestamp, 1, 19) >= $(ConvertTo-NetworkSqliteTextLiteral $startText)
GROUP BY target_id;
"@
    $rows = @(Invoke-NetworkSqliteJsonQuery `
        -SqliteExePath $SqliteExePath `
        -DatabasePath $DatabasePath `
        -Sql $sql)
    foreach ($row in $rows) {
        $targetId = [string]$row.targetId
        if (-not [string]::IsNullOrWhiteSpace($targetId)) {
            $counts[$targetId] = [long]$row.measurementCount
        }
    }
    return $counts
}

function New-NetworkMeasurementInsertSql {
    param([object]$Measurement)

    $timestamp = ConvertTo-NetworkSqliteTextLiteral $Measurement.timestamp
    $targetId = ConvertTo-NetworkSqliteTextLiteral $Measurement.targetId
    $targetName = ConvertTo-NetworkSqliteTextLiteral $Measurement.targetName
    $address = ConvertTo-NetworkSqliteTextLiteral $Measurement.address
    $result = ConvertTo-NetworkSqliteTextLiteral $Measurement.result
    $ok = ConvertTo-NetworkSqliteBoolLiteral $Measurement.ok
    $responseTimeMs = ConvertTo-NetworkSqliteIntegerLiteral $Measurement.responseTimeMs
    $errorDetail = ConvertTo-NetworkSqliteTextLiteral $Measurement.errorDetail
    $consecutiveFailures = ConvertTo-NetworkSqliteIntegerLiteral $Measurement.consecutiveFailures
    $loss100 = ConvertTo-NetworkSqliteRealLiteral $Measurement.loss100Percent
    $loss600 = ConvertTo-NetworkSqliteRealLiteral $Measurement.loss600Percent
    $loss3600 = ConvertTo-NetworkSqliteRealLiteral $Measurement.loss3600Percent
    $loss21600 = ConvertTo-NetworkSqliteRealLiteral $Measurement.loss21600Percent
    $loss100SampleCount = ConvertTo-NetworkSqliteIntegerLiteral $Measurement.loss100SampleCount
    $loss600SampleCount = ConvertTo-NetworkSqliteIntegerLiteral $Measurement.loss600SampleCount
    $loss3600SampleCount = ConvertTo-NetworkSqliteIntegerLiteral $Measurement.loss3600SampleCount
    $loss21600SampleCount = ConvertTo-NetworkSqliteIntegerLiteral $Measurement.loss21600SampleCount
    $quality = ConvertTo-NetworkSqliteTextLiteral $Measurement.quality

    return @"
INSERT INTO network_measurements (
    timestamp,
    target_id,
    target_name,
    address,
    result,
    ok,
    response_time_ms,
    error_detail,
    consecutive_failures,
    loss100_percent,
    loss600_percent,
    loss3600_percent,
    loss21600_percent,
    loss100_sample_count,
    loss600_sample_count,
    loss3600_sample_count,
    loss21600_sample_count,
    quality
) VALUES (
    $timestamp,
    $targetId,
    $targetName,
    $address,
    $result,
    $ok,
    $responseTimeMs,
    $errorDetail,
    $consecutiveFailures,
    $loss100,
    $loss600,
    $loss3600,
    $loss21600,
    $loss100SampleCount,
    $loss600SampleCount,
    $loss3600SampleCount,
    $loss21600SampleCount,
    $quality
);
"@
}

function Add-NetworkSqliteMeasurements {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath,
        [object[]]$Measurements
    )

    if (-not $Measurements -or $Measurements.Count -eq 0) { return }

    $sqlParts = New-Object System.Collections.ArrayList
    [void]$sqlParts.Add("PRAGMA busy_timeout=500;")
    [void]$sqlParts.Add("BEGIN IMMEDIATE;")
    foreach ($measurement in @($Measurements)) {
        try {
            [void]$sqlParts.Add((New-NetworkMeasurementInsertSql -Measurement $measurement))
        }
        catch {
            $measurementType = if ($null -eq $measurement) { "null" } else { $measurement.GetType().FullName }
            $failureValue = @($measurement.consecutiveFailures)
            $failureTypes = @($failureValue | ForEach-Object {
                if ($null -eq $_) { "null" } else { $_.GetType().FullName }
            }) -join ","
            throw "測定値SQL変換失敗 target=$($measurement.targetId), measurementType=$measurementType, consecutiveFailuresCount=$($failureValue.Count), consecutiveFailuresTypes=$failureTypes : $($_.Exception.Message)"
        }
    }
    [void]$sqlParts.Add("COMMIT;")

    Invoke-NetworkSqliteCommand `
        -SqliteExePath $SqliteExePath `
        -DatabasePath $DatabasePath `
        -Sql ($sqlParts -join "`n") | Out-Null
}

function Remove-InvalidDnsPingMeasurements {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath
    )

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) { return }

    # DNS対象へ誤ってPingを実行していた版が保存した偽の一般エラーだけを除去する。
    $sql = @"
DELETE FROM network_measurements
WHERE target_id IN ('dns-default', 'dns-google')
  AND result = '一般エラー'
  AND (error_detail IS NULL OR error_detail NOT LIKE 'nslookup %');
"@
    Invoke-NetworkSqliteCommand `
        -SqliteExePath $SqliteExePath `
        -DatabasePath $DatabasePath `
        -Sql $sql | Out-Null
}

function Import-LegacyNetworkJsonlToSqlite {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath,
        [string]$LegacyJsonlPath
    )

    if (-not (Test-Path -LiteralPath $LegacyJsonlPath -PathType Leaf)) { return }
    if ((Get-NetworkSqliteCount -SqliteExePath $SqliteExePath -DatabasePath $DatabasePath) -gt 0) { return }

    $batch = New-Object System.Collections.ArrayList
    foreach ($line in (Get-Content -LiteralPath $LegacyJsonlPath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try {
            $record = $line | ConvertFrom-Json
            [void]$batch.Add($record)
            if ($batch.Count -ge 500) {
                Add-NetworkSqliteMeasurements `
                    -SqliteExePath $SqliteExePath `
                    -DatabasePath $DatabasePath `
                    -Measurements @($batch.ToArray())
                $batch.Clear()
            }
        }
        catch {}
    }

    if ($batch.Count -gt 0) {
        Add-NetworkSqliteMeasurements `
            -SqliteExePath $SqliteExePath `
            -DatabasePath $DatabasePath `
            -Measurements @($batch.ToArray())
    }
}

function Trim-NetworkSqliteDatabase {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath,
        [int]$MaxRows
    )

    $safeMaxRows = [Math]::Max(1, $MaxRows)
    $sql = @"
DELETE FROM network_measurements
WHERE id NOT IN (
    SELECT id FROM network_measurements ORDER BY id DESC LIMIT $safeMaxRows
);
PRAGMA wal_checkpoint(TRUNCATE);
"@
    Invoke-NetworkSqliteCommand -SqliteExePath $SqliteExePath -DatabasePath $DatabasePath -Sql $sql | Out-Null
}

function Read-NetworkSqliteAvailableYears {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath,
        [string]$TargetId
    )

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) { return @() }

    $whereSql = ""
    if (-not [string]::IsNullOrWhiteSpace($TargetId)) {
        $whereSql = "WHERE target_id = $(ConvertTo-NetworkSqliteTextLiteral $TargetId)"
    }

    $sql = @"
SELECT DISTINCT CAST(substr(timestamp, 1, 4) AS INTEGER) AS year
FROM network_measurements
$whereSql
ORDER BY year ASC;
"@
    $rows = Invoke-NetworkSqliteJsonQuery `
        -SqliteExePath $SqliteExePath `
        -DatabasePath $DatabasePath `
        -Sql $sql
    return @($rows | ForEach-Object { [int]$_.year } | Where-Object { $_ -gt 0 })
}
function Read-NetworkSqliteHistory {
    param(
        [string]$SqliteExePath,
        [string]$DatabasePath,
        [string]$TargetId,
        [int]$Limit = 1200,
        [int]$Offset = 0,
        [string]$SortOrder = "desc",
        [string]$ResultFilter,
        $StartDate,
        $EndDate
    )

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) { return @() }

    $safeLimit = [Math]::Min(50000, [Math]::Max(1, $Limit))
    $safeOffset = [Math]::Max(0, $Offset)
    $orderSql = if ([string]$SortOrder -eq "asc") { "ASC" } else { "DESC" }
    $where = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($TargetId)) {
        [void]$where.Add("target_id = $(ConvertTo-NetworkSqliteTextLiteral $TargetId)")
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultFilter) -and $ResultFilter -ne "all") {
        [void]$where.Add("result = $(ConvertTo-NetworkSqliteTextLiteral $ResultFilter)")
    }
    if ($StartDate) {
        [void]$where.Add("substr(timestamp, 1, 19) >= $(ConvertTo-NetworkSqliteTextLiteral $StartDate.ToString('yyyy-MM-ddTHH:mm:ss'))")
    }
    if ($EndDate) {
        [void]$where.Add("substr(timestamp, 1, 19) <= $(ConvertTo-NetworkSqliteTextLiteral $EndDate.ToString('yyyy-MM-ddTHH:mm:ss'))")
    }

    $whereSql = ""
    if ($where.Count -gt 0) {
        $whereSql = "WHERE " + ($where -join " AND ")
    }

    $sql = @"
SELECT
    timestamp AS timestamp,
    target_id AS targetId,
    target_name AS targetName,
    address AS address,
    result AS result,
    ok AS ok,
    response_time_ms AS responseTimeMs,
    error_detail AS errorDetail,
    consecutive_failures AS consecutiveFailures,
    loss100_percent AS loss100Percent,
    loss600_percent AS loss600Percent,
    loss3600_percent AS loss3600Percent,
    loss21600_percent AS loss21600Percent,
    loss100_sample_count AS loss100SampleCount,
    loss600_sample_count AS loss600SampleCount,
    loss3600_sample_count AS loss3600SampleCount,
    loss21600_sample_count AS loss21600SampleCount,
    quality AS quality
FROM network_measurements
$whereSql
ORDER BY id $orderSql
LIMIT $safeLimit OFFSET $safeOffset;
"@

    $rows = Invoke-NetworkSqliteJsonQuery `
        -SqliteExePath $SqliteExePath `
        -DatabasePath $DatabasePath `
        -Sql $sql
    foreach ($row in @($rows)) {
        $row.ok = ([int]$row.ok -eq 1)
        if ([string]$row.quality -eq "オフライン") {
            try {
                $timestamp = [datetimeoffset]::Parse([string]$row.timestamp)
                if ($timestamp.LocalDateTime.Hour -lt 7) {
                    $row.quality = "通信エラー"
                }
            }
            catch {}
        }
    }
    return @($rows)
}
