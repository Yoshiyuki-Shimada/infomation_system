/** 表示させる情報の番号 */
let currentSlide = 0;

/** 表示される情報を格納するリスト */
let slideList = [];

const container = document.getElementById("slide-container");
const idleView = document.getElementById("idle-view");
const headerView = document.getElementById("signage-header");

/** 1行あたりの最大文字数 */
const TEXT_LENGTH = 35;

/** 鉄道情報の最大行数 */
const TRAIN_INFO_LINE_LENGTH = 8;

/** ニュース情報の最大行数 */
const NEWS_LINE_LENGTH = 12;

/* 前回の更新時刻を保管 */
let lastUpdateTime = "";

/** 情報モード */
const MODE = {
    RAILWAY: 0,
    NEWS: 1,
};

/** 取得路線情報 */
const TRAIN_COMPANY = {
    JR_WEST: 0,
    OTHERS: 1,
};

/** 地震・津波情報を保管する配列 */
let emergencyList;

/** 避難情報を保管する配列 */
let evacuationList;

/** 列車運行情報を保管する配列 */
let railwayList;

/** ニュースを記事単位で保管する配列 */
let newsArticles;

/** 天気予報を保管する配列 */
let weatherList;

let lastSignalData;

/**
 * 路線名から路線記号の画像HTMLを生成する
 */
function getLineSymbolHtml(lineName, contextText = "", lineCode) {
    if (!lineName) return "";
    if (lineCode != TRAIN_COMPANY.JR_WEST) return "";
    let icons = "";
    //console.log("line-name" + contextText);

    // 山陰線の特殊判定ロジック
    if (lineName.includes("山陰線")) {
        // E判定：運行情報の区間（開始地点もしくは終点地点）に以下の駅が含まれる場合
        const isE =
            /園部|船岡|日吉|鍼灸大学前|胡麻|下山|和知|安栖里|立木|山家|綾部|高津|石原|福知山|上川口|下夜久野|上夜久野|梁瀬|和田山|養父|八鹿|江原|国府|豊岡|玄武洞/.test(
                contextText,
            );
        // A判定：運行情報の区間（開始地点もしくは終点地点）に以下の駅が含まれる場合
        const isA =
            /玄武洞|城崎温泉|竹野|佐津|柴山|香住|鎧|餘部|久谷|浜坂|諸寄|居組|東浜|岩美|大岩|福部|鳥取|鳥取大学前|倉吉|伯耆大山|米子/.test(
                contextText,
            );

        const imgStyle =
            "height: 1.0em; vertical-align: middle; margin-right: 5px;";
        if (isE)
            icons += `<img src="img/JRLinesImage/keihanshin_area/E.png" style="${imgStyle}">`;
        if (isA)
            icons += `<img src="img/JRLinesImage/yonago_area/A.png" style="${imgStyle}">`;

        return icons;
    }

    /** JR近畿エリアの路線記号一覧 */
    const symbols = [
        {
            area: "keihanshin_area",
            symbol: "A",
            keywords: [
                "北陸線",
                "琵琶湖線",
                "JR京都線",
                "JR神戸線",
                "ＪＲ京都線",
                "ＪＲ神戸線",
                "山陽線",
                "赤穂線",
            ],
        },
        { area: "keihanshin_area", symbol: "B", keywords: ["湖西線"] },
        { area: "keihanshin_area", symbol: "C", keywords: ["草津線"] },
        { area: "keihanshin_area", symbol: "D", keywords: ["奈良線"] },
        {
            area: "keihanshin_area",
            symbol: "E",
            keywords: ["嵯峨野線", "山陰線"],
        }, // 京阪神優先
        { area: "keihanshin_area", symbol: "F", keywords: ["おおさか東線"] },
        {
            area: "keihanshin_area",
            symbol: "G",
            keywords: ["JR宝塚線", "福知山線", "ＪＲ宝塚線"],
        },
        {
            area: "keihanshin_area",
            symbol: "H",
            keywords: ["JR東西線", "学研都市線", "ＪＲ東西線"],
        },
        { area: "keihanshin_area", symbol: "I", keywords: ["加古川線"] },
        { area: "keihanshin_area", symbol: "J", keywords: ["播担線"] },
        { area: "keihanshin_area", symbol: "K", keywords: ["姫新線"] },
        { area: "keihanshin_area", symbol: "L", keywords: ["舞鶴線"] },
        { area: "keihanshin_area", symbol: "O", keywords: ["大阪環状線"] },
        {
            area: "keihanshin_area",
            symbol: "P",
            keywords: ["JRゆめ咲線", "ＪＲゆめ咲線", "桜島線"],
        },
        { area: "keihanshin_area", symbol: "Q", keywords: ["大和路線"] },
        { area: "keihanshin_area", symbol: "R", keywords: ["阪和線"] },
        { area: "keihanshin_area", symbol: "S", keywords: ["関西空港線"] },
        { area: "keihanshin_area", symbol: "T", keywords: ["和歌山線"] },
        {
            area: "keihanshin_area",
            symbol: "U",
            keywords: ["万葉まほろば線", "桜井線"],
        },
        { area: "keihanshin_area", symbol: "V", keywords: ["関西線"] },
        {
            area: "keihanshin_area",
            symbol: "W",
            keywords: ["きのくに線", "紀勢線"],
        },
        { area: "yonago_area", symbol: "A", keywords: ["山陰線"] },
    ];

    // 路線名に含まれるキーワードを探す
    const found = symbols.find((item) =>
        item.keywords.some((k) => lineName.includes(k)),
    );

    if (found) {
        return `<img src="img/JRLinesImage/${found.area}/${found.symbol}.png"style="height: 1.0em; vertical-align: middle; margin-right: 6px;">`;
    }
    return "";
}

function updateSignage() {
    // データの存在チェック（undefined または null の場合は時計モードへ）
    if (typeof signageData === "undefined" || signageData === null) {
        lastUpdateTime = ""; // データが消失した際は時刻をリセットして、復帰時に確実に更新されるようにするよ
        infoDataFailed();
        return;
    }

    if (signageData.updateTime === lastUpdateTime) return;

    console.log("最終更新:" + lastUpdateTime);
    console.log("取得ファイルの日時:" + signageData.updateTime);

    lastUpdateTime = signageData.updateTime;

    emergencyList = [];
    evacuationList = [];
    railwayList = [];
    newsArticles = [];
    weatherList = [];

    currentSlide = 0; // インデックスリセット

    console.log("データ読み取り実行");

    //津波情報
    importTsunamiData();

    //地震情報
    importEarthquakeData();

    //避難情報
    importEvacuationData();

    //列車運行情報
    importRailwayInfoData();

    //ニュース
    importNewsData();

    //気象情報
    importWeatherData();

    // ==========================================
    // 2. 優先順位に基づいたスライドリストの組み立て
    // ==========================================
    slideList = [];

    // 【修正】重要情報をひとつにまとめる
    const importantInfo = [...emergencyList, ...evacuationList, ...railwayList];

    // ① 起動・更新時の最優先表示 (重要情報 → 気象情報)
    // 【修正】重要情報の次に気象情報が来るように追加
    slideList.push(...importantInfo);
    slideList.push(...weatherList);

    // ② ニュース記事の配置
    // 【修正】index を受け取って3の倍数判定に使う
    newsArticles.forEach((pages, index) => {
        // 記事の全ページを表示し終わるまで railway などを挟まない
        slideList.push(...pages);

        // 1つの記事が終わるごとに高優先度情報（重要情報）をリピート
        slideList.push(...importantInfo);

        // 記事が3の倍数個終わったタイミングで気象情報を挟む
        if ((index + 1) % 3 === 0) {
            slideList.push(...weatherList);
        }
    });

    // フィルタリング（空スライドの除去）
    slideList = slideList.filter((s) => s !== "");

    // 画面反映
    const container = document.getElementById("slide-container");
    console.log("リスト:" + slideList.length);
    if (slideList.length > 0) {
        document.getElementById("idle-view").style.display = "none";
        document.getElementById("signage-header").style.display = "flex";
        container.innerHTML = slideList.join("");
        container.style.display = "block";

        showSlide();
    } else {
        infoDataFailed();
    }
}

/**
 * 津波情報を取得
 */
function importTsunamiData() {
    if (signageData.tsunami?.length > 0) {
        emergencyList.push(createTsunamiHtml());
    }
}

/**
 * 地震情報を取得
 */
function importEarthquakeData() {
    if (signageData.earthquake) {
        const q = signageData.earthquake;
        if (q.ikunoScale >= 10 || q.maxScale >= 45) {
            const scaleMap = {
                10: "1",
                20: "2",
                30: "3",
                40: "4",
                45: "5弱",
                50: "5強",
                55: "6弱",
                60: "6強",
                70: "7",
            };
            const bg =
                q.ikunoScale >= 50
                    ? "bg-red"
                    : q.ikunoScale >= 30
                      ? "bg-yellow"
                      : "bg-cyan";

            emergencyList.push(createEarthquakeHtml(q, scaleMap, bg));
        }
    }
}

/**
 * 避難情報の取得
 */
function importEvacuationData() {
    if (signageData.evacuation?.length > 0) {
        signageData.evacuation.forEach((ev) => {
            const bg =
                ev.level === "emergency"
                    ? "bg-white"
                    : ev.level === "instruction"
                      ? "bg-purple"
                      : "bg-red";
            evacuationList.push(createEvacuationHtml(bg, ev));
        });
    }
}

/**
 * 列車の運行情報の取得
 */
function importRailwayInfoData() {
    if (signageData.railway?.length > 0) {
        signageData.railway.forEach((r) => {
            // デフォルトカラー（遅延・一部運休など）
            let badgeBg = "var(--sky-yellow)";
            let badgeText = "#000";

            let fixedBottomHtml = "";

            if (r.color === "red") {
                // 運転見合わせなど
                badgeBg = "var(--alert-red-bg)";
                badgeText = "#fff";
            } else if (r.color === "orange") {
                // お知らせ・運休の可能性ありなど
                badgeBg = "var(--imazato-orange)";
                badgeText = "#fff";
            }

            console.log(r.lineCode);

            if (r.lineCode == TRAIN_COMPANY.JR_WEST) {
                const parts = r.msg.split(" 【");
                const causeStr =
                    parts
                        .find(
                            (p) =>
                                p.startsWith("原因】") ||
                                p.startsWith("事由】") ||
                                p.startsWith("理由】"),
                        )
                        ?.replace(/.*】/, "") || "";
                const resumeStr =
                    parts
                        .find(
                            (p) =>
                                p.startsWith("再開見込】") ||
                                p.startsWith("運転再開見込み】") ||
                                p.startsWith("再開見込み】"),
                        )
                        ?.replace(/.*】/, "") || "";

                // 影響区間のデータを整形して保管
                const formattedSections = parts[0]
                    .split(" / ")
                    .map((s) => {
                        const m = s.match(/(.*?)（(.*?)）/);
                        const icon = getLineSymbolHtml(r.name, s, r.lineCode); // アイコン取得
                        const lineTitle = `<div class="line_name">${icon}<strong>${r.name}</strong></div>`;
                        return m
                            ? `${lineTitle}【${m[2]}】  ${m[1]}`
                            : `${lineTitle}${s}`;
                    })
                    .join("<br>");

                // 影響区間・運転再開見込み・事象発生原因の項目
                fixedBottomHtml = createRailwayInfoOverviewHtml(
                    formattedSections,
                    causeStr,
                    resumeStr,
                );
            }

            // 第4引数を true にして、行数上限まで詰め込む
            const bodyChunks = splitTextByLines(
                r.body || "",
                TRAIN_INFO_LINE_LENGTH,
                TEXT_LENGTH,
                MODE.RAILWAY,
            );

            bodyChunks.forEach((chunk, i) => {
                
                const pageNumTag =
                    bodyChunks.length > 1
                        ? `<div class="page-num">${i + 1}/${bodyChunks.length}</div>`
                        : "";

                railwayList.push(
                    createRailwayInfoBodyHtml(
                        r,
                        chunk,
                        badgeBg,
                        badgeText,
                        fixedBottomHtml,
                        pageNumTag,
                    ),
                );
            });
        });
    }
}

/**
 * ニュースデータの取得
 */
function importNewsData() {
    if (!signageData.news) return;

    signageData.news.forEach((n) => {
        // 1. タグを改行コードに変換して、計算しやすいテキストにするよ！
        // </p><p> は段落なので2行改行（\n\n）、<br> は1行改行（\n）に置き換えるね
        const processedBody = n.body
            .replace(/<\/p>\s*<p>/g, "\n\n")
            .replace(/<br\s*\/?>/g, "\n")
            .replace(/<[^>]+>/g, "") // その他のタグ（外側の <p> など）をきれいに消去
            .trim(); // 前後の余計な空行をカット

        // 2. ページ分割（改行を考慮して、行数ベースでしっかり分けるよ）
        const chunks = splitTextByLines(
            processedBody,
            NEWS_LINE_LENGTH,
            TEXT_LENGTH,
            MODE.NEWS,
        );

        const pages = chunks.map((text, i) => {
            // 3. 表示する時に \n を <br> に戻して、HTMLとしての改行を再現！
            const htmlText = text.replace(/\n/g, "<br>");

            const pageNum =
                chunks.length > 1
                    ? `<div class="page-num">${i + 1}/${chunks.length}</div>`
                    : "";

            return createNewsDataHtml(n.title, htmlText, pageNum);
        });

        newsArticles.push(pages);
    });
}

/**
 * 天気予報の取得
 */
function importWeatherData() {
    if (signageData.weather && signageData.weather.hourly) {
        const w = signageData.weather;
        const now = new Date();

        /**
         * WMOコードをGoogle WeatherアイコンURLに変換
         * 背景が黒なので指示通り末尾に "_dark.svg" を追加するよ！
         */
        const getGoogleWeatherIcon = (code, isDay = 1) => {
            let name = "error"; // デフォルト

            if (code === 0) {
                // CLEAR (image_10386a)
                name = "sunny";
            } else if (code === 1) {
                // MOSTLY_CLEAR (image_10386a)
                name = "mostly_sunny";
            } else if (code === 2) {
                // PARTLY_CLOUDY (image_10386a)
                name = "partly_cloudy";
            } else if (code === 3) {
                // CLOUDY (image_10386a)
                name = "cloudy";
            } else if (code >= 45 && code <= 48) {
                // 霧：要件の表にないため「cloudy」を使用
                name = "cloudy";
            } else if (code >= 51 && code <= 55) {
                // LIGHT_RAIN (image_10388e)
                name = "drizzle";
            } else if (code >= 61 && code <= 67) {
                // RAIN (image_10388e)
                name = "showers";
            } else if (code >= 71 && code <= 77) {
                // SNOW (image_1038ab)
                name = "snow";
            } else if (code >= 80 && code <= 82) {
                // RAIN_SHOWERS (image_10388e)
                name = "rain_showers";
            } else if (code >= 95) {
                // THUNDERSTORM (image_1038c9)
                name = "thunderstorm";
            }

            // 指定のベースURIに基づき、ダークモード用のSVGを返すよ
            return `https://maps.gstatic.com/weather/v1/${name}_dark.svg`;
        };

        // 日本語天気名マップ
        const wMap = {
            0: "晴れ",
            1: "晴れ",
            2: "一部曇り",
            3: "曇り",
            45: "霧",
            48: "霧氷",
            51: "霧雨",
            53: "霧雨",
            55: "霧雨",
            56: "霧雨（凍雨を伴う）",
            57: "霧雨（凍雨を伴う）",
            61: "雨",
            63: "雨",
            65: "雨",
            66: "雨（凍雨を伴う）",
            67: "雨（凍雨を伴う）",
            71: "雪",
            73: "雪",
            75: "雪",
            77: "雪粒子",
            80: "にわか雨",
            81: "にわか雨",
            82: "にわか雨",
            85: "にわか雪",
            86: "にわか雪",
            95: "雷雨",
            96: "雷雨（ひょうを伴う）",
            99: "雷雨（ひょうを伴う）",
        };

        // --- 【計算ロジック】今この瞬間から「次に来る3の倍数時」を起点にする ---
        const firstIndex = w.hourly.time.findIndex((t) => {
            const d = new Date(t);
            // 現在より未来、かつ 0, 3, 6, 9...時である最初のデータを探す
            return d > now && d.getHours() % 3 === 0;
        });

        // 起点から [0, 3, 6, 9, 12, 15] 時間後の計6件分を生成
        const hourlyHtml = [0, 3, 6, 9, 12, 15, 18, 21, 24]
            .map((offset) => {
                const idx = firstIndex + offset;
                if (idx < 0 || !w.hourly.time[idx]) return "";

                const d = new Date(w.hourly.time[idx]);
                const hour = d.getHours();
                const code = w.hourly.weathercode[idx];
                const temp = Math.round(w.hourly.temperature_2m[idx]);
                // 予報時間帯が昼(6-18時)か夜かでアイコンを出し分け
                const isDayTime = hour >= 6 && hour < 18 ? 1 : 0;

                return createWeatherDataHtmlTime(
                    getGoogleWeatherIcon,
                    hour,
                    code,
                    isDayTime,
                    wMap,
                    temp,
                );
            })
            .join("");

        // --- スライド1：現在の天気 ＋ 直近6件（18時間分）の予報 ---
        const currentCode = w.current_weather.weathercode;
        const isDayNow = w.current_weather.is_day;
        weatherList.push(
            createWeatherDataHtmlNow(
                getGoogleWeatherIcon,
                w,
                wMap,
                currentCode,
                isDayNow,
                hourlyHtml,
            ),
        );

        // --- スライド2：明日の天気サマリー ---
        const tomorrowCode = w.daily.weathercode[1];
        weatherList.push(
            createWeatherDataHtmlTomorrow(
                getGoogleWeatherIcon,
                tomorrowCode,
                wMap,
                w,
            ),
        );
    }
}

/* インフォデータの取得失敗時 */
function infoDataFailed() {
    const idleView = document.getElementById("idle-view");
    const headerView = document.getElementById("signage-header");
    const container = document.getElementById("slide-container");

    // "block" ではなく "flex" にするのが超重要！
    if (idleView) idleView.style.display = "flex";
    if (headerView) headerView.style.display = "none";
    if (container) container.style.display = "none";
    if (container) container.innerHTML = "";
}

/**
 * 画面の反映
 * @returns データなしなら実行しない
 */
function showSlide() {
    const slides = document.querySelectorAll(".slide");
    if (slides.length === 0) return;
    slides.forEach((s) => s.classList.remove("active"));
    currentSlide = currentSlide % slides.length;
    slides[currentSlide].classList.add("active");
    currentSlide = (currentSlide + 1) % slides.length;
}

/**
 * 文章を句点（。）で区切り、指定文字数を超えないように分割する
 */
function splitTextBySentences(text, maxLength) {
    const sentences = text.split("。");
    let chunks = [];
    let currentChunk = "";

    sentences.forEach((s) => {
        if (!s.trim()) return;
        const sentence = s + "。";
        // 現在の塊に次の文を足して制限文字数を超えるなら、新しい塊を作る
        if (
            (currentChunk + sentence).length > maxLength &&
            currentChunk !== ""
        ) {
            chunks.push(currentChunk);
            currentChunk = sentence;
        } else {
            currentChunk += sentence;
        }
    });
    if (currentChunk) chunks.push(currentChunk);
    return chunks;
}

/**
 * 文章を行数に基づいて分割する
 * @param {string} text 元の文章
 * @param {number} maxLines 1ページあたりの最大行数
 * @param {number} charsPerLine 1行あたりの目安文字数
 * @param {boolean} splitMode 文章の分割モードの選択
 */
function splitTextByLines(text, maxLines, charsPerLine = 35, splitMode) {
    if (!text) return [""];

    const rawLines = text.split("\n");
    let atoms = [];

    switch (splitMode) {
        case MODE.RAILWAY:
            {
                rawLines.forEach((line) => {
                    const s = line.trim();
                    if (!s) {
                        atoms.push("");
                        return;
                    }

                    // 見出しやリスト（・や時刻）はそのまま
                    const isHeader = /^[＜【]/.test(s);
                    const isList = /^(・|※|[^\s　]+[ 　]+\d{1,2}時)/.test(s);

                    if (isHeader || isList) {
                        atoms.push(s);
                    } else {
                        // 【ここが最大の修正ポイント】
                        // 文章を「。」の後ろで分割して、1文ずつを1つの塊（atom）にする
                        // これにより「〜」の途中や駅名の途中で切れるのを防ぐよ
                        const segments = s.split(/(?<=。)/);
                        segments.forEach((seg) => {
                            if (seg.trim()) atoms.push(seg.trim());
                        });
                    }
                });
            }
            break;

        case MODE.NEWS:
            {
                const segments = text.split(/(?<=[。？?！!])|\n+/);
                segments.forEach((seg) => {
                    if (seg === "") {
                        atoms.push(""); // 空行維持
                        return;
                    }

                    const s = seg.trim();
                    if (!s) return;
                    // 1文がページ最大容量を超える場合は分割
                    if (Math.ceil(s.length / charsPerLine) > maxLines) {
                        for (let i = 0; i < s.length; i += charsPerLine) {
                            atoms.push(s.substring(i, i + charsPerLine));
                        }
                    } else {
                        atoms.push(s);
                    }
                });
            }
            break;

        default:
            console.log(
                "このモードに対応する機能がありません。  選択モード:" +
                    splitMode,
            );
            break;
    }

    // 原子（atoms）をページに詰める
    let pages = [];
    let currentPageAtoms = [];
    let currentLineCount = 0;

    atoms.forEach((atom) => {
        // このアトムが何行分消費するか計算
        const atomLines = Math.max(1, Math.ceil(atom.length / charsPerLine));

        if (
            currentLineCount + atomLines > maxLines &&
            currentPageAtoms.length > 0
        ) {
            pages.push(currentPageAtoms.join("\n"));
            currentPageAtoms = [];
            currentLineCount = 0;
        }
        currentPageAtoms.push(atom);
        currentLineCount += atomLines;
    });

    if (currentPageAtoms.length > 0) {
        pages.push(currentPageAtoms.join("\n"));
    }

    return pages;
}

/**
 * 1秒ごとに実行する：ページはリロードせず、データファイルだけを読み直す
 */
function fetchNewData() {
    const oldScript = document.getElementById("data-script");
    if (oldScript) oldScript.remove();

    const script = document.createElement("script");
    script.id = "data-script";
    script.src = `temp/news_data.js?v=${Date.now()}`;

    // 読み込み成功時
    script.onload = () => {
        updateSignage();
    };

    //ファイルが削除されたり、ネットワークエラーで読み込めなかった時の処理
    script.onerror = () => {
        window.signageData = undefined; // メモリ上の古いデータを消去
        updateSignage(); // 反映させる
    };

    document.body.appendChild(script);
}
