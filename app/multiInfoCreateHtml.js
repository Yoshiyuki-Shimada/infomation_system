/**
 * 津波情報のHTMLデータを生成
 * @returns 生成後のHTML
 */
function createTsunamiHtml() {
    return `
        <div class="slide bg-purple">
            <div class="slide-title">津波情報</div>
            <div class="slide-content" class="tsunami">
                国内で津波情報が発表されています。テレビやラジオの指示に従ってください。
            </div>
        </div>
    `;
}

/**
 * 地震情報のHTMLを生成
 * @param {*} q 地震データ
 * @returns 生成後のHTML
 */
function createEarthquakeHtml(q, scaleMap, bg) {
    return `
        <div class="slide ${bg}">
            <div class="slide-title">地震情報</div>
            <div class="slide-content">
                <div class="seismic_intensity">
                    <div class="seismic_intensity_ikuno">
                        生野区震度<br>
                        <span class="seismic_intensity_num">
                            ${scaleMap[q.ikunoScale] || "―"}
                        </span>
                    </div>
                    <div class="seismic_intensity_max">
                        最大震度<br>
                        <span class="seismic_intensity_num">
                            ${scaleMap[q.maxScale]}
                        </span>
                    </div>
                </div>
                ${q.time}頃、${q.hypocenter}で地震。
            </div>
        </div>
    `;
}

/**
 * 避難情報のHTMLの生成
 * @param {*} bg 避難レベル
 * @param {*} ev 避難メッセージ
 * @returns 生成後のHTML
 */
function createEvacuationHtml(bg, ev) {
    return `
        <div class="slide ${bg}">
            <div class="slide-title">避難情報 (大阪市生野区)</div>
            <div class="slide-content evacuation">
                ${ev.msg}
            </div>
        </div>
    `;
}

/**
 * 大阪市の気象警報・注意報HTMLを生成
 * @param {*} warningData
 * @returns 生成後のHTML一覧
 */
const WEATHER_WARNING_CARDS_PER_SLIDE = 10;

function createWeatherWarningSlidesHtml(warningData) {
    const warningNames = {
        "02": "暴風雪警報",
        "03": "大雨警報",
        "04": "氾濫警報",
        "05": "暴風警報",
        "06": "大雪警報",
        "07": "波浪警報",
        "08": "高潮警報",
        "09": "土砂災害警報",
        "10": "大雨注意報",
        "12": "大雪注意報",
        "13": "風雪注意報",
        "14": "雷注意報",
        "15": "強風注意報",
        "16": "波浪注意報",
        "17": "融雪注意報",
        "18": "氾濫注意報",
        "19": "高潮注意報",
        "20": "濃霧注意報",
        "21": "乾燥注意報",
        "22": "なだれ注意報",
        "23": "低温注意報",
        "24": "霜注意報",
        "25": "着氷注意報",
        "26": "着雪注意報",
        "27": "その他の注意報",
        "29": "土砂災害注意報",
        "32": "暴風雪特別警報",
        "33": "大雨特別警報",
        "34": "氾濫特別警報",
        "35": "暴風特別警報",
        "36": "大雪特別警報",
        "37": "波浪特別警報",
        "38": "高潮特別警報",
        "39": "土砂災害特別警報",
        "43": "大雨危険警報",
        "44": "氾濫危険警報",
        "48": "高潮危険警報",
        "49": "土砂災害危険警報",
    };

    const getWarningLevelInfo = (code) => {
        const number = Number(code);
        if (number >= 32 && number <= 39) {
            return { key: "special", number: 5, label: "特別警報" };
        }
        if (number >= 40) {
            return { key: "danger", number: 4, label: "危険警報" };
        }
        if (number >= 2 && number <= 9) {
            return { key: "warning", number: 3, label: "警報" };
        }
        return { key: "advisory", number: 2, label: "注意報" };
    };

    const getWarningBaseName = (name, levelInfo) => {
        const sourceName = String(name || "");
        const levelSuffix = new RegExp(`${levelInfo.label}$`);
        return sourceName.replace(levelSuffix, "");
    };

    const formatWarningReportDatetime = (value) => {
        if (!value) return "";

        const date = new Date(value);
        if (Number.isNaN(date.getTime())) return "";

        const year = date.getFullYear();
        const month = String(date.getMonth() + 1).padStart(2, "0");
        const day = String(date.getDate()).padStart(2, "0");
        const hour = String(date.getHours()).padStart(2, "0");
        const minute = String(date.getMinutes()).padStart(2, "0");
        return `${year}/${month}/${day} ${hour}:${minute}`;
    };

    const getWarningSortRank = (warning) => {
        const code = Number(warning.code || 0);
        if (String(warning.status || "").includes("解除")) return 4;
        if (code >= 32 && code <= 39) return 0;
        if (code >= 40) return 1;
        if (code >= 2 && code <= 9) return 2;
        return 3;
    };

    const createWarningCardHtml = (warning) => {
        const code = String(warning.code || "");
        const levelInfo = getWarningLevelInfo(code);
        const sourceName = warning.name || warningNames[code] || "気象情報";
        const warningName = getWarningBaseName(sourceName, levelInfo);
        const isReleased = String(warning.status || "").includes("解除");
        const title = isReleased
            ? `以下の【レベル${levelInfo.number}】${levelInfo.label}は解除`
            : `【レベル${levelInfo.number}】${levelInfo.label}`;
        const statusText = isReleased ? "解除" : (warning.status || "発表");
        const reportDatetime = formatWarningReportDatetime(
            warning.reportDatetime || warningData.reportDatetime,
        );
        const status = reportDatetime
            ? `${statusText}（${reportDatetime}）`
            : statusText;
        const cardClass = isReleased
            ? "weather-warning-released"
            : `weather-warning-${levelInfo.key}`;

        return `
            <div class="weather-warning-item ${cardClass}">
                <div class="weather-warning-level">${title}</div>
                <div class="weather-warning-name">${warningName}</div>
                <div class="weather-warning-status">${status}</div>
            </div>
        `;
    };

    // 重大度順に並べ、特別警報・危険警報を最初のページから確認できるようにする。
    const warnings = (
        Array.isArray(warningData?.warnings) ? warningData.warnings : []
    )
        .slice()
        .sort(
            (left, right) =>
                getWarningSortRank(left) - getWarningSortRank(right),
        );
    const pages = [];

    if (warnings.length === 0) {
        pages.push([]);
    } else {
        for (
            let index = 0;
            index < warnings.length;
            index += WEATHER_WARNING_CARDS_PER_SLIDE
        ) {
            pages.push(
                warnings.slice(
                    index,
                    index + WEATHER_WARNING_CARDS_PER_SLIDE,
                ),
            );
        }
    }

    return pages.map((pageWarnings, pageIndex) => {
        const warningCards = pageWarnings
            .map((warning) => createWarningCardHtml(warning))
            .join("");
        const content = warningCards || `
            <div class="weather-warning-empty">警報・注意報は発表されていません。</div>
        `;
        const pageLabel =
            pages.length > 1 ? `（${pageIndex + 1}/${pages.length}）` : "";

        return `
            <div class="slide weather-warning-slide">
                <div class="slide-title">気象警報・注意報（${warningData.areaName || "大阪市"}）${pageLabel}</div>
                <div class="slide-content">
                    <div class="weather-warning-list ${pageWarnings.length ? "" : "weather-warning-list-empty"}">
                        ${content}
                    </div>
                    <div class="weather-warning-source">気象庁発表</div>
                </div>
            </div>
        `;
    });
}

/** HTMLへ挿入する予定表示文字列をエスケープする。 */
function escapeCalendarHtml(value) {
    return String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
}

function getCalendarBusyText(slot, showMunicipality) {
    const count = Number(slot?.count || 0);
    if (count <= 0) return "";
    if (count >= 2) return `予定あり（${count}件）`;
    if (showMunicipality && slot.municipality) {
        return `予定あり（${escapeCalendarHtml(slot.municipality)}）`;
    }
    return "予定あり";
}

/** 本日と明日から7日間の予定スライドを生成する。 */
function createCalendarScheduleSlidesHtml(schedule) {
    const days = Array.isArray(schedule?.days) ? schedule.days : [];
    if (days.length === 0) return [];

    const today = days[0];
    const todayRows = (today.slots || [])
        .map((slot) => {
            const busyText = getCalendarBusyText(slot, true);
            return `
                <div class="calendar-today-row ${busyText ? "is-busy" : ""}">
                    <div class="calendar-time-label">${escapeCalendarHtml(slot.label)}</div>
                    <div class="calendar-busy-value">${busyText || "予定なし"}</div>
                </div>
            `;
        })
        .join("");
    const slides = [`
        <div class="slide calendar-schedule-slide">
            <div class="slide-title">本日の予定</div>
            <div class="slide-content calendar-today-list">${todayRows}</div>
        </div>
    `];

    const futureDays = days.slice(1, 8);
    for (let pageStart = 0; pageStart < futureDays.length; pageStart += 4) {
        const pageDays = futureDays.slice(pageStart, pageStart + 4);
        const labels = pageDays[0]?.slots?.map((slot) => slot.label) || [];
        const headerCells = pageDays
            .map(
                (day) =>
                    `<div class="calendar-week-date">${escapeCalendarHtml(day.label)}</div>`,
            )
            .join("");
        const rows = labels
            .map((label, slotIndex) => {
                const dayCells = pageDays
                    .map((day) => {
                        const text = getCalendarBusyText(
                            day.slots?.[slotIndex],
                            false,
                        );
                        return `<div class="calendar-week-value ${text ? "is-busy" : ""}">${text || "予定なし"}</div>`;
                    })
                    .join("");
                return `
                    <div class="calendar-week-row" style="--calendar-day-count: ${pageDays.length}">
                        <div class="calendar-week-time">${escapeCalendarHtml(label)}</div>
                        ${dayCells}
                    </div>
                `;
            })
            .join("");
        slides.push(`
            <div class="slide calendar-schedule-slide">
                <div class="slide-title">週間予定（明日から7日間）</div>
                <div class="slide-content calendar-week-list">
                    <div class="calendar-week-header" style="--calendar-day-count: ${pageDays.length}">
                        <div></div>${headerCells}
                    </div>
                    ${rows}
                </div>
            </div>
        `);
    }
    return slides;
}
/**
 * 運行情報の概要のHTMLを生成
 * @param {*} formattedSections 影響区間・
 * @param {*} causeStr 原因
 * @param {*} resumeStr 運転再開見込み
 * @returns 生成後のHTML
 */
function createRailwayDetailItemHtml(label, content) {
    if (!content) return "";

    return `
        <div class="railway-detail-item">
            <div class="railway-detail-label">${label}</div>
            <div class="railway-detail-content">
                ${content}
            </div>
        </div>
    `;
}

function createRailwayDetailListHtml(items, extraClass = "") {
    const detailItems = items
        .filter((item) => item && item.content)
        .map((item) => createRailwayDetailItemHtml(item.label, item.content))
        .join("");
    if (!detailItems) return "";

    const className = `railway-detail-list${extraClass ? ` ${extraClass}` : ""}`;
    return `<div class="${className}">${detailItems}</div>`;
}

function createRailwayInfoOverviewHtml(
    formattedSections,
    causeStr,
    resumeStr,
    showSections = true,
) {
    const detailItems = [];
    if (showSections && formattedSections) {
        detailItems.push({ label: "影響区間", content: formattedSections });
    }
    if (causeStr) {
        detailItems.push({ label: "原因", content: causeStr });
    }
    if (resumeStr) {
        detailItems.push({ label: "運転再開見込み", content: resumeStr });
    }

    return createRailwayDetailListHtml(detailItems);
}

function formatRailwayMainBodyHtml(chunk) {
    const source = String(chunk || "");
    const marker = "対象列車\n";
    const markerIndex = source.indexOf(marker);
    if (markerIndex < 0) {
        return source.replace(/\n/g, "<br>");
    }

    const bodyText = source.slice(0, markerIndex).trimEnd();
    const targetTrainText = source.slice(markerIndex + marker.length).trim();
    const bodyHtml = bodyText.replace(/\n/g, "<br>");
    const targetTrainHtml = createRailwayDetailListHtml(
        [
            {
                label: "対象列車",
                content: targetTrainText.replace(/\n/g, "<br>"),
            },
        ],
        "railway-main-detail-list",
    );

    if (!bodyHtml) return targetTrainHtml;
    if (!targetTrainHtml) return bodyHtml;
    return `${bodyHtml}<br><br>${targetTrainHtml}`;
}

/**
 * 運行情報のHTMLを生成
 * @param {*} r 運行情報の概要・タイトル
 * @param {*} chunk 表示する本文
 * @returns 生成後のHTML
 */
function createRailwayInfoBodyHtml(
    r,
    chunk,
    badgeBg,
    badgeText,
    fixedBottomHtml,
) {
    const railwayRouteKey = encodeURIComponent(getRailwayRouteKey(r));
    const lineSymbolHtml = getLineSymbolHtml(
        r.name,
        r.msg,
        r.lineCode || "",
        r.lineId || "",
    );
    const railwaySlideTitleHtml = `
        <div class="slide-title railway-slide-title">
            <span>列車運行情報</span>
            ${lineSymbolHtml ? `<span class="railway-title-symbols">${lineSymbolHtml}</span>` : ""}
        </div>
    `;
    const railwayHeaderHtml = `
        <div class="railway-badge" style="background:${badgeBg}; color:${badgeText};">
            <div class="line_name">
                ${lineSymbolHtml}${r.name}
            </div>
        </div>

        <div class="railway-main-title">
            ${r.title || "運行情報"}
        </div>
    `;

    if (r.lineCode == TRAIN_COMPANY.JR_WEST) {
        return `
            <div class="slide" data-slide-type="railway" data-railway-route-key="${railwayRouteKey}">
                ${railwaySlideTitleHtml}
                <div class="slide-content railway-fixed-layout">
                    <div class="railway-fixed-header">
                        ${railwayHeaderHtml}
                    </div>

                    <div class="auto-scroll-viewport railway-body-viewport">
                        <div class="auto-scroll-content railway-body-scroll">
                            <div class="railway-main-body">
                                ${formatRailwayMainBodyHtml(chunk)}
                            </div>
                        </div>
                    </div>

                    ${fixedBottomHtml}
                </div>
            </div>
        `;
    }

    return `
        <div class="slide" data-slide-type="railway" data-railway-route-key="${railwayRouteKey}">
            ${railwaySlideTitleHtml}
            <div class="slide-content auto-scroll-viewport">
                <div class="auto-scroll-content railway-scroll-content">
                    ${railwayHeaderHtml}

                    <div class="railway-main-body">
                        ${formatRailwayMainBodyHtml(chunk)}
                    </div>
                    ${fixedBottomHtml}
                </div>
            </div>
        </div>
    `;
}

/**
 * ニュースのHTMLを生成
 * @param {*} title ニュースのタイトル
 * @param {*} htmlText ニュースの本文
 * @returns 生成後のHTML
 */
function createNewsDataHtml(title, htmlText) {
    return `
        <div class="slide">
            <div class="slide-title">ニュース</div>
            <div class="slide-content news-fixed-layout">
                <div class="news-fixed-header">
                    <p><b class="news_title">${title}</b></p>
                </div>

                <div class="auto-scroll-viewport news-body-viewport">
                    <div class="auto-scroll-content news-body-scroll">
                        <div class="news_article">${htmlText}</div>
                    </div>
                </div>
            </div>
        </div>
    `;
}

/**
 * 3時間ごとの天気予報のHTMLを生成
 * @param {*} getGoogleWeatherIcon
 * @param {*} dateLabel
 * @param {*} hour
 * @param {*} code
 * @param {*} isDayTime
 * @param {*} wMap
 * @param {*} temp
 * @param {*} precipitationProbability
 * @returns 生成後のHMTL
 */
function createWeatherDataHtmlTime(
    getGoogleWeatherIcon,
    dateLabel,
    hour,
    code,
    isDayTime,
    wMap,
    temp,
    precipitationProbability,
) {
    const precipitationText =
        precipitationProbability == null
            ? "--"
            : `${Math.round(precipitationProbability)}%`;

    return `
        <div class="weather-item weather_time">
            <span class="weather_time_date">${dateLabel}</span>
            <span class="weather_time_hour">${String(hour).padStart(2, "0")}:00</span>
            <img src="${getGoogleWeatherIcon(code, isDayTime)}" class="weather_time_icon">
            <div><span class="weather_time_msg">${wMap[code] || "情報なし"}</span></div>
            <span class="weather_time_temperature">${temp}℃</span>
            <span class="weather_precipitation">降水 ${precipitationText}</span>
        </div>
    `;
}

function createWeatherTemperatureGraphHtml(forecastItems) {
    if (!forecastItems.length) return "";

    const temperatures = forecastItems.map((item) => item.temp);
    const minTemperature = Math.min(...temperatures);
    const maxTemperature = Math.max(...temperatures);
    const axisMinTemperature = minTemperature - 5;
    const axisMaxTemperature = maxTemperature + 5;
    const axisMiddleTemperature =
        (axisMinTemperature + axisMaxTemperature) / 2;
    const temperatureRange = Math.max(
        1,
        axisMaxTemperature - axisMinTemperature,
    );
    const columnWidth = 100;
    const graphHeight = 500;
    const topPadding = 48;
    const bottomPadding = 38;
    const usableHeight = graphHeight - topPadding - bottomPadding;
    const graphWidth = forecastItems.length * columnWidth;

    const points = forecastItems.map((item, index) => {
        const x = index * columnWidth + columnWidth / 2;
        const y =
            topPadding +
            ((axisMaxTemperature - item.temp) / temperatureRange) *
                usableHeight;
        return { x, y, temp: item.temp };
    });
    const lineSegments = points
        .slice(1)
        .map((point) => `L ${point.x} ${point.y}`)
        .join(" ");
    const linePath = `M ${points[0].x} ${points[0].y} ${lineSegments}`;
    const areaPath = [
        `M 0 ${points[0].y}`,
        `L ${points[0].x} ${points[0].y}`,
        lineSegments,
        `L ${graphWidth} ${points[points.length - 1].y}`,
        `L ${graphWidth} ${graphHeight}`,
        `L 0 ${graphHeight}`,
        "Z",
    ].join(" ");
    const verticalGrid = Array.from(
        { length: forecastItems.length + 1 },
        (_, index) =>
            `<line class="weather_graph_grid" x1="${index * columnWidth}" y1="0" x2="${index * columnWidth}" y2="${graphHeight}"></line>`,
    ).join("");
    const horizontalGrid = [topPadding, graphHeight / 2, graphHeight - bottomPadding]
        .map(
            (y) =>
                `<line class="weather_graph_grid" x1="0" y1="${y}" x2="${graphWidth}" y2="${y}"></line>`,
        )
        .join("");
    const axisLabels = [
        { temperature: axisMaxTemperature, y: topPadding },
        { temperature: axisMiddleTemperature, y: graphHeight / 2 },
        { temperature: axisMinTemperature, y: graphHeight - bottomPadding },
    ]
        .map(
            (label) =>
                `<text class="weather_graph_axis_label" x="7" y="${label.y - 4}">${Math.round(label.temperature)}℃</text>`,
        )
        .join("");
    const labels = points
        .map(
            (point) => `
                <circle cx="${point.x}" cy="${point.y}" r="5"></circle>
                <text x="${point.x}" y="${point.y - 10}" text-anchor="middle">${point.temp}℃</text>
            `,
        )
        .join("");

    return `
        <div class="weather_temperature_graph">
            <div class="weather_temperature_graph_label">気温推移</div>
            <svg viewBox="0 0 ${graphWidth} ${graphHeight}" preserveAspectRatio="none" role="img" aria-label="3時間ごとの気温グラフ。縦軸${axisMinTemperature}度から${axisMaxTemperature}度">
                ${verticalGrid}
                ${horizontalGrid}
                ${axisLabels}
                <path class="weather_temperature_area" d="${areaPath}"></path>
                <path class="weather_temperature_line" d="${linePath}"></path>
                ${labels}
            </svg>
        </div>
    `;
}

/**
 * 現在の天気のHTMLを生成
 * @param {*} getGoogleWeatherIcon
 * @param {*} w
 * @param {*} wMap
 * @param {*} currentCode
 * @param {*} isDayNow
 * @param {*} hourlyHtml
 * @param {*} temperatureGraphHtml
 * @param {*} currentPrecipitationProbability
 * @returns
 */
function createWeatherDataHtmlNow(
    getGoogleWeatherIcon,
    w,
    wMap,
    currentCode,
    isDayNow,
    hourlyHtml,
    temperatureGraphHtml,
    currentPrecipitationProbability,
) {
    const precipitationText =
        currentPrecipitationProbability == null
            ? "--"
            : `${Math.round(currentPrecipitationProbability)}%`;
    const todayDateKey = new Date().toLocaleDateString("sv-SE");
    const todayIndex = Array.isArray(w.daily?.time)
        ? Math.max(0, w.daily.time.indexOf(todayDateKey))
        : 0;
    const todayMaximumTemperature = Number(
        w.daily?.temperature_2m_max?.[todayIndex],
    );
    const todayMinimumTemperature = Number(
        w.daily?.temperature_2m_min?.[todayIndex],
    );
    const maximumTemperatureText = Number.isFinite(todayMaximumTemperature)
        ? `${Math.round(todayMaximumTemperature)}℃`
        : "--";
    const minimumTemperatureText = Number.isFinite(todayMinimumTemperature)
        ? `${Math.round(todayMinimumTemperature)}℃`
        : "--";
    const temperatureLabels = createTemperatureDayLabelsHtml(
        todayMaximumTemperature,
        todayMinimumTemperature,
        "now",
    );

    return `
        <div class="slide">
            <div class="slide-title">現在の天気（大阪市生野区）</div>
            <div class="slide-content">
                <div class="weather_now">
                    <img src="${getGoogleWeatherIcon(currentCode, isDayNow)}" class="weather_icon_now">
                    <div>
                        <span class="weather_temperature_now">
                            ${Math.round(w.current_weather.temperature)}℃
                        </span><br>
                        <span class="weather_name_now">${wMap[currentCode] || "情報なし"}</span>
                        <div class="weather_precipitation_now">降水確率 ${precipitationText}</div>
                        <div class="weather_temperature_range_now">
                            <span class="weather_temperature_max_now">最高 ${maximumTemperatureText}</span>
                            <span class="weather_temperature_min_now">最低 ${minimumTemperatureText}</span>
                        </div>
                        ${temperatureLabels}
                    </div>
                </div>
                <div class="weather_time_grid">今後の予報（3時間おき）</div>
                <div class="weather-grid weather_time_grid_list">
                    ${hourlyHtml}
                </div>
                ${temperatureGraphHtml}
            </div>
        </div>
    `;
}

// 気象庁の天気コードを、表示名とローカル画像へ一元的に対応付ける。
const jmaWeatherNames = {
    100: "晴れ",
    101: "晴れ時々曇り",
    102: "晴れ一時雨",
    103: "晴れ時々雨",
    104: "晴れ一時雪",
    105: "晴れ時々雪",
    110: "晴れ後時々曇り",
    111: "晴れ後曇り",
    112: "晴れ後一時雨",
    113: "晴れ後時々雨",
    114: "晴れ後雨",
    115: "晴れ後一時雪",
    116: "晴れ後時々雪",
    117: "晴れ後雪",
    200: "曇り",
    201: "曇り時々晴れ",
    202: "曇り一時雨",
    203: "曇り時々雨",
    204: "曇り一時雪",
    205: "曇り時々雪",
    210: "曇り後時々晴れ",
    211: "曇り後晴れ",
    212: "曇り後一時雨",
    213: "曇り後時々雨",
    214: "曇り後雨",
    215: "曇り後一時雪",
    216: "曇り後時々雪",
    217: "曇り後雪",
    300: "雨",
    301: "雨時々晴れ",
    302: "雨時々止む",
    303: "雨時々雪",
    304: "雨か雪",
    306: "大雨",
    307: "風雨が強い",
    308: "雨で暴風を伴う",
    309: "雨一時雪",
    311: "雨後晴れ",
    313: "雨後曇り",
    314: "雨後雪",
    315: "雨後時々雪",
    316: "雨か雪後晴れ",
    317: "雨か雪後曇り",
    328: "雨一時強く降る",
    329: "雨一時みぞれ",
    340: "雪か雨",
    350: "雨で雷を伴う",
    400: "雪",
    401: "雪時々晴れ",
    402: "雪時々止む",
    403: "雪時々雨",
    406: "風雪が強い",
    407: "暴風雪",
    409: "雪一時雨",
    411: "雪後晴れ",
    413: "雪後曇り",
    414: "雪後雨",
    415: "雪後時々雨",
    416: "雪か雨後晴れ",
    361: "雪か雨後晴れ",
    371: "雪か雨後曇り",
    405: "大雪",
};

const jmaWeatherIconNames = {
    100: "clear-day",
    101: "sunny-sometimes-cloudy",
    102: "sunny-sometimes-rain",
    103: "sunny-sometimes-rain",
    104: "sunny-sometimes-snow",
    105: "sunny-sometimes-snow",
    110: "sunny-then-cloudy",
    111: "sunny-then-cloudy",
    112: "sunny-then-rain",
    113: "sunny-then-rain",
    114: "sunny-then-rain",
    115: "sunny-then-snow",
    116: "sunny-then-snow",
    117: "sunny-then-snow",
    200: "cloudy",
    201: "cloudy-sometimes-sunny",
    202: "cloudy-sometimes-rain",
    203: "cloudy-sometimes-rain",
    204: "cloudy-sometimes-snow",
    205: "cloudy-sometimes-snow",
    210: "cloudy-then-sunny",
    211: "cloudy-then-sunny",
    212: "cloudy-then-rain",
    213: "cloudy-then-rain",
    214: "cloudy-then-rain",
    215: "cloudy-then-snow",
    216: "cloudy-then-snow",
    217: "cloudy-then-snow",
    300: "rain",
    301: "rain-sometimes-sunny",
    302: "rain-intermittent",
    303: "rain-sometimes-snow",
    304: "sleet",
    306: "heavy-rain",
    307: "wind-rain",
    308: "wind-rain",
    309: "rain-sometimes-snow",
    311: "rain-then-sunny",
    313: "rain-then-cloudy",
    314: "rain-then-snow",
    315: "rain-then-snow",
    316: "sleet",
    317: "sleet",
    328: "heavy-rain",
    329: "sleet",
    340: "sleet",
    350: "thunderstorm",
    400: "snow",
    401: "snow-sometimes-sunny",
    402: "snow-intermittent",
    403: "snow-sometimes-rain",
    406: "blowing-snow",
    407: "blowing-snow",
    409: "snow-sometimes-rain",
    411: "snow-then-sunny",
    413: "snow-then-cloudy",
    414: "snow-then-rain",
    415: "snow-then-rain",
    416: "sleet",
    361: "sleet",
    371: "sleet",
    405: "snow",
};

function normalizeJmaWeatherText(weatherText) {
    return String(weatherText ?? "").replace(/[\s　]+/g, "");
}

function getJmaRainIntensity(weatherText) {
    const normalizedText = normalizeJmaWeatherText(weatherText);

    if (/霧雨/.test(normalizedText)) return "drizzle";
    if (/小雨/.test(normalizedText)) return "light-rain";
    if (/大雨|激しい雨|非常に激しい雨|猛烈な雨|強く降る/.test(normalizedText)) {
        return "heavy-rain";
    }

    return "";
}

function getJmaWeatherIconName(code, weatherText) {
    const baseIconName = jmaWeatherIconNames[code];
    const rainIntensity = getJmaRainIntensity(weatherText);
    if (!rainIntensity) return baseIconName;

    const intensityIcons = {
        rain: rainIntensity,
        "heavy-rain": rainIntensity,
        "sunny-sometimes-rain": `sunny-sometimes-${rainIntensity}`,
        "sunny-then-rain": `sunny-then-${rainIntensity}`,
        "cloudy-sometimes-rain": `cloudy-sometimes-${rainIntensity}`,
        "cloudy-then-rain": `cloudy-then-${rainIntensity}`,
    };

    return intensityIcons[baseIconName] || baseIconName || rainIntensity;
}

function getJmaWeatherName(code, weatherText = "") {
    const detailedName = normalizeJmaWeatherText(weatherText);
    if (detailedName) return detailedName;
    if (jmaWeatherNames[code]) return jmaWeatherNames[code];
    if (code >= 100 && code < 200) return "晴れ";
    if (code >= 200 && code < 300) return "曇り";
    if (code >= 300 && code < 400) return "雨";
    if (code >= 400 && code < 500) return "雪";
    return "情報なし";
}

function getJmaWeatherIconPath(code, weatherText = "") {
    let iconName = getJmaWeatherIconName(code, weatherText);

    if (!iconName && code >= 100 && code < 200) iconName = "clear-day";
    if (!iconName && code >= 200 && code < 300) iconName = "cloudy";
    if (!iconName && code >= 300 && code < 400) iconName = "rain";
    if (!iconName && code >= 400 && code < 500) iconName = "snow";

    return `img/weather/${iconName || "unknown"}.png`;
}

/**
 * 気象庁APIによる明日の天気予報HTMLを生成する。
 * @param {*} forecast 気象庁の明日予報
 * @returns 生成後のHTML
 */
function createWeatherDataHtmlTomorrow(forecast) {
    const tomorrowCode = Number(forecast.weatherCode);
    const tomorrowPrecipitationProbability =
        forecast.precipitationProbability;
    const precipitationText =
        tomorrowPrecipitationProbability == null
            ? "--"
            : `${Math.round(tomorrowPrecipitationProbability)}%`;
    const maximumTemperature = Number(forecast.temperatureMax);
    const minimumTemperature = Number(forecast.temperatureMin);
    const tomorrowMaxTemperature = Number.isFinite(maximumTemperature)
        ? Math.round(maximumTemperature)
        : null;
    const tomorrowMinTemperature = Number.isFinite(minimumTemperature)
        ? Math.round(minimumTemperature)
        : null;
    const maximumTemperatureText =
        tomorrowMaxTemperature == null ? "--" : tomorrowMaxTemperature;
    const minimumTemperatureText =
        tomorrowMinTemperature == null ? "--" : tomorrowMinTemperature;
    const temperatureLabels = createTemperatureDayLabelsHtml(
        tomorrowMaxTemperature,
        tomorrowMinTemperature,
        "tomorrow",
    );

    return `
        <div class="slide">
            <div class="slide-title">明日の天気（大阪府・気象庁）</div>
            <div class="slide-content">
                <div class="weather_tomorrow">
                    <img src="${getJmaWeatherIconPath(tomorrowCode, forecast.weatherText)}" class="weather_icon_tomorrow">
                    <div class="weather_name_tomorrow">${getJmaWeatherName(tomorrowCode, forecast.weatherText)}</div>
                    <span class="weather_temperature_tomorrow">
                        <span class="weather_temperature_max_tomorrow">
                            ${maximumTemperatureText}℃
                        </span>
                        <span class="weather_slash_tomorrow">/</span>
                        <span class="weather_temperature_min_tomorrow">
                            ${minimumTemperatureText}℃
                        </span>
                    </span>
                    <span class="weather_precipitation_tomorrow">
                        降水確率 ${precipitationText}
                    </span>
                    ${temperatureLabels}
                </div>
            </div>
        </div>
    `;
}

function createTemperatureDayLabelsHtml(
    maximumTemperature,
    minimumTemperature,
    size = "weekly",
) {
    const labels = [];

    if (maximumTemperature >= 40) {
        labels.push({ text: "酷暑日", className: "extreme-hot" });
    } else if (maximumTemperature >= 35) {
        labels.push({ text: "猛暑日", className: "very-hot" });
    } else if (maximumTemperature >= 30) {
        labels.push({ text: "真夏日", className: "mid-summer" });
    } else if (maximumTemperature >= 25) {
        labels.push({ text: "夏日", className: "summer" });
    } else if (maximumTemperature < 0) {
        labels.push({ text: "真冬日", className: "ice-day" });
    }

    if (minimumTemperature >= 30) {
        labels.push({ text: "超熱帯夜", className: "extreme-tropical-night" });
    } else if (minimumTemperature >= 25) {
        labels.push({ text: "熱帯夜", className: "tropical-night" });
    } else if (minimumTemperature < 0) {
        labels.push({ text: "冬日", className: "winter-day" });
    }

    if (!labels.length) return "";

    return `
        <div class="temperature-day-labels temperature-day-labels-${size}">
            ${labels
                .map(
                    (label) =>
                        `<span class="temperature-day-label temperature-day-${label.className}">${label.text}</span>`,
                )
                .join("")}
        </div>
    `;
}

/**
 * 気象庁の週間天気予報HTMLを生成
 * @param {*} weeklyWeather
 * @returns 生成後のHTML
 */
function createWeeklyWeatherHtml(weeklyWeather) {
    const weekdays = ["日", "月", "火", "水", "木", "金", "土"];

    const items = weeklyWeather.days
        .map((forecast) => {
            const date = new Date(`${forecast.date}T00:00:00`);
            const code = Number(forecast.weatherCode);
            const monthDayText = `${String(date.getMonth() + 1).padStart(2, "0")}/${String(date.getDate()).padStart(2, "0")}`;
            const weekdayText = `（${weekdays[date.getDay()]}）`;
            const weatherName = getJmaWeatherName(code, forecast.weatherText);
            const maxTemperature =
                forecast.temperatureMax == null
                    ? "--"
                    : Math.round(forecast.temperatureMax);
            const minTemperature =
                forecast.temperatureMin == null
                    ? "--"
                    : Math.round(forecast.temperatureMin);
            const precipitationProbability =
                forecast.precipitationProbability == null
                    ? "--"
                    : `${Math.round(forecast.precipitationProbability)}%`;
            const temperatureLabels = createTemperatureDayLabelsHtml(
                maxTemperature,
                minTemperature,
                "weekly",
            );

            return `
                <div class="weather_weekly_item">
                    <div class="weather_weekly_date">
                        <span class="weather_weekly_month_day">${monthDayText}</span>
                        <span class="weather_weekly_weekday">${weekdayText}</span>
                    </div>
                    <img
                        src="${getJmaWeatherIconPath(code, forecast.weatherText)}"
                        class="weather_weekly_icon"
                        alt="${weatherName}"
                    >
                    <div class="weather_weekly_name">${weatherName}</div>
                    <div class="weather_weekly_temperature">
                        <span class="weather_weekly_max">${maxTemperature}℃</span>
                        <span class="weather_weekly_slash">/</span>
                        <span class="weather_weekly_min">${minTemperature}℃</span>
                    </div>
                    <div class="weather_weekly_precipitation">
                        降水確率 ${precipitationProbability}
                    </div>
                    ${temperatureLabels}
                </div>
            `;
        })
        .join("");

    return `
        <div class="slide">
            <div class="slide-title">週間天気予報（大阪府・気象庁）</div>
            <div class="slide-content">
                <div class="weather_weekly_grid">
                    ${items}
                </div>
            </div>
        </div>
    `;
}

function escapeDisasterHtml(value) {
    return String(value ?? "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
}

function formatDisasterTime(value) {
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return escapeDisasterHtml(value);
    return `${date.getMonth() + 1}月${date.getDate()}日${date.getHours()}時${String(date.getMinutes()).padStart(2, "0")}分`;
}

function formatEewIssueTime(value) {
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return escapeDisasterHtml(value);

    const dateText = `${date.getMonth() + 1}月${date.getDate()}日`;
    const timeText = `${date.getHours()}時${String(date.getMinutes()).padStart(2, "0")}分`;
    return `${dateText}<br>${timeText}`;
}

function formatDisasterTimeShort(value) {
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return escapeDisasterHtml(value);
    return `${date.getMonth() + 1}/${date.getDate()} ${date.getHours()}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function createDisasterMapHtml(data, altText) {
    const fallbackImage = "earthquake/Map/Resources/Maps/japan-gsi_2048-8bit.png";
    const imageSource = data?.mapImage || fallbackImage;
    const loadingClass = data?.mapImage ? "" : " disaster-map-loading";
    return `
        <div class="disaster-map-panel${loadingClass}">
            <img class="disaster-map-image" src="${escapeDisasterHtml(imageSource)}" alt="${escapeDisasterHtml(altText)}">
            ${data?.mapImage ? "" : '<div class="disaster-map-status">地図を生成しています</div>'}
        </div>
    `;
}

function createEewHtml(eew) {
    if (!eew) return "";
    const areaItems = (eew.areas || [])
        .map(
            (area) => `
                <div class="eew-area-item">
                    <span>${escapeDisasterHtml(area.pref || area.name)}</span>
                </div>
            `,
        )
        .join("");
    const title = eew.cancelled
        ? "緊急地震速報 取り消し"
        : eew.isFollowUp
          ? "緊急地震速報 続報"
          : "緊急地震速報";

    return `
        <div class="slide eew-slide">
            <div class="slide-title">${title}</div>
            <div class="slide-content disaster-content-grid eew-content">
                <div class="disaster-detail-panel">
                    <div class="eew-main-title">${eew.cancelled ? "先ほどの緊急地震速報は取り消されました" : "強い揺れに警戒"}</div>
                    <div class="eew-detail-grid">
                        <div><span>震源</span><strong>${escapeDisasterHtml(eew.hypocenter || "調査中")}</strong></div>
                        <div><span>発表</span><strong>${formatEewIssueTime(eew.issueTime)}</strong></div>
                        <div><span>規模</span><strong>${eew.magnitude ? `M${escapeDisasterHtml(eew.magnitude)}` : "調査中"}</strong></div>
                        <div><span>深さ</span><strong>${eew.depth ? `${escapeDisasterHtml(eew.depth)}km` : "調査中"}</strong></div>
                    </div>
                    <div class="eew-area-list">${areaItems}</div>
                </div>
                ${createDisasterMapHtml(eew, "緊急地震速報の対象地域地図")}
            </div>
        </div>
    `;
}

function createTsunamiHtml(tsunamiData = null) {
    const areas = tsunamiData?.areas || [];
    const areaItems = areas
        .map(
            (area) => `
                <div class="tsunami-area-item">
                    <div class="tsunami-area-name">${escapeDisasterHtml(area.name)}</div>
                    <div class="tsunami-area-grade">${escapeDisasterHtml(area.grade || "津波情報")}</div>
                    <div class="tsunami-area-meta">高さ ${escapeDisasterHtml(area.maxHeight || "不明")}　到達 ${escapeDisasterHtml(area.firstHeight || "調査中")}</div>
                </div>
            `,
        )
        .join("");

    return `
        <div class="slide tsunami-slide">
            <div class="slide-title">津波情報発表中</div>
            <div class="slide-content disaster-content-grid tsunami-detail">
                <div class="disaster-detail-panel">
                    <div class="tsunami-lead">海岸や川の河口付近から離れてください</div>
                    <div class="tsunami-detail-list">
                        ${areaItems || "<div class=\"tsunami-area-item\">津波情報が発表されています。テレビやラジオの情報に注意してください。</div>"}
                    </div>
                </div>
                ${createDisasterMapHtml(tsunamiData, "津波情報の対象沿岸地図")}
            </div>
        </div>
    `;
}

function getEarthquakeScaleGroups(q) {
    if (Array.isArray(q?.scaleGroups) && q.scaleGroups.length) {
        return q.scaleGroups;
    }

    const scaleOrder = [70, 60, 55, 50, 45, 40, 30];
    const byScale = new Map();
    (q?.points || []).forEach((point) => {
        const scale = Number(point.scale || 0);
        if (scale < 30) return;
        if (!byScale.has(scale)) byScale.set(scale, new Map());
        const prefMap = byScale.get(scale);
        const pref = point.pref || "その他";
        if (!prefMap.has(pref)) prefMap.set(pref, []);
        prefMap.get(pref).push(point.addr || "");
    });

    return scaleOrder
        .filter((scale) => byScale.has(scale))
        .map((scale) => ({
            scale,
            scaleText: convertScaleTextForDisplay(scale),
            prefs: Array.from(byScale.get(scale).entries()).map(([pref, addrs]) => ({
                pref,
                addrs,
            })),
        }));
}

function convertScaleTextForDisplay(scale) {
    const map = {
        70: "7",
        60: "6強",
        55: "6弱",
        50: "5強",
        45: "5弱",
        40: "4",
        30: "3",
    };
    return map[scale] || String(scale || "-");
}

function createEarthquakeIntensityGroupsHtml(q) {
    const groups = getEarthquakeScaleGroups(q);
    if (!groups.length) return "";

    return groups
        .map((group) => {
            const prefLines = (group.prefs || [])
                .map((prefGroup) => {
                    const addresses = (prefGroup.addrs || [])
                        .filter(Boolean)
                        .map((addr) => escapeDisasterHtml(addr))
                        .join("、");
                    return `<div class="quake-pref-line"><span>${escapeDisasterHtml(prefGroup.pref)}：</span>${addresses}</div>`;
                })
                .join("");
            return `
                <section class="quake-scale-group">
                    <div class="quake-scale-heading">震度${escapeDisasterHtml(group.scaleText)}</div>
                    <div class="quake-pref-list">${prefLines}</div>
                </section>
            `;
        })
        .join("");
}

function createEarthquakeHtml(q) {
    if (!q) return "";
    const bgClass = q.maxScale >= 60 ? "bg-red" : q.maxScale >= 45 ? "bg-yellow" : "bg-cyan";
    const informationType = q.informationType || "Detail";
    const isScalePrompt = informationType === "ScalePrompt";
    const isHypocenterReport = informationType === "Destination";
    const hasIntensityDetails = ["ScalePrompt", "ScaleAndDestination", "Detail"].includes(informationType);
    const intensityGroupsHtml = createEarthquakeIntensityGroupsHtml(q);
    const occurredAt = formatDisasterTime(q.time);
    let summaryHtml = `${occurredAt}頃、地震がありました。<br>最大震度は${escapeDisasterHtml(q.maxScaleText || "-")}です。`;
    if (isHypocenterReport) {
        summaryHtml = `${occurredAt}頃、${escapeDisasterHtml(q.hypocenter || "不明")}を震源とする地震がありました。`;
    } else if (!isScalePrompt) {
        summaryHtml = `${occurredAt}頃、${escapeDisasterHtml(q.hypocenter || "不明")}で地震がありました。<br>最大震度は${escapeDisasterHtml(q.maxScaleText || "-")}です。`;
    }
    const hypocenterDetailHtml = isScalePrompt
        ? ""
        : `<div class="quake-summary-sub">M${escapeDisasterHtml(q.magnitude || "-")}　震源地 ${escapeDisasterHtml(q.hypocenter || "不明")}　深さ ${escapeDisasterHtml(q.depth || "-")}km　津波 ${escapeDisasterHtml(q.tsunami || "-")}</div>`;
    const intensityListHtml = hasIntensityDetails && intensityGroupsHtml
        ? `<div class="auto-scroll-viewport earthquake-points-viewport"><div class="auto-scroll-content earthquake-points-scroll"><div class="earthquake-intensity-groups">${intensityGroupsHtml}</div></div></div>`
        : "";
    const ikunoHtml = ["ScaleAndDestination", "Detail"].includes(informationType)
        ? `<div class="ikuno-intensity"><span>大阪市生野区</span><strong>${q.ikunoScale >= 30 ? `震度${escapeDisasterHtml(q.ikunoScaleText)}` : "震度情報なし"}</strong></div>`
        : "";

    return `
        <div class="slide earthquake-slide ${bgClass}">
            <div class="slide-title">${escapeDisasterHtml(q.informationTitle || "地震情報")}</div>
            <div class="slide-content disaster-content-grid earthquake-detail earthquake-fixed-layout">
                <div class="disaster-detail-panel">
                    <div class="quake-summary-main">${summaryHtml}</div>
                    ${hypocenterDetailHtml}
                    ${intensityListHtml}
                </div>
                <div class="earthquake-map-column">
                    ${createDisasterMapHtml(q, "震源と震度分布の地図")}
                    ${ikunoHtml}
                </div>
            </div>
        </div>
    `;
}
function createRailwayDisasterTickerItems(railwayItems = []) {
    return railwayItems
        .map((r) => {
            const name = escapeDisasterHtml(r.name || "路線");
            const msg = String(r.msg || r.body || r.title || "").replace(/<[^>]*>/g, " ");
            if (r.lineCode == TRAIN_COMPANY.JR_WEST) {
                const cause =
                    (msg.match(/(?:原因|事由|理由)[：:】\s]*([^【\n]+)/) || [])[1]?.trim() ||
                    r.title ||
                    "運行情報";
                const section =
                    (msg.match(/(?:影響区間|区間)[：:】\s]*([^【\n]+)/) || [])[1]?.trim() ||
                    "";
                const status = r.title || "運行情報あり";
                return `【${escapeDisasterHtml(cause)}】${name}　${escapeDisasterHtml(section)}　${escapeDisasterHtml(status)}`;
            }
            return `【運行情報あり】${name}`;
        })
        .filter(Boolean);
}

function createRailwayDisasterTickerHtml(railwayItems = []) {
    const items = createRailwayDisasterTickerItems(railwayItems);
    if (!items.length) return "";
    const tickerText = items.join("　　　");
    return `
        <div class="disaster-ticker">
            <div class="disaster-ticker-label">鉄道運行情報</div>
            <div class="disaster-ticker-viewport">
                <div class="disaster-ticker-track">${escapeDisasterHtml(tickerText)}</div>
            </div>
        </div>
    `;
}

function createDisasterPriorityHtml(emergencyData, railwayItems = [], kind = "") {
    if (!emergencyData) return "";
    let mainHtml = "";
    if (kind === "eew" && emergencyData.eew) {
        mainHtml = createEewHtml(emergencyData.eew).replace('<div class="slide eew-slide">', '<div class="disaster-main-inner eew-slide">').replace('</div>\n    ', '</div>\n    ');
    } else if (kind === "tsunami" && emergencyData.tsunami?.active) {
        mainHtml = createTsunamiHtml(emergencyData.tsunami).replace('<div class="slide tsunami-slide">', '<div class="disaster-main-inner tsunami-slide">');
    } else if (kind === "earthquake" && emergencyData.earthquake) {
        mainHtml = createEarthquakeHtml(emergencyData.earthquake).replace('<div class="slide earthquake-slide ', '<div class="disaster-main-inner earthquake-slide ');
    } else if (emergencyData.eew) {
        mainHtml = createEewHtml(emergencyData.eew).replace('<div class="slide eew-slide">', '<div class="disaster-main-inner eew-slide">').replace('</div>\n    ', '</div>\n    ');
    } else if (emergencyData.tsunami?.active) {
        mainHtml = createTsunamiHtml(emergencyData.tsunami).replace('<div class="slide tsunami-slide">', '<div class="disaster-main-inner tsunami-slide">');
    } else if (emergencyData.earthquake) {
        mainHtml = createEarthquakeHtml(emergencyData.earthquake).replace('<div class="slide earthquake-slide ', '<div class="disaster-main-inner earthquake-slide ');
    }

    return `
        <div class="slide disaster-priority-slide">
            <div class="disaster-main-area">
                ${mainHtml}
            </div>
        </div>
    `;
}

function createEarthquakeBottomBannerHtml(emergencyData) {
    const emergencyQuake = emergencyData?.emergencyEarthquake || emergencyData?.earthquake;
    if (!emergencyQuake) return "";

    const recentQuake = emergencyData?.recentScale3Earthquake;
    const isEmergencyMode = !!emergencyData?.emergencyMode?.active;
    const label = isEmergencyMode ? "緊急情報" : "地震情報";
    const emergencyContext = `${escapeDisasterHtml(emergencyQuake.hypocenter || "不明")}で震度${escapeDisasterHtml(emergencyQuake.maxScaleText || "-")}`;

    const createRegionFrames = (q, minScale, topLine, mode) => {
        const groups = getEarthquakeScaleGroups(q).filter((group) => Number(group.scale || 0) >= minScale);
        const frames = [];
        groups.forEach((group) => {
            (group.prefs || []).forEach((prefGroup) => {
                const addrs = (prefGroup.addrs || []).filter(Boolean);
                for (let i = 0; i < addrs.length; i += 5) {
                    const addrText = addrs
                        .slice(i, i + 5)
                        .map((addr) => escapeDisasterHtml(addr))
                        .join("、");
                    if (!addrText) continue;
                    const scalePrefix = mode === "a"
                        ? `【震度${escapeDisasterHtml(group.scaleText)}】`
                        : `震度${escapeDisasterHtml(group.scaleText)}：`;
                    frames.push({
                        mode,
                        top: topLine,
                        bottom: `${scalePrefix}${escapeDisasterHtml(prefGroup.pref || "その他")}：${addrText}`,
                    });
                }
            });
        });
        if (!frames.length) frames.push({ mode, top: topLine, bottom: "" });
        return frames;
    };

    const aTop = `${formatDisasterTimeShort(emergencyQuake.time)}頃 ${escapeDisasterHtml(emergencyQuake.hypocenter || "不明")}で震度${escapeDisasterHtml(emergencyQuake.maxScaleText || "-")}の地震`;
    const aFrames = createRegionFrames(emergencyQuake, 45, aTop, "a");

    const shouldCreateB = recentQuake && recentQuake.id !== emergencyQuake.id && Number(recentQuake.maxScale || 0) >= 30;
    const bTop = shouldCreateB
        ? `【${emergencyContext}】${formatDisasterTimeShort(recentQuake.time)}頃 ${escapeDisasterHtml(recentQuake.hypocenter || "不明")}で地震がありました。最大震度は${escapeDisasterHtml(recentQuake.maxScaleText || "-")}です。`
        : "";
    const bFrames = shouldCreateB ? createRegionFrames(recentQuake, 30, bTop, "b") : [];
    const frames = [...aFrames, ...bFrames];
    const frameHtml = frames
        .map((frame, index) => `
            <div class="emergency-info-frame emergency-info-frame-${frame.mode} ${index === 0 ? "is-active" : ""}" data-mode="${frame.mode}">
                <div class="emergency-info-line emergency-info-line-top">${frame.top}</div>
                <div class="emergency-info-line emergency-info-line-bottom">${frame.bottom}</div>
            </div>
        `)
        .join("");

    return `
        <div class="earthquake-bottom-banner emergency-info-banner ${isEmergencyMode ? "is-emergency-mode" : ""}" data-recent-id="${escapeDisasterHtml(recentQuake?.id || "")}" data-recent-time="${escapeDisasterHtml(recentQuake?.time || "")}">
            <div class="emergency-info-label">${label}</div>
            <div class="emergency-info-frame-viewport" aria-live="polite">
                ${frameHtml}
            </div>
        </div>
    `;
}
