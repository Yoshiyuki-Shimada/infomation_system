# fetch_news.ps1
# Snow Link Drone 統合データ収集スクリプト (クラス指定抽出版)

# 保存先パスの計算 (ループの外で1回だけ実行)
$parentDir = Split-Path -Path $PSScriptRoot -Parent
$tempDir = Join-Path -Path $parentDir -ChildPath "temp"
$filePath = Join-Path -Path $tempDir -ChildPath "news_data.js"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Yahoo!運行情報の路線ID
$privateLineIds = @(
    "320", "321", "322", "323", "324", "325", "326", "327", "537",   #Osaka Metro線
    "284", "285", "287", "295" #近鉄線
    "339", "340", "347", #南海線
    "306", "310", "311", "313", #阪急線
    "300", #京阪線
    "315", "316", "623", #阪神線
    "349", #北大阪急行線
    "362", #阪堺線
    "380", #大阪モノレール
    "354", #山陽電車線
    "7", "8" #東海道・山陽新幹線
)


while ($true) {
    $data = @{
        weather    = @();
        news       = @();
        railway    = @();
        jrWestRouteMapUrl = $null;
        earthquake = $null;
        tsunami    = @();
        evacuation = @();
        weeklyWeather = $null;
        weatherWarnings = $null;
        updateTime = "";
    }
    Write-Host "$(Get-Date -Format 'HH:mm:ss') [Snow Link Drone] 情報更新開始..." -ForegroundColor Cyan

    # --- 1. 気象情報 (Open-Meteo) ---
    try {
        $w = Invoke-RestMethod -Uri "https://api.open-meteo.com/v1/forecast?latitude=34.65&longitude=135.53&current_weather=true&hourly=temperature_2m,weathercode,precipitation_probability&daily=weathercode,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=Asia%2FTokyo"
        
        # 【修正点】生成時間を 0 にリセット（内容の比較に影響させないため）
        if ($null -ne $w.generationtime_ms) { $w.generationtime_ms = 0 }

        try {
            $jma = Invoke-RestMethod -Uri "https://www.jma.go.jp/bosai/forecast/data/forecast/270000.json"
            $popSeries = $jma[0].timeSeries | Where-Object { $_.areas[0].pops } | Select-Object -First 1

            if ($popSeries) {
                $jmaTimeDefines = @($popSeries.timeDefines)
                $jmaPops = @($popSeries.areas[0].pops)
                $hourlyTimes = @($w.hourly.time)
                $hourlyPops = @($w.hourly.precipitation_probability)

                for ($i = 0; $i -lt $hourlyTimes.Count; $i++) {
                    $hourlyDate = [datetime]::Parse($hourlyTimes[$i])

                    for ($j = 0; $j -lt $jmaTimeDefines.Count; $j++) {
                        $start = [datetimeoffset]::Parse($jmaTimeDefines[$j]).DateTime
                        if ($j + 1 -lt $jmaTimeDefines.Count) {
                            $end = [datetimeoffset]::Parse($jmaTimeDefines[$j + 1]).DateTime
                        }
                        else {
                            $end = $start.AddHours(6)
                        }

                        if ($hourlyDate -ge $start -and $hourlyDate -lt $end) {
                            $hourlyPops[$i] = [int]$jmaPops[$j]
                            break
                        }
                    }
                }

                $w.hourly.precipitation_probability = $hourlyPops

                if ($w.daily -and $w.daily.time -and $w.daily.precipitation_probability_max) {
                    $dailyPops = @($w.daily.precipitation_probability_max)
                    for ($d = 0; $d -lt $w.daily.time.Count; $d++) {
                        $targetDate = [datetime]::Parse($w.daily.time[$d]).Date
                        $values = @()

                        for ($j = 0; $j -lt $jmaTimeDefines.Count; $j++) {
                            $start = [datetimeoffset]::Parse($jmaTimeDefines[$j]).DateTime
                            if ($start.Date -eq $targetDate) {
                                $values += [int]$jmaPops[$j]
                            }
                        }

                        if ($values.Count -gt 0) {
                            $dailyPops[$d] = ($values | Measure-Object -Maximum).Maximum
                        }
                    }
                    $w.daily.precipitation_probability_max = $dailyPops
                }

                Write-Host " 天気降水確率：気象庁データで補正" -ForegroundColor Green
            }

            # 気象庁の週間天気予報を表示用データとして保存
            if ($jma.Count -gt 1 -and $jma[1].timeSeries.Count -ge 2) {
                $weeklyWeatherSeries = $jma[1].timeSeries[0]
                $weeklyTemperatureSeries = $jma[1].timeSeries[1]
                $weeklyWeatherArea = $weeklyWeatherSeries.areas |
                    Where-Object { $_.area.code -eq "270000" } |
                    Select-Object -First 1
                $weeklyTemperatureArea = $weeklyTemperatureSeries.areas |
                    Where-Object { $_.area.code -eq "62078" } |
                    Select-Object -First 1

                if ($weeklyWeatherArea -and $weeklyTemperatureArea) {
                    $shortTemperatureSeries = $jma[0].timeSeries |
                        Where-Object { $_.areas[0].temps } |
                        Select-Object -First 1
                    $shortTemperatureArea = $shortTemperatureSeries.areas |
                        Where-Object { $_.area.code -eq "62078" } |
                        Select-Object -First 1
                    $weeklyDays = @()
                    $weeklyTimes = @($weeklyWeatherSeries.timeDefines)

                    for ($dayIndex = 0; $dayIndex -lt $weeklyTimes.Count; $dayIndex++) {
                        $targetDate = [datetimeoffset]::Parse($weeklyTimes[$dayIndex]).Date
                        $pop = [string]$weeklyWeatherArea.pops[$dayIndex]
                        $tempMin = [string]$weeklyTemperatureArea.tempsMin[$dayIndex]
                        $tempMax = [string]$weeklyTemperatureArea.tempsMax[$dayIndex]

                        if ([string]::IsNullOrWhiteSpace($pop) -and $popSeries) {
                            $shortPopsForDate = @()
                            for ($popIndex = 0; $popIndex -lt $jmaTimeDefines.Count; $popIndex++) {
                                $popDate = [datetimeoffset]::Parse($jmaTimeDefines[$popIndex]).Date
                                if ($popDate -eq $targetDate -and
                                    -not [string]::IsNullOrWhiteSpace([string]$jmaPops[$popIndex])) {
                                    $shortPopsForDate += [int]$jmaPops[$popIndex]
                                }
                            }
                            if ($shortPopsForDate.Count -gt 0) {
                                $pop = [string](($shortPopsForDate | Measure-Object -Maximum).Maximum)
                            }
                        }

                        if (($tempMin -eq "" -or $tempMax -eq "") -and
                            $shortTemperatureSeries -and $shortTemperatureArea) {
                            $shortTempsForDate = @()
                            $shortTemperatureTimes = @($shortTemperatureSeries.timeDefines)
                            $shortTemperatures = @($shortTemperatureArea.temps)

                            for ($tempIndex = 0; $tempIndex -lt $shortTemperatureTimes.Count; $tempIndex++) {
                                $temperatureDate = [datetimeoffset]::Parse($shortTemperatureTimes[$tempIndex]).Date
                                if ($temperatureDate -eq $targetDate -and
                                    -not [string]::IsNullOrWhiteSpace([string]$shortTemperatures[$tempIndex])) {
                                    $shortTempsForDate += [int]$shortTemperatures[$tempIndex]
                                }
                            }

                            if ($shortTempsForDate.Count -gt 0) {
                                if ([string]::IsNullOrWhiteSpace($tempMin)) {
                                    $tempMin = [string](($shortTempsForDate | Measure-Object -Minimum).Minimum)
                                }
                                if ([string]::IsNullOrWhiteSpace($tempMax)) {
                                    $tempMax = [string](($shortTempsForDate | Measure-Object -Maximum).Maximum)
                                }
                            }
                        }

                        $weeklyDays += @{
                            date = $targetDate.ToString("yyyy-MM-dd")
                            weatherCode = [string]$weeklyWeatherArea.weatherCodes[$dayIndex]
                            precipitationProbability = if ([string]::IsNullOrWhiteSpace($pop)) { $null } else { [int]$pop }
                            temperatureMin = if ([string]::IsNullOrWhiteSpace($tempMin)) { $null } else { [int]$tempMin }
                            temperatureMax = if ([string]::IsNullOrWhiteSpace($tempMax)) { $null } else { [int]$tempMax }
                            reliability = [string]$weeklyWeatherArea.reliabilities[$dayIndex]
                        }
                    }

                    $data.weeklyWeather = @{
                        reportDatetime = [string]$jma[1].reportDatetime
                        areaName = "大阪府"
                        days = $weeklyDays
                    }
                    Write-Host " 週間天気予報：気象庁データ取得済み" -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Host " 天気降水確率：気象庁補正失敗・Open-Meteo値を使用" -ForegroundColor Yellow
        }
        
        $data.weather = $w
        Write-Host " 天気取得：処理済み" -ForegroundColor Green
    }
    catch { Write-Host " 天気取得：失敗・処理中断" -ForegroundColor Red }

    # --- 大阪市の気象警報・注意報（気象庁） ---
    try {
        $warningResponse = Invoke-WebRequest `
            -Uri "https://www.jma.go.jp/bosai/warning/data/r8/270000.json" `
            -UserAgent $ua `
            -UseBasicParsing `
            -TimeoutSec 15
        $warningResponse.RawContentStream.Position = 0
        $warningReader = [System.IO.StreamReader]::new(
            $warningResponse.RawContentStream,
            [System.Text.Encoding]::UTF8,
            $true
        )
        try {
            $warningJson = $warningReader.ReadToEnd()
        }
        finally {
            $warningReader.Dispose()
        }
        $warningReports = @($warningJson | ConvertFrom-Json)
        $osakaCityWarningsByCode = [ordered]@{}
        $warningReportDatetime = $null
        $targetWarningAreaCodes = @(
            "2710000", # 大阪市
            "2711600"  # 大阪市生野区（区単位で配信された場合）
        )

        foreach ($report in $warningReports) {
            foreach ($item in @($report.warning.class20Items)) {
                if ([string]$item.areaCode -notin $targetWarningAreaCodes) {
                    continue
                }

                foreach ($kind in @($item.kinds)) {
                    $status = [string]$kind.status
                    $code = [string]$kind.code
                    if (
                        [string]::IsNullOrWhiteSpace($code) -or
                        $status -eq "解除" -or
                        $status -match "発表警報・注意報はなし"
                    ) {
                        continue
                    }

                    if (-not $osakaCityWarningsByCode.Contains($code)) {
                        $osakaCityWarningsByCode[$code] = @{
                            code = $code
                            status = $status
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($warningReportDatetime)) {
                        $warningReportDatetime = [string]$report.reportDatetime
                    }
                }
            }
        }
        $osakaCityWarnings = @($osakaCityWarningsByCode.Values)

        if ($osakaCityWarnings.Count -gt 0) {
            $data.weatherWarnings = @{
                reportDatetime = $warningReportDatetime
                areaName = "大阪市"
                warnings = $osakaCityWarnings
            }
            Write-Host " 気象警報・注意報：大阪市に発表中の情報あり" -ForegroundColor Yellow
        }
        else {
            Write-Host " 気象警報・注意報：大阪市は発表なし" -ForegroundColor Green
        }
    }
    catch {
        Write-Host " 気象警報・注意報：取得失敗（$($_.Exception.Message)）" -ForegroundColor Yellow
    }

    Write-Host " [RAILWAY] 鉄道処理を開始します..." -ForegroundColor DarkCyan
    try {
        # JR西日本 取得関数
        function Get-JRWestTrafficInfoData {
            $jrApiUrl = "https://trafficinfo.westjr.co.jp/api/v1/trafficinfo.json"
            $jrRaw = Invoke-RestMethod -Uri $jrApiUrl -Method Get
            $results = @()

            # 近畿エリア(ID:2)を抽出
            $area = $jrRaw.areaTrafficInfos | Where-Object { $_.id -eq 2 }
            if (-not $area -or -not $area.dailyData) { return $results }

            # 深夜帯は日付が混在するため、配信されている全日程(dailyData)をループする
            foreach ($daily in $area.dailyData) {
                foreach ($place in $daily.placeTrafficInfos) {
                    foreach ($line in $place.conventionalLineTrafficInfos) {
                        
                        $lineName = if ($line.name) { $line.name } else { $line.lineName }
                        if (-not $line.conventionalLineTrafficInfoDetails) { continue }

                        foreach ($detail in $line.conventionalLineTrafficInfoDetails) {
                            $secList = @()
                            $maxSev = 0

                            # 区間情報の解析
                            if ($detail.sections) {
                                foreach ($sec in $detail.sections) {
                                    if ($sec.conditionName -eq "平常") { continue }
                                    
                                    if ($sec.endStation -eq "" -or $sec.endStation -eq $null) {
                                        $secList += "$($sec.startStation)（$($sec.conditionName)）"
                                    }
                                    else {
                                        $secList += "$($sec.startStation)　～　$($sec.endStation)（$($sec.conditionName)）"
                                    }
                                    
                                    if ($sec.conditionName -match "見合わせ|取り止め|運休") { $maxSev = 3 }
                                    if ($sec.conditionName -match "お知らせ|可能性") { $maxSev = 2 }
                                }
                            }

                            # 詳細テキストがある場合は採用（区間が空でもメッセージがあれば出す）
                            if ($secList.Count -eq 0 -and $detail.versionDetail) {
                                $secList += "運行情報あり"
                            }

                            if ($secList.Count -eq 0) { continue }

                            # 詳細メッセージ取得
                            $title = ""; $body = ""
                            if ($detail.versionDetail) {
                                $latestDetail = $detail.versionDetail | Sort-Object id -Descending | Select-Object -First 1
                                $title = $latestDetail.title; $body = $latestDetail.body
                            }

                            $msg = ($secList -join " / ")
                            if ($detail.cause) { $msg += " 【原因】$($detail.cause)" }
                            if ($detail.resume) { $msg += " 【再開見込】$($detail.resume)" }

                            $color = switch ($maxSev) { 3 { "red" }; 2 { "orange" }; default { "yellow" } }

                            $results += @{
                                company = "JR西日本"; name = $lineName; msg = $msg;
                                color = $color; title = $title; body = $body; lineCode = 0;
                            }
                            Write-Host "  -> [JR] $lineName ($color) を採用" -ForegroundColor Green
                            
                            
                        }

                    }
                }
            }
            
            return $results
        }

        # JR実行
        $jrResults = Get-JRWestTrafficInfoData
        if ($jrResults) {
            $data.railway += $jrResults

            # 路線図取得は行わない。
            $hasJrKinkiDisruption = $false

            if ($hasJrKinkiDisruption) {
                try {
                    $jrKinkiPageUrl = "https://trafficinfo.westjr.co.jp/kinki.html"
                    $jrKinkiHtml = (
                        Invoke-WebRequest `
                            -Uri $jrKinkiPageUrl `
                            -UserAgent $ua `
                            -UseBasicParsing `
                            -TimeoutSec 15
                    ).Content

                    # Next.jsの埋め込みデータ内では画像パスが
                    # \/、\u002F、%2Fなどにエスケープされる場合がある。
                    $jrKinkiSearchHtml = $jrKinkiHtml `
                        -replace '\\u002[fF]', '/' `
                        -replace '\\/', '/' `
                        -replace '%2[fF]', '/'
                    $routeMapImageTag = [regex]::Match(
                        $jrKinkiSearchHtml,
                        '(?is)<img\b[^>]*class=["''][^"'']*RouteMap_overview__[^"'']*["''][^>]*>'
                    )

                    $routeMapSrcMatch = $null
                    if ($routeMapImageTag.Success) {
                        $routeMapSrcMatch = [regex]::Match(
                            $routeMapImageTag.Value,
                            '\bsrc=["''](?<src>[^"'']+)["'']'
                        )
                    }

                    # CSSクラス名が変更された場合も、路線図画像のパスから取得する。
                    if (-not $routeMapSrcMatch -or -not $routeMapSrcMatch.Success) {
                        $routeMapSrcMatch = [regex]::Match(
                            $jrKinkiSearchHtml,
                            '(?is)\bsrc=["''](?<src>[^"'']*/routemap/[^"'']+\.(?:gif|png|svg)(?:\?[^"'']*)?)["'']'
                        )
                    }

                    # src属性がReact Server Components内に分割されていても、
                    # 概要版の路線図パスそのものを拾う。
                    if (-not $routeMapSrcMatch -or -not $routeMapSrcMatch.Success) {
                        $routeMapSrcMatch = [regex]::Match(
                            $jrKinkiSearchHtml,
                            '(?is)(?<src>/routemap/[^\\\s"'']*?routemap_small_kinki\.(?:gif|png|svg)(?:\?[^\\\s"'']*)?)'
                        )
                    }

                    # ファイル名が変更された場合の最終フォールバック。
                    if (-not $routeMapSrcMatch -or -not $routeMapSrcMatch.Success) {
                        $routeMapSrcMatch = [regex]::Match(
                            $jrKinkiSearchHtml,
                            '(?is)(?<src>/routemap/[^\\\s"'']+\.(?:gif|png|svg)(?:\?[^\\\s"'']*)?)'
                        )
                    }

                    # 静的HTMLに路線図がない場合は、EdgeでJavaScript実行後の
                    # DOMを取得する。JR西日本ページは路線図を後から描画する場合がある。
                    $renderedHtml = ""
                    if (-not $routeMapSrcMatch -or -not $routeMapSrcMatch.Success) {
                        $edgeCandidates = @(
                            (Get-Command "msedge.exe" -ErrorAction SilentlyContinue).Source,
                            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
                        ) | Where-Object {
                            -not [string]::IsNullOrWhiteSpace($_) -and
                            (Test-Path -LiteralPath $_ -PathType Leaf)
                        } | Select-Object -Unique

                        $edgePath = $edgeCandidates | Select-Object -First 1
                        if ($edgePath) {
                            $edgeProfilePath = Join-Path `
                                -Path $tempDir `
                                -ChildPath "jr-route-map-edge-profile"
                            if (-not (Test-Path -LiteralPath $edgeProfilePath)) {
                                New-Item `
                                    -Path $edgeProfilePath `
                                    -ItemType Directory `
                                    -Force | Out-Null
                            }

                            $edgeOutputPath = Join-Path `
                                -Path $tempDir `
                                -ChildPath "jr_kinki_edge_output.html"
                            $edgeErrorPath = Join-Path `
                                -Path $tempDir `
                                -ChildPath "jr_kinki_edge_error.log"
                            [IO.File]::WriteAllText(
                                $edgeOutputPath,
                                "",
                                [Text.UTF8Encoding]::new($false)
                            )
                            [IO.File]::WriteAllText(
                                $edgeErrorPath,
                                "",
                                [Text.UTF8Encoding]::new($false)
                            )

                            $edgeArguments = @(
                                "--headless=new",
                                "--disable-gpu",
                                "--no-first-run",
                                "--disable-extensions",
                                "--run-all-compositor-stages-before-draw",
                                "--virtual-time-budget=10000",
                                "`"--user-data-dir=$edgeProfilePath`"",
                                "--dump-dom",
                                $jrKinkiPageUrl
                            )
                            $edgeProcess = Start-Process `
                                -FilePath $edgePath `
                                -ArgumentList $edgeArguments `
                                -RedirectStandardOutput $edgeOutputPath `
                                -RedirectStandardError $edgeErrorPath `
                                -WindowStyle Hidden `
                                -Wait `
                                -PassThru
                            $renderedHtml = Get-Content `
                                -LiteralPath $edgeOutputPath `
                                -Raw `
                                -Encoding UTF8 `
                                -ErrorAction SilentlyContinue
                            Write-Host `
                                "  -> [JR] Edge描画後HTMLを確認（終了コード$($edgeProcess.ExitCode)・$($renderedHtml.Length)文字）" `
                                -ForegroundColor DarkGray

                            $renderedSearchHtml = $renderedHtml `
                                -replace '\\u002[fF]', '/' `
                                -replace '\\/', '/' `
                                -replace '%2[fF]', '/'
                            $routeMapSrcMatch = [regex]::Match(
                                $renderedSearchHtml,
                                '(?is)<img\b[^>]*alt=["'']路線図_概要["''][^>]*\bsrc=["''](?<src>[^"'']+)["'']'
                            )
                            if (-not $routeMapSrcMatch.Success) {
                                $routeMapSrcMatch = [regex]::Match(
                                    $renderedSearchHtml,
                                    '(?is)<img\b[^>]*\bsrc=["''](?<src>[^"'']+)["''][^>]*alt=["'']路線図_概要["'']'
                                )
                            }
                            if (-not $routeMapSrcMatch.Success) {
                                $routeMapSrcMatch = [regex]::Match(
                                    $renderedSearchHtml,
                                    '(?is)(?<src>/routemap/[^\\\s"'']+\.(?:gif|png|svg)(?:\?[^\\\s"'']*)?)'
                                )
                            }
                        }
                    }

                    if ($routeMapSrcMatch.Success) {
                        $routeMapSrc = [Net.WebUtility]::HtmlDecode(
                            $routeMapSrcMatch.Groups["src"].Value
                        )
                        $jrKinkiBaseUri = [Uri]$jrKinkiPageUrl
                        $data.jrWestRouteMapUrl = [Uri]::new(
                            $jrKinkiBaseUri,
                            $routeMapSrc
                        ).AbsoluteUri
                        Write-Host "  -> [JR] 近畿エリア路線図を取得" -ForegroundColor Green
                    }
                    else {
                        $staticDebugPath = Join-Path `
                            -Path $tempDir `
                            -ChildPath "jr_kinki_static_debug.html"
                        $renderedDebugPath = Join-Path `
                            -Path $tempDir `
                            -ChildPath "jr_kinki_rendered_debug.html"
                        [IO.File]::WriteAllText(
                            $staticDebugPath,
                            [string]$jrKinkiHtml,
                            [Text.UTF8Encoding]::new($false)
                        )
                        [IO.File]::WriteAllText(
                            $renderedDebugPath,
                            [string]$renderedHtml,
                            [Text.UTF8Encoding]::new($false)
                        )
                        Write-Host `
                            "  -> [JR] 近畿エリア路線図が見つかりません（診断HTMLをtempへ保存）" `
                            -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "  -> [JR] 近畿エリア路線図の取得失敗" -ForegroundColor Yellow
                }
            }
        }

        # --- Yahoo!他社線 ---
        if ($privateLineIds) {
            foreach ($id in $privateLineIds) {
                try {
                    $yHtml = (Invoke-WebRequest -Uri "https://transit.yahoo.co.jp/diainfo/$id/0" -UserAgent $ua -UseBasicParsing -TimeoutSec 5).Content
                    if ($yHtml -match '(?s)<h1[^>]*class="title"[^>]*>(?<n>.*?)</h1>') {
                        $yName = ($Matches['n'] -replace 'の運行情報', '').Trim()
                        
                        # 修正ポイント：class="trouble" の後に他のクラス(suspendなど)が続いてもマッチするように [^"]* を追加
                        if ($yHtml -match '(?s)<[a-z0-9]+[^>]*class="[^"]*trouble[^"]*"[^>]*>.*?<p[^>]*>(?<m>.*?)</p>') {
                            $yMsg = ($Matches['m'] -replace '<[^>]*>', '' -replace '&nbsp;', ' ' -replace '[\r\n\t\s]+', ' ').Trim()
                            
                            # 平常運転時などのメッセージを除外
                            if ($yMsg -match "情報はありません" -or [string]::IsNullOrWhiteSpace($yMsg) -or $yMsg -match "平常どおり") { continue }

                            
                            $yCol = "yellow" 
                            Write-Host "状況:$yMsg"
                            
                            # 判定ロジック
                            if ($yMsg -match "見合わせ|停止") {
                                $yCol = "red"
                            }
                            elseif ($yMsg -match "再開|遅れ|遅延|遅れや運休|一部列車に運休|一部列車運休|部分運休") {
                                $yCol = "yellow"
                            }
                            elseif ($yMsg -match "可能性|お知らせ|計画") {
                                $yCol = "orange"
                            
                            }
                            elseif ($yMsg -match "取り止め|運休") {
                                $yCol = "red"
                            }


                            $data.railway += @{ 
                                company  = "私鉄線"; 
                                name     = $yName; 
                                body     = $yMsg; 
                                color    = $yCol; 
                                lineCode = 1; 
                            }
                            Write-Host "  -> [Yahoo!] $yName ($yCol)" -ForegroundColor Green
                        }
                    }
                }
                catch { Write-Host "  -> [Yahoo!] ID:$id 取得エラー" -ForegroundColor DarkGray }
                Start-Sleep -Milliseconds 150
            }
        }
    }
    catch {
        Write-Host " [RAILWAY] 処理中にエラーが発生: $($_.Exception.Message)" -ForegroundColor Red
    }
    # --- 3. ニュース取得 (指定クラス highLightSearchTarget を抽出) ---
    # 除外ワードの定義
    $excludePattern = "スポーツ|連勝|連敗|勝利|敗北|競馬|ゴルフ|芸能|引き分け|アイドル|ミュージカル|野球|エンタメ|リーグ|ドラマ|映画|番組|詳しくはWeb|詳しくは動画|詳しくは気象動画|詳しくは天気動画"
    $rssUrls = @("https://news.yahoo.co.jp/rss/media/kantele/all.xml", "https://news.yahoo.co.jp/rss/media/ytv/all.xml", "https://news.yahoo.co.jp/rss/media/kyodonews/all.xml", "https://news.yahoo.co.jp/rss/media/ann/all.xml", "https://news.yahoo.co.jp/rss/media/zdn_n/all.xml", "https://news.yahoo.co.jp/rss/media/mbsnews/all.xml", "https://news.yahoo.co.jp/rss/media/suntvv/all.xml")

    foreach ($u in $rssUrls) {
        try {
            $rss = Invoke-RestMethod -Uri $u -UserAgent $ua
            
            # 【重要】先に除外判定を行い、残ったものから確実に「先頭2件」を抽出する
            $validItems = $rss | Where-Object { 
                $_.title -notmatch $excludePattern -and $_.description -notmatch $excludePattern 
                
            } | Select-Object -First 2

            foreach ($item in $validItems) {
                Write-Host "  ニュース採用: $($item.title)" -ForegroundColor Green
                
                # 本文取得 (指定クラス highLightSearchTarget を狙い撃ち)
                $articleHtml = (Invoke-WebRequest -Uri $item.link -UserAgent $ua -UseBasicParsing -TimeoutSec 10).Content
                $paragraphs = [regex]::Matches($articleHtml, '<p[^>]*class="[^"]*highLightSearchTarget[^"]*"[^>]*>(.*?)</p>', 'Singleline') | ForEach-Object {
                    $inner = $_.Groups[1].Value `
                        -replace '<[^>]*>', '' `
                        -replace '[ \t]+', ' '

                    if ($inner.Length -gt 5) {
                        "<p>$($inner.Trim())</p>"
                    }
                }
                
                # 抽出した段落を結合（分割はJS側に任せる）
                $body = ($paragraphs | Select-Object -First 15) -join ""
                
                # 本文が空の場合のフォールバック
                if ([string]::IsNullOrWhiteSpace($body)) {
                    $body = $item.description -replace '<[^>]*>', ''
                }

                # データの追加（タイトルから（）内をカットしてスッキリさせる）
                # $cleanTitle = if ($item.title -match "（") { $item.title.Split("（")[0].Trim() } else { $item.title.Trim() }
                $cleanTitle = $item.title
                $data.news += @{ 
                    title = $cleanTitle; 
                    body  = $body.Trim() 
                }
            }
        }
        catch {
            Write-Host "  ニュース取得エラー: $u" -ForegroundColor Red
        }
    }

    # --- 4. 地震・津波情報 ---
    # 地震・津波・緊急地震速報は earthquake\earthquake_monitor.ps1 で常時監視する。
    # --- 5. 避難情報 (大阪市生野区) ---
    try {
        #27/27116/
        $ev = Invoke-WebRequest -Uri "https://crisis.yahoo.co.jp/evacuation/27/27116/" -UserAgent $ua -UseBasicParsing
        if ($ev.Content -match 'evacuation_detail_section.*?>(.*?)</div>') {
            $txt = $Matches[1] -replace '<[^>]*>', ''; $level = if ($txt -match "緊急安全確保") { "emergency" } elseif ($txt -match "避難指示") { "instruction" } else { "elderly" }
            $data.evacuation += @{ level = $level; msg = $txt.Trim() }
            
        }
        Write-Host " 避難情報取得：処理済み" -ForegroundColor Green
    }
    catch { Write-Host " 避難情報取得：失敗・処理中断" -ForegroundColor Red }

    # --- 比較と保存のロジック ---
    $oldData = $null
    $hasChanged = $true

    if (Test-Path $filePath) {
        try {
            $rawContent = Get-Content $filePath -Raw
            if ($rawContent -match 'var signageData = (\{.*\});') {
                $oldData = $Matches[1] | ConvertFrom-Json

                if ($oldData.weather -and $null -ne $oldData.weather.generationtime_ms) {
                    $oldData.weather.generationtime_ms = 0
                }
            }
        }
        catch {
            Write-Host " [System] 前回データの読み込みに失敗したため、更新します。" -ForegroundColor Yellow
        }
    }

    if ($oldData -ne $null) {
        $currentCompareJson = $data | Select-Object * -ExcludeProperty updateTime | ConvertTo-Json -Depth 10 -Compress
        $oldCompareJson = $oldData | Select-Object * -ExcludeProperty updateTime | ConvertTo-Json -Depth 10 -Compress

        if ($currentCompareJson -eq $oldCompareJson) {
            $hasChanged = $false
            Write-Host " [System] 取得データに変更なし。news_data.js は更新しません。" -ForegroundColor Yellow
        }
    }

    if ($hasChanged) {
        $data.updateTime = (Get-Date -Format "yyyy/MM/dd HH:mm")
        Write-Host " [System] 新しいデータを検知しました。" -ForegroundColor Cyan

        if (-not (Test-Path $tempDir)) {
            New-Item -Path $tempDir -ItemType Directory | Out-Null
            Write-Host " [System] temp フォルダを自動作成しました。" -ForegroundColor Yellow
        }

        $json = $data | ConvertTo-Json -Depth 10
        "var signageData = $json;" | Out-File -FilePath $filePath -Encoding utf8 -Force

        Write-Host "$(Get-Date -Format 'HH:mm:ss') news_data.js を更新しました。($filePath)" -ForegroundColor Cyan
    }
    # 5分ごとの情報取得
    Start-Sleep -Seconds 300
}
