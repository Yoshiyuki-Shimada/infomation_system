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
            const delayMinutes = parseDelayMinutes(
                passInfo,
                timeData.scheduledTime,
                timeData.predictedTime,
            );

            if (!line || !dest || !timeData.scheduledTime) return null;

            return {
                time: timeData.scheduledTime,
                predictedTime: timeData.predictedTime,
                delayMinutes,
                delayText:
                    delayMinutes >= 5 ? `約${delayMinutes}分遅れ` : "",
                line,
                dir: direction,
                onlineDest: dest,
                suspensionFlg,
                lastFlg: /最終/.test(allText),
                msg: "",
                onlineFlg: true,
            };
        })
        .filter(Boolean)
        .sort((a, b) => a.time.localeCompare(b.time));
}

function buildOnlineSchedule(northHtml, southHtml) {
    const north = parseOnlineApproachHtml(northHtml, "北");
    const south = parseOnlineApproachHtml(southHtml, "南");

    return {
        oikebashi: north,
        kumata: south.filter((bus) => bus.line !== "13"),
        abenobashi: south.filter((bus) => bus.line === "13"),
    };
}

function registerOnlineBusHtml(payload) {
    try {
        const fetchedAt = new Date(payload.fetchedAt);
        const schedule = buildOnlineSchedule(
            payload.northHtml,
            payload.southHtml,
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
