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
        earthquake = $null;
        tsunami    = @();
        evacuation = @();
        updateTime = "";
    }
    Write-Host "$(Get-Date -Format 'HH:mm:ss') [Snow Link Drone] 情報更新開始..." -ForegroundColor Cyan

    # --- 1. 気象情報 (Open-Meteo) ---
    try {
        $w = Invoke-RestMethod -Uri "https://api.open-meteo.com/v1/forecast?latitude=34.65&longitude=135.53&current_weather=true&hourly=temperature_2m,weathercode&daily=weathercode,temperature_2m_max,temperature_2m_min&timezone=Asia%2FTokyo"
        
        # 【修正点】生成時間を 0 にリセット（内容の比較に影響させないため）
        if ($null -ne $w.generationtime_ms) { $w.generationtime_ms = 0 }
        
        $data.weather = $w
        Write-Host " 天気取得：処理済み" -ForegroundColor Green
    }
    catch { Write-Host " 天気取得：失敗・処理中断" -ForegroundColor Red }

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
        if ($jrResults) { $data.railway += $jrResults }

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

    # --- 4. 地震情報 ---
    try {
        $eq = Invoke-RestMethod -Uri "https://api.p2pquake.net/v2/history?codes=551&limit=1"
        if ($eq) {
            $q = $eq[0]; 
            $ikuno = $q.points | Where-Object { $_.addr -match "生野区" }
            $data.earthquake = @{
                time       = $q.earthquake.time; 
                hypocenter = $q.earthquake.hypocenter.name;
                maxScale   = $q.earthquake.maxScale; 
                # 修正：.pref から .scale に変更
                ikunoScale = if ($ikuno) { $ikuno.scale } else { 0 }; 
                magnitude  = $q.earthquake.hypocenter.magnitude; 
                depth      = $q.earthquake.hypocenter.depth;
                tsunami    = $q.earthquake.tsunamiAdvisory;
            }
            Write-Host " 地震情報取得：処理済み" -ForegroundColor Green
        }
    }
    catch { Write-Host " 地震情報取得：失敗" -ForegroundColor Red }

    # --- 4.5 津波情報 (コード552) 新設！ ---
    try {
        # P2P地震情報の「津波情報（552）」を個別に取得
        $tsunamiResponse = Invoke-RestMethod -Uri "https://api.p2pquake.net/v2/history?codes=552&limit=1"
        if ($tsunamiResponse -and $tsunamiResponse.Count -gt 0) {
            $t = $tsunamiResponse[0]
            # 発表されている全エリアをループして抽出
            if ($t.areas) {
                foreach ($area in $t.areas) {
                    $data.tsunami += @{
                        name  = $area.name;  # 沿岸名（例：徳島県、和歌山県など）
                        grade = $area.grade; # 警報の種類（大津波警報/津波警報/津波注意報）
                    }
                }
            }
            Write-Host " 津波詳細取得：処理済み ($($data.tsunami.Count)件)" -ForegroundColor Green
        }
    }
    catch { Write-Host " 津波詳細取得：失敗" -ForegroundColor Red }

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
    $shouldUpdateTimestamp = $true

    # 1. 既存のファイル（news_data.js）を読み込んでオブジェクトに戻す
    # --- 比較と保存のロジック ---
    
    $oldData = $null
    $shouldUpdateTimestamp = $true

    if (Test-Path $filePath) {
        try {
            $rawContent = Get-Content $filePath -Raw
            if ($rawContent -match 'var signageData = (\{.*\});') {
                $oldData = $Matches[1] | ConvertFrom-Json
                
                # 【修正点】古いデータの生成時間も 0 にして、今回のデータと比較条件を揃える
                if ($oldData.weather -and $null -ne $oldData.weather.generationtime_ms) {
                    $oldData.weather.generationtime_ms = 0
                }
            }
        }
        catch { }
    }

    # 2. 内容の比較
    if ($oldData -ne $null) {
        # updateTime 以外の項目を JSON 文字列にして比較
        $currentCompareJson = $data | ConvertTo-Json -Depth 10 -Compress
        $oldCompareJson = $oldData | Select-Object * -ExcludeProperty updateTime | ConvertTo-Json -Depth 10 -Compress

        if ($currentCompareJson -eq $oldCompareJson) {
            # 中身が全く同じなら、前回の時刻をそのまま使う
            $data.updateTime = $oldData.updateTime
            $shouldUpdateTimestamp = $false
            Write-Host " [System] データに変更がないため、更新時刻を維持します。" -ForegroundColor Yellow
        }
    }

    # 3. 変更があった場合のみ、現在の時刻をセット
    if ($shouldUpdateTimestamp) {
        $data.updateTime = (Get-Date -Format "yyyy/MM/dd HH:mm")
        Write-Host " [System] 新しいデータを検知しました。" -ForegroundColor Cyan
    }


    # tempフォルダーがない場合の自動作成
    if (-not (Test-Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory | Out-Null
        Write-Host " [System] temp フォルダを自動作成しました。" -ForegroundColor Yellow
    }

    # JSON形式に変換して保存
    $json = $data | ConvertTo-Json -Depth 10
    "var signageData = $json;" | Out-File -FilePath $filePath -Encoding utf8 -Force

    Write-Host "$(Get-Date -Format 'HH:mm:ss') news_data.js を更新しました。($filePath)" -ForegroundColor Cyan
    # 5分ごとの情報取得
    Start-Sleep -Seconds 300
}