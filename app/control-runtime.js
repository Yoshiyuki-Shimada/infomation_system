const INFORMATION_CONTROL_RELOAD_MS = 1000;
let informationControlReloadInProgress = false;

function getInformationControlData() {
    return window.informationControlData || {
        settings: {},
        displayOverrides: [],
        busTests: [],
        routes: [],
        timetable: [],
        testMode: false,
    };
}

function isInformationControlEntryActive(entry, now = new Date()) {
    if (!entry || entry.enabled === false) return false;
    if (!entry.expiresAt) return true;

    const expiresAt = new Date(entry.expiresAt);
    return !Number.isNaN(expiresAt.getTime()) && now < expiresAt;
}

function isInformationControlTestActive(now = new Date()) {
    const data = getInformationControlData();
    if (data.testMode === true) return true;
    return (data.busTests || []).some((test) =>
        isInformationControlEntryActive(test, now),
    );
}

function getInformationControlDisplayOverride(targetId, now = new Date()) {
    return (getInformationControlData().displayOverrides || []).find(
        (entry) =>
            entry.targetId === targetId &&
            isInformationControlEntryActive(entry, now),
    );
}

function getInformationControlFallbackScheduleType() {
    const value = getInformationControlData().settings?.fallbackScheduleType;
    return ["weekday", "saturday", "holiday"].includes(value)
        ? value
        : "auto";
}

function getInformationControlOverrideHtml(targetId, now = new Date()) {
    const override = getInformationControlDisplayOverride(targetId, now);
    if (!override) return "";

    const status = String(override.status || "調整中").replace(
        "運転見合わせ",
        "運行停止中",
    );
    const statusClass = ["運行停止中", "停留所休止中"].includes(status)
        ? "is-critical"
        : ["調整中", "試験中"].includes(status)
          ? "is-warning"
          : "";

    return `
        <div class="no-bus information-control-override ${statusClass}">
            <div class="no-bus-ja">${status}</div>
        </div>
    `;
}

function isInformationControlTimetableMissing(section, scheduleType) {
    const data = getInformationControlData();
    if (!data.settings?.managedTimetableEnabled) return false;
    return !(data.timetable || []).some(
        (entry) =>
            entry.section === section && entry.scheduleType === scheduleType,
    );
}

function formatInformationControlTime(date) {
    return `${String(date.getHours()).padStart(2, "0")}:${String(
        date.getMinutes(),
    ).padStart(2, "0")}`;
}

function applyInformationControlTestToBus(bus, test, now) {
    if (test.time && bus.time !== test.time) return bus;
    if (test.line && String(bus.line).toUpperCase() !== String(test.line).toUpperCase()) {
        return bus;
    }

    const minutes = Math.max(1, Number(test.delayMinutes) || 5);
    const predicted = new Date(now.getTime() + minutes * 60000);
    const startPast = new Date(now.getTime() - 2 * 60000);
    const missingPast = new Date(now.getTime() - 11 * 60000);
    const common = { ...bus, onlineFlg: true, timetableFlg: false };

    if (test.type === "suspension") {
        return { ...common, suspensionFlg: true, suspensionText: "運休" };
    }
    if (test.type === "delay") {
        return {
            ...common,
            delayMinutes: minutes,
            delayText: `約${minutes}分遅れ`,
            predictedTime: formatInformationControlTime(predicted),
        };
    }
    if (test.type === "departure-delay") {
        return {
            ...common,
            startDepartureBeforeFlg: true,
            startDepartureDelayEstimateFlg: true,
            delayEstimateMinutes: minutes,
            delayEstimateTime: formatInformationControlTime(predicted),
            startDepartureTime: formatInformationControlTime(startPast),
        };
    }
    if (test.type === "location-error") {
        return {
            ...common,
            startDepartureBeforeFlg: true,
            startDepartureUndetectedFlg: true,
            startDepartureTime: formatInformationControlTime(startPast),
        };
    }
    if (test.type === "departure-not-detected") {
        return {
            ...common,
            startDepartureBeforeFlg: true,
            startDepartureUndetectedFlg: true,
            startDepartureTime: formatInformationControlTime(missingPast),
        };
    }

    return bus;
}

function applyInformationControlBusTests(schedule, surface, now = new Date()) {
    const tests = (getInformationControlData().busTests || []).filter(
        (test) =>
            test.surface === surface &&
            isInformationControlEntryActive(test, now),
    );
    if (!tests.length || !schedule) return schedule;

    const result = {};
    Object.entries(schedule).forEach(([section, buses]) => {
        result[section] = (Array.isArray(buses) ? buses : []).map((bus) => {
            return tests
                .filter((test) => !test.section || test.section === section)
                .reduce(
                    (current, test) =>
                        applyInformationControlTestToBus(current, test, now),
                    bus,
                );
        });
    });
    return result;
}

function createInformationControlSchedule(data) {
    const schedule = { weekday: {}, saturday: {}, holiday: {} };
    (data.timetable || [])
        .filter(
            (entry) =>
                entry.stopKey === "tajima" &&
                ["oikebashi", "kumata", "abenobashi"].includes(
                    entry.section,
                ),
        )
        .forEach((entry) => {
        const type = entry.scheduleType;
        if (!schedule[type]) return;
        if (!schedule[type][entry.section]) schedule[type][entry.section] = [];
        schedule[type][entry.section].push({
            time: entry.departureTime,
            line: entry.line,
            dir: entry.direction,
            msg: "",
            lastFlg: entry.lastFlag === true || Number(entry.lastFlag) === 1,
            suspensionFlg: false,
        });
        });

    Object.values(schedule).forEach((daySchedule) => {
        Object.values(daySchedule).forEach((buses) => {
            buses.sort((left, right) => left.time.localeCompare(right.time));
        });
    });
    return schedule;
}

function getInformationControlScheduleType(date) {
    const forcedType = getInformationControlFallbackScheduleType();
    if (forcedType !== "auto") return forcedType;

    const dateKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
    const holidays =
        typeof getJapaneseHolidayMap === "function"
            ? getJapaneseHolidayMap()
            : {};
    if (
        date.getDay() === 0 ||
        Object.prototype.hasOwnProperty.call(holidays, dateKey)
    ) {
        return "holiday";
    }
    return date.getDay() === 6 ? "saturday" : "weekday";
}

function getInformationControlLinerFallbackSchedule(now = new Date()) {
    const data = getInformationControlData();
    if (!data.settings?.managedTimetableEnabled) return null;

    const operationalDate = new Date(now.getTime());
    if (now.getHours() < 4) operationalDate.setDate(operationalDate.getDate() - 1);
    const scheduleType = getInformationControlScheduleType(operationalDate);
    const sectionNames = [
        "oikebashiNorth",
        "oikebashiSouth",
        "tajimaNorth",
        "tajimaSouth",
    ];
    const routeById = new Map((data.routes || []).map((route) => [route.id, route]));
    const schedule = Object.fromEntries(sectionNames.map((name) => [name, []]));

    const stopKeyBySection = {
        oikebashiNorth: "oikebashi",
        oikebashiSouth: "oikebashi",
        tajimaNorth: "tajima5",
        tajimaSouth: "tajima5",
    };

    (data.timetable || [])
        .filter(
            (entry) =>
                entry.scheduleType === scheduleType &&
                sectionNames.includes(entry.section) &&
                entry.stopKey === stopKeyBySection[entry.section],
        )
        .forEach((entry) => {
            const route = routeById.get(entry.routeId);
            if (!route) return;
            schedule[entry.section].push({
                time: entry.departureTime,
                predictedTime: "",
                startDepartureTime: "",
                startDepartureDelayMinutes: 0,
                startDepartureBeforeFlg: false,
                startDepartureDelayEstimateFlg: false,
                startDepartureUndetectedFlg: false,
                line: route.line,
                destination: route.destination,
                delayMinutes: 0,
                suspensionFlg: false,
                lastFlg: entry.lastFlag === true || Number(entry.lastFlag) === 1,
                onlineFlg: false,
                timetableFlg: true,
                serviceUnavailableFlg: true,
            });
        });

    const hasEntries = sectionNames.some((name) => schedule[name].length > 0);
    if (!hasEntries) return null;
    sectionNames.forEach((name) =>
        schedule[name].sort((left, right) => left.time.localeCompare(right.time)),
    );
    return schedule;
}

function applyInformationControlMasterData() {
    const data = getInformationControlData();
    if (typeof routeMaster !== "undefined") {
        (data.routes || []).forEach((route) => {
            routeMaster[route.id] = {
                via: route.via || "",
                viaEng: route.viaEng || "",
                dest: route.destination || "",
                destEng: route.destinationEng || "",
                destKana: route.destinationKana || "",
                msg1: route.transferGuide || "",
                msg2: "",
            };

            if (!String(route.line || "").startsWith("BRT")) return;
            if (typeof imazatoLinerGuideMaster === "undefined") return;
            const stops = String(route.linerStops || "")
                .split(/[、,\n]/)
                .map((value) => value.trim())
                .filter(Boolean);
            const destinationKeys = [route.destination];
            if (route.destination === "今里・神路公園") destinationKeys.push("神路公園");
            ["oikebashi", "tajima"].forEach((stopKey) => {
                destinationKeys.forEach((destination) => {
                    imazatoLinerGuideMaster[stopKey][destination] = {
                        line: route.line,
                        stops,
                        transfer: route.transferGuide || "",
                    };
                });
            });
        });
    }

    if (typeof scheduleDataList === "undefined") return;
    const existingIndex = scheduleDataList.findIndex(
        (item) => item.id === "information-control",
    );
    if (existingIndex >= 0) scheduleDataList.splice(existingIndex, 1);
    if (!data.settings?.managedTimetableEnabled) return;

    scheduleDataList.push({
        id: "information-control",
        name: "管理画面登録ダイヤ",
        priority: 10000,
        start_date: "2000-01-01",
        end_date: "2099-12-31",
        target_date: [],
        schedule: createInformationControlSchedule(data),
    });
}

function reloadInformationControlData() {
    if (informationControlReloadInProgress) return;
    informationControlReloadInProgress = true;

    const oldScript = document.getElementById("information-control-data-script");
    if (oldScript) oldScript.remove();

    const script = document.createElement("script");
    script.id = "information-control-data-script";
    script.src = `temp/control_data.js?t=${Date.now()}`;
    script.onload = () => {
        informationControlReloadInProgress = false;
        applyInformationControlMasterData();
    };
    script.onerror = () => {
        informationControlReloadInProgress = false;
        script.remove();
    };
    document.head.appendChild(script);
}

applyInformationControlMasterData();
setInterval(reloadInformationControlData, INFORMATION_CONTROL_RELOAD_MS);
