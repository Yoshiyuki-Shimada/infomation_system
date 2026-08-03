const IMAZATO_LINER_MAX_AGE_MS = 120000;

const imazatoLinerDestinationMaster = {
    あべの橋: {
        destinationEn: "Abenobashi",
        destinationKana: "あべのばし",
        via: "杭全方面",
        viaEn: "Via Kumata",
    },
    JR長居駅前: {
        destinationEn: "JR-Nagai Station",
        destinationKana: "じぇいあーる ながいえきまえ",
        via: "杭全・湯里六丁目・地下鉄長居方面",
        viaEn: "Via Kumata",
    },
    神路公園: {
        displayName: "今里・神路公園",
        destinationEn: "Imazato・Kamiji-koen",
        destinationKana: "いまざと・かみじこうえん",
        via: "中川西公園前方面",
        viaEn: "Nakagawanishi koen-mae",
    },
    地下鉄今里: {
        destinationEn: "Subway Imazato",
        destinationKana: "ちかてついまざと",
        via: "中川西公園前・地下鉄今里・神路公園方面",
        viaEn: "Kamiji-koen",
    },
};

const imazatoLinerGuideMaster = {
    oikebashi: {
        神路公園: {
            stops: [
                "中川西公園前",
                "地下鉄今里（南）",
                "地下鉄今里（北）",
                "神路公園",
            ],
            transfer:
                "地下鉄千日前線・今里筋線は「地下鉄今里」でお乗り換えください。（千日前線は地下鉄今里（南）、今里筋線は地下鉄今里（北）が最寄りです。）",
        },
        地下鉄今里: {
            stops: [
                "中川西公園前",
                "地下鉄今里（南）",
                "地下鉄今里（北）",
                "神路公園",
                "地下鉄今里（北）",
            ],
            transfer:
                "地下鉄千日前線・今里筋線は「地下鉄今里」でお乗り換えください。（千日前線は地下鉄今里（南）、今里筋線は地下鉄今里（北）が最寄りです。）",
        },
        あべの橋: {
            line: "BRT2",
            stops: ["田島五丁目", "杭全", "あべの橋"],
            transfer:
                "JR大和路線は、「杭全」で。地下鉄御堂筋線・谷町線・JR阪和線・JR大和路線・近鉄南大阪線・阪堺線は、「あべの橋」でお乗り換えください。",
        },
        JR長居駅前: {
            stops: [
                "田島五丁目",
                "杭全",
                "今川二丁目",
                "中野中学校前",
                "湯里六丁目",
                "長居公園南口",
                "地下鉄長居",
                "JR長居駅前",
            ],
            transfer:
                "JR大和路線は、「杭全」で。地下鉄御堂筋線は、「地下鉄長居」で。JR阪和線は、「JR長居駅前」でお乗り換えください。",
        },
    },
    tajima: {
        神路公園: {
            stops: [
                "大池橋",
                "中川西公園前",
                "地下鉄今里（南）",
                "地下鉄今里（北）",
                "神路公園",
            ],
            transfer:
                "地下鉄千日前線・今里筋線は「地下鉄今里」でお乗り換えください。（千日前線は地下鉄今里（南）、今里筋線は地下鉄今里（北）が最寄りです。）",
        },
        地下鉄今里: {
            stops: [
                "大池橋",
                "中川西公園前",
                "地下鉄今里（南）",
                "地下鉄今里（北）",
                "神路公園",
                "地下鉄今里（北）",
            ],
            transfer:
                "地下鉄千日前線・今里筋線は「地下鉄今里」でお乗り換えください。（千日前線は地下鉄今里（南）、今里筋線は地下鉄今里（北）が最寄りです。）",
        },
        あべの橋: {
            line: "BRT2",
            stops: ["杭全", "あべの橋"],
            transfer:
                "JR大和路線は、「杭全」で。地下鉄御堂筋線・谷町線・JR阪和線・JR大和路線・近鉄南大阪線・阪堺線は、「あべの橋」でお乗り換えください。",
        },
        JR長居駅前: {
            stops: [
                "杭全",
                "今川二丁目",
                "中野中学校前",
                "湯里六丁目",
                "長居公園南口",
                "地下鉄長居",
                "JR長居駅前",
            ],
            transfer:
                "JR大和路線は、「杭全」で。地下鉄御堂筋線は、「地下鉄長居」で。JR阪和線は、「JR長居駅前」でお乗り換えください。",
        },
    },
};
let imazatoLinerState = {
    fetchedAt: null,
    schedule: null,
    timetableDate: "",
    pollIntervalMs: 30000,
    reloadIntervalMs: 30000,
};
let imazatoLinerReloadTimer = null;

function normalizeImazatoLinerText(value) {
    return String(value || "")
        .replace(/\u00a0/g, " ")
        .replace(/\s+/g, " ")
        .trim();
}

function parseImazatoLinerTime(passTimeText) {
    const text = normalizeImazatoLinerText(passTimeText);
    const scheduledMatch = text.match(/定刻\s*(\d{1,2}:\d{2})/);
    const predictedMatch = text.match(/予測\s*(\d{1,2}:\d{2})/);
    const simpleMatch = text.match(/(\d{1,2}:\d{2})/);

    return {
        scheduledTime: scheduledMatch?.[1] || simpleMatch?.[1] || "",
        predictedTime: predictedMatch?.[1] || "",
    };
}

function calculateImazatoLinerDelay(passInfo) {
    const delayMatch = normalizeImazatoLinerText(passInfo).match(
        /約?\s*(\d+)\s*分遅れ/,
    );
    if (delayMatch) return Number(delayMatch[1]);
    return 0;
}

function normalizeImazatoLinerTime(value) {
    const match = normalizeImazatoLinerText(value).match(/^(\d{1,2}):(\d{2})$/);
    if (!match) return normalizeImazatoLinerText(value);

    return `${String(Number(match[1])).padStart(2, "0")}:${match[2]}`;
}

function normalizeImazatoLinerRouteName(value) {
    return normalizeImazatoLinerText(value)
        .replace(/\s/g, "")
        .replace(/\s*(号|蜿ｷ)\s*$/, "");
}

function normalizeImazatoLinerDestinationName(value) {
    return normalizeImazatoLinerText(value)
        .replace(/[Ａ-Ｚａ-ｚ０-９]/g, (character) => {
            return String.fromCharCode(character.charCodeAt(0) - 0xfee0);
        })
        .replace(/\s*(行き|行|陦後き?|陦圭s*)\s*$/, "")
        .replace(/^・ｪ・ｲ/, "JR");
}

function getImazatoLinerDestinationInfo(destination) {
    const normalizedDestination = normalizeImazatoLinerDestinationName(
        destination,
    );

    return imazatoLinerDestinationMaster[normalizedDestination] || {
        displayName: "",
        destinationEn: "",
        destinationKana: "",
        via: "",
        viaEn: "",
    };
}
function formatImazatoLinerEnglishGuide(prefix, value) {
    const text = normalizeImazatoLinerText(value);
    if (!text) return "";

    return new RegExp(`^${prefix}\\b`, "i").test(text)
        ? text
        : `${prefix} ${text}`;
}

function getImazatoLinerRouteKey(href) {
    try {
        const url = new URL(
            href,
            "https://oc.bus-vision.jp/osakacitybus/view/",
        );
        const routeCode = url.searchParams.get("routeCd");
        const updownCode = url.searchParams.get("updownCd");
        const lineCode = url.searchParams.get("lineCd");
        return lineCode && routeCode && updownCode
            ? `${lineCode}_${routeCode}_${updownCode}`
            : "";
    } catch {
        return "";
    }
}

function parseImazatoLinerOfficialTimetableHtml(
    html,
    routeDetails = {},
) {
    if (!html) return [];

    const documentData = new DOMParser().parseFromString(html, "text/html");
    const buses = [];

    documentData.querySelectorAll(".timetableLine").forEach((lineElement) => {
        const hour = normalizeImazatoLinerText(
            lineElement.querySelector(".timetableHour #hour")?.textContent,
        ).match(/\d{1,2}/)?.[0];
        if (hour == null) return;

        lineElement
            .querySelectorAll(".timetableMinute a#value[href]")
            .forEach((anchor) => {
                const minute = normalizeImazatoLinerText(
                    anchor.querySelector("#label")?.textContent ||
                        anchor.textContent,
                ).match(/\d{1,2}/)?.[0];
                const routeKey = getImazatoLinerRouteKey(
                    anchor.getAttribute("href"),
                );
                const detail = routeDetails[routeKey];
                const line = normalizeImazatoLinerRouteName(detail?.routeName);
                const destination = normalizeImazatoLinerDestinationName(
                    detail?.destinationName,
                );

                if (minute == null || !destination) return;
                if (line !== "BRT1" && line !== "BRT2") return;

                buses.push({
                    time: `${String(Number(hour)).padStart(2, "0")}:${String(Number(minute)).padStart(2, "0")}`,
                    predictedTime: "",
                    line,
                    destination,
                    delayMinutes: 0,
                    suspensionFlg: false,
                    lastFlg: false,
                    onlineFlg: false,
                    timetableFlg: true,
                    serviceUnavailableFlg: true,
                });
            });
    });

    return buses.sort((a, b) => a.time.localeCompare(b.time));
}

function getImazatoLinerDestination(bus) {
    return normalizeImazatoLinerDestinationName(bus.destination);
}

function isImazatoLinerNorthboundImazatoGroup(bus) {
    return ["神路公園", "地下鉄今里"].includes(
        getImazatoLinerDestination(bus),
    );
}

function hasLaterImazatoLinerBus(buses, targetBus) {
    return buses.some((bus) => {
        if (bus.time <= targetBus.time) return false;

        if (isImazatoLinerNorthboundImazatoGroup(targetBus)) {
            return isImazatoLinerNorthboundImazatoGroup(bus);
        }

        if (String(bus.line || "") !== String(targetBus.line || "")) return false;
        return getImazatoLinerDestination(bus) === getImazatoLinerDestination(targetBus);
    });
}
function markImazatoLinerOfficialLastBuses(buses) {
    return buses.map((bus) => {
        return {
            ...bus,
            lastFlg: !hasLaterImazatoLinerBus(buses, bus),
        };
    });
}

function doesImazatoLinerOnlineMatchTimetable(onlineBus, timetableBus) {
    return (
        normalizeImazatoLinerTime(onlineBus.time) ===
            normalizeImazatoLinerTime(timetableBus.time) &&
        String(onlineBus.line || "") === String(timetableBus.line || "") &&
        getImazatoLinerDestination(onlineBus) ===
            getImazatoLinerDestination(timetableBus)
    );
}

function mergeImazatoLinerOnlineWithTimetable(onlineBuses, timetableBuses) {
    const merged = timetableBuses.map((bus) => ({ ...bus }));

    onlineBuses.forEach((onlineBus) => {
        const timetableIndex = merged.findIndex((timetableBus) =>
            doesImazatoLinerOnlineMatchTimetable(onlineBus, timetableBus),
        );
        if (timetableIndex >= 0) {
            const timetableBus = merged[timetableIndex];
            merged[timetableIndex] = {
                ...timetableBus,
                ...onlineBus,
                lastFlg: timetableBus.lastFlg || onlineBus.lastFlg,
                onlineFlg: true,
                timetableFlg: true,
                serviceUnavailableFlg: false,
            };
        } else {
            merged.push({
                ...onlineBus,
                onlineFlg: true,
                timetableFlg: false,
                serviceUnavailableFlg: false,
            });
        }
    });

    return merged.sort((a, b) => a.time.localeCompare(b.time));
}

function buildImazatoLinerSection(onlineHtml, timetableHtml, routeDetails) {
    const onlineBuses = parseImazatoLinerApproachHtml(onlineHtml);
    const timetableBuses = markImazatoLinerOfficialLastBuses(
        parseImazatoLinerOfficialTimetableHtml(timetableHtml, routeDetails),
    );

    return mergeImazatoLinerOnlineWithTimetable(onlineBuses, timetableBuses);
}
function parseImazatoLinerApproachHtml(html) {
    const documentData = new DOMParser().parseFromString(html, "text/html");

    return Array.from(documentData.querySelectorAll(".approachData"))
        .map((element) => {
            const line = normalizeImazatoLinerRouteName(
                element.querySelector("#routeNm")?.textContent,
            );
            if (line !== "BRT1" && line !== "BRT2") return null;

            const destination = normalizeImazatoLinerDestinationName(
                element.querySelector("#destNm")?.textContent,
            );
            const passTimeText = normalizeImazatoLinerText(
                element.querySelector("#passTimeFromText")?.textContent,
            );
            const passInfoList = Array.from(
                element.querySelectorAll("#passInfo"),
            ).map((item) => normalizeImazatoLinerText(item.textContent));
            const passInfo =
                passInfoList.find((item) =>
                    /驕倶ｼ掃驕・ｌ|螳壼綾/.test(item),
                ) || passInfoList.join(" ");
            const time = parseImazatoLinerTime(passTimeText);
            const allText = normalizeImazatoLinerText(element.textContent);
            const delayMinutes = calculateImazatoLinerDelay(passInfo);

            if (!time.scheduledTime || !destination) return null;

            return {
                time: normalizeImazatoLinerTime(time.scheduledTime),
                predictedTime: normalizeImazatoLinerTime(time.predictedTime),
                line,
                destination,
                delayMinutes,
                suspensionFlg:
                    /驕倶ｼ・/.test(passInfo) || /驕倶ｼ・/.test(allText),
                lastFlg: /譛邨・/.test(allText),
                onlineFlg: true,
                timetableFlg: false,
                serviceUnavailableFlg: false,
            };
        })
        .filter(Boolean);
}
function registerImazatoLinerHtml(payload) {
    try {
        const fetchedAt = new Date(payload.fetchedAt);
        if (Number.isNaN(fetchedAt.getTime())) {
            throw new Error("Invalid fetchedAt");
        }

        const routeDetails = payload.timetableRouteDetails || {};
        imazatoLinerState = {
            fetchedAt,
            timetableDate: normalizeImazatoLinerText(payload.timetableDate),
            pollIntervalMs: Math.min(
                3600000,
                Math.max(
                    15000,
                    Number(payload.pollIntervalSeconds || 30) * 1000,
                ),
            ),
            reloadIntervalMs: Math.min(
                3600000,
                Math.max(
                    1000,
                    Number(
                        payload.reloadAfterSeconds ||
                            payload.pollIntervalSeconds ||
                            30,
                    ) * 1000,
                ),
            ),
            schedule: {
                oikebashiNorth: buildImazatoLinerSection(
                    payload.oikebashiNorthHtml,
                    payload.timetableOikebashiNorthHtml,
                    routeDetails,
                ),
                oikebashiSouth: buildImazatoLinerSection(
                    payload.oikebashiSouthHtml,
                    payload.timetableOikebashiSouthHtml,
                    routeDetails,
                ),
                tajimaNorth: buildImazatoLinerSection(
                    payload.tajimaNorthHtml,
                    payload.timetableTajimaNorthHtml,
                    routeDetails,
                ),
                tajimaSouth: buildImazatoLinerSection(
                    payload.tajimaSouthHtml,
                    payload.timetableTajimaSouthHtml,
                    routeDetails,
                ),
            },
        };
    } catch (error) {
        console.error("Imazato Liner data parse failed", error);
    }
}
function getImazatoLinerSchedule(now = new Date()) {
    if (!imazatoLinerState.fetchedAt || !imazatoLinerState.schedule) {
        return null;
    }
    const maxAgeMs = Math.max(
        IMAZATO_LINER_MAX_AGE_MS,
        imazatoLinerState.pollIntervalMs + 120000,
    );
    if (now - imazatoLinerState.fetchedAt > maxAgeMs) {
        return null;
    }
    return imazatoLinerState.schedule;
}

function getSecondsUntilImazatoLiner(time, now) {
    const [hour, minute] = time.split(":").map(Number);
    return (
        hour * 3600 +
        minute * 60 -
        (now.getHours() * 3600 +
            now.getMinutes() * 60 +
            now.getSeconds())
    );
}

function formatImazatoLinerYmd(date) {
    return `${date.getFullYear()}${String(date.getMonth() + 1).padStart(2, "0")}${String(date.getDate()).padStart(2, "0")}`;
}

function getImazatoLinerOperationalDate(now) {
    const operationalDate = new Date(now.getTime());
    if (now.getHours() < 4) {
        operationalDate.setDate(operationalDate.getDate() - 1);
    }
    return operationalDate;
}

function isImazatoLinerNextServiceDayHidden(now) {
    const timetableDate = imazatoLinerState.timetableDate;
    if (!timetableDate) return false;

    const operationalDateKey = formatImazatoLinerYmd(
        getImazatoLinerOperationalDate(now),
    );
    return timetableDate !== operationalDateKey;
}

function getImazatoLinerTimetableFallbackStatus(bus, cycleSeconds) {
    if (bus.timetableFlg !== true || bus.onlineFlg === true) {
        return null;
    }

    if (bus.lastFlg && cycleSeconds >= 6) {
        return { text: "最終", color: "#e02135" };
    }

    return { text: "運行情報未取得", color: "#8c8f93" };
}

function getImazatoLinerRowStatus(bus) {
    const cycleSeconds = Math.floor(Date.now() / 1000) % 12;
    const fallbackStatus = getImazatoLinerTimetableFallbackStatus(
        bus,
        cycleSeconds,
    );
    if (fallbackStatus) return fallbackStatus;

    if (bus.suspensionFlg) {
        return { text: "運休", color: "#e02135" };
    }

    if (bus.lastFlg && Number(bus.delayMinutes) >= 3) {
        return cycleSeconds < 6
            ? { text: `約${bus.delayMinutes}分遅れ`, color: "#e02135" }
            : { text: "最終", color: "#e02135" };
    }

    if (Number(bus.delayMinutes) >= 3) {
        return { text: `約${bus.delayMinutes}分遅れ`, color: "#e02135" };
    }

    if (bus.lastFlg) {
        return { text: "最終", color: "#e02135" };
    }

    return { text: "", color: "#e02135" };
}
function createImazatoLinerRow(bus) {
    const destinationInfo = getImazatoLinerDestinationInfo(bus.destination);
    const status = getImazatoLinerRowStatus(bus);
    const guideMode = Math.floor(Date.now() / 8000) % 3;
    const viaText = destinationInfo.via;
    const destinationText = destinationInfo.displayName || bus.destination;
    const destinationGuides = [
        formatImazatoLinerEnglishGuide("Via", destinationInfo.viaEn),
        formatImazatoLinerEnglishGuide("For", destinationInfo.destinationEn),
        destinationInfo.destinationKana,
    ];
    const destinationGuide = destinationGuides[guideMode];

    return `
        <div class="bus-row liner-schedule-row">
            <div class="time-block liner-time-block">
                <div class="scheduled-time liner-scheduled-time">${bus.time}</div>
                <div class="status liner-row-status" style="color: ${status.color};">${status.text}</div>
            </div>
            <div class="line-number liner-line-number">${bus.line}</div>
            <div class="destination-info">
                <div class="via liner-via">${viaText}</div>
                <div class="destination liner-destination">
                    ${destinationText}
                    <span class="liner-destination-en">${destinationGuide}</span>
                </div>
            </div>
        </div>
    `;
}
function renderImazatoLinerList(elementId, buses, now) {
    const element = document.getElementById(elementId);
    if (!element) return [];

    const displayedRows = [];
    const displayedBuses = [];
    const sortedBuses = [...buses].sort((a, b) => {
        const aTime = a.predictedTime || a.time;
        const bTime = b.predictedTime || b.time;
        return (
            getSecondsUntilImazatoLiner(aTime, now) -
            getSecondsUntilImazatoLiner(bTime, now)
        );
    });

    for (const bus of sortedBuses) {
        const removalTime = bus.predictedTime || bus.time;
        const secondsUntilRemoval = getSecondsUntilImazatoLiner(
            removalTime,
            now,
        );

        if (secondsUntilRemoval <= 590) continue;

        if (secondsUntilRemoval <= 600) {
            displayedRows.push(
                '<div class="bus-row liner-schedule-row liner-blank-row"></div>',
            );
        } else {
            displayedRows.push(createImazatoLinerRow(bus));
        }
        displayedBuses.push(bus);

        if (displayedRows.length >= 3) break;
    }

    element.innerHTML = displayedRows.length
        ? displayedRows.join("")
        : createImazatoLinerServiceFinishedHtml();

    return displayedBuses;
}

function getImazatoLinerGuideData(stopKey, bus) {
    const destination = getImazatoLinerDestination(bus);
    const guideData = imazatoLinerGuideMaster[stopKey]?.[destination];
    if (!guideData) return null;
    if (guideData.line && String(bus.line || "") !== guideData.line) return null;

    return guideData;
}

function getImazatoLinerGuideDestinationName(bus) {
    const destinationInfo = getImazatoLinerDestinationInfo(bus.destination);
    return destinationInfo.displayName || getImazatoLinerDestination(bus);
}

function createImazatoLinerGuideText(stopKey, bus) {
    const guideData = getImazatoLinerGuideData(stopKey, bus);
    if (!guideData) return "";

    const destination = getImazatoLinerGuideDestinationName(bus);
    return `【${bus.time}発 ${destination}行きのご案内】＜停車停留所＞ ${guideData.stops.join("、")}　＜乗換＞ ${guideData.transfer}`;
}

function appendImazatoLinerGuideSpan(parent, text, className) {
    const span = document.createElement("span");
    span.className = className;
    span.textContent = text;
    parent.appendChild(span);
}

function appendImazatoLinerTransferSentence(parent, sentence) {
    const match = sentence.match(/^(.+?)(は)(、?)(「[^」]+」)(.*)$/);
    if (!match) {
        appendImazatoLinerGuideSpan(parent, sentence, "transfer-guide-text");
        return;
    }

    appendImazatoLinerGuideSpan(parent, match[1], "transfer-guide-route");
    appendImazatoLinerGuideSpan(parent, `${match[2]}${match[3]}`, "transfer-guide-text");
    appendImazatoLinerGuideSpan(parent, match[4], "transfer-guide-station");
    appendImazatoLinerGuideSpan(parent, match[5], "transfer-guide-text");
}

function appendImazatoLinerTransferMessage(parent, message) {
    const sentences = message.match(/[^。]+。?/g) || [message];
    sentences.forEach((sentence) => appendImazatoLinerTransferSentence(parent, sentence));
}

function createImazatoLinerGuideItemElement(stopKey, bus) {
    const guideData = getImazatoLinerGuideData(stopKey, bus);
    if (!guideData) return null;

    const destination = getImazatoLinerGuideDestinationName(bus);
    const itemElement = document.createElement("span");
    itemElement.className = "transfer-guide-item";

    appendImazatoLinerGuideSpan(
        itemElement,
        `【${bus.time}発 ${destination}行きのご案内】＜停車停留所＞ ${guideData.stops.join("、")}　＜乗換＞ `,
        "transfer-guide-text",
    );
    appendImazatoLinerTransferMessage(itemElement, guideData.transfer);

    return itemElement;
}

function getImazatoLinerGuideTargetBus(stopKey, buses, now) {
    return [...buses]
        .filter((bus) => getImazatoLinerGuideData(stopKey, bus))
        .filter((bus) => {
            const guideTime = bus.predictedTime || bus.time;
            return getSecondsUntilImazatoLiner(guideTime, now) > 600;
        })
        .sort((a, b) => {
            const aTime = a.predictedTime || a.time;
            const bTime = b.predictedTime || b.time;
            return (
                getSecondsUntilImazatoLiner(aTime, now) -
                getSecondsUntilImazatoLiner(bTime, now)
            );
        })[0];
}

function updateImazatoLinerGuide(elementId, stopKey, buses, now) {
    const guideElement = document.getElementById(elementId);
    if (!guideElement) return;

    const guideBus = getImazatoLinerGuideTargetBus(stopKey, buses, now);
    const guideText = guideBus ? createImazatoLinerGuideText(stopKey, guideBus) : "";

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
    const itemElement = createImazatoLinerGuideItemElement(stopKey, guideBus);
    if (itemElement) {
        trackElement.appendChild(itemElement);
    }
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

function clearImazatoLinerGuides() {
    document.querySelectorAll(".liner-transfer-guide").forEach((guideElement) => {
        guideElement.dataset.guideText = "";
        guideElement.innerHTML = "";
    });
}
function createImazatoLinerServiceFinishedHtml() {
    return `
        <div class="no-bus no-liner">
            <div class="no-bus-ja">本日の運行は終了しました</div>
            <div class="no-bus-en">The Service of today was finished</div>
        </div>
    `;
}

function showImazatoLinerServiceFinished() {
    clearImazatoLinerGuides();
    [
        "list-oikebashi-north",
        "list-oikebashi-south",
        "list-tajima-north",
        "list-tajima-south",
    ].forEach((id) => {
        const element = document.getElementById(id);
        if (element) {
            element.innerHTML = createImazatoLinerServiceFinishedHtml();
        }
    });
}

function showImazatoLinerAdjusting() {
    clearImazatoLinerGuides();
    [
        "list-oikebashi-north",
        "list-oikebashi-south",
        "list-tajima-north",
        "list-tajima-south",
    ].forEach((id) => {
        const element = document.getElementById(id);
        if (element) {
            element.innerHTML = '<div class="liner-adjusting">調整中</div>';
        }
    });
    document.querySelectorAll(".liner-online-status").forEach((element) => {
        element.textContent = "● オンラインデータ調整中";
    });
}

function updateImazatoLinerScreenOff(now = new Date()) {
    const minutesFromMidnight = now.getHours() * 60 + now.getMinutes();
    const isScreenOff = minutesFromMidnight >= 5 && minutesFromMidnight < 355;
    document.body.classList.toggle("liner-screen-off", isScreenOff);
}

function refreshImazatoLinerDisplay() {
    const now = new Date();
    updateImazatoLinerScreenOff(now);
    const isOutsideOnlineServiceHours =
        now.getHours() >= 1 && now.getHours() < 5;
    const schedule = getImazatoLinerSchedule(now);
    if (!schedule) {
        showImazatoLinerAdjusting();
        if (isOutsideOnlineServiceHours) {
            document
                .querySelectorAll(".liner-online-status")
                .forEach((element) => {
                    element.textContent =
                        "● オンラインデータ（情報提供時間外）";
                });
        }
        return;
    }

    const fetchedAt = imazatoLinerState.fetchedAt;
    const updateTime = `${String(fetchedAt.getHours()).padStart(2, "0")}:${String(fetchedAt.getMinutes()).padStart(2, "0")}`;
    const pollSeconds = imazatoLinerState.pollIntervalMs / 1000;
    document.querySelectorAll(".liner-online-status").forEach((element) => {
        element.textContent = isOutsideOnlineServiceHours
            ? "● オンラインデータ（情報提供時間外）"
            : `● オンラインデータ（${updateTime}更新・${pollSeconds}秒間隔更新）`;
    });

    if (isImazatoLinerNextServiceDayHidden(now)) {
        showImazatoLinerServiceFinished();
        return;
    }
    const displayedOikebashiNorth = renderImazatoLinerList(
        "list-oikebashi-north",
        schedule.oikebashiNorth,
        now,
    );
    const displayedOikebashiSouth = renderImazatoLinerList(
        "list-oikebashi-south",
        schedule.oikebashiSouth,
        now,
    );
    const displayedTajimaNorth = renderImazatoLinerList(
        "list-tajima-north",
        schedule.tajimaNorth,
        now,
    );
    const displayedTajimaSouth = renderImazatoLinerList(
        "list-tajima-south",
        schedule.tajimaSouth,
        now,
    );

    updateImazatoLinerGuide(
        "liner-guide-oikebashi-north",
        "oikebashi",
        schedule.oikebashiNorth,
        now,
    );
    updateImazatoLinerGuide(
        "liner-guide-oikebashi-south",
        "oikebashi",
        schedule.oikebashiSouth,
        now,
    );
    updateImazatoLinerGuide(
        "liner-guide-tajima-north",
        "tajima",
        schedule.tajimaNorth,
        now,
    );
    updateImazatoLinerGuide(
        "liner-guide-tajima-south",
        "tajima",
        schedule.tajimaSouth,
        now,
    );
}

function reloadImazatoLinerData() {
    if (imazatoLinerReloadTimer) {
        clearTimeout(imazatoLinerReloadTimer);
        imazatoLinerReloadTimer = null;
    }

    const oldScript = document.getElementById("imazato-liner-data-script");
    if (oldScript) oldScript.remove();

    const script = document.createElement("script");
    script.id = "imazato-liner-data-script";
    script.src = `temp/imazato_liner_online.js?t=${Date.now()}`;
    script.onload = () => {
        refreshImazatoLinerDisplay();
        imazatoLinerReloadTimer = setTimeout(
            reloadImazatoLinerData,
            imazatoLinerState.reloadIntervalMs,
        );
    };
    script.onerror = () => {
        script.remove();
        imazatoLinerState.fetchedAt = null;
        imazatoLinerState.timetableDate = "";
        imazatoLinerState.schedule = null;
        refreshImazatoLinerDisplay();
        imazatoLinerReloadTimer = setTimeout(
            reloadImazatoLinerData,
            30000,
        );
    };
    document.head.appendChild(script);
}

updateImazatoLinerScreenOff();
showImazatoLinerAdjusting();
reloadImazatoLinerData();
setInterval(refreshImazatoLinerDisplay, 1000);
