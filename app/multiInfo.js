/** 表示させる情報の番号 */
let currentSlide = 0;

let slideTimerId = null;
let emergencyInfoTimerId = null;
let emergencyInfoState = { recentId: "", mode: "a", index: 0, startedAt: 0 };
const DEFAULT_SLIDE_INTERVAL_MS = 30000;
const SCROLL_END_WAIT_MS = 10000;
const SCROLL_START_DELAY_MS = 10000;
const EMERGENCY_INFO_FRAME_INTERVAL_MS = 5000;
const EMERGENCY_RECENT_REPEAT_MS = 5 * 60 * 1000;
const SIGNAGE_DATA_MAX_TIME_OFFSET_MS = 30 * 60 * 1000;
const INFORMATION_DISPLAY_LOG_URL =
    "http://127.0.0.1:18765/time-signal/information/display-log";
const DISPLAY_LOG_DUPLICATE_WINDOW_MS = 5000;
const DATA_RELOAD_TIMEOUT_MS = 10000;

let lastDisplayLogKey = "";
let lastDisplayLogAt = 0;

/** 表示される情報を格納するリスト */
let slideList = [];
let slideCycleRanges = [];
let activeSignageData = null;
let activeSignageSignature = "";
let pendingSignageData = null;
let pendingSignageSignature = "";
let pendingNonNewsApplied = false;
let activeEarthquakeSignature = "";
let hasRenderedActiveSignage = false;
let dataReloadInProgress = false;
let dataReloadStartedAt = 0;
let dataReloadRequestId = 0;

const container = document.getElementById("slide-container");
const idleView = document.getElementById("idle-view");
const headerView = document.getElementById("signage-header");

/* 前回の更新時刻を保管 */
let lastUpdateTime = "";

/** 取得路線情報 */
const TRAIN_COMPANY = {
    JR_WEST: 0,
    OTHERS: 1,
};

/** Yahoo!運行情報の路線IDと私鉄路線アイコンの対応表 */
const PRIVATE_RAILWAY_SYMBOLS = {
    321: ["osaka_metro/midousuji_line.png", "御堂筋線"],
    324: ["osaka_metro/chuo_line.png", "中央線"],
    537: ["osaka_metro/imazatosuji_line.png", "今里筋線"],
    327: [
        "osaka_metro/nagahori_tsurumi-ryokuti_line.png",
        "長堀鶴見緑地線",
    ],
    320: ["osaka_metro/nankou_port_line.png", "南港ポートタウン線"],
    326: ["osaka_metro/sakaisuji_line.png", "堺筋線"],
    325: ["osaka_metro/sennichimae_line.png", "千日前線"],
    322: ["osaka_metro/tanimachi_line.png", "谷町線"],
    323: ["osaka_metro/yotsubashi_line.png", "四つ橋線"],
    284: ["kintetsu/kintetsu_osaka_line.png", "近鉄大阪線"],
    285: ["kintetsu/kintetsu_nara_line.png", "近鉄奈良線"],
    295: ["kintetsu/kintetsu_minami_osaka_line.png", "近鉄南大阪線"],
    287: ["kintetsu/kintetsu_keihanna_line.png", "近鉄けいはんな線"],
    339: ["nankai/nankai_main_line.png", "南海本線"],
    340: ["nankai/nankai_airport_line.png", "南海空港線"],
    347: ["nankai/nankai_shiomibashi_line.png", "南海汐見橋線"],
    306: ["hankyu/hankyu_kyoto_line.png", "阪急京都線系統"],
    313: ["hankyu/hankyu_kyoto_line.png", "阪急京都線系統"],
    310: ["hankyu/hankyu_kobe_line.png", "阪急神戸線系統"],
    311: ["hankyu/hankyu_takaraduka_line.png", "阪急宝塚線系統"],
    300: ["keihan/keihan.png", "京阪線"],
    315: ["hanshin/hanshin.png", "阪神線"],
    316: ["hanshin/hanshin.png", "阪神線"],
    623: ["hanshin/hanshin.png", "阪神線"],
    354: ["sanyo/sanyo_railway.png", "山陽電車"],
    7: ["tokaido_shinkansen/tokaido_shinkansen.png", "東海道新幹線"],
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

/** Google Calendarの予定情報を保管する配列 */
let scheduleList;

/**
 * 路線記号の画像HTMLを生成する
 */
function createLineSymbolImageHtml(src, alt) {
    return `<img src="${src}" class="jr-line-symbol" alt="${alt}">`;
}

function createJrLineSymbolImageHtml(area, symbol) {
    return createLineSymbolImageHtml(
        `img/JRLinesImage/${area}/${symbol}.png`,
        symbol,
    );
}

function getPrivateRailwaySymbolHtml(lineId) {
    const symbol = PRIVATE_RAILWAY_SYMBOLS[String(lineId || "")];
    if (!symbol) return "";

    return createLineSymbolImageHtml(
        `img/private_railway_image/${symbol[0]}`,
        symbol[1],
    );
}

/**
 * 路線名から路線記号の画像HTMLを生成する
 */
function getLineSymbolHtml(lineName, contextText = "", lineCode, lineId = "") {
    if (!lineName) return "";
    if (lineCode == TRAIN_COMPANY.OTHERS) {
        return getPrivateRailwaySymbolHtml(lineId);
    }
    if (lineCode != TRAIN_COMPANY.JR_WEST) return "";

    if (lineName.includes("山陽新幹線")) {
        return createJrLineSymbolImageHtml(
            "sanyo_shinkansen",
            "sanyo-shinkansen",
        );
    }

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

        if (isE) icons += createJrLineSymbolImageHtml("keihanshin_area", "E");
        if (isA) icons += createJrLineSymbolImageHtml("yonago_area", "A");

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
        { area: "keihanshin_area", symbol: "J", keywords: ["播但線", "播担線"] },
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
    const searchText = `${lineName} ${contextText}`;
    const found = symbols.find((item) =>
        item.keywords.some((k) => searchText.includes(k)),
    );

    if (found) {
        return createJrLineSymbolImageHtml(found.area, found.symbol);
    }
    return "";
}

function getActiveEarthquakeData() {
    return typeof earthquakeData !== "undefined" && earthquakeData
        ? earthquakeData
        : null;
}

function getUpdateSignature(value) {
    try {
        const text = JSON.stringify(value || null) || "";
        let hash = 0;
        for (let index = 0; index < text.length; index += 1) {
            hash = (hash * 31 + text.charCodeAt(index)) >>> 0;
        }
        return `${text.length}:${hash.toString(16)}`;
    } catch {
        return String(Date.now());
    }
}

function getComparableSignageData(data) {
    const comparable = JSON.parse(JSON.stringify(data || {}));
    delete comparable.updateTime;

    if (comparable.calendarSchedule) {
        delete comparable.calendarSchedule.updateTime;
    }
    if (comparable.weather) {
        comparable.weather.generationtime_ms = 0;
        if (comparable.weather.current_weather) {
            delete comparable.weather.current_weather.time;
            delete comparable.weather.current_weather.interval;
        }
    }
    if (comparable.weeklyWeather) {
        delete comparable.weeklyWeather.reportDatetime;
    }

    return comparable;
}

function getSignageContentSignature(data) {
    return getUpdateSignature(getComparableSignageData(data));
}

function getNonNewsSignature(data) {
    const comparable = getComparableSignageData(data);
    delete comparable.news;
    return getUpdateSignature(comparable);
}

function getNewsSignature(data) {
    return getUpdateSignature(getComparableSignageData(data).news || []);
}

function parseSignageDataUpdateTime(value) {
    const match = String(value || "").match(
        /^(\d{4})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2})$/,
    );
    if (!match) return null;

    const updateTime = new Date(
        Number(match[1]),
        Number(match[2]) - 1,
        Number(match[3]),
        Number(match[4]),
        Number(match[5]),
        0,
        0,
    );
    if (Number.isNaN(updateTime.getTime())) return null;

    const hasExactComponents =
        updateTime.getFullYear() === Number(match[1]) &&
        updateTime.getMonth() === Number(match[2]) - 1 &&
        updateTime.getDate() === Number(match[3]) &&
        updateTime.getHours() === Number(match[4]) &&
        updateTime.getMinutes() === Number(match[5]);
    return hasExactComponents ? updateTime : null;
}

function isSignageDataCurrent(data, now = new Date()) {
    const fetchStatus =
        typeof signageFetchStatus !== "undefined" ? signageFetchStatus : null;
    const updateTime = parseSignageDataUpdateTime(
        fetchStatus?.updateTime || data?.updateTime,
    );
    if (!updateTime) return false;

    return (
        Math.abs(now.getTime() - updateTime.getTime()) <=
        SIGNAGE_DATA_MAX_TIME_OFFSET_MS
    );
}

function updateSignage() {
    const activeEarthquakeData = getActiveEarthquakeData();
    const hasLoadedSignageData =
        typeof signageData !== "undefined" && signageData !== null;
    const hasCurrentSignageData =
        hasLoadedSignageData && isSignageDataCurrent(signageData);

    if (!hasCurrentSignageData && !activeEarthquakeData) {
        lastUpdateTime = "";
        activeSignageData = null;
        activeSignageSignature = "";
        pendingSignageData = null;
        pendingSignageSignature = "";
        pendingNonNewsApplied = false;
        hasRenderedActiveSignage = false;
        infoDataFailed();
        return;
    }

    const incomingData = hasCurrentSignageData
        ? JSON.parse(JSON.stringify(signageData))
        : {
            updateTime: "",
            tsunami: [],
            earthquake: null,
            weatherWarnings: null,
            evacuation: [],
            railway: [],
            news: [],
            weather: null,
            weeklyWeather: null,
            calendarSchedule: null,
        };
    const incomingSignature = getSignageContentSignature(incomingData);
    const earthquakeSignature = getUpdateSignature(activeEarthquakeData);

    if (!activeSignageData) {
        activeSignageData = incomingData;
        activeSignageSignature = incomingSignature;
        window.signageData = activeSignageData;
        renderActiveSignage(0);
        return;
    }

    // 古いnews_dataは即時破棄し、別ファイルの緊急情報だけを表示する。
    if (!hasCurrentSignageData) {
        const requiresRender =
            incomingSignature !== activeSignageSignature ||
            earthquakeSignature !== activeEarthquakeSignature;
        activeSignageData = incomingData;
        activeSignageSignature = incomingSignature;
        pendingSignageData = null;
        pendingSignageSignature = "";
        pendingNonNewsApplied = false;
        window.signageData = activeSignageData;
        if (requiresRender) renderActiveSignage(0);
        return;
    }

    if (incomingSignature === activeSignageSignature) {
        pendingSignageData = null;
        pendingSignageSignature = "";
        pendingNonNewsApplied = false;
    } else if (incomingSignature !== pendingSignageSignature) {
        pendingSignageData = incomingData;
        pendingSignageSignature = incomingSignature;
        pendingNonNewsApplied = false;
    }

    // 読み込んだ最新データはサイクル境界まで保留し、表示中データへ戻す。
    window.signageData = activeSignageData;
    if (!hasRenderedActiveSignage) {
        renderActiveSignage(0);
        return;
    }
    if (earthquakeSignature !== activeEarthquakeSignature) {
        const currentCycle = getSlideCycleRange(currentSlide)?.cycleIndex || 0;
        renderActiveSignage(currentCycle);
    }
}

function renderActiveSignage(startCycleIndex = 0) {
    hasRenderedActiveSignage = false;
    const activeEarthquakeData = getActiveEarthquakeData();
    window.signageData = activeSignageData;
    activeSignageSignature = getSignageContentSignature(activeSignageData);
    activeEarthquakeSignature = getUpdateSignature(activeEarthquakeData);
    lastUpdateTime = `${activeSignageSignature}|${activeEarthquakeSignature}`;

    emergencyList = [];
    evacuationList = [];
    railwayList = [];
    newsArticles = [];
    weatherList = [];
    scheduleList = [];

    console.log("データ読み取り実行");

    importTsunamiData();
    importEarthquakeData();
    importWeatherWarningData();
    importEvacuationData();
    importRailwayInfoData();
    importCalendarScheduleData();
    importNewsData();
    importWeatherData();

    const alertInfo = [...emergencyList, ...evacuationList];
    const transitInfo = [...railwayList, ...scheduleList];
    const isDisasterPriority = activeEarthquakeData?.priorityMode === "disaster";
    const hasEarthquakeBottomBanner = activeEarthquakeData?.priorityMode === "bottom" || !!activeEarthquakeData?.emergencyMode?.active;

    let cycles = [];
    if (isDisasterPriority) {
        cycles = [[
            createDisasterPriorityHtml(
                activeEarthquakeData,
                signageData.railway || [],
            ),
        ]];
    } else {
        const newsCycles = newsArticles.length > 0 ? newsArticles : [[]];
        cycles = newsCycles.map((newsPages, index) => {
            return [
                ...alertInfo,
                ...(index % 3 === 0 ? weatherList : []),
                ...transitInfo,
                ...newsPages,
            ].filter((slide) => slide !== "");
        });
    }

    slideList = [];
    slideCycleRanges = [];
    cycles.forEach((cycleSlides, cycleIndex) => {
        if (cycleSlides.length === 0) return;

        const start = slideList.length;
        slideList.push(...cycleSlides);
        slideCycleRanges.push({
            cycleIndex,
            start,
            end: slideList.length - 1,
        });
    });

    const bottomBannerHtml =
        !isDisasterPriority && hasEarthquakeBottomBanner
            ? createEarthquakeBottomBannerHtml(activeEarthquakeData)
            : "";

    const container = document.getElementById("slide-container");
    container?.classList.toggle("with-earthquake-bottom-banner", !!bottomBannerHtml);
    console.log("リスト" + slideList.length);
    if (slideList.length > 0 || bottomBannerHtml) {
        document.getElementById("idle-view").style.display = "none";
        document.getElementById("signage-header").style.display = "flex";
        clearEmergencyInfoTimer();
        container.innerHTML = slideList.join("") + bottomBannerHtml;
        startEmergencyInfoLineRotation(container);
        container.style.display = "block";

        if (slideList.length > 0) {
            const cycleCount = slideCycleRanges.length;
            const normalizedCycleIndex = cycleCount
                ? ((startCycleIndex % cycleCount) + cycleCount) % cycleCount
                : 0;
            const startRange =
                slideCycleRanges.find(
                    (range) => range.cycleIndex === normalizedCycleIndex,
                ) || slideCycleRanges[0];
            currentSlide = startRange?.start || 0;
            showSlide();
        }
        hasRenderedActiveSignage = true;
    } else {
        infoDataFailed();
    }
}

function importTsunamiData() {
    const activeEarthquakeData = getActiveEarthquakeData();
    if (activeEarthquakeData?.tsunami?.active) {
        emergencyList.push(createTsunamiHtml(activeEarthquakeData.tsunami));
        return;
    }

    if (signageData.tsunami?.length > 0) {
        emergencyList.push(createTsunamiHtml({ active: true, areas: signageData.tsunami }));
    }
}

function importEarthquakeData() {
    const activeEarthquakeData = getActiveEarthquakeData();
    if (activeEarthquakeData?.eew) {
        emergencyList.push(createEewHtml(activeEarthquakeData.eew));
    }

    const q = activeEarthquakeData?.earthquake || signageData.earthquake;
    if (!q) return;

    if (activeEarthquakeData) {
        if (activeEarthquakeData.priorityMode === "disaster") {
            emergencyList.push(createEarthquakeHtml(q));
        }
        return;
    }

    if (q.ikunoScale >= 10 || q.maxScale >= 45) {
        emergencyList.push(createEarthquakeHtml(q));
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
 * 大阪市の気象警報・注意報を取得
 */
function importWeatherWarningData() {
    const warningData = signageData.weatherWarnings;
    if (!warningData) return;

    const decodeJmaStatus = (status) => {
        const value = String(status || "");
        if (!/[ÃÂèéç]/.test(value)) return value;

        try {
            const bytes = Uint8Array.from(
                [...value].map((character) => character.charCodeAt(0)),
            );
            return new TextDecoder("utf-8").decode(bytes);
        } catch {
            return value;
        }
    };

    const warnings = (warningData.warnings || []).map((warning) => ({
        ...warning,
        status: decodeJmaStatus(warning.status),
    }));

    emergencyList.push(
        ...createWeatherWarningSlidesHtml({
            ...warningData,
            warnings,
        }),
    );
}

/** Google Calendarの本日・週間予定を重要情報として取り込む。 */
function importCalendarScheduleData() {
    const schedule = signageData.calendarSchedule;
    if (!schedule || schedule.status !== "ok") return;
    scheduleList.push(...createCalendarScheduleSlidesHtml(schedule));
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

            const isLimitedExpress =
                r.limitedExpress === true || /^特急/.test(String(r.name || ""));

            if (r.lineCode == TRAIN_COMPANY.JR_WEST) {
                const parts = String(r.msg || "").split(" 【");
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

                if (isLimitedExpress) {
                    fixedBottomHtml = createRailwayInfoOverviewHtml(
                        "",
                        causeStr,
                        resumeStr,
                        false,
                    );
                } else {
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
            }

            railwayList.push(
                createRailwayInfoBodyHtml(
                    r,
                    r.body || "",
                    badgeBg,
                    badgeText,
                    fixedBottomHtml,
                ),
            );
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

        const htmlText = processedBody.replace(/\n/g, "<br>");
        newsArticles.push([createNewsDataHtml(n.title, htmlText)]);
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

            // 雷雨系はダーク版のファイル名が異なるため、指定URLを直接返す。
            if (code === 95) {
                return "https://maps.gstatic.com/weather/v1/strong_tstorms.svg";
            }
            if (code === 96 || code === 99) {
                return "https://maps.gstatic.com/weather/v1/sleet_hail.svg";
            }
            if (code >= 80 && code <= 82) {
                return "https://maps.gstatic.com/weather/v1/isolated_tstorms.svg";
            }

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
            }

            // 指定のベースURIに基づき、ダークモード用のSVGを返すよ
            return `https://maps.gstatic.com/weather/v1/${name}_dark.svg`;
        };

        const getDisplayWeatherCode = (code, precipitationProbability) => {
            const probability = Number(precipitationProbability);
            if (!Number.isFinite(probability)) return code;

            if (probability >= 70 && code >= 0 && code <= 3) return 61;
            if (probability >= 50 && code >= 0 && code <= 2) return 3;

            return code;
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

        // 起点から3時間おき、24時間先までの9件を生成
        const forecastItems = [0, 3, 6, 9, 12, 15, 18, 21, 24]
            .map((offset) => {
                const idx = firstIndex + offset;
                if (idx < 0 || !w.hourly.time[idx]) return null;

                const d = new Date(w.hourly.time[idx]);
                const hour = d.getHours();
                const rawCode = w.hourly.weathercode[idx];
                const temp = Math.round(w.hourly.temperature_2m[idx]);
                const precipitationProbability =
                    w.hourly.precipitation_probability?.[idx];
                const code = getDisplayWeatherCode(
                    rawCode,
                    precipitationProbability,
                );
                // 予報時間帯が昼(6-18時)か夜かでアイコンを出し分け
                const isDayTime = hour >= 6 && hour < 18 ? 1 : 0;

                return {
                    hour,
                    dateKey: `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`,
                    dateLabel: `${d.getMonth() + 1}/${d.getDate()}`,
                    code,
                    temp,
                    precipitationProbability,
                    isDayTime,
                };
            })
            .filter(Boolean);

        const hourlyHtml = forecastItems
            .map((forecast, index) => {
                const previousForecast = forecastItems[index - 1];
                const dateLabel =
                    !previousForecast ||
                    previousForecast.dateKey !== forecast.dateKey
                        ? forecast.dateLabel
                        : "";

                return createWeatherDataHtmlTime(
                    getGoogleWeatherIcon,
                    dateLabel,
                    forecast.hour,
                    forecast.code,
                    forecast.isDayTime,
                    wMap,
                    forecast.temp,
                    forecast.precipitationProbability,
                );
            })
            .join("");
        const temperatureGraphHtml =
            createWeatherTemperatureGraphHtml(forecastItems);

        const currentHourIndex = w.hourly.time.findIndex((time) => {
            const hourlyDate = new Date(time);
            return (
                hourlyDate.getFullYear() === now.getFullYear() &&
                hourlyDate.getMonth() === now.getMonth() &&
                hourlyDate.getDate() === now.getDate() &&
                hourlyDate.getHours() === now.getHours()
            );
        });
        const currentPrecipitationProbability =
            currentHourIndex >= 0
                ? w.hourly.precipitation_probability?.[currentHourIndex]
                : null;

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
                temperatureGraphHtml,
                currentPrecipitationProbability,
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

        if (signageData.weeklyWeather?.days?.length) {
            weatherList.push(
                createWeeklyWeatherHtml(signageData.weeklyWeather),
            );
        }
    }
}

/* インフォデータの取得失敗時 */
function infoDataFailed() {
    hasRenderedActiveSignage = false;
    clearSlideTimer();
    clearEmergencyInfoTimer();
    const idleView = document.getElementById("idle-view");
    const headerView = document.getElementById("signage-header");
    const container = document.getElementById("slide-container");

    // "block" ではなく "flex" にするのが超重要！
    if (idleView) idleView.style.display = "flex";
    if (headerView) headerView.style.display = "none";
    if (container) container.style.display = "none";
    if (container) {
        container.classList.remove("with-earthquake-bottom-banner");
        container.innerHTML = "";
    }
}

/**
 * 画面の反映
 * @returns データなしなら実行しない
 */
function normalizeDisplayLogText(value) {
    return String(value || "").replace(/\s+/g, " ").trim();
}

function logDisplayedSlide(slide, slideIndex, slideCount) {
    const titleElement = slide.querySelector(
        ".slide-title, .info-title, h1, h2, h3",
    );
    const payload = {
        slideIndex: slideIndex + 1,
        slideCount,
        dataUpdateTime:
            typeof signageData !== "undefined" ? signageData.updateTime || "" : "",
        classes: Array.from(slide.classList).filter(
            (className) => className !== "active",
        ),
        title: normalizeDisplayLogText(titleElement?.textContent),
        text: normalizeDisplayLogText(slide.textContent),
    };
    const logKey = JSON.stringify(payload);
    const now = Date.now();

    // 同一スライドの再描画による連続した重複だけを抑止する。
    if (
        logKey === lastDisplayLogKey &&
        now - lastDisplayLogAt < DISPLAY_LOG_DUPLICATE_WINDOW_MS
    ) {
        return;
    }

    lastDisplayLogKey = logKey;
    lastDisplayLogAt = now;
    const url = `${INFORMATION_DISPLAY_LOG_URL}?payload=${encodeURIComponent(logKey)}`;
    fetch(url, { cache: "no-store" }).catch(() => {
        // ログ障害はサイネージ表示を妨げない。
    });
}

function getSlideCycleRange(slideIndex) {
    return slideCycleRanges.find(
        (range) => slideIndex >= range.start && slideIndex <= range.end,
    );
}

function applyPendingDataAtCycleEnd(completedRange) {
    if (!pendingSignageData || !completedRange) return false;

    const completedRangeIndex = slideCycleRanges.indexOf(completedRange);
    const isFullRotation =
        completedRangeIndex === slideCycleRanges.length - 1;
    if (!isFullRotation && pendingNonNewsApplied) return false;

    const hasNonNewsChanges =
        getNonNewsSignature(pendingSignageData) !==
        getNonNewsSignature(activeSignageData);
    const hasNewsChanges =
        getNewsSignature(pendingSignageData) !==
        getNewsSignature(activeSignageData);

    if (!isFullRotation && !hasNonNewsChanges) {
        pendingNonNewsApplied = true;
        return false;
    }

    if (isFullRotation && !hasNonNewsChanges && !hasNewsChanges) {
        pendingSignageData = null;
        pendingSignageSignature = "";
        pendingNonNewsApplied = false;
        return false;
    }

    const nextData = JSON.parse(JSON.stringify(pendingSignageData));
    if (!isFullRotation) {
        // ニュースは全ニュースサイクルを表示し終えるまで現在版を維持する。
        nextData.news = JSON.parse(
            JSON.stringify(activeSignageData?.news || []),
        );
    }

    activeSignageData = nextData;
    activeSignageSignature = getSignageContentSignature(activeSignageData);
    if (isFullRotation) {
        pendingSignageData = null;
        pendingSignageSignature = "";
        pendingNonNewsApplied = false;
    } else {
        pendingNonNewsApplied = true;
    }

    const nextRangeIndex =
        (completedRangeIndex + 1) % slideCycleRanges.length;
    const nextCycleIndex = slideCycleRanges[nextRangeIndex]?.cycleIndex || 0;
    renderActiveSignage(nextCycleIndex);
    return true;
}

function completeDisplayedSlide(slideIndex) {
    const completedRange = getSlideCycleRange(slideIndex);
    const isCycleEnd = completedRange?.end === slideIndex;
    if (isCycleEnd && applyPendingDataAtCycleEnd(completedRange)) return;

    showSlide();
}

function showSlide() {
    clearSlideTimer();

    const slides = document.querySelectorAll(".slide");
    if (slides.length === 0) return;
    slides.forEach((s) => s.classList.remove("active"));
    currentSlide = currentSlide % slides.length;
    const activeSlideIndex = currentSlide;
    const activeSlide = slides[activeSlideIndex];
    activeSlide.classList.add("active");
    logDisplayedSlide(activeSlide, activeSlideIndex, slides.length);

    const nextSlideInterval = prepareAutoScroll(activeSlide);
    currentSlide = (currentSlide + 1) % slides.length;
    scheduleNextSlide(nextSlideInterval, activeSlideIndex);
}

function clearSlideTimer() {
    if (slideTimerId) {
        clearTimeout(slideTimerId);
        slideTimerId = null;
    }
}

function clearEmergencyInfoTimer() {
    if (emergencyInfoTimerId) {
        clearInterval(emergencyInfoTimerId);
        emergencyInfoTimerId = null;
    }
}

function setEmergencyInfoFrame(frames, index) {
    frames.forEach((frame, frameIndex) => frame.classList.toggle("is-active", frameIndex === index));
}

function startEmergencyInfoLineRotation(root = document) {
    clearEmergencyInfoTimer();
    const banner = root.querySelector(".earthquake-bottom-banner");
    if (!banner) return;

    const aFrames = Array.from(banner.querySelectorAll('.emergency-info-frame[data-mode="a"]'));
    const bFrames = Array.from(banner.querySelectorAll('.emergency-info-frame[data-mode="b"]'));
    const recentId = banner.dataset.recentId || "";
    const recentTime = Date.parse(banner.dataset.recentTime || "");
    const isRecentFresh = !Number.isNaN(recentTime) && Date.now() - recentTime < EMERGENCY_RECENT_REPEAT_MS;
    const hasB = recentId && bFrames.length > 0;

    if (recentId !== emergencyInfoState.recentId) {
        emergencyInfoState = {
            recentId,
            mode: hasB && isRecentFresh ? "b" : "a",
            index: 0,
            startedAt: Number.isNaN(recentTime) ? Date.now() : recentTime,
        };
    }
    if (!hasB && emergencyInfoState.mode === "b") {
        emergencyInfoState.mode = "a";
        emergencyInfoState.index = 0;
    }

    const showCurrent = () => {
        const activeFrames = emergencyInfoState.mode === "b" ? bFrames : aFrames;
        const inactiveFrames = emergencyInfoState.mode === "b" ? aFrames : bFrames;
        inactiveFrames.forEach((frame) => frame.classList.remove("is-active"));
        if (!activeFrames.length) return;
        emergencyInfoState.index = emergencyInfoState.index % activeFrames.length;
        setEmergencyInfoFrame(activeFrames, emergencyInfoState.index);
    };

    showCurrent();

    emergencyInfoTimerId = setInterval(() => {
        const activeFrames = emergencyInfoState.mode === "b" ? bFrames : aFrames;
        if (!activeFrames.length) return;

        emergencyInfoState.index += 1;
        if (emergencyInfoState.index >= activeFrames.length) {
            emergencyInfoState.index = 0;
            if (
                emergencyInfoState.mode === "b" &&
                Date.now() - emergencyInfoState.startedAt >= EMERGENCY_RECENT_REPEAT_MS
            ) {
                emergencyInfoState.mode = "a";
            }
        }

        showCurrent();
    }, EMERGENCY_INFO_FRAME_INTERVAL_MS);
}
function scheduleNextSlide(
    intervalMs = DEFAULT_SLIDE_INTERVAL_MS,
    completedSlideIndex = null,
) {
    clearSlideTimer();
    slideTimerId = setTimeout(() => {
        if (Number.isInteger(completedSlideIndex)) {
            completeDisplayedSlide(completedSlideIndex);
            return;
        }
        showSlide();
    }, intervalMs);
}

function resetAutoScrollContent(content) {
    content.getAnimations?.().forEach((animation) => animation.cancel());
    content.classList.remove("is-scrolling");
    content.style.transform = "translateY(0)";
    content.style.removeProperty("--auto-scroll-distance");
    content.style.removeProperty("--auto-scroll-duration");
    content.style.removeProperty("--auto-scroll-delay");
}

function prepareAutoScroll(slide) {
    const viewport = slide.querySelector(".auto-scroll-viewport");
    if (!viewport) return DEFAULT_SLIDE_INTERVAL_MS;

    const content = viewport.querySelector(".auto-scroll-content");
    if (!content) return DEFAULT_SLIDE_INTERVAL_MS;

    resetAutoScrollContent(content);
    void content.offsetHeight;

    const distance = Math.max(0, content.scrollHeight - viewport.clientHeight);
    if (distance <= 4) return DEFAULT_SLIDE_INTERVAL_MS;

    const duration = Math.min(60, Math.max(20, distance / 8));
    const durationMs = duration * 1000;
    content.style.setProperty("--auto-scroll-distance", `-${distance}px`);
    content.style.setProperty("--auto-scroll-duration", `${duration}s`);
    content.style.setProperty("--auto-scroll-delay", `${SCROLL_START_DELAY_MS}ms`);

    if (typeof content.animate === "function") {
        content.animate(
            [
                { transform: "translateY(0)" },
                { transform: `translateY(-${distance}px)` },
            ],
            {
                delay: SCROLL_START_DELAY_MS,
                duration: durationMs,
                easing: "linear",
                fill: "forwards",
            },
        );
    } else {
        content.classList.add("is-scrolling");
    }

    const scrollCompleteInterval =
        SCROLL_START_DELAY_MS + durationMs + SCROLL_END_WAIT_MS;
    return Math.max(DEFAULT_SLIDE_INTERVAL_MS, scrollCompleteInterval);
}
/**
 * 1秒ごとに実行する：ページはリロードせず、データファイルだけを読み直す
 */
function loadEarthquakeDataThenUpdate(requestId) {
    if (requestId !== dataReloadRequestId) return;

    const oldEarthquakeScript = document.getElementById("earthquake-data-script");
    if (oldEarthquakeScript) oldEarthquakeScript.remove();

    const earthquakeScript = document.createElement("script");
    earthquakeScript.id = "earthquake-data-script";
    earthquakeScript.src = `temp/earthquake_data.js?v=${Date.now()}`;
    earthquakeScript.onload = () => finishDataReloadAndUpdate(requestId);
    earthquakeScript.onerror = () => {
        window.earthquakeData = undefined;
        finishDataReloadAndUpdate(requestId);
    };
    document.body.appendChild(earthquakeScript);
}

function loadSignageDataThenUpdate(requestId) {
    if (requestId !== dataReloadRequestId) return;

    const oldScript = document.getElementById("data-script");
    if (oldScript) oldScript.remove();

    const script = document.createElement("script");
    script.id = "data-script";
    script.src = `temp/news_data.js?v=${Date.now()}`;

    script.onload = () => loadEarthquakeDataThenUpdate(requestId);
    script.onerror = () => {
        window.signageData = undefined;
        loadEarthquakeDataThenUpdate(requestId);
    };

    document.body.appendChild(script);
}

function fetchNewData() {
    const now = Date.now();
    if (
        dataReloadInProgress &&
        now - dataReloadStartedAt < DATA_RELOAD_TIMEOUT_MS
    ) {
        return;
    }

    dataReloadInProgress = true;
    dataReloadStartedAt = now;
    const requestId = ++dataReloadRequestId;
    const oldStatusScript = document.getElementById("news-status-script");
    if (oldStatusScript) oldStatusScript.remove();

    const statusScript = document.createElement("script");
    statusScript.id = "news-status-script";
    statusScript.src = `temp/news_status.js?v=${Date.now()}`;
    statusScript.onload = () => loadSignageDataThenUpdate(requestId);
    statusScript.onerror = () => {
        window.signageFetchStatus = undefined;
        loadSignageDataThenUpdate(requestId);
    };
    document.body.appendChild(statusScript);
}

function updateSignageWithRetryLogging() {
    try {
        updateSignage();
    } catch (error) {
        hasRenderedActiveSignage = false;
        console.error("情報表示の更新に失敗しました。次回再試行します。", error);
    }
}

function finishDataReloadAndUpdate(requestId) {
    if (requestId !== dataReloadRequestId) return;

    try {
        updateSignageWithRetryLogging();
    } finally {
        dataReloadInProgress = false;
        dataReloadStartedAt = 0;
    }
}


