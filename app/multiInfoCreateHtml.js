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
    let curveSegments = "";
    for (let index = 1; index < points.length; index++) {
        const previous = points[index - 1];
        const current = points[index];
        const middleX = (previous.x + current.x) / 2;
        curveSegments += ` C ${middleX} ${previous.y}, ${middleX} ${current.y}, ${current.x} ${current.y}`;
    }
    const linePath = `M ${points[0].x} ${points[0].y}${curveSegments}`;
    const areaPath = [
        `M 0 ${points[0].y}`,
        `L ${points[0].x} ${points[0].y}`,
        curveSegments,
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
                <defs>
                    <linearGradient id="weather-temperature-area" x1="0" y1="0" x2="1" y2="0">
                        <stop offset="0%" stop-color="#ff4a5a"></stop>
                        <stop offset="55%" stop-color="#ffe766"></stop>
                        <stop offset="100%" stop-color="#ff4a5a"></stop>
                    </linearGradient>
                </defs>
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

    return `
        <div class="slide">
            <div class="slide-title">明日の天気</div>
            <div class="slide-content">
                <div class="weather_tomorrow">
                    <img src="${getGoogleWeatherIcon(tomorrowCode, 1)}" class="weather_icon_tomorrow"><br>
                    <span class="weather_name_tomorrow">${wMap[tomorrowCode] || "情報なし"}</span><br>
                    <span class="weather_temperature_tomorrow">
                        <span class="weather_temperature_max_tomorrow">
                            ${Math.round(w.daily.temperature_2m_max[1])}℃
                        </span>
                        <span class="weather_slash_tomorrow">/</span>
                        <span class="weather_temperature_min_tomorrow">
                            ${Math.round(w.daily.temperature_2m_min[1])}℃
                        </span>
                    </span>
                    <span class="weather_precipitation_tomorrow">
                        降水確率 ${precipitationText}
                    </span>
                </div>
            </div>
        </div>
    `;
}
