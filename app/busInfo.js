const engVisible = {
    for: 0,
    via: 1,
    kana: 2,
    msg1: 3,
    msg2: 4,
    bus_msg: 5,
};

/**
 * 日本の祝日判定ロジック (2026年)
 */
function isJapaneseHoliday(date) {
    const m = date.getMonth() + 1;
    const d = date.getDate();
    const day = date.getDay();
    const fixed = [`${m}/${d}`];
    if (
        [
            "1/1",
            "1/2",
            "1/3",
            "2/11",
            "2/23",
            "4/29",
            "5/3",
            "5/4",
            "5/5",
            "8/11",
            "11/3",
            "11/23",
            "12/30",
            "12/31",
        ].includes(fixed[0])
    )
        return true;
    if (day === 1 && (m === 1 || m === 10) && Math.floor((d - 1) / 7) + 1 === 2)
        return true;
    if (day === 1 && (m === 7 || m === 9) && Math.floor((d - 1) / 7) + 1 === 3)
        return true;
    if ((m === 3 && d === 20) || (m === 9 && d === 22)) return true;
    return day === 0;
}

/**
 * 指定された日付からダイヤの種類を判定する
 */
function getScheduleType(date) {
    if (isJapaneseHoliday(date)) return "holiday";
    if (date.getDay() === 6) return "saturday";
    return "weekday";
}

/**
 * 4時切り替えロジックに基づいた「運用上の日付」を取得する
 */
function getOperationalDate(now) {
    const opDate = new Date(now.getTime());
    if (now.getHours() < 4) {
        opDate.setDate(opDate.getDate() - 1);
    }
    return opDate;
}

function formatDateKey(date) {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, "0");
    const d = String(date.getDate()).padStart(2, "0");

    return `${y}-${m}-${d}`;
}

function isDateInRange(dateKey, startDate, endDate) {
    if (!startDate) return false;

    if (endDate) {
        return startDate <= dateKey && dateKey <= endDate;
    }

    return startDate <= dateKey;
}

function isScheduleTargetDate(dateKey, scheduleData) {
    if (!Array.isArray(scheduleData.target_date)) return false;

    return scheduleData.target_date.includes(dateKey);
}

function isScheduleActive(dateKey, scheduleData) {
    if (isScheduleTargetDate(dateKey, scheduleData)) {
        return true;
    }

    return isDateInRange(
        dateKey,
        scheduleData.start_date,
        scheduleData.end_date,
    );
}

function getActiveScheduleData(opDate) {
    const dateKey = formatDateKey(opDate);

    const activeList = scheduleDataList.filter((scheduleData) => {
        return isScheduleActive(dateKey, scheduleData);
    });

    if (activeList.length === 0) {
        return null;
    }

    activeList.sort((a, b) => {
        const priorityA = Number(a.priority || 0);
        const priorityB = Number(b.priority || 0);

        return priorityB - priorityA;
    });

    return activeList[0];
}

function getDisplaySchedule(opDate) {
    const activeScheduleData = getActiveScheduleData(opDate);

    if (!activeScheduleData) {
        return {
            type: "none",
            name: "ダイヤ未設定",
            schedule: {},
        };
    }

    const type = getScheduleType(opDate);

    return {
        type: type,
        name: `${activeScheduleData.name} / ${
            {
                weekday: "平日ダイヤ",
                saturday: "土曜ダイヤ",
                holiday: "休日ダイヤ",
            }[type]
        }`,
        schedule: activeScheduleData.schedule[type] || {},
    };
}

/**
 * 時刻の差分（分）を計算する
 * 基準となる日付(baseDate)の時刻として計算する
 */
function calculateDiff(busTime, now, baseDate) {
    const [h, m] = busTime.split(":").map(Number);
    const target = new Date(baseDate.getTime());
    target.setHours(h, m, 0, 0);

    const diffMs = target - now;

    return {
        minutes: Math.floor(diffMs / 60000),
        seconds: Math.floor(diffMs / 1000) % 60,
        pure_seconds: Math.floor(diffMs / 1000),
    };
}

/**
 * 画面更新メイン処理
 */
function refresh() {
    if (!Array.isArray(scheduleDataList) || scheduleDataList.length === 0) {
        return;
    }

    const now = new Date();
    const opDate = getOperationalDate(now);
    const displaySchedule = getDisplaySchedule(opDate);
    const type = displaySchedule.type;
    const schedule = displaySchedule.schedule;

    document.getElementById("debug-mode").textContent =
        `● ${displaySchedule.name}`;
    const timeStr = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    const days = ["日", "月", "火", "水", "木", "金", "土"];
    const dateStr = `${now.getFullYear()}年${String(now.getMonth() + 1).padStart(2, "0")}月${String(now.getDate()).padStart(2, "0")}日（${days[now.getDay()]}）`;

    document.getElementById("clock-big").textContent = timeStr;
    document.getElementById("date-big").textContent = dateStr;
    document.getElementById("clock-small").textContent = timeStr;
    document.getElementById("date-small").textContent = dateStr;

    // --- バス路線の描画 ---
    renderBusList("list-oikebashi", schedule.oikebashi || [], now, opDate, 3); // 守口車庫前・なんば方面（3本）
    renderBusList("list-kumata", schedule.kumata || [], now, opDate, 2); // 杭全・出戸バスターミナル方面（2本・新規追加）
    renderBusList("list-abenobashi", schedule.abenobashi || [], now, opDate, 1); // あべの橋方面（1本）

    // --- いまざとライナーの10秒切り替え表示 ---
    const seconds = Math.floor(now.getTime() / 1000);
    const isAbenoMode = Math.floor(seconds / 10) % 2 === 1; // 10秒おきに切替

    // 出発10分前より後のバスを表示対象とするフィルタ
    const filterLiner = (bus) =>
        calculateDiff(bus.time, now, opDate).minutes >= 10;

    if (isAbenoMode) {
        updateLinerHeader(
            "いまざとライナー　杭全・あべの橋方面（あべの橋行きのみ表示）",
            "Imazato Liner　For Kumata / Abenobashi",
        );
        renderLinerList(
            (schedule.liner_abeno || []).filter(filterLiner).slice(0, 2),
            "あべの橋行き",
            "abeno",
        );
    } else {
        updateLinerHeader(
            "いまざとライナー　地下鉄今里・神路公園方面",
            "Imazato Liner　For Subway Imazato / Kamiji-koen",
        );
        renderLinerList(
            (schedule.liner_imazato || []).filter(filterLiner).slice(0, 2),
            "地下鉄今里・神路公園方面行き",
            "imazato",
        );
    }
}

/**
 * バス路線のリストを表示（画像表示対応版）
 */
function renderBusList(id, buses, now, opDate, maxDisplay) {
    const el = document.getElementById(id);
    if (!el) return;
    const pageEl = document.getElementById(id.replace("list-", "page-"));

    const allUpcoming = buses.filter(
        (bus) => calculateDiff(bus.time, now, opDate).pure_seconds >= 175,
    ); // 実際に表示に使う「3分より後」のバス

    const activeUpcoming = allUpcoming;

    let displayBuses = [];
    let totalPages = 1;
    let pageIdx = 0; // 15分以内のバスが多い場合はページング

    const within15 = activeUpcoming.filter(
        (bus) => calculateDiff(bus.time, now, opDate).pure_seconds <= 900,
    ); // 15分以内に発車するバスの本数が設定した maxDisplay より多いならページを分割して表示

    if (within15.length > maxDisplay) {
        // ← 4固定から maxDisplay 超過条件に変更！
        const pageSize = maxDisplay; // ← 3固定から maxDisplay に変更！
        totalPages = Math.ceil(within15.length / pageSize);
        pageIdx = Math.floor(Date.now() / 15000) % totalPages;
        displayBuses = within15.slice(
            pageIdx * pageSize,
            pageIdx * pageSize + pageSize,
        );
        if (pageEl) pageEl.textContent = `${pageIdx + 1}/${totalPages}`;
    } else {
        // 15分以内が少ない場合は、直近 maxDisplay 件を表示
        displayBuses = allUpcoming.slice(0, maxDisplay); // ← 3固定から maxDisplay に変更！
        if (pageEl) pageEl.textContent = "";
    }

    if (displayBuses.length === 0) {
        el.innerHTML = '<div class="no-bus">★ 本日のバスは終了しました ★</div>';
        return;
    }

    const engMode = Math.floor(Date.now() / 8000) % 6;
    const cycleSeconds = Math.floor(now.getTime() / 1000) % 12;
    const isTimeMode = cycleSeconds < 8;
    const isLastMode = cycleSeconds >= 4 && cycleSeconds < 8;
    let engText = "";

    el.innerHTML = displayBuses
        .map((bus) => {
            const diffInfo = calculateDiff(bus.time, now, opDate);
            const pureSeconds = diffInfo.pure_seconds;

            // 2分55秒〜2分59秒の間は、このバスの行だけ空欄にする
            if (pureSeconds >= 175 && pureSeconds < 180) {
                return `
                    <div class="bus-row blank-bus-row"></div>
                `;
            }

            const info = routeMaster[`${bus.line}_${bus.dir}`] || {
                via: "",
                viaEng: "",
                dest: "",
                destEng: "",
                destKana: "",
                msg1: "",
                msg2: "",
            };

            const diff = calculateDiff(bus.time, now, opDate).minutes;
            const diff_sec = calculateDiff(bus.time, now, opDate).seconds;
            const diff_sec_pure = calculateDiff(
                bus.time,
                now,
                opDate,
            ).pure_seconds;

            let statusResult = "";
            let status = "";
            let imgName = "";
            let via_color = "#8c8f93";
            let status_color = "#e02135";

            engText = engModeChange(engMode, info, bus.msg);

            if (bus.suspensionFlg) {
                status = "運転休止";
                imgName = "suspension.png";
            } else {
                if (diff >= 0 && diff_sec_pure <= 900) {
                    // テキストの出し分け
                    if (isTimeMode) {
                        statusResult = visibleTime(
                            isLastMode,
                            bus.lastFlg,
                            diff,
                            diff_sec,
                            diff_sec_pure,
                        );
                        status = statusResult.text;
                        status_color = statusResult.color;
                    } else {
                        status_color = "#ffe766";
                        if (diff_sec_pure <= 270) {
                            status = "諦めましょう";
                            status_color = "#e02135";
                        } else if (diff <= 7) {
                            status = "走ったら間に合う";
                            status_color = "#ee7b1a";
                        } else if (diff <= 8) status = "早歩きで間に合う";
                        else status = "歩いても間に合う";
                    }

                    // 15分以内のときの表示アイコン
                    if (diff_sec_pure <= 270) imgName = "missed.png";
                    else if (diff <= 7) imgName = "run.png";
                    else if (diff <= 8) imgName = "walk_fast.png";
                    else imgName = "walk.png";
                } else {
                    if (bus.lastFlg) {
                        status = "最終";
                    }
                }
            }

            if (
                engMode == engVisible.bus_msg &&
                bus.msg &&
                bus.msg.includes("【最終】")
            ) {
                via_color = "#e02135";
            } else if ([engVisible.msg1, engVisible.msg2].includes(engMode)) {
                via_color = "#98f5e1";
            } else {
                via_color = "#8c8f93";
            }

            const charIconClass = bus.suspensionFlg
                ? "char-icon char-icon-suspension"
                : "char-icon";

            const charHtml = imgName
                ? `<div class="char-container"><img src="img/${imgName}" class="${charIconClass}"></div>`
                : '<div class="char-container"></div>';

            return `
                <div class="bus-row">
                    <div class="time-block">
                        <div class="scheduled-time">${bus.time}</div>
                        <div class="status" style="color: ${status_color};">${status}</div>
                    </div>

                    <div class="line-number">${bus.line}</div>

                    <div class="destination-info">
                        <div class="via">${info.via || "&nbsp;"}</div>
                        <div class="destination">${info.dest}</div>
                        <div class="via eng-sub" style="color: ${via_color};">${engText || "&nbsp;"}</div>
                    </div>

                    ${charHtml}
                </div>
            `;
        })
        .join("");
}

function visibleTime(isLastMode, lastFlg, diff, diff_sec, diff_sec_pure) {
    const displayMinutes = String(diff).padStart(2, "\u00A0");
    const displaySeconds = String(diff_sec).padStart(2, "0");

    if (lastFlg && isLastMode) {
        return {
            text: "最終",
            color: "#e02135",
        };
    }

    if (diff_sec_pure <= 270) {
        return {
            text: `あと${displayMinutes}分${displaySeconds}秒`,
            color: "#e02135",
        };
    }

    if (diff_sec_pure < 480) {
        return {
            text: `あと${displayMinutes}分${displaySeconds}秒`,
            color: "#ee7b1a",
        };
    }

    return {
        text: `あと${displayMinutes}分${displaySeconds}秒`,
        color: "#ffe766",
    };
}

function engModeChange(engMode, info, bus_msg) {
    let ans = "";
    switch (engMode) {
        case engVisible.for:
            ans = info.destEng;
            break;

        case engVisible.via:
            ans = info.viaEng;
            break;

        case engVisible.kana:
            ans = info.destKana;
            break;

        case engVisible.msg1:
            ans = info.msg1;
            break;

        case engVisible.msg2:
            ans = info.msg2;
            break;

        case engVisible.bus_msg:
            ans = bus_msg;
            break;

        default:
            console.log("engModeChange:この値は定義されていません。" + engMode);
            break;
    }
    return ans;
}

// ヘッダーテキストを書き換える関数（新規）
function updateLinerHeader(jp, en) {
    const header = document.getElementById("liner-header");
    header.innerHTML = `<span>${jp}</span><span class="eng-sub">${en}</span>`;
}

/**
 * いまざとライナーのリストを表示する
 * @param {string} mode - 'imazato' または 'abeno'
 */
function renderLinerList(buses, directionLabel, mode) {
    const el = document.getElementById("list-liner");
    if (!buses || buses.length === 0) {
        el.innerHTML =
            '<div class="no-bus no-liner">★ 本日のバスは終了しました ★</div>';
        return;
    }

    // モードに応じて駅名を固定で割り当て
    const s1 = mode === "imazato" ? "田島五丁目" : "大池橋";
    const s2 = mode === "imazato" ? "大池橋" : "田島五丁目";

    el.innerHTML = buses
        .map(
            (bus, i) => `
                        <div class="liner-col">
                            <div class="liner-label ${i === 0 ? "first" : ""}">【${i === 0 ? "先発" : "次発"}】${directionLabel}</div>
                            <div class="liner-item"><span>${s1}</span> <span>${bus.time1}</span></div>
                            <div class="liner-item"><span>${s2}</span> <span>${bus.time2}</span></div>
                        </div>`,
        )
        .join("");
}
