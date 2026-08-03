const engVisible = {
    for: 0,
    via: 1,
    kana: 2,
    msg1: 3,
    msg2: 4,
    bus_msg: 5,
};
const OBON_SATURDAY_DATE_KEYS = ["2026-08-13", "2026-08-14"];

const transferGuideMessages = {
    "35_北": "地下鉄千日前線・今里筋線は、「地下鉄今里」で。地下鉄中央線は、「地下鉄緑橋」で。JR学研都市線・おおさか東線は、「鴫野駅前」で。地下鉄長堀鶴見緑地線は、「地下鉄蒲生四丁目」で。京阪線は、「地下鉄関目成育」で。地下鉄谷町線は、「高殿」でお乗り換えください。",
    "35A_北": "地下鉄千日前線・今里筋線は、「地下鉄今里」でお乗り換えください。",
    "85_北": "地下鉄千日前線・今里筋線は、「地下鉄今里」で。地下鉄長堀鶴見緑地線・JR環状線は、「玉造」で。地下鉄谷町線は、「谷町六丁目」で。地下鉄堺筋線は、「長堀橋」で。地下鉄御堂筋線・四つ橋線は、「心斎橋」で。近鉄難波線・阪神なんば線・南海線は、「なんば」でお乗り換えください。",
    "73_北": "JR環状線は、「桃谷駅前」で。地下鉄千日前線・近鉄難波線・奈良線・大阪線は「鶴橋駅前」で。地下鉄谷町線は、「谷町九丁目」で。地下鉄堺筋線は、「日本橋一丁目」で。地下鉄御堂筋線・四つ橋線・阪神なんば線・南海線は、「なんば」でお乗り換えください。",
    "35_南": "JR大和路線は「杭全」でお乗り換えください。",
    "35A_南": "JR大和路線は「杭全」でお乗り換えください。",
    "85_南": "JR大和路線は「杭全」でお乗り換えください。",
    "13_北": "地下鉄千日前線は「北巽バスターミナル」でお乗り換えください。",
    "73_南": "JR大和路線は「杭全」で。地下鉄谷町線は、「地下鉄平野」でお乗り換えください。",
    "13_南": "JR環状線は、「寺田町駅前」で。地下鉄御堂筋線・谷町線・JR阪和線・JR大和路線・近鉄南大阪線・阪堺線は、「あべの橋」でお乗り換えください。",
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
    if (OBON_SATURDAY_DATE_KEYS.includes(formatDateKey(date))) return "saturday";
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

function getBusDelayBaseTime(bus) {
    return bus.predictedTime || bus.delayEstimateTime || "";
}

function getBusRemovalTime(bus) {
    if (bus.onlineFlg && Number(bus.delayMinutes) >= 5) {
        const delayBaseTime = getBusDelayBaseTime(bus);
        if (delayBaseTime) return delayBaseTime;
    }

    return bus.time;
}

function calculateRemovalDiff(bus, now, baseDate) {
    return calculateDiff(getBusRemovalTime(bus), now, baseDate);
}

function getBusSortTime(bus) {
    return getBusDelayBaseTime(bus) || bus.time;
}

function hasMajorDelayForDisplay(bus) {
    return bus.onlineFlg && Number(bus.delayMinutes) >= 5 && !!getBusDelayBaseTime(bus);
}
function sortBusesByDisplayTime(buses, now, baseDate) {
    return [...buses].sort((a, b) => {
        const diffA = calculateDiff(getBusSortTime(a), now, baseDate).pure_seconds;
        const diffB = calculateDiff(getBusSortTime(b), now, baseDate).pure_seconds;
        if (diffA !== diffB) return diffA - diffB;

        const aDelayed = hasMajorDelayForDisplay(a);
        const bDelayed = hasMajorDelayForDisplay(b);
        if (aDelayed !== bDelayed) return aDelayed ? 1 : -1;

        return a.time.localeCompare(b.time);
    });
}

function normalizeDestinationName(value) {
    return String(value || "")
        .replace(/\s+/g, "")
        .replace(/行き?$/, "");
}

function getBusDestination(bus) {
    if (bus.onlineDest) return normalizeDestinationName(bus.onlineDest);

    const routeInfo = routeMaster[`${bus.line}_${bus.dir}`];
    return normalizeDestinationName(routeInfo?.dest);
}

function doesScheduleBusMatch(busA, busB) {
    return (
        busA.time === busB.time &&
        String(busA.line) === String(busB.line) &&
        String(busA.dir || "") === String(busB.dir || "") &&
        getBusDestination(busA) === getBusDestination(busB)
    );
}

function mergeOnlineWithOfflineFallback(onlineBuses, offlineBuses) {
    const merged = (onlineBuses || []).map((onlineBus) => {
        const offlineMatch = (offlineBuses || []).find((offlineBus) =>
            doesScheduleBusMatch(onlineBus, offlineBus),
        );

        return {
            ...onlineBus,
            lastFlg: onlineBus.lastFlg || offlineMatch?.lastFlg === true,
        };
    });

    (offlineBuses || []).forEach((offlineBus) => {
        if (
            merged.some((onlineBus) =>
                doesScheduleBusMatch(onlineBus, offlineBus),
            )
        ) {
            return;
        }

        merged.push({
            ...offlineBus,
            onlineFlg: false,
            delayEstimateTime: "",
            delayEstimateMinutes: 0,
            timetableFlg: true,
        });
    });

    return merged;
}

function mergeOnlineScheduleWithOfflineFallback(onlineSchedule, offlineSchedule) {
    const groupNames = ["oikebashi", "kumata", "abenobashi"];
    const result = {};

    for (const groupName of groupNames) {
        const offlineBuses = offlineSchedule[groupName] || [];
        result[groupName] = mergeOnlineWithOfflineFallback(
            onlineSchedule[groupName] || [],
            offlineBuses,
        );
    }

    return result;
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
    const onlineSchedule = getCurrentOnlineSchedule(now);
    const onlineFetchedAt = onlineSchedule ? getOnlineBusFetchedAt() : null;
    const onlinePollIntervalSeconds = onlineSchedule
        ? getOnlineBusPollIntervalSeconds()
        : null;
    const schedule = onlineSchedule
        ? {
              ...displaySchedule.schedule,
              ...onlineSchedule,
          }
        : displaySchedule.schedule;

    const onlineUpdateTime = onlineFetchedAt
        ? `${String(onlineFetchedAt.getHours()).padStart(2, "0")}:${String(onlineFetchedAt.getMinutes()).padStart(2, "0")}`
        : "";
    const isOutsideOnlineServiceHours =
        now.getHours() >= 1 && now.getHours() < 5;
    document.getElementById("debug-mode").textContent =
        isOutsideOnlineServiceHours
            ? "● オンラインデータ（情報提供時間外）"
            : onlineSchedule
              ? `● オンラインデータ（${onlineUpdateTime}更新・${onlinePollIntervalSeconds}秒間隔更新）`
              : `● ${displaySchedule.name}`;
    const timeStr = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    const days = ["日", "月", "火", "水", "木", "金", "土"];
    const dateStr = `${now.getFullYear()}年${String(now.getMonth() + 1).padStart(2, "0")}月${String(now.getDate()).padStart(2, "0")}日（${days[now.getDay()]}）`;

    document.getElementById("clock-big").textContent = timeStr;
    document.getElementById("date-big").textContent = dateStr;
    document.getElementById("clock-small").textContent = timeStr;
    document.getElementById("date-small").textContent = dateStr;

    // --- バス路線の描画 ---
    renderBusList(
        "list-oikebashi",
        schedule.oikebashi || [],
        now,
        opDate,
        3,
    ); // 守口車庫前・なんば方面（3本）
    renderBusList(
        "list-kumata",
        schedule.kumata || [],
        now,
        opDate,
        2,
    ); // 杭全・出戸バスターミナル方面（2本）
    renderBusList(
        "list-abenobashi",
        schedule.abenobashi || [],
        now,
        opDate,
        2,
    ); // あべの橋方面（2本）

    updateTransferGuide(
        "transfer-guide-oikebashi",
        getTransferGuidePagingBuses(schedule.oikebashi || [], now, opDate, 3),
        now,
        opDate,
    );
    updateTransferGuide(
        "transfer-guide-kumata",
        getTransferGuidePagingBuses(schedule.kumata || [], now, opDate, 2),
        now,
        opDate,
    );
    updateTransferGuide(
        "transfer-guide-abenobashi",
        getTransferGuidePagingBuses(schedule.abenobashi || [], now, opDate, 2),
        now,
        opDate,
    );
}

/**
 * バス路線のリストを表示（画像表示対応版）
 */
function pickBusDisplayInfo(
    cycleSeconds,
    remainingInfo,
    delayInfo,
    statusInfo,
    lastInfo,
    suspensionInfo,
) {
    if (cycleSeconds < 7) {
        if (remainingInfo && delayInfo) {
            return cycleSeconds < 4 ? remainingInfo : delayInfo;
        }
        return remainingInfo || delayInfo || lastInfo || suspensionInfo || statusInfo;
    }

    const statusInfos = [statusInfo, lastInfo, suspensionInfo].filter(Boolean);
    if (statusInfos.length === 2) {
        return cycleSeconds < 9 ? statusInfos[0] : statusInfos[1];
    }
    if (statusInfos.length > 2) {
        if (cycleSeconds < 9) return statusInfos[0];
        if (cycleSeconds < 10.5) return statusInfos[1];
        return statusInfos[2];
    }

    return statusInfo || lastInfo || suspensionInfo || delayInfo || remainingInfo;
}

function getTimetableFallbackStatus(bus, cycleSeconds) {
    if (bus.timetableFlg !== true || bus.onlineFlg === true) {
        return null;
    }

    if (bus.lastFlg && cycleSeconds >= 6) {
        return { text: "最終", color: "#e02135" };
    }

    return { text: "運行情報未取得", color: "#8c8f93" };
}

function isBusPagingTarget(bus, now, opDate) {
    const scheduledSeconds = calculateDiff(bus.time, now, opDate).pure_seconds;
    const removalSeconds = calculateRemovalDiff(bus, now, opDate).pure_seconds;

    return scheduledSeconds <= 900 || removalSeconds <= 900;
}

function getBusPagingWindow(activeUpcoming, now, opDate, maxDisplay) {
    let latestPagingTargetSeconds = null;

    activeUpcoming.forEach((bus) => {
        if (!isBusPagingTarget(bus, now, opDate)) return;

        const displaySeconds = calculateDiff(
            getBusSortTime(bus),
            now,
            opDate,
        ).pure_seconds;
        if (
            latestPagingTargetSeconds === null ||
            displaySeconds > latestPagingTargetSeconds
        ) {
            latestPagingTargetSeconds = displaySeconds;
        }
    });

    if (latestPagingTargetSeconds === null) {
        return activeUpcoming.slice(0, maxDisplay);
    }

    const pagingWindow = activeUpcoming.filter((bus) => {
        return (
            calculateDiff(getBusSortTime(bus), now, opDate).pure_seconds <=
            latestPagingTargetSeconds
        );
    });

    if (pagingWindow.length < maxDisplay) {
        return activeUpcoming.slice(0, maxDisplay);
    }

    return pagingWindow;
}

function getTransferGuidePagingBuses(buses, now, opDate, maxDisplay) {
    const activeUpcoming = sortBusesByDisplayTime(buses, now, opDate).filter(
        (bus) => calculateRemovalDiff(bus, now, opDate).pure_seconds >= 175,
    );
    const pagingWindow = getBusPagingWindow(
        activeUpcoming,
        now,
        opDate,
        maxDisplay,
    );

    if (!pagingWindow.some((bus) => isBusPagingTarget(bus, now, opDate))) {
        return [];
    }

    return pagingWindow;
}

function getLineNumberStyle(line) {
    const lineText = String(line || "");
    const lineColors = {
        "73": { background: "#e44d93", color: "#fff" },
        "85": { background: "#a9cc51", color: "#000" },
        "13": { background: "#E60012", color: "#fff" },
    };

    if (lineText === "35" || lineText === "35A") return "";

    const colors = lineColors[lineText] || { background: "#7d7d7d", color: "#fff" };
    return ` style="background-color: ${colors.background}; color: ${colors.color};"`;
}

function renderBusList(id, buses, now, opDate, maxDisplay) {
    const el = document.getElementById(id);
    if (!el) return [];
    const pageEl = document.getElementById(id.replace("list-", "page-"));

    const allUpcoming = sortBusesByDisplayTime(buses, now, opDate).filter(
        (bus) => calculateRemovalDiff(bus, now, opDate).pure_seconds >= 175,
    ); // 5分以上遅延時は予測時刻、それ以外は定刻の3分前に表示を切り替える

    const activeUpcoming = allUpcoming;

    let displayBuses = [];
    let totalPages = 1;
    let pageIdx = 0; // 15分以内のバスが多い場合はページング

    const pagingWindow = getBusPagingWindow(
        activeUpcoming,
        now,
        opDate,
        maxDisplay,
    );

    if (pagingWindow.length > maxDisplay) {
        const pageSize = maxDisplay;
        totalPages = Math.ceil(pagingWindow.length / pageSize);
        pageIdx = Math.floor(Date.now() / 15000) % totalPages;
        displayBuses = pagingWindow.slice(
            pageIdx * pageSize,
            pageIdx * pageSize + pageSize,
        );
        if (pageEl) pageEl.textContent = `${pageIdx + 1}/${totalPages}`;
    } else {
        displayBuses = activeUpcoming.slice(0, maxDisplay);
        if (pageEl) pageEl.textContent = "";
    }

    if (displayBuses.length === 0) {
        el.innerHTML = `
            <div class="no-bus">
                <div class="no-bus-ja">本日の運行は終了しました</div>
                <div class="no-bus-en">The Service of today was finished</div>
            </div>
        `;
        return [];
    }

    const engMode = Math.floor(Date.now() / 8000) % 6;
    const cycleSeconds = Math.floor(now.getTime() / 1000) % 12;
    let engText = "";

    el.innerHTML = displayBuses
        .map((bus) => {
            const diffInfo = calculateRemovalDiff(bus, now, opDate);
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
            const destination = normalizeDestinationName(
                bus.onlineDest || info.dest,
            );

            const diff = calculateDiff(bus.time, now, opDate).minutes;
            const diff_sec = calculateDiff(bus.time, now, opDate).seconds;
            const diff_sec_pure = calculateDiff(
                bus.time,
                now,
                opDate,
            ).pure_seconds;

            let status = "";
            let imgName = "";
            let via_color = "#8c8f93";
            let status_color = "#e02135";
            const timetableFallbackStatus = getTimetableFallbackStatus(
                bus,
                cycleSeconds,
            );
            const isWaitingForOnlineInfo = !!timetableFallbackStatus;
            const hasMajorDelay = bus.onlineFlg && Number(bus.delayMinutes) >= 5;
            const predictedSeconds = pureSeconds;
            const delayStatusInfo =
                hasMajorDelay && bus.delayText
                    ? { text: bus.delayText, color: "#e02135" }
                    : null;
            const lastInfo = bus.lastFlg
                ? { text: "\u6700\u7d42", color: "#e02135" }
                : null;
            const suspensionInfo = bus.suspensionFlg
                ? { text: "\u904b\u8ee2\u4f11\u6b62", color: "#e02135" }
                : null;
            const isWithinDetailWindow =
                (diff >= 0 || hasMajorDelay) && diff_sec_pure < 900;
            const isScheduledInSoonWindow =
                hasMajorDelay && diff_sec_pure <= 270;
            const predictionWithinSevenMinutes = predictedSeconds <= 420;
            const showSoon =
                isScheduledInSoonWindow && predictionWithinSevenMinutes;
            const delayOnly =
                isScheduledInSoonWindow && !predictionWithinSevenMinutes;

            engText = engModeChange(engMode, info, bus.msg);

            let displayInfo = null;
            let statusInfo = null;

            if (isWithinDetailWindow) {
                const scheduledSecondsForDisplay = Math.max(0, diff_sec_pure);
                const scheduledDiffForDisplay = {
                    minutes: Math.floor(scheduledSecondsForDisplay / 60),
                    seconds: scheduledSecondsForDisplay % 60,
                };
                const remainingResult = visibleTime(
                    false,
                    bus.lastFlg,
                    scheduledDiffForDisplay.minutes,
                    scheduledDiffForDisplay.seconds,
                    scheduledSecondsForDisplay,
                    hasMajorDelay,
                );
                const remainingInfo =
                    !suspensionInfo &&
                    diff_sec_pure >= 0 &&
                    !delayOnly &&
                    !showSoon
                        ? {
                              text: remainingResult.text,
                              color: remainingResult.color,
                          }
                        : null;
                const delayInfo = delayStatusInfo;
                const travelResult = getTravelStatus(
                    diff,
                    diff_sec_pure,
                    hasMajorDelay,
                );
                statusInfo =
                    !suspensionInfo && showSoon
                        ? { text: "\u307e\u3082\u306a\u304f", color: "#ee7b1a" }
                        : !suspensionInfo && travelResult.text
                          ? {
                                text: travelResult.text,
                                color: travelResult.color,
                            }
                          : null;

                displayInfo = pickBusDisplayInfo(
                    cycleSeconds,
                    remainingInfo,
                    delayInfo,
                    statusInfo,
                    lastInfo,
                    suspensionInfo,
                );

            } else {
                displayInfo = pickBusDisplayInfo(
                    cycleSeconds,
                    null,
                    delayStatusInfo,
                    null,
                    lastInfo,
                    suspensionInfo,
                );


            }

            if (displayInfo) {
                status = displayInfo.text;
                status_color = displayInfo.color;
            }

            if (isWaitingForOnlineInfo) {
                status = timetableFallbackStatus.text;
                status_color = timetableFallbackStatus.color;
            }

            if (bus.suspensionFlg) {
                imgName = "suspension.png";
            } else if (showSoon) {
                imgName = "delay.png";
            } else if (delayOnly) {
                imgName = "infomation.png";
            } else if (isWithinDetailWindow) {
                if (diff_sec_pure <= 270 && !hasMajorDelay)
                    imgName = "missed.png";
                else if (diff <= 7) imgName = "run.png";
                else if (diff <= 8) imgName = "walk_fast.png";
                else imgName = "walk.png";
            }
            if (isWaitingForOnlineInfo) {
                imgName = "";
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

            const uncroppedIconNames = [
                "suspension.png",
                "delay.png",
                "infomation.png",
            ];
            const charIconClass = uncroppedIconNames.includes(imgName)
                ? "char-icon char-icon-status"
                : "char-icon";

            const charHtml = imgName
                ? `<div class="char-container"><img src="img/${imgName}" class="${charIconClass}"></div>`
                : '<div class="char-container"></div>';
            const lineNumberStyle = getLineNumberStyle(bus.line);

            return `
                <div class="bus-row">
                    <div class="time-block">
                        <div class="scheduled-time">${bus.time}</div>
                        <div class="status${hasMajorDelay && status === bus.delayText ? " delay-status" : ""}" style="color: ${status_color};">${status}</div>
                    </div>

                    <div class="line-number"${lineNumberStyle}>${bus.line}</div>

                    <div class="destination-info">
                        <div class="via">${info.via || "&nbsp;"}</div>
                        <div class="destination">${destination}</div>
                        <div class="via eng-sub" style="color: ${via_color};">${engText || "&nbsp;"}</div>
                    </div>

                    ${charHtml}
                </div>
            `;
        })
        .join("");

    return displayBuses;
}

function getTransferGuideMessage(bus) {
    return transferGuideMessages[`${bus.line}_${bus.dir}`] || "";
}

function createTransferGuideText(bus) {
    const info = routeMaster[`${bus.line}_${bus.dir}`] || {};
    const destination = normalizeDestinationName(bus.onlineDest || info.dest);
    const message = getTransferGuideMessage(bus);
    if (!message) return "";

    return `【${bus.time}発 ${destination}行きのご案内】＜乗換＞${message}`;
}

function appendTransferGuideSpan(parent, text, className) {
    const span = document.createElement("span");
    span.className = className;
    span.textContent = text;
    parent.appendChild(span);
}

function appendTransferGuideSentence(parent, sentence) {
    const match = sentence.match(/^(.+?)(は)(、?)(「[^」]+」)(.*)$/);
    if (!match) {
        appendTransferGuideSpan(parent, sentence, "transfer-guide-text");
        return;
    }

    appendTransferGuideSpan(parent, match[1], "transfer-guide-route");
    appendTransferGuideSpan(parent, `${match[2]}${match[3]}`, "transfer-guide-text");
    appendTransferGuideSpan(parent, match[4], "transfer-guide-station");
    appendTransferGuideSpan(parent, match[5], "transfer-guide-text");
}

function appendTransferGuideMessage(parent, message) {
    const sentences = message.match(/[^。]+。?/g) || [message];
    sentences.forEach((sentence) => appendTransferGuideSentence(parent, sentence));
}

function createTransferGuideItemElement(bus) {
    const info = routeMaster[`${bus.line}_${bus.dir}`] || {};
    const destination = normalizeDestinationName(bus.onlineDest || info.dest);
    const message = getTransferGuideMessage(bus);
    if (!message) return null;

    const itemElement = document.createElement("span");
    itemElement.className = "transfer-guide-item";
    appendTransferGuideSpan(
        itemElement,
        `【${bus.time}発 ${destination}行きのご案内】＜乗換＞`,
        "transfer-guide-text",
    );
    appendTransferGuideMessage(itemElement, message);

    return itemElement;
}

function getTransferGuideTargetBuses(displayedBuses, now, opDate) {
    const activeGuideBuses = displayedBuses.filter((bus) => {
        return calculateRemovalDiff(bus, now, opDate).pure_seconds >= 175;
    });

    return sortBusesByDisplayTime(activeGuideBuses, now, opDate).filter((bus) =>
        getTransferGuideMessage(bus),
    );
}

function updateTransferGuide(elementId, displayedBuses, now, opDate) {
    const guideElement = document.getElementById(elementId);
    if (!guideElement) return;

    const guideBuses = getTransferGuideTargetBuses(displayedBuses, now, opDate);
    const guideText = guideBuses.map(createTransferGuideText).join("　　　");

    if (!guideText) {
        guideElement.dataset.guideText = "";
        guideElement.innerHTML = "";
        return;
    }

    if (guideElement.dataset.guideText === guideText) {
        return;
    }

    guideElement.dataset.guideText = guideText;
    guideElement.innerHTML = "";

    const trackElement = document.createElement("div");
    trackElement.className = "transfer-guide-track";
    guideBuses.forEach((bus, index) => {
        if (index > 0) {
            trackElement.appendChild(document.createTextNode("　　　"));
        }

        const itemElement = createTransferGuideItemElement(bus);
        if (itemElement) {
            trackElement.appendChild(itemElement);
        }
    });
    guideElement.appendChild(trackElement);

    requestAnimationFrame(() => {
        const guideWidth = guideElement.clientWidth;
        const trackWidth = trackElement.scrollWidth;
        const durationSeconds = Math.max(35, Math.ceil((guideWidth + trackWidth) / 55));

        trackElement.style.setProperty("--transfer-guide-start", `${guideWidth}px`);
        trackElement.style.setProperty("--transfer-guide-end", `-${trackWidth}px`);
        trackElement.style.setProperty("--transfer-guide-duration", `${durationSeconds}s`);
    });
}
function getTravelStatus(diff, diff_sec_pure, suppressGiveUp) {
    if (diff_sec_pure <= 270) {
        return suppressGiveUp
            ? { text: "", color: "#e02135" }
            : { text: "諦めましょう", color: "#e02135" };
    }
    if (diff <= 7) {
        return { text: "走ったら間に合う", color: "#ee7b1a" };
    }
    if (diff <= 8) {
        return { text: "早歩きで間に合う", color: "#ffe766" };
    }
    return { text: "歩いても間に合う", color: "#38d5ff" };
}

function visibleTime(
    isLastMode,
    lastFlg,
    diff,
    diff_sec,
    diff_sec_pure,
    suppressLast = false,
) {
    const displayMinutes = String(diff).padStart(2, "\u00A0");
    const displaySeconds = String(diff_sec).padStart(2, "0");

    if (lastFlg && isLastMode && !suppressLast) {
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
        color: diff > 8 ? "#38d5ff" : "#ffe766",
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
