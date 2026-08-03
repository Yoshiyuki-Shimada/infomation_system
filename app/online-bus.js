const ONLINE_BUS_MAX_AGE_MS = 120000;

let onlineBusState = {
    fetchedAt: null,
    schedule: null,
    pollIntervalMs: 30000,
    reloadIntervalMs: 30000,
};
let onlineBusReloadTimer = null;

function normalizeOnlineText(value) {
    return String(value || "")
        .replace(/\u00a0/g, " ")
        .replace(/\s+/g, " ")
        .trim();
}

function parseOnlineTime(passTimeText) {
    const text = normalizeOnlineText(passTimeText);
    const scheduledMatch = text.match(/定刻\s*(\d{1,2}:\d{2})/);
    const predictedMatch = text.match(/予測\s*(\d{1,2}:\d{2})/);
    const simpleMatch = text.match(/(\d{1,2}:\d{2})/);

    return {
        scheduledTime: scheduledMatch?.[1] || simpleMatch?.[1] || "",
        predictedTime: predictedMatch?.[1] || "",
    };
}

function normalizeOnlineTime(value) {
    const match = normalizeOnlineText(value).match(/^(\d{1,2}):(\d{2})$/);
    if (!match) return normalizeOnlineText(value);

    return `${String(Number(match[1])).padStart(2, "0")}:${match[2]}`;
}

function addMinutesToOnlineTime(time, minutes) {
    const normalizedTime = normalizeOnlineTime(time);
    const match = normalizedTime.match(/^(\d{2}):(\d{2})$/);
    if (!match || !Number.isFinite(minutes)) return "";

    const totalMinutes = Number(match[1]) * 60 + Number(match[2]) + minutes;
    const wrappedMinutes = ((totalMinutes % 1440) + 1440) % 1440;
    const hour = Math.floor(wrappedMinutes / 60);
    const minute = wrappedMinutes % 60;
    return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function parseDelayEstimateMinutes(delayEstimateText) {
    const estimateMatch = normalizeOnlineText(delayEstimateText).match(
        /約?\s*(\d+)\s*分遅れ.*発車予定/,
    );
    return estimateMatch ? Number(estimateMatch[1]) : 0;
}
function parseDelayMinutes(passInfoText, scheduledTime, predictedTime) {
    const infoMatch = normalizeOnlineText(passInfoText).match(
        /約?\s*(\d+)\s*分遅れ/,
    );
    if (infoMatch) return Number(infoMatch[1]);

    if (!scheduledTime || !predictedTime) return 0;
    const toMinutes = (time) => {
        const [hour, minute] = time.split(":").map(Number);
        return hour * 60 + minute;
    };
    let diff = toMinutes(predictedTime) - toMinutes(scheduledTime);
    if (diff < -720) diff += 1440;
    return Math.max(0, diff);
}

function parseOnlineApproachHtml(html, direction) {
    const documentData = new DOMParser().parseFromString(html, "text/html");

    return Array.from(documentData.querySelectorAll(".approachData"))
        .map((element) => {
            const routeText = normalizeOnlineText(
                element.querySelector("#routeNm")?.textContent,
            );
            const destinationText = normalizeOnlineText(
                element.querySelector("#destNm")?.textContent,
            );
            const passTimeText = normalizeOnlineText(
                element.querySelector("#passTimeFromText")?.textContent,
            );
            const passInfoList = Array.from(
                element.querySelectorAll("#passInfo"),
            ).map((item) => normalizeOnlineText(item.textContent));
            const delayEstimateText = normalizeOnlineText(
                element.querySelector(".passTimeStartDiffText")?.textContent,
            );
            const passInfo =
                passInfoList.find((item) =>
                    /運休|遅れ|定刻/.test(item),
                ) || passInfoList.join(" ");
            const timeData = parseOnlineTime(passTimeText);
            const allText = normalizeOnlineText(element.textContent);
            const line = routeText.replace(/\s*号\s*$/, "");
            const dest = destinationText.replace(/\s*行\s*$/, "");
            const suspensionFlg =
                /運休/.test(passInfo) || /運休/.test(allText);
            const delayEstimateMinutes = parseDelayEstimateMinutes(delayEstimateText);
            const estimatedTime =
                !timeData.predictedTime && delayEstimateMinutes >= 5
                    ? addMinutesToOnlineTime(
                          timeData.scheduledTime,
                          delayEstimateMinutes,
                      )
                    : "";
            const delayMinutes = timeData.predictedTime
                ? parseDelayMinutes(
                      passInfo,
                      timeData.scheduledTime,
                      timeData.predictedTime,
                  )
                : delayEstimateMinutes ||
                  parseDelayMinutes(
                      passInfo,
                      timeData.scheduledTime,
                      timeData.predictedTime,
                  );

            if (!line || !dest || !timeData.scheduledTime) return null;

            return {
                time: normalizeOnlineTime(timeData.scheduledTime),
                predictedTime: normalizeOnlineTime(timeData.predictedTime),
                delayEstimateTime: normalizeOnlineTime(estimatedTime),
                delayEstimateMinutes,
                delayMinutes,
                delayText:
                    delayMinutes >= 5
                        ? `約${delayMinutes}分遅れ${estimatedTime ? "見込み" : ""}`
                        : "",
                line,
                dir: direction,
                onlineDest: dest,
                suspensionFlg,
                lastFlg: /最終/.test(allText),
                msg: "",
                onlineFlg: true,
                serviceUnavailableFlg: false,
            };
        })
        .filter(Boolean)
        .sort((a, b) => a.time.localeCompare(b.time));
}

function getTimetableRouteKey(href) {
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

function parseOfficialTimetableHtml(html, direction, routeDetails = {}) {
    if (!html) return [];
    const documentData = new DOMParser().parseFromString(html, "text/html");
    const buses = [];

    documentData.querySelectorAll(".timetableLine").forEach((lineElement) => {
        const hour = normalizeOnlineText(
            lineElement.querySelector(".timetableHour #hour")?.textContent,
        ).match(/\d{1,2}/)?.[0];
        if (hour == null) return;

        lineElement
            .querySelectorAll(".timetableMinute a#value[href]")
            .forEach((anchor) => {
                const minute = normalizeOnlineText(
                    anchor.querySelector("#label")?.textContent ||
                        anchor.textContent,
                ).match(/\d{1,2}/)?.[0];
                const routeKey = getTimetableRouteKey(
                    anchor.getAttribute("href"),
                );
                const detail = routeDetails[routeKey];
                const routeName = normalizeOnlineText(detail?.routeName)
                    .replace(/\s*号\s*$/, "");
                const destinationName = normalizeOnlineText(
                    detail?.destinationName,
                ).replace(/\s*行\s*$/, "");

                if (minute == null || !routeName || !destinationName) return;
                buses.push({
                    time: `${String(Number(hour)).padStart(2, "0")}:${String(Number(minute)).padStart(2, "0")}`,
                    predictedTime: "",
                    delayEstimateTime: "",
                    delayEstimateMinutes: 0,
                    delayMinutes: 0,
                    delayText: "",
                    line: routeName,
                    dir: direction,
                    onlineDest: destinationName,
                    suspensionFlg: false,
                    lastFlg: false,
                    msg: "",
                    onlineFlg: false,
                    timetableFlg: true,
                    serviceUnavailableFlg: true,
                });
            });
    });

    return buses.sort((a, b) => a.time.localeCompare(b.time));
}

function hasLaterOfficialBus(buses, targetBus, predicate) {
    return buses.some((bus) => {
        if (bus.time <= targetBus.time) return false;
        return predicate(bus);
    });
}

function markOfficialLastBuses(buses) {
    return buses.map((bus) => {
        const line = String(bus.line || "").toUpperCase();
        const dest = getOnlineBusDestination(bus);
        const hasSameLineAndDestinationLater = hasLaterOfficialBus(
            buses,
            bus,
            (laterBus) =>
                String(laterBus.line || "").toUpperCase() === line &&
                getOnlineBusDestination(laterBus) === dest,
        );
        let lastFlg = !hasSameLineAndDestinationLater;

        if (
            bus.dir === "北" &&
            line === "35A" &&
            dest === "地下鉄今里" &&
            hasLaterOfficialBus(
                buses,
                bus,
                (laterBus) =>
                    String(laterBus.line || "").toUpperCase() === "35" &&
                    getOnlineBusDestination(laterBus) === "守口車庫前",
            )
        ) {
            lastFlg = false;
        }

        if (
            bus.dir === "南" &&
            ["35A", "85"].includes(line) &&
            dest === "杭全" &&
            hasLaterOfficialBus(
                buses,
                bus,
                (laterBus) =>
                    String(laterBus.line || "").toUpperCase() === "35" &&
                    getOnlineBusDestination(laterBus) === "杭全",
            )
        ) {
            lastFlg = false;
        }

        return { ...bus, lastFlg };
    });
}

function getOnlineBusDestination(bus) {
    return normalizeOnlineText(bus.onlineDest).replace(/\s*行き?\s*$/, "");
}

function doesOnlineBusMatchTimetable(onlineBus, timetableBus) {
    return (
        normalizeOnlineTime(onlineBus.time) ===
            normalizeOnlineTime(timetableBus.time) &&
        String(onlineBus.line) === String(timetableBus.line) &&
        String(onlineBus.dir || "") === String(timetableBus.dir || "") &&
        getOnlineBusDestination(onlineBus) ===
            getOnlineBusDestination(timetableBus)
    );
}

function mergeOnlineWithTimetable(onlineBuses, timetableBuses) {
    const merged = timetableBuses.map((bus) => ({ ...bus }));

    onlineBuses.forEach((onlineBus) => {
        const timetableIndex = merged.findIndex((timetableBus) =>
            doesOnlineBusMatchTimetable(onlineBus, timetableBus),
        );
        if (timetableIndex >= 0) {
            const timetableBus = merged[timetableIndex];
            merged[timetableIndex] = {
                ...timetableBus,
                ...onlineBus,
                lastFlg: timetableBus.lastFlg || onlineBus.lastFlg,
                timetableFlg: true,
                serviceUnavailableFlg: false,
            };
        } else {
            merged.push(onlineBus);
        }
    });

    return merged.sort((a, b) => a.time.localeCompare(b.time));
}

function buildOnlineSchedule(
    northHtml,
    southHtml,
    timetableNorthHtml = "",
    timetableSouthHtml = "",
    timetableRouteDetails = {},
) {
    const north = parseOnlineApproachHtml(northHtml, "北");
    const south = parseOnlineApproachHtml(southHtml, "南");
    const northTimetable = markOfficialLastBuses(
        parseOfficialTimetableHtml(
            timetableNorthHtml,
            "北",
            timetableRouteDetails,
        ),
    );
    const southTimetable = markOfficialLastBuses(
        parseOfficialTimetableHtml(
            timetableSouthHtml,
            "南",
            timetableRouteDetails,
        ),
    );
    const northMerged = mergeOnlineWithTimetable(north, northTimetable);
    const southMerged = mergeOnlineWithTimetable(south, southTimetable);

    return {
        oikebashi: northMerged,
        kumata: southMerged.filter((bus) => bus.line !== "13"),
        abenobashi: southMerged.filter((bus) => bus.line === "13"),
    };
}

function registerOnlineBusHtml(payload) {
    try {
        const fetchedAt = new Date(payload.fetchedAt);
        const schedule = buildOnlineSchedule(
            payload.northHtml,
            payload.southHtml,
            payload.timetableNorthHtml,
            payload.timetableSouthHtml,
            payload.timetableRouteDetails,
        );
        if (Number.isNaN(fetchedAt.getTime())) {
            throw new Error("オンラインバスデータの取得日時が不正です。");
        }

        onlineBusState = {
            fetchedAt,
            schedule,
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
        };
    } catch (error) {
        console.error("オンラインバスデータ解析失敗:", error);
    }
}

function getCurrentOnlineSchedule(now = new Date()) {
    if (!onlineBusState.fetchedAt || !onlineBusState.schedule) return null;
    const maxAgeMs = Math.max(
        ONLINE_BUS_MAX_AGE_MS,
        onlineBusState.pollIntervalMs + 120000,
    );
    if (now - onlineBusState.fetchedAt > maxAgeMs) return null;

    return onlineBusState.schedule;
}

function getOnlineBusFetchedAt() {
    return onlineBusState.fetchedAt
        ? new Date(onlineBusState.fetchedAt.getTime())
        : null;
}

function getOnlineBusPollIntervalSeconds() {
    return onlineBusState.pollIntervalMs / 1000;
}

function reloadOnlineBusData() {
    if (onlineBusReloadTimer) {
        clearTimeout(onlineBusReloadTimer);
        onlineBusReloadTimer = null;
    }

    const oldScript = document.getElementById("online-bus-data-script");
    if (oldScript) oldScript.remove();

    const script = document.createElement("script");
    script.id = "online-bus-data-script";
    script.src = `temp/bus_online.js?t=${Date.now()}`;
    script.onload = () => {
        onlineBusReloadTimer = setTimeout(
            reloadOnlineBusData,
            onlineBusState.reloadIntervalMs,
        );
    };
    script.onerror = () => {
        script.remove();
        onlineBusReloadTimer = setTimeout(reloadOnlineBusData, 30000);
    };
    document.head.appendChild(script);
}

reloadOnlineBusData();
