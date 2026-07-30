[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

$projectDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path $projectDir "temp"
$outputPath = Join-Path $tempDir "earthquake_data.js"
$playScript = Join-Path $PSScriptRoot "play_eew_sequence.ps1"
$eewPriorityPath = Join-Path $tempDir "eew_audio_priority.lock"
$ua = "SnowLinkDrone-EarthquakeMonitor/1.0"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$lastPayloadJson = ""
$lastEewAudioKey = ""
$audioProcess = $null

function Convert-ScaleText {
    param([int]$Scale)
    switch ($Scale) {
        10 { "1" }
        20 { "2" }
        30 { "3" }
        40 { "4" }
        45 { "5弱" }
        50 { "5強" }
        55 { "6弱" }
        60 { "6強" }
        70 { "7" }
        default { if ($Scale -gt 0) { [string]$Scale } else { "-" } }
    }
}

function Parse-QuakeTime {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return [datetime]::Parse($Value) } catch { return $null }
}

function Invoke-P2PHistory {
    param([int]$Code, [int]$Limit = 1)
    try {
        return Invoke-RestMethod -Uri "https://api.p2pquake.net/v2/history?codes=$Code&limit=$Limit" -UserAgent $ua -TimeoutSec 10
    }
    catch {
        Write-Host "P2P取得失敗 code=$Code $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Invoke-JmaJson {
    param([string]$Uri)
    try {
        $client = New-Object System.Net.WebClient
        $client.Headers.Add("User-Agent", $ua)
        $bytes = $client.DownloadData($Uri)
        $jsonText = [System.Text.Encoding]::UTF8.GetString($bytes)
        return $jsonText | ConvertFrom-Json
    }
    catch {
        Write-Host "気象庁取得失敗 $Uri $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Convert-JmaScale {
    param($Scale)
    switch ([string]$Scale) {
        "7" { 70 }
        "6+" { 60 }
        "6-" { 55 }
        "5+" { 50 }
        "5-" { 45 }
        "4" { 40 }
        "3" { 30 }
        "2" { 20 }
        "1" { 10 }
        default { 0 }
    }
}

function Get-JmaPrefName {
    param([string]$Code)
    $prefMap = @{
        "01"="北海道"; "02"="青森県"; "03"="岩手県"; "04"="宮城県"; "05"="秋田県"; "06"="山形県"; "07"="福島県";
        "08"="茨城県"; "09"="栃木県"; "10"="群馬県"; "11"="埼玉県"; "12"="千葉県"; "13"="東京都"; "14"="神奈川県";
        "15"="新潟県"; "16"="富山県"; "17"="石川県"; "18"="福井県"; "19"="山梨県"; "20"="長野県"; "21"="岐阜県"; "22"="静岡県"; "23"="愛知県";
        "24"="三重県"; "25"="滋賀県"; "26"="京都府"; "27"="大阪府"; "28"="兵庫県"; "29"="奈良県"; "30"="和歌山県";
        "31"="鳥取県"; "32"="島根県"; "33"="岡山県"; "34"="広島県"; "35"="山口県"; "36"="徳島県"; "37"="香川県"; "38"="愛媛県"; "39"="高知県";
        "40"="福岡県"; "41"="佐賀県"; "42"="長崎県"; "43"="熊本県"; "44"="大分県"; "45"="宮崎県"; "46"="鹿児島県"; "47"="沖縄県"
    }
    if ([string]::IsNullOrWhiteSpace($Code) -or $Code.Length -lt 2) { return "その他" }
    $key = $Code.Substring(0, 2)
    if ($prefMap.ContainsKey($key)) { return $prefMap[$key] }
    return "その他"
}

function Get-JmaAreaName {
    param($AreaMaster, [string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return "" }

    $fallbackMap = @{
        "4010100"="北九州市門司区"; "4010300"="北九州市若松区"; "4010500"="北九州市戸畑区"; "4010600"="北九州市小倉北区";
        "4010700"="北九州市小倉南区"; "4010800"="北九州市八幡東区"; "4010900"="北九州市八幡西区";
        "4013100"="福岡市東区"; "4013200"="福岡市博多区"; "4013300"="福岡市中央区"; "4013400"="福岡市南区";
        "4013500"="福岡市西区"; "4013600"="福岡市城南区"; "4013700"="福岡市早良区";
        "4310100"="熊本市中央区"; "4310200"="熊本市東区"; "4310300"="熊本市西区"; "4310400"="熊本市南区"; "4310500"="熊本市北区";
        "4320200"="八代市"; "4221200"="西海市"
    }

    if ($fallbackMap.ContainsKey($Code)) { return $fallbackMap[$Code] }

    foreach ($section in @("class20s", "class15s", "class10s", "offices", "centers")) {
        if ($AreaMaster.$section -and $AreaMaster.$section.$Code -and -not [string]::IsNullOrWhiteSpace($AreaMaster.$section.$Code.name)) {
            return $AreaMaster.$section.$Code.name
        }
    }
    return $Code
}

function Convert-JmaQuakeToP2PShape {
    param($JmaQuake, $AreaMaster)
    if (-not $JmaQuake) { return $null }

    $points = @()
    foreach ($pref in @($JmaQuake.int)) {
        foreach ($city in @($pref.city)) {
            $scale = Convert-JmaScale $city.maxi
            if ($scale -le 0) { continue }
            $cityCode = [string]$city.code
            $cityName = Get-JmaAreaName -AreaMaster $AreaMaster -Code $cityCode
            $points += [pscustomobject]@{
                pref = Get-JmaPrefName $cityCode
                addr = $cityName
                scale = $scale
            }
        }
    }

    $maxScale = Convert-JmaScale $JmaQuake.maxi
    if ($maxScale -le 0 -and $points.Count -gt 0) {
        $maxScale = [int](@($points | Sort-Object scale -Descending | Select-Object -First 1).scale)
    }

    [pscustomobject]@{
        id = $JmaQuake.eid
        issue = [pscustomobject]@{ time = $JmaQuake.rdt }
        earthquake = [pscustomobject]@{
            time = $JmaQuake.at
            maxScale = $maxScale
            domesticTsunami = "不明"
            hypocenter = [pscustomobject]@{
                name = $JmaQuake.anm
                magnitude = $JmaQuake.mag
                depth = ""
            }
        }
        points = $points
    }
}

function Invoke-JmaQuakeHistory {
    $rawList = Invoke-JmaJson "https://www.jma.go.jp/bosai/quake/data/list.json"
    $list = @(foreach ($item in $rawList) { $item })
    if ($list.Count -eq 0) { return @() }
    $areaMaster = Invoke-JmaJson "https://www.jma.go.jp/bosai/common/const/area.json"
    if (-not $areaMaster) { return @() }

    return @($list |
        Where-Object { $_.ttl -eq "震源・震度情報" -or $_.ttl -eq "震度速報" } |
        ForEach-Object { Convert-JmaQuakeToP2PShape -JmaQuake $_ -AreaMaster $areaMaster })
}

function Get-RetentionUntil {
    param($Quake, [datetime]$BaseTime)
    $maxScale = if ($null -ne $Quake.earthquake.maxScale) { [int]$Quake.earthquake.maxScale } else { 0 }
    $ikuno = $Quake.points | Where-Object { $_.addr -match "生野区" } | Sort-Object scale -Descending | Select-Object -First 1
    $ikunoScale = if ($ikuno) { [int]$ikuno.scale } else { 0 }

    if ($maxScale -ge 70) { return $BaseTime.AddHours(5) }
    if ($maxScale -ge 45) { return $BaseTime.AddHours(3) }
    if ($ikunoScale -ge 30) { return $BaseTime.AddHours(1) }
    return $null
}

function Get-EmergencyUntil {
    param($Quake, [datetime]$BaseTime)
    $maxScale = if ($null -ne $Quake.earthquake.maxScale) { [int]$Quake.earthquake.maxScale } else { 0 }
    if ($maxScale -ge 70) { return $BaseTime.AddHours(72) }
    if ($maxScale -ge 45) { return $BaseTime.AddHours(6) }
    return $null
}

function Get-QuakeIssueTypeLabel {
    param([string]$Type)
    switch ($Type) {
        "ScalePrompt" { "震度速報" }
        "Destination" { "震源速報" }
        "DetailScale" { "各地の震度情報" }
        default { "地震情報" }
    }
}

function Get-ActiveQuakeBulletin {
    param(
        [array]$QuakeList,
        $Eew,
        [datetime]$Now
    )

    $bulletins = @($QuakeList | Where-Object {
        $_ -and $_.issue.type -in @("ScalePrompt", "Destination", "DetailScale")
    })
    if ($bulletins.Count -eq 0) { return $null }

    $significantOrigins = @($bulletins | Where-Object {
        $_.issue.type -in @("ScalePrompt", "DetailScale") -and
        $null -ne $_.earthquake.maxScale -and
        [int]$_.earthquake.maxScale -ge 30
    } | ForEach-Object {
        $origin = Parse-QuakeTime $_.earthquake.time
        if ($origin) { $origin.ToString("yyyyMMddHHmm") }
    } | Select-Object -Unique)

    $eewOrigin = if ($Eew) { Parse-QuakeTime $Eew.originTime } else { $null }
    $eewIssue = if ($Eew) { Parse-QuakeTime $Eew.issueTime } else { $null }
    $recentStart = $Now.AddMinutes(-10)

    $candidates = @($bulletins | Where-Object {
        $issueTime = Parse-QuakeTime $_.issue.time
        $origin = Parse-QuakeTime $_.earthquake.time
        if (-not $issueTime -or -not $origin -or $issueTime -lt $recentStart) { return $false }

        if ($eewOrigin) {
            return [Math]::Abs(($origin - $eewOrigin).TotalSeconds) -le 120 -and
                (-not $eewIssue -or $issueTime -ge $eewIssue)
        }

        return $significantOrigins -contains $origin.ToString("yyyyMMddHHmm")
    })

    if ($candidates.Count -eq 0) { return $null }
    return $candidates |
        Sort-Object @{Expression={ Parse-QuakeTime $_.issue.time }; Descending=$true} |
        Select-Object -First 1
}

function Convert-QuakePayload {
    param($Quake)
    if (-not $Quake) { return $null }

    $origin = Parse-QuakeTime $Quake.earthquake.time
    if (-not $origin) { $origin = Get-Date }
    $maxScale = if ($null -ne $Quake.earthquake.maxScale) { [int]$Quake.earthquake.maxScale } else { 0 }
    $ikuno = $Quake.points | Where-Object { $_.addr -match "生野区" } | Sort-Object scale -Descending | Select-Object -First 1
    $ikunoScale = if ($ikuno) { [int]$ikuno.scale } else { 0 }
    $topPoints = @($Quake.points | Where-Object { $_.scale -ge 10 } | Sort-Object @{Expression="scale"; Descending=$true}, pref, addr | ForEach-Object {
        [pscustomobject]@{
            pref = $_.pref
            addr = $_.addr
            scale = [int]$_.scale
            scaleText = Convert-ScaleText ([int]$_.scale)
            isArea = [bool]$_.isArea
        }
    })
    $scaleGroups = @()
    foreach ($scaleValue in @(70, 60, 55, 50, 45, 40, 30, 20, 10)) {
        $scalePoints = @($topPoints | Where-Object { $_.scale -eq $scaleValue })
        if ($scalePoints.Count -eq 0) { continue }
        $prefGroups = @($scalePoints | Group-Object pref | Sort-Object Name | ForEach-Object {
            [ordered]@{
                pref = if ([string]::IsNullOrWhiteSpace($_.Name)) { "その他" } else { $_.Name }
                addrs = @($_.Group | Sort-Object addr | ForEach-Object { $_.addr })
            }
        })
        $scaleGroups += [ordered]@{
            scale = $scaleValue
            scaleText = Convert-ScaleText $scaleValue
            prefs = $prefGroups
        }
    }

    [ordered]@{
        id = $Quake.id
        time = $Quake.earthquake.time
        issueTime = $Quake.issue.time
        issueType = $Quake.issue.type
        issueTypeLabel = Get-QuakeIssueTypeLabel $Quake.issue.type
        hypocenter = $Quake.earthquake.hypocenter.name
        maxScale = $maxScale
        maxScaleText = Convert-ScaleText $maxScale
        ikunoScale = $ikunoScale
        ikunoScaleText = Convert-ScaleText $ikunoScale
        magnitude = $Quake.earthquake.hypocenter.magnitude
        depth = $Quake.earthquake.hypocenter.depth
        tsunami = $Quake.earthquake.domesticTsunami
        points = $topPoints
        scaleGroups = $scaleGroups
    }
}

function Convert-TsunamiPayload {
    param($Tsunami)
    if (-not $Tsunami) {
        return [ordered]@{ active = $false; cancelled = $false; areas = @(); issueTime = $null }
    }
    if ($Tsunami.cancelled -or -not $Tsunami.areas) {
        return [ordered]@{ active = $false; cancelled = [bool]$Tsunami.cancelled; areas = @(); issueTime = $Tsunami.issue.time }
    }

    $areas = @($Tsunami.areas | ForEach-Object {
        [ordered]@{
            name = $_.name
            grade = $_.grade
            immediate = [bool]$_.immediate
            maxHeight = $_.maxHeight.description
            firstHeight = if ($_.firstHeight.arrivalTime) { $_.firstHeight.arrivalTime } else { $_.firstHeight.condition }
        }
    })

    [ordered]@{
        active = $areas.Count -gt 0
        cancelled = [bool]$Tsunami.cancelled
        issueTime = $Tsunami.issue.time
        type = $Tsunami.issue.type
        areas = $areas
    }
}

function Convert-EewPayload {
    param($Eew)
    if (-not $Eew) { return $null }
    $issueTime = Parse-QuakeTime $Eew.issue.time
    if (-not $issueTime) { $issueTime = Get-Date }
    $ageSeconds = ((Get-Date) - $issueTime).TotalSeconds
    if (-not $Eew.cancelled -and $ageSeconds -gt 600) { return $null }
    if ($Eew.cancelled -and $ageSeconds -gt 300) { return $null }

    $serial = if ($null -ne $Eew.issue.serial) { [int]$Eew.issue.serial } else { 1 }
    $areas = @($Eew.areas | Sort-Object scaleFrom -Descending | ForEach-Object {
        $scaleFrom = if ($null -ne $_.scaleFrom) { [int]$_.scaleFrom } else { 0 }
        $scaleTo = if ($null -ne $_.scaleTo) { [int]$_.scaleTo } else { 0 }
        [ordered]@{
            name = $_.name
            pref = $_.pref
            scaleFrom = $scaleFrom
            scaleTo = $scaleTo
            scaleText = Convert-ScaleText $scaleFrom
            arrivalTime = $_.arrivalTime
            kindCode = $_.kindCode
        }
    })

    [ordered]@{
        id = $Eew.id
        eventId = $Eew.issue.eventId
        serial = $serial
        isFollowUp = $serial -gt 1
        cancelled = [bool]$Eew.cancelled
        issueTime = $Eew.issue.time
        originTime = $Eew.earthquake.originTime
        arrivalTime = $Eew.earthquake.arrivalTime
        hypocenter = $Eew.earthquake.hypocenter.name
        magnitude = $Eew.earthquake.hypocenter.magnitude
        depth = $Eew.earthquake.hypocenter.depth
        areas = $areas
    }
}

function Stop-EewAudio {
    if ($script:audioProcess -and -not $script:audioProcess.HasExited) {
        try { Stop-Process -Id $script:audioProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:audioProcess = $null
}

function Set-EewAudioPriority {
    if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }
    $until = (Get-Date).AddMinutes(5).ToString("o")
    $until | Set-Content -LiteralPath $eewPriorityPath -Encoding UTF8 -Force
}

function Start-EewAudio {
    param($Eew)
    if (-not $Eew) { return }
    $key = "$($Eew.eventId)-$($Eew.serial)-$($Eew.cancelled)"
    if ($key -eq $script:lastEewAudioKey) { return }
    $script:lastEewAudioKey = $key

    $issueTime = Parse-QuakeTime $Eew.issueTime
    if ($issueTime -and ((Get-Date) - $issueTime).TotalSeconds -gt 120) { return }

    Set-EewAudioPriority

    Stop-EewAudio
    $mode = if ($Eew.cancelled) { "Cancel" } elseif ($Eew.isFollowUp) { "FollowUp" } else { "Alert" }
    $prefs = @($Eew.areas | ForEach-Object { @($_.pref, $_.name) } | Where-Object { $_ } | Select-Object -Unique)
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $playScript,
        "-Mode", $mode
    )
    if ($prefs.Count -gt 0) {
        $args += "-Prefs"
        $args += $prefs
    }
    $script:audioProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $args -WindowStyle Hidden -PassThru
}

while ($true) {
    $now = Get-Date
    if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }

    $eewRawList = @(Invoke-P2PHistory -Code 556 -Limit 1)
    $eewRaw = if ($eewRawList.Count -gt 0) { $eewRawList[0] } else { $null }
    $quakeRaw = @(Invoke-P2PHistory -Code 551 -Limit 100)
    $jmaQuakeRaw = @(Invoke-JmaQuakeHistory)
    $allQuakeRaw = @($quakeRaw + $jmaQuakeRaw) | Where-Object { $_ } | Sort-Object @{Expression={ Parse-QuakeTime $_.earthquake.time }; Descending=$true}
    $tsunamiRawList = @(Invoke-P2PHistory -Code 552 -Limit 1)
    $tsunamiRaw = if ($tsunamiRawList.Count -gt 0) { $tsunamiRawList[0] } else { $null }

    $eew = Convert-EewPayload $eewRaw
    if ($eew) { Start-EewAudio $eew }
    $activeBulletinRaw = Get-ActiveQuakeBulletin -QuakeList $quakeRaw -Eew $eew -Now $now
    $activeBulletin = Convert-QuakePayload $activeBulletinRaw

    $displayQuakeRaw = $null
    $emergencyQuakeRaw = $null
    $displayCandidates = @()
    $emergencyCandidates = @()
    $recentScale3QuakeRaw = $null
    $historyStart = $now.AddHours(-72)
    foreach ($q in @($allQuakeRaw)) {
        $origin = Parse-QuakeTime $q.earthquake.time
        if (-not $origin -or $origin -lt $historyStart) { continue }

        $maxScaleForLoop = if ($null -ne $q.earthquake.maxScale) { [int]$q.earthquake.maxScale } else { 0 }
        if (-not $recentScale3QuakeRaw -and $maxScaleForLoop -ge 30 -and $now -le $origin.AddHours(3)) { $recentScale3QuakeRaw = $q }

        $displayUntil = Get-RetentionUntil -Quake $q -BaseTime $origin
        $emergencyUntil = Get-EmergencyUntil -Quake $q -BaseTime $origin
        if ($displayUntil -and $now -le $displayUntil) {
            $displayCandidates += [pscustomobject]@{ Quake = $q; MaxScale = $maxScaleForLoop; PointCount = @($q.points).Count; HasHypocenter = -not [string]::IsNullOrWhiteSpace($q.earthquake.hypocenter.name); Origin = $origin; Until = $displayUntil }
        }
        if ($emergencyUntil -and $now -le $emergencyUntil) {
            $emergencyCandidates += [pscustomobject]@{ Quake = $q; MaxScale = $maxScaleForLoop; PointCount = @($q.points).Count; HasHypocenter = -not [string]::IsNullOrWhiteSpace($q.earthquake.hypocenter.name); Origin = $origin; Until = $emergencyUntil }
        }
    }

    if ($displayCandidates.Count -gt 0) {
        $displayQuakeRaw = @($displayCandidates | Sort-Object @{Expression="MaxScale"; Descending=$true}, @{Expression="PointCount"; Descending=$true}, @{Expression="HasHypocenter"; Descending=$true}, @{Expression="Origin"; Descending=$true} | Select-Object -First 1).Quake
    }
    if ($emergencyCandidates.Count -gt 0) {
        $emergencyQuakeRaw = @($emergencyCandidates | Sort-Object @{Expression="MaxScale"; Descending=$true}, @{Expression="PointCount"; Descending=$true}, @{Expression="HasHypocenter"; Descending=$true}, @{Expression="Until"; Descending=$true} | Select-Object -First 1).Quake
    }

    $tsunami = Convert-TsunamiPayload $tsunamiRaw

    $emergencyReasons = @()
    $emergencyUntilText = $null
    if ($tsunami.active) {
        $emergencyReasons += "tsunami"
    }
    if ($emergencyQuakeRaw) {
        $origin = Parse-QuakeTime $emergencyQuakeRaw.earthquake.time
        $until = Get-EmergencyUntil -Quake $emergencyQuakeRaw -BaseTime $origin
        $emergencyReasons += if ([int]$emergencyQuakeRaw.earthquake.maxScale -ge 70) { "quake7" } else { "quake5" }
        $emergencyUntilText = $until.ToString("yyyy/MM/dd HH:mm:ss")
    }
    $emergencyActive = $emergencyReasons.Count -gt 0
    $emergencyReason = ($emergencyReasons | Select-Object -Unique) -join ","

    if (-not $displayQuakeRaw -and $emergencyQuakeRaw) { $displayQuakeRaw = $emergencyQuakeRaw }
    if (-not $displayQuakeRaw -and $emergencyActive -and $recentScale3QuakeRaw) { $displayQuakeRaw = $recentScale3QuakeRaw }

    $quake = Convert-QuakePayload $displayQuakeRaw
    $emergencyEarthquake = Convert-QuakePayload $emergencyQuakeRaw
    $recentScale3Earthquake = Convert-QuakePayload $recentScale3QuakeRaw

    $localQuakePriority = $false
    if ($quake) {
        $origin = Parse-QuakeTime $quake.time
        $localQuakePriority = $quake.ikunoScale -ge 30 -and $origin -and $now -le $origin.AddHours(1)
    }

    $priorityMode = if ($activeBulletin -or $eew -or $tsunami.active -or $localQuakePriority) { "disaster" } elseif ($quake -or $emergencyActive) { "bottom" } else { "normal" }
    $payloadCore = [ordered]@{
        eew = $eew
        bulletin = $activeBulletin
        earthquake = $quake
        emergencyEarthquake = $emergencyEarthquake
        recentScale3Earthquake = $recentScale3Earthquake
        tsunami = $tsunami
        emergencyMode = [ordered]@{
            active = $emergencyActive
            reason = $emergencyReason
            until = $emergencyUntilText
        }
        priorityMode = $priorityMode
    }
    $compareJson = $payloadCore | ConvertTo-Json -Depth 12 -Compress
    if ($compareJson -ne $lastPayloadJson) {
        $lastPayloadJson = $compareJson
        $payload = [ordered]@{
            updateTime = (Get-Date -Format "yyyy/MM/dd HH:mm:ss")
            eew = $payloadCore.eew
            bulletin = $payloadCore.bulletin
            earthquake = $payloadCore.earthquake
            emergencyEarthquake = $payloadCore.emergencyEarthquake
            recentScale3Earthquake = $payloadCore.recentScale3Earthquake
            tsunami = $payloadCore.tsunami
            emergencyMode = $payloadCore.emergencyMode
            priorityMode = $payloadCore.priorityMode
        }
        $json = $payload | ConvertTo-Json -Depth 12
        "var earthquakeData = $json;" | Out-File -LiteralPath $outputPath -Encoding utf8 -Force
        Write-Host "$(Get-Date -Format 'HH:mm:ss') earthquake_data.js 更新 ($priorityMode)" -ForegroundColor Cyan
    }

    Start-Sleep -Seconds 5
}
