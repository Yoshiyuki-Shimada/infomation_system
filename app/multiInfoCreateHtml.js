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
 * @returns 生成後のHTML
 */
function createWeatherWarningHtml(warningData) {
    const warningNames = {
        "02": "暴風雪警報",
        "03": "大雨警報",
        "04": "洪水警報",
        "05": "暴風警報",
        "06": "大雪警報",
        "07": "波浪警報",
        "08": "高潮警報",
        10: "大雨注意報",
        12: "大雪注意報",
        13: "風雪注意報",
        14: "雷注意報",
        15: "強風注意報",
        16: "波浪注意報",
        17: "融雪注意報",
        18: "洪水注意報",
        19: "高潮注意報",
        20: "濃霧注意報",
        21: "乾燥注意報",
        22: "なだれ注意報",
        23: "低温注意報",
        24: "霜注意報",
        25: "着氷注意報",
        26: "着雪注意報",
        32: "暴風雪特別警報",
        33: "大雨特別警報",
        35: "暴風特別警報",
        36: "大雪特別警報",
        37: "波浪特別警報",
        38: "高潮特別警報",
    };
    Object.assign(warningNames, {
        "02": "暴風雪警報", "03": "大雨警報", "04": "氾濫警報",
        "05": "暴風警報", "06": "大雪警報", "07": "波浪警報",
        "08": "高潮警報", "09": "土砂災害警報",
        "10": "大雨注意報", "12": "大雪注意報", "13": "風雪注意報",
        "14": "雷注意報", "15": "強風注意報", "16": "波浪注意報",
        "17": "融雪注意報", "18": "氾濫注意報", "19": "高潮注意報",
        "20": "濃霧注意報", "21": "乾燥注意報", "22": "なだれ注意報",
        "23": "低温注意報", "24": "霜注意報", "25": "着氷注意報",
        "26": "着雪注意報", "27": "その他の注意報",
        "29": "土砂災害注意報",
        "32": "暴風雪特別警報", "33": "大雨特別警報",
        "34": "氾濫特別警報", "35": "暴風特別警報",
        "36": "大雪特別警報", "37": "波浪特別警報",
        "38": "高潮特別警報", "39": "土砂災害特別警報",
        "43": "大雨危険警報", "44": "氾濫危険警報",
        "48": "高潮危険警報", "49": "土砂災害危険警報",
    });
    const getWarningLevel = (code) => {
        const number = Number(code);
        if (number >= 32 && number <= 39) return "special";
        if (number >= 40) return "danger";
        if (number >= 2 && number <= 9) return "warning";
        return "advisory";
    };
    const warningItems = warningData.warnings
        .map((warning) => {
            const code = String(warning.code).padStart(2, "0");
            const level = getWarningLevel(code);
            const name = warningNames[code] || `気象情報（${code}）`;

            return `
                <div class="weather-warning-item weather-warning-${level}">
                    <div class="weather-warning-name">${name}</div>
                    <div class="weather-warning-status">${warning.status || "発表中"}</div>
                </div>
            `;
        })
        .join("");
    const reportDate = warningData.reportDatetime
        ? new Date(warningData.reportDatetime)
        : null;
    const reportTime =
        reportDate && !Number.isNaN(reportDate.getTime())
            ? `${String(reportDate.getHours()).padStart(2, "0")}:${String(reportDate.getMinutes()).padStart(2, "0")}発表`
            : "";

    return `
        <div class="slide weather-warning-slide">
            <div class="slide-title">気象警報・注意報（大阪市）</div>
            <div class="slide-content">
                <div class="weather-warning-report-time">${reportTime}</div>
                <div class="weather-warning-list">
                    ${warningItems}
                </div>
                <div class="weather-warning-source">気象庁発表</div>
            </div>
        </div>
    `;
}

/**
 * 運行情報の概要のHTMLを生成
 * @param {*} formattedSections 影響区間・
 * @param {*} causeStr 原因
 * @param {*} resumeStr 運転再開見込み
 * @returns 生成後のHTML
 */
function createRailwayInfoOverviewHtml(formattedSections, causeStr, resumeStr) {
    return `
        <div class="railway-detail-list">
            <div class="railway-detail-item">
                <div class="railway-detail-label">影響区間</div>
                <div class="railway-detail-content">
                    ${formattedSections}
                </div>
            </div>
            ${causeStr ? causeStrHtml(causeStr) : ""}
            ${resumeStr ? resumeStrHtml(resumeStr) : ""}
        </div>`;
}

/**
 * 原因表示のHTMLを生成
 * @param {*} causeStr 原因
 * @returns 生成後のHTML
 */
function causeStrHtml(causeStr) {
    return `
        <div class="railway-detail-item">
            <div class="railway-detail-label">原因</div>
            <div class="railway-detail-content">
                ${causeStr}
            </div>
        </div>
    `;
}

/**
 * 運転再開見込みのHTMLを生成
 * @param {*} resumeStr 運転再開見込み
 * @returns 生成後のHTML
 */
function resumeStrHtml(resumeStr) {
    return `
        <div class="railway-detail-item">
            <div class="railway-detail-label">運転再開見込み</div>
            <div class="railway-detail-content">
                ${resumeStr}
            </div>
        </div>
    `;
}

/**
 * JR西日本・近畿エリアの現在の運行状況路線図スライドを生成
 * @param {*} routeMapUrl 路線図画像URL
 * @returns 生成後のHTML
 */
function createJRWestRouteMapSlideHtml(routeMapUrl) {
    return `
        <div class="slide jr-west-route-map-slide">
            <div class="slide-title">JR線の現在の運行情報</div>
            <div class="slide-content">
                <figure class="jr-west-route-map">
                    <figcaption>近畿エリア路線図</figcaption>
                    <img
                        src="${routeMapUrl}"
                        alt="JR西日本 近畿エリアの現在の運行情報路線図"
                        class="jr-west-route-map-image"
                    >
                </figure>
            </div>
        </div>
    `;
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
    const railwayHeaderHtml = `
        <div class="railway-badge" style="background:${badgeBg}; color:${badgeText};">
            <div class="line_name">
                ${getLineSymbolHtml(r.name, r.msg, r.lineCode || "")}${r.name}
            </div>
        </div>

        <div class="railway-main-title">
            ${r.title || "運行情報"}
        </div>
    `;

    if (r.lineCode == TRAIN_COMPANY.JR_WEST) {
        return `
            <div class="slide">
                <div class="slide-title">列車運行情報</div>
                <div class="slide-content railway-fixed-layout">
                    <div class="railway-fixed-header">
                        ${railwayHeaderHtml}
                    </div>

                    <div class="auto-scroll-viewport railway-body-viewport">
                        <div class="auto-scroll-content railway-body-scroll">
                            <div class="railway-main-body">
                                ${chunk.replace(/\n/g, "<br>")}
                            </div>
                        </div>
                    </div>

                    ${fixedBottomHtml}
                </div>
            </div>
        `;
    }

    return `
        <div class="slide">
            <div class="slide-title">列車運行情報</div>
            <div class="slide-content auto-scroll-viewport">
                <div class="auto-scroll-content railway-scroll-content">
                    ${railwayHeaderHtml}

                    <div class="railway-main-body">
                        ${chunk.replace(/\n/g, "<br>")}
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

/**
 * 明日の天気予報のHTMLを生成
 * @param {*} getGoogleWeatherIcon
 * @param {*} tomorrowCode
 * @param {*} wMap
 * @param {*} w
 * @returns 生成後のHTML
 */
function createWeatherDataHtmlTomorrow(
    getGoogleWeatherIcon,
    tomorrowCode,
    wMap,
    w,
) {
    const tomorrowPrecipitationProbability =
        w.daily.precipitation_probability_max?.[1];
    const precipitationText =
        tomorrowPrecipitationProbability == null
            ? "--"
            : `${Math.round(tomorrowPrecipitationProbability)}%`;
    const tomorrowMaxTemperature = Math.round(
        w.daily.temperature_2m_max[1],
    );
    const tomorrowMinTemperature = Math.round(
        w.daily.temperature_2m_min[1],
    );
    const temperatureLabels = createTemperatureDayLabelsHtml(
        tomorrowMaxTemperature,
        tomorrowMinTemperature,
        "tomorrow",
    );

    return `
        <div class="slide">
            <div class="slide-title">明日の天気</div>
            <div class="slide-content">
                <div class="weather_tomorrow">
                    <img src="${getGoogleWeatherIcon(tomorrowCode, 1)}" class="weather_icon_tomorrow"><br>
                    <span class="weather_name_tomorrow">${wMap[tomorrowCode] || "情報なし"}</span><br>
                    <span class="weather_temperature_tomorrow">
                        <span class="weather_temperature_max_tomorrow">
                            ${tomorrowMaxTemperature}℃
                        </span>
                        <span class="weather_slash_tomorrow">/</span>
                        <span class="weather_temperature_min_tomorrow">
                            ${tomorrowMinTemperature}℃
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
    const weatherNames = {
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
        308: "雨で暴風を伴う",
        311: "雨後晴れ",
        313: "雨後曇り",
        314: "雨後雪",
        400: "雪",
        401: "雪時々晴れ",
        402: "雪時々止む",
        403: "雪時々雨",
        406: "風雪が強い",
        411: "雪後晴れ",
        413: "雪後曇り",
        414: "雪後雨",
    };
    const getFallbackWeatherName = (code) => {
        if (code >= 100 && code < 200) return "晴れ";
        if (code >= 200 && code < 300) return "曇り";
        if (code >= 300 && code < 400) return "雨";
        if (code >= 400 && code < 500) return "雪";
        return "情報なし";
    };

    const items = weeklyWeather.days
        .map((forecast) => {
            const date = new Date(`${forecast.date}T00:00:00`);
            const code = Number(forecast.weatherCode);
            const dateText = `${date.getMonth() + 1}/${date.getDate()}（${weekdays[date.getDay()]}）`;
            const weatherName =
                weatherNames[code] || getFallbackWeatherName(code);
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
                    <div class="weather_weekly_date">${dateText}</div>
                    <img
                        src="https://www.jma.go.jp/bosai/forecast/img/${forecast.weatherCode}.svg"
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

function formatDisasterTimeShort(value) {
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return escapeDisasterHtml(value);
    return `${date.getMonth() + 1}/${date.getDate()} ${date.getHours()}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function createEewHtml(eew) {
    if (!eew) return "";
    const areaItems = (eew.areas || [])
        .slice(0, 12)
        .map(
            (area) => `
                <div class="eew-area-item">
                    <span>${escapeDisasterHtml(area.pref || area.name)}</span>
                    <strong>震度${escapeDisasterHtml(area.scaleText || "-")}</strong>
                </div>
            `,
        )
        .join("");
    const title = eew.cancelled
        ? "緊急地震速報 取り消し"
        : `緊急地震速報 第${escapeDisasterHtml(eew.serial || 1)}報`;

    return `
        <div class="slide eew-slide">
            <div class="slide-title">${title}</div>
            <div class="slide-content eew-content">
                <div class="eew-main-title">${eew.cancelled ? "先ほどの緊急地震速報は取り消されました" : "強い揺れに警戒"}</div>
                <div class="eew-detail-grid">
                    <div><span>震源</span><strong>${escapeDisasterHtml(eew.hypocenter || "調査中")}</strong></div>
                    <div><span>発表</span><strong>${formatDisasterTime(eew.issueTime)}</strong></div>
                    <div><span>規模</span><strong>M${escapeDisasterHtml(eew.magnitude || "-")}</strong></div>
                    <div><span>深さ</span><strong>${escapeDisasterHtml(eew.depth || "-")}km</strong></div>
                </div>
                <div class="eew-area-list">${areaItems}</div>
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
            <div class="slide-content tsunami-detail">
                <div class="tsunami-lead">海岸や川の河口付近から離れてください</div>
                <div class="tsunami-detail-list">
                    ${areaItems || "<div class=\"tsunami-area-item\">津波情報が発表されています。テレビやラジオの情報に注意してください。</div>"}
                </div>
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
    const intensityGroupsHtml = createEarthquakeIntensityGroupsHtml(q);

    return `
        <div class="slide earthquake-slide ${bgClass}">
            <div class="slide-title">地震情報</div>
            <div class="slide-content earthquake-detail earthquake-fixed-layout">
                <div class="quake-summary-main">
                    ${formatDisasterTime(q.time)}頃、${escapeDisasterHtml(q.hypocenter || "不明")}で地震がありました。<br>
                    最大震度は${escapeDisasterHtml(q.maxScaleText || "-")}です。
                </div>
                <div class="quake-summary-sub">M${escapeDisasterHtml(q.magnitude || "-")}　深さ ${escapeDisasterHtml(q.depth || "-")}km　津波 ${escapeDisasterHtml(q.tsunami || "-")}</div>
                <div class="auto-scroll-viewport earthquake-points-viewport">
                    <div class="auto-scroll-content earthquake-points-scroll">
                        <div class="earthquake-intensity-groups">${intensityGroupsHtml}</div>
                    </div>
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

function createDisasterPriorityHtml(emergencyData, railwayItems = []) {
    if (!emergencyData) return "";
    let mainHtml = "";
    if (emergencyData.eew) {
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
            ${createRailwayDisasterTickerHtml(railwayItems)}
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