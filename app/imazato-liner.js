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
        destinationEn: "Kamiji-koen",
        destinationKana: "かみじこうえん",
        via: "地下鉄今里方面",
        viaEn: "Via Subway Imazato",
    },
    地下鉄今里: {
        destinationEn: "Subway Imazato",
        destinationKana: "ちかてついまざと",
        via: "中川西公園前・神路公園方面",
        viaEn: "Via Kamiji-koen",
    },
};

let imazatoLinerState = {
    fetchedAt: null,
    schedule: null,
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

function parseImazatoLinerApproachHtml(html) {
    const documentData = new DOMParser().parseFromString(html, "text/html");

    return Array.from(documentData.querySelectorAll(".approachData"))
        .map((element) => {
            const routeText = normalizeImazatoLinerText(
                element.querySelector("#routeNm")?.textContent,
            );
            const line = routeText.replace(/\s*号\s*$/, "").replace(/\s/g, "");
            if (line !== "BRT1" && line !== "BRT2") return null;

            const destination = normalizeImazatoLinerText(
                element.querySelector("#destNm")?.textContent,
            )
                .replace(/\s*行\s*$/, "")
                .replace(/^ＪＲ/, "JR");
            const passTimeText = normalizeImazatoLinerText(
                element.querySelector("#passTimeFromText")?.textContent,
            );
            const passInfoList = Array.from(
                element.querySelectorAll("#passInfo"),
            ).map((item) => normalizeImazatoLinerText(item.textContent));
            const passInfo =
                passInfoList.find((item) =>
                    /運休|遅れ|定刻/.test(item),
                ) || passInfoList.join(" ");
            const time = parseImazatoLinerTime(passTimeText);
            const allText = normalizeImazatoLinerText(element.textContent);
            const delayMinutes = calculateImazatoLinerDelay(passInfo);

            if (!time.scheduledTime || !destination) return null;

            return {
                time: time.scheduledTime,
                predictedTime: time.predictedTime,
                line,
                destination,
                delayMinutes,
                suspensionFlg:
                    /運休/.test(passInfo) || /運休/.test(allText),
            };
        })
        .filter(Boolean);
}

function registerImazatoLinerHtml(payload) {
    try {
        const fetchedAt = new Date(payload.fetchedAt);
        if (Number.isNaN(fetchedAt.getTime())) {
            throw new Error("取得日時が不正です。");
        }

        imazatoLinerState = {
            fetchedAt,
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
                oikebashiNorth: parseImazatoLinerApproachHtml(
                    payload.oikebashiNorthHtml,
                ),
                oikebashiSouth: parseImazatoLinerApproachHtml(
                    payload.oikebashiSouthHtml,
                ),
                tajimaNorth: parseImazatoLinerApproachHtml(
                    payload.tajimaNorthHtml,
                ),
                tajimaSouth: parseImazatoLinerApproachHtml(
                    payload.tajimaSouthHtml,
                ),
            },
        };
    } catch (error) {
        console.error("いまざとライナーデータ解析失敗:", error);
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
    let difference =
        hour * 3600 +
        minute * 60 -
        (now.getHours() * 3600 +
            now.getMinutes() * 60 +
            now.getSeconds());
    if (difference < -43200) difference += 86400;
    return difference;
}

function createImazatoLinerRow(bus) {
    const destinationInfo = imazatoLinerDestinationMaster[bus.destination] || {
        destinationEn: "",
        destinationKana: "",
        via: "",
        viaEn: "",
    };
    const status = bus.suspensionFlg
        ? "運休"
        : bus.delayMinutes >= 3
          ? `約${bus.delayMinutes}分遅れ`
          : "";
    const guideMode = Math.floor(Date.now() / 8000) % 3;
    const viaText = destinationInfo.via;
    const destinationGuides = [
        destinationInfo.viaEn,
        destinationInfo.destinationEn
            ? `For ${destinationInfo.destinationEn}`
            : "",
        destinationInfo.destinationKana,
    ];
    const destinationGuide = destinationGuides[guideMode];

    return `
        <div class="bus-row liner-schedule-row">
            <div class="time-block liner-time-block">
                <div class="scheduled-time liner-scheduled-time">${bus.time}</div>
                <div class="status liner-row-status">${status}</div>
            </div>
            <div class="line-number liner-line-number">${bus.line}</div>
            <div class="destination-info">
                <div class="via liner-via">${viaText}</div>
                <div class="destination liner-destination">
                    ${bus.destination}
                    <span class="liner-destination-en">${destinationGuide}</span>
                </div>
            </div>
        </div>
    `;
}

function renderImazatoLinerList(elementId, buses, now) {
    const element = document.getElementById(elementId);
    if (!element) return;

    const displayedRows = [];
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

        if (displayedRows.length >= 3) break;
    }

    element.innerHTML = displayedRows.length
        ? displayedRows.join("")
        : '<div class="liner-no-data">現在、接近情報はありません</div>';
}

function showImazatoLinerAdjusting() {
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
    const isScreenOff =
        (now.getHours() === 0 && now.getMinutes() >= 5) ||
        (now.getHours() >= 1 && now.getHours() < 6);
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

    renderImazatoLinerList(
        "list-oikebashi-north",
        schedule.oikebashiNorth,
        now,
    );
    renderImazatoLinerList(
        "list-oikebashi-south",
        schedule.oikebashiSouth,
        now,
    );
    renderImazatoLinerList("list-tajima-north", schedule.tajimaNorth, now);
    renderImazatoLinerList("list-tajima-south", schedule.tajimaSouth, now);
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
