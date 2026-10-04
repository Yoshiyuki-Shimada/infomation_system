const apiBase = window.location.origin;
let controlState = null;
let toastTimer = null;
let activeTimetableFilter = null;

const timetableStopLabels = {
    tajima: "田島三丁目",
    oikebashi: "大池橋",
    tajima5: "田島五丁目",
};

const timetableSectionLabels = {
    oikebashi: "【一般】大池橋方向",
    kumata: "【一般】杭全方向",
    abenobashi: "【一般】舎利寺・あべの橋方向",
    oikebashiNorth: "【いまざとライナー】大池橋・今里方向",
    oikebashiSouth: "【いまざとライナー】大池橋・杭全方向",
    tajimaNorth: "【いまざとライナー】田島五丁目・今里方向",
    tajimaSouth: "【いまざとライナー】田島五丁目・杭全方向",
};

const scheduleTypeLabels = {
    weekday: "平日",
    saturday: "土曜",
    holiday: "休日",
};

const earthquakeScaleOptions = ["3", "4", "5弱", "5強", "6弱", "6強", "7"];

function createScaleOptions(selected = "3") {
    return earthquakeScaleOptions.map((scale) =>
        `<option value="${scale}"${scale === selected ? " selected" : ""}>震度${scale}</option>`,
    ).join("");
}

function addQuakeTestPoint(pref = "大阪府", name = "大阪市生野区", scale = "4") {
    const row = document.createElement("div");
    row.className = "test-point-row quake-test-point";
    row.innerHTML = `
        <label>都道府県<input data-field="pref" value="${escapeHtml(pref)}"></label>
        <label>拠点<input data-field="name" value="${escapeHtml(name)}"></label>
        <label>震度<select data-field="scale">${createScaleOptions(scale)}</select></label>
        <button class="danger" type="button" data-remove-test-row>削除</button>`;
    document.getElementById("quake-test-points").appendChild(row);
}

function addTsunamiTestArea(name = "大阪府", grade = "津波注意報") {
    const row = document.createElement("div");
    row.className = "test-point-row tsunami tsunami-test-area";
    row.innerHTML = `
        <label>地点<input data-field="name" value="${escapeHtml(name)}"></label>
        <label>種別<select data-field="grade">
            ${["大津波警報", "津波警報", "津波注意報"].map((item) => `<option${item === grade ? " selected" : ""}>${item}</option>`).join("")}
        </select></label>
        <button class="danger" type="button" data-remove-test-row>削除</button>`;
    document.getElementById("tsunami-test-areas").appendChild(row);
}

function collectDisasterTestPayload(kind) {
    const common = { action: "earthquakeTest", kind };
    if (kind === "eew") {
        return {
            ...common,
            hypocenter: document.getElementById("eew-hypocenter").value.trim(),
            eewAreas: document.getElementById("eew-areas").value
                .split(/[、,\n]/).map((value) => value.trim()).filter(Boolean),
        };
    }
    if (kind === "earthquake") {
        const earthquakePoints = Array.from(document.querySelectorAll(".quake-test-point")).map((row) => ({
            pref: row.querySelector('[data-field="pref"]').value.trim(),
            name: row.querySelector('[data-field="name"]').value.trim(),
            scale: row.querySelector('[data-field="scale"]').value,
        })).filter((point) => point.name);
        return {
            ...common,
            hypocenter: document.getElementById("quake-hypocenter").value.trim(),
            scale: earthquakePoints[0]?.scale || "3",
            earthquakePoints,
        };
    }
    if (kind === "tsunami") {
        return {
            ...common,
            tsunamiAreas: Array.from(document.querySelectorAll(".tsunami-test-area")).map((row) => ({
                name: row.querySelector('[data-field="name"]').value.trim(),
                grade: row.querySelector('[data-field="grade"]').value,
            })).filter((area) => area.name),
        };
    }
    return common;
}

function showToast(message, isError = false) {
    const toast = document.getElementById("toast");
    toast.textContent = message;
    toast.className = `${isError ? "is-error " : ""}is-visible`;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toast.className = ""; }, 4000);
}

function escapeHtml(value) {
    return String(value ?? "")
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
}

function formToObject(form) {
    const result = Object.fromEntries(new FormData(form).entries());
    form.querySelectorAll('input[type="checkbox"]').forEach((input) => {
        result[input.name] = input.checked;
    });
    return result;
}

function setDefaultExpiry() {
    const date = new Date(Date.now() + 30 * 60000);
    const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000)
        .toISOString().slice(0, 16);
    document.querySelectorAll('input[name="expiresAt"]').forEach((input) => {
        if (!input.value) input.value = local;
    });
}

async function requestJson(path, options = {}) {
    const response = await fetch(`${apiBase}${path}`, {
        cache: "no-store",
        ...options,
        headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    });
    const payload = await response.json();
    if (!response.ok || payload.ok === false) throw new Error(payload.error || `HTTP ${response.status}`);
    return payload;
}

async function runAction(action) {
    const payload = await requestJson("/infomation_control/api/action", {
        method: "POST",
        body: JSON.stringify(action),
    });
    controlState = payload.state;
    renderState();
    showToast(payload.message || "設定を反映しました。");
}

function renderRoutes() {
    const body = document.getElementById("route-body");
    const routeSelect = document.getElementById("timetable-route");
    const routes = controlState?.routes || [];
    body.innerHTML = routes.map((route) => `
        <tr><td>${escapeHtml(route.id)}</td><td>${escapeHtml(route.line)}</td><td>${escapeHtml(route.direction)}</td>
        <td>${escapeHtml(route.destination)}</td><td>${escapeHtml(route.via)}</td>
        <td>${escapeHtml(route.transferGuide)}</td><td>${escapeHtml(route.linerStops)}</td><td>
        <button data-edit-route="${escapeHtml(route.id)}">編集</button>
        <button class="danger" data-delete-route="${escapeHtml(route.id)}">削除</button></td></tr>`).join("");
    renderTimetableRouteOptions(routes);
}

function getRoute(routeId) {
    return (controlState?.routes || []).find((route) => route.id === routeId);
}

function getTimetableDirection(section) {
    return ["oikebashi", "oikebashiNorth", "tajimaNorth"].includes(section)
        ? "北"
        : "南";
}

function renderTimetableRouteOptions(routes = controlState?.routes || []) {
    const routeSelect = document.getElementById("timetable-route");
    const selectedRouteId = routeSelect.value;
    const direction = activeTimetableFilter
        ? getTimetableDirection(activeTimetableFilter.section)
        : "";
    const matchingRoutes = direction
        ? routes.filter((route) => route.direction === direction)
        : routes;
    routeSelect.innerHTML = matchingRoutes.map((route) =>
        `<option value="${escapeHtml(route.id)}">${escapeHtml(route.line)} ${escapeHtml(route.direction)} / ${escapeHtml(route.destination)}</option>`,
    ).join("");
    if (matchingRoutes.some((route) => route.id === selectedRouteId)) {
        routeSelect.value = selectedRouteId;
    }
}

// 停留所ごとに登録可能な方面だけを表示し、誤った組み合わせを防ぐ。
function updateTimetableSectionOptions(preferredSection = "") {
    const stopKey = document.getElementById("timetable-stop").value;
    const sectionSelect = document.getElementById("timetable-section");
    const availableOptions = Array.from(sectionSelect.options).filter((option) => {
        const available = option.dataset.stopKey === stopKey;
        option.hidden = !available;
        option.disabled = !available;
        return available;
    });
    const preferredOption = availableOptions.find(
        (option) => option.value === preferredSection,
    );
    sectionSelect.value = preferredOption?.value || availableOptions[0]?.value || "";
}

function getSelectedTimetableFilter() {
    return {
        stopKey: document.getElementById("timetable-stop").value,
        scheduleType: document.getElementById("timetable-schedule-type").value,
        section: document.getElementById("timetable-section").value,
    };
}

function resetTimetableEntryForm() {
    const form = document.getElementById("timetable-form");
    form.elements.id.value = "";
    form.elements.departureTime.value = "";
    form.elements.lastFlag.checked = false;
    if (!activeTimetableFilter) return;
    form.elements.stopKey.value = activeTimetableFilter.stopKey;
    form.elements.scheduleType.value = activeTimetableFilter.scheduleType;
    form.elements.section.value = activeTimetableFilter.section;
    renderTimetableRouteOptions();
}

function applyTimetableFilter(filter = getSelectedTimetableFilter()) {
    activeTimetableFilter = { ...filter };
    document.getElementById("timetable-stop").value = filter.stopKey;
    updateTimetableSectionOptions(filter.section);
    document.getElementById("timetable-schedule-type").value = filter.scheduleType;
    document.getElementById("timetable-workspace").hidden = false;
    resetTimetableEntryForm();
    renderTimetable();
}

function renderTimetable() {
    const body = document.getElementById("timetable-body");
    if (!activeTimetableFilter) {
        body.innerHTML = "";
        return;
    }
    const entries = (controlState?.timetable || []).filter((entry) =>
        entry.stopKey === activeTimetableFilter.stopKey &&
        entry.scheduleType === activeTimetableFilter.scheduleType &&
        entry.section === activeTimetableFilter.section,
    );
    const stopLabel = timetableStopLabels[activeTimetableFilter.stopKey] || activeTimetableFilter.stopKey;
    const scheduleLabel = scheduleTypeLabels[activeTimetableFilter.scheduleType] || activeTimetableFilter.scheduleType;
    const sectionLabel = timetableSectionLabels[activeTimetableFilter.section] || activeTimetableFilter.section;
    document.getElementById("timetable-selection-title").textContent =
        `${stopLabel} / ${scheduleLabel} / ${sectionLabel}`;
    document.getElementById("timetable-summary").textContent = `${entries.length}件`;
    body.innerHTML = entries.map((entry) => {
        const route = getRoute(entry.routeId) || {};
        return `<tr><td><input type="checkbox" data-timetable-select="${entry.id}" aria-label="${escapeHtml(entry.departureTime)}を選択"></td><td>${escapeHtml(entry.departureTime)}</td><td>${escapeHtml(entry.line)}</td>
        <td>${escapeHtml(route.destination)}</td><td>${Number(entry.lastFlag) === 1 ? "最終" : ""}</td><td><button data-edit-time="${entry.id}">編集</button>
        <button class="danger" data-delete-time="${entry.id}">削除</button></td></tr>`;
    }).join("");
}

function renderActiveEntries() {
    const tests = controlState?.busTests || [];
    document.getElementById("active-tests").innerHTML = tests.length
        ? tests.map((test) => `<div>${escapeHtml(test.surface)} / ${escapeHtml(test.section)} / ${escapeHtml(test.time)} ${escapeHtml(test.line)} / ${escapeHtml(test.type)} / ${escapeHtml(test.expiresAt)}まで</div>`).join("")
        : "<div>実行中のバステストはありません。</div>";
    const overrides = controlState?.displayOverrides || [];
    document.getElementById("active-overrides").innerHTML = overrides.length
        ? overrides.map((entry) => {
            const status = entry.status === "運転見合わせ"
                ? "運行停止中"
                : entry.status;
            return `<div>${escapeHtml(entry.targetId)}：${escapeHtml(status)} / ${escapeHtml(entry.expiresAt)}まで</div>`;
        }).join("")
        : "<div>有効な表示制御はありません。</div>";
}

function renderState() {
    renderRoutes();
    renderTimetable();
    renderActiveEntries();
    document.getElementById("fallback-schedule").value =
        controlState?.settings?.fallbackScheduleType || "auto";
    document.getElementById("connection-status").textContent =
        `接続中 / 最終取得 ${new Date(controlState.updatedAt).toLocaleString("ja-JP")}`;
}

async function loadState() {
    try {
        const payload = await requestJson("/infomation_control/api/state");
        controlState = payload.state;
        renderState();
    } catch (error) {
        document.getElementById("connection-status").textContent = "接続エラー";
        showToast(error.message, true);
    }
}

async function loadTimeSignalStatus() {
    try {
        const status = await requestJson("/time-signal/status");
        document.getElementById("time-signal-status").textContent = status.paused
            ? `${new Date(status.until).toLocaleString("ja-JP")}まで停止中`
            : `時報有効（${status.intervalMinutes}分間隔）`;
    } catch (error) {
        document.getElementById("time-signal-status").textContent = error.message;
    }
}

async function loadNetworkHistory() {
    const logType = document.getElementById("log-type").value;
    if (logType !== "network") return loadInformationLogs(logType);
    const target = document.getElementById("network-target").value;
    const order = document.getElementById("network-order").value;
    const filter = document.getElementById("network-result").value;
    try {
        const payload = await requestJson(`/time-signal/network/status?limit=500&target=${encodeURIComponent(target)}&filter=${encodeURIComponent(filter)}&order=${order}`);
        const targets = payload.summary?.targets || [];
        const select = document.getElementById("network-target");
        const selected = select.value;
        select.innerHTML = '<option value="">すべて</option>' + targets.map((item) => `<option value="${escapeHtml(item.id)}">${escapeHtml(item.name || item.id)}</option>`).join("");
        select.value = selected;
        document.getElementById("network-summary").textContent = `最終更新 ${payload.summary?.updateTime || "-"} / SQLite / ${payload.history.length}件表示`;
        document.getElementById("log-table-head").innerHTML = "<tr><th>日時</th><th>対象</th><th>結果</th><th>応答</th><th>品質</th><th>詳細</th></tr>";
        document.getElementById("network-body").innerHTML = payload.history.map((row) => `<tr><td>${escapeHtml(row.timestamp)}</td><td>${escapeHtml(row.targetName || row.targetId)}</td><td>${escapeHtml(row.result)}</td><td>${row.responseTimeMs == null ? "-" : `${row.responseTimeMs} ms`}</td><td>${escapeHtml(row.quality)}</td><td>${escapeHtml(row.errorDetail)}</td></tr>`).join("");
    } catch (error) { showToast(error.message, true); }
}

async function loadInformationLogs(type) {
    const subtype = document.getElementById("log-subtype").value;
    try {
        const payload = await requestJson(`/infomation_control/api/logs?type=${encodeURIComponent(type)}&subtype=${encodeURIComponent(subtype)}&limit=500`);
        const rows = payload.rows || [];
        document.getElementById("network-summary").textContent = `${type === "earthquake" ? "地震情報" : "APIエラー"} / ${rows.length}件表示`;
        document.getElementById("log-table-head").innerHTML = type === "earthquake"
            ? "<tr><th>気象庁発表時刻</th><th>受信時刻</th><th>表示時刻</th><th>種別</th><th>試験</th><th>詳細</th></tr>"
            : "<tr><th>日時</th><th>種別</th><th colspan=4>詳細</th></tr>";
        document.getElementById("network-body").innerHTML = rows.map((row) => type === "earthquake"
            ? `<tr><td>${escapeHtml(row.jmaIssueAt)}</td><td>${escapeHtml(row.receivedAt)}</td><td>${escapeHtml(row.displayedAt)}</td><td>${escapeHtml(row.type)}</td><td>${row.isTest ? "試験" : "本番"}</td><td><pre>${escapeHtml(JSON.stringify(row.details, null, 2))}</pre></td></tr>`
            : `<tr><td>${escapeHtml(row.timestamp || row.time || row.recordedAt || "-")}</td><td>${escapeHtml(row.type || row.level || "API")}</td><td colspan="4"><pre>${escapeHtml(JSON.stringify(row, null, 2))}</pre></td></tr>`
        ).join("");
    } catch (error) { showToast(error.message, true); }
}

function updateLogControls() {
    const type = document.getElementById("log-type").value;
    const subtype = document.getElementById("log-subtype");
    const options = type === "earthquake"
        ? [["", "すべて"], ["eew", "緊急地震速報"], ["earthquake", "地震情報"], ["tsunami", "津波情報"]]
        : type === "api"
          ? [["", "すべて"], ["ERROR", "エラー"], ["WARN", "警告"]]
          : [["", "すべて"]];
    subtype.innerHTML = options.map(([value, label]) => `<option value="${value}">${label}</option>`).join("");
    const networkOnly = type === "network";
    document.getElementById("network-target").hidden = !networkOnly;
    document.getElementById("network-result").closest("label").hidden = !networkOnly;
    document.getElementById("network-order").hidden = !networkOnly;
}

document.querySelectorAll(".tab").forEach((button) => {
    button.addEventListener("click", () => {
        document.querySelectorAll(".tab").forEach((item) => item.classList.toggle("is-active", item === button));
        document.querySelectorAll(".panel").forEach((panel) => panel.classList.toggle("is-active", panel.id === `panel-${button.dataset.tab}`));
    });
});

document.getElementById("refresh-button").addEventListener("click", loadState);
document.querySelectorAll("[data-disaster-test]").forEach((button) => {
    button.addEventListener("click", () => runAction(collectDisasterTestPayload(button.dataset.disasterTest)).catch((error) => showToast(error.message, true)));
});
document.getElementById("add-quake-point").addEventListener("click", () => addQuakeTestPoint());
document.getElementById("add-tsunami-area").addEventListener("click", () => addTsunamiTestArea());
document.getElementById("bus-test-form").addEventListener("submit", (event) => {
    event.preventDefault();
    runAction({ action: "busTest", ...formToObject(event.currentTarget) }).catch((error) => showToast(error.message, true));
});
document.getElementById("clear-bus-tests").addEventListener("click", () => runAction({ action: "clearBusTests" }).catch((error) => showToast(error.message, true)));
document.getElementById("display-form").addEventListener("submit", (event) => {
    event.preventDefault();
    runAction({ action: "displayOverride", ...formToObject(event.currentTarget) }).catch((error) => showToast(error.message, true));
});
document.getElementById("save-fallback").addEventListener("click", () => runAction({ action: "fallbackSchedule", value: document.getElementById("fallback-schedule").value }).catch((error) => showToast(error.message, true)));
document.getElementById("route-form").addEventListener("submit", (event) => {
    event.preventDefault();
    runAction({ action: "saveRoute", ...formToObject(event.currentTarget) }).then(() => event.currentTarget.reset()).catch((error) => showToast(error.message, true));
});
document.getElementById("timetable-form").addEventListener("submit", (event) => {
    event.preventDefault();
    runAction({ action: "saveTimetable", ...formToObject(event.currentTarget) }).then(resetTimetableEntryForm).catch((error) => showToast(error.message, true));
});
document.getElementById("timetable-filter-form").addEventListener("submit", (event) => {
    event.preventDefault();
    applyTimetableFilter();
});
document.getElementById("import-timetable").addEventListener("click", () => {
    const filter = getSelectedTimetableFilter();
    applyTimetableFilter(filter);
    if (!confirm("選択中の時刻表を、いまどこの公式時刻表で更新しますか？")) return;
    runAction({ action: "importTimetable", ...filter })
        .then(() => applyTimetableFilter(filter))
        .catch((error) => showToast(error.message, true));
});
document.getElementById("timetable-stop").addEventListener("change", () => {
    updateTimetableSectionOptions();
});
document.getElementById("timetable-form").addEventListener("reset", () => {
    setTimeout(resetTimetableEntryForm, 0);
});
document.getElementById("select-all-timetable").addEventListener("change", (event) => {
    document.querySelectorAll("[data-timetable-select]").forEach((checkbox) => {
        checkbox.checked = event.currentTarget.checked;
    });
});
document.getElementById("delete-selected-timetable").addEventListener("click", () => {
    const ids = Array.from(document.querySelectorAll("[data-timetable-select]:checked"))
        .map((checkbox) => Number(checkbox.dataset.timetableSelect));
    if (!ids.length) return showToast("削除する時刻を選択してください。", true);
    if (!confirm(`${ids.length}件を削除しますか？`)) return;
    runAction({ action: "deleteTimetableMany", ids }).catch((error) => showToast(error.message, true));
});
document.getElementById("delete-all-timetable").addEventListener("click", () => {
    if (!activeTimetableFilter || !confirm("表示中の時刻表をすべて削除しますか？")) return;
    runAction({ action: "deleteTimetableFilter", ...activeTimetableFilter }).catch((error) => showToast(error.message, true));
});

document.addEventListener("click", (event) => {
    if (event.target.matches("[data-remove-test-row]")) {
        event.target.closest(".test-point-row")?.remove();
        return;
    }
    const routeId = event.target.dataset.editRoute;
    if (routeId) {
        const route = getRoute(routeId);
        const form = document.getElementById("route-form");
        Object.entries(route).forEach(([key, value]) => { if (form.elements[key]) form.elements[key].value = value ?? ""; });
        form.scrollIntoView({ behavior: "smooth" });
    }
    if (event.target.dataset.deleteRoute && confirm("路線を削除しますか？")) runAction({ action: "deleteRoute", id: event.target.dataset.deleteRoute }).catch((error) => showToast(error.message, true));
    const timetableId = Number(event.target.dataset.editTime);
    if (timetableId) {
        const entry = controlState.timetable.find((item) => Number(item.id) === timetableId);
        applyTimetableFilter({
            stopKey: entry.stopKey,
            scheduleType: entry.scheduleType,
            section: entry.section,
        });
        const form = document.getElementById("timetable-form");
        Object.entries(entry).forEach(([key, value]) => { if (form.elements[key]) form.elements[key].value = value ?? ""; });
        form.elements.lastFlag.checked = Number(entry.lastFlag) === 1;
        form.scrollIntoView({ behavior: "smooth" });
    }
    if (event.target.dataset.deleteTime && confirm("時刻表データを削除しますか？")) runAction({ action: "deleteTimetable", id: Number(event.target.dataset.deleteTime) }).catch((error) => showToast(error.message, true));
});

document.getElementById("pause-signal").addEventListener("click", async () => {
    const value = document.getElementById("pause-until").value;
    if (!value) return showToast("停止終了日時を入力してください。", true);
    try { await requestJson(`/time-signal/pause?untilMs=${new Date(value).getTime()}&admin=1`); await loadTimeSignalStatus(); showToast("時報を一時停止しました。"); } catch (error) { showToast(error.message, true); }
});
document.getElementById("resume-signal").addEventListener("click", async () => {
    try { await requestJson("/time-signal/resume"); await loadTimeSignalStatus(); showToast("時報を再開しました。"); } catch (error) { showToast(error.message, true); }
});
document.getElementById("load-network").addEventListener("click", loadNetworkHistory);
document.getElementById("log-type").addEventListener("change", () => {
    updateLogControls();
    loadNetworkHistory();
});

setDefaultExpiry();
addQuakeTestPoint();
addTsunamiTestArea();
updateLogControls();
updateTimetableSectionOptions();
loadState();
loadTimeSignalStatus();
loadNetworkHistory();
