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
 * @param {*} chunk 対象のページの本文
 * @returns 生成後のHTML
 */
function createRailwayInfoBodyHtml(
    r,
    chunk,
    badgeBg,
    badgeText,
    fixedBottomHtml,
    pageNumTag,
) {
    return `
        <div class="slide">
            <div class="slide-title">列車運行情報</div>
            <div class="slide-content">
                <div class="railway-badge" style="background:${badgeBg}; color:${badgeText};">
                    <div class="line_name">
                        ${getLineSymbolHtml(r.name, r.msg, r.lineCode || "")}${r.name}
                    </div>
                </div>

                <div class="railway-main-title">
                    ${r.title || "運行情報"}
                </div>

                <div class="railway-main-body">
                    ${chunk.replace(/\n/g, "<br>")}
                </div>
            ${fixedBottomHtml}
            </div>
            ${pageNumTag}
        </div>
    `;
}

/**
 * ニュースのHTMLを生成
 * @param {*} title ニュースのタイトル
 * @param {*} htmlText ニュースの本文
 * @param {*} pageNum ページ番号
 * @returns 生成後のHTML
 */
function createNewsDataHtml(title, htmlText, pageNum) {
    return `
        <div class="slide">
            <div class="slide-title">ニュース</div>
            <div class="slide-content">
                <p><b class="news_title">${title}</b></p>
                <div class="news_article">${htmlText}</div>
            </div>
            ${pageNum}
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
 * @returns 生成後のHMTL
 */
function createWeatherDataHtmlTime(
    getGoogleWeatherIcon,
    hour,
    code,
    isDayTime,
    wMap,
    temp,
) {
    return `
        <div class="weather-item weather_time">
            <span class="weather_time_hour">${hour}:00</span><br>
            <img src="${getGoogleWeatherIcon(code, isDayTime)}" class="weather_time_icon"><br>
            <div><span class="weather_time_msg">${wMap[code] || "情報なし"}</span></div>
            <span class="weather_time_msg">${temp}℃</span>
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
 * @returns
 */
function createWeatherDataHtmlNow(
    getGoogleWeatherIcon,
    w,
    wMap,
    currentCode,
    isDayNow,
    hourlyHtml,
) {
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
                    </div>
                </div>
                <div class="weather_time_grid">今後の予報（3時間おき）</div>
                <div class="weather-grid weather_time_grid_list">
                    ${hourlyHtml}
                </div>
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
                </div>
            </div>
        </div>
    `;
}
