const apiBase = window.location.origin;
let controlState = null;
let toastTimer = null;
let activeTimetableFilter = null;
let disasterReference = null;
let selectedEewAreas = [];
let selectedQuakeAreas = [];
let selectedQuakePoints = [];
let selectedTsunamiAreas = [];

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

const earthquakeScaleOptions = ["欠測", "1", "2", "3", "4", "5弱", "5強", "6弱", "6強", "7"];

function createScaleOptions(selected = "3") {
    return earthquakeScaleOptions.map((scale) =>
        `<option value="${scale}"${scale === selected ? " selected" : ""}>${scale === "欠測" ? "欠測" : `震度${scale}`}</option>`,
    ).join("");
}

function setSelectOptions(select, items, valueKey = "name", labelKey = "name") {
    select.innerHTML = items.map((item) =>
        `<option value="${escapeHtml(String(item[valueKey]))}">${escapeHtml(String(item[labelKey]))}</option>`,
    ).join("");
}

function getLocationKey(item) {
    return `${item.pref || ""}|${item.name}`;
}

function getSelectedValues(select) {
    return Array.from(select.selectedOptions).map((option) => option.value);
}

function setGroupedLocationOptions(select, locations) {
    select.innerHTML = "";
    const groups = new Map();
    locations.forEach((location) => {
        const pref = location.pref || "その他";
        if (!groups.has(pref)) groups.set(pref, []);
        groups.get(pref).push(location);
    });
    groups.forEach((items, pref) => {
        const group = document.createElement("optgroup");
        group.label = pref;
        items.forEach((item) => {
            const option = document.createElement("option");
            option.value = getLocationKey(item);
            option.textContent = item.name;
            group.appendChild(option);
        });
        select.appendChild(group);
    });
}

function renderEewAssignments() {
    const assignedCodes = new Set(selectedEewAreas.map((area) => String(area.code)));
    const available = disasterReference.eewAreas.filter((area) => !assignedCodes.has(String(area.code)));
    setSelectOptions(document.getElementById("eew-area-available"), available, "code", "name");
    setSelectOptions(document.getElementById("eew-area-selected"), selectedEewAreas, "code", "name");
}

function changeEewAssignments(add, all = false) {
    const source = document.getElementById(add ? "eew-area-available" : "eew-area-selected");
    const codes = all
        ? Array.from(source.options).map((option) => option.value)
        : getSelectedValues(source);
    if (add) {
        const additions = disasterReference.eewAreas.filter((area) => codes.includes(String(area.code)));
        selectedEewAreas.push(...additions);
    } else {
        selectedEewAreas = selectedEewAreas.filter((area) => !codes.includes(String(area.code)));
    }
    renderEewAssignments();
}

function getQuakeAssignmentConfig(kind) {
    return kind === "area"
        ? {
            source: disasterReference.observationAreas,
            assignments: selectedQuakeAreas,
            scaleId: "quake-area-scale",
            availableId: "quake-area-available",
            selectedId: "quake-area-selected",
        }
        : {
            source: disasterReference.observationPoints,
            assignments: selectedQuakePoints,
            scaleId: "quake-point-scale",
            availableId: "quake-point-available",
            selectedId: "quake-point-selected",
        };
}

function renderQuakeAssignments(kind) {
    const config = getQuakeAssignmentConfig(kind);
    const currentScale = document.getElementById(config.scaleId).value;
    const assignedKeys = new Set(config.assignments.map(getLocationKey));
    const available = config.source.filter((item) => !assignedKeys.has(getLocationKey(item)));
    const selected = config.assignments.filter((item) => item.scale === currentScale);
    setGroupedLocationOptions(document.getElementById(config.availableId), available);
    setGroupedLocationOptions(document.getElementById(config.selectedId), selected);
}

function addQuakeAssignments(kind, all = false) {
    const config = getQuakeAssignmentConfig(kind);
    const sourceSelect = document.getElementById(config.availableId);
    const keys = all
        ? Array.from(sourceSelect.querySelectorAll("option")).map((option) => option.value)
        : getSelectedValues(sourceSelect);
    const scale = document.getElementById(config.scaleId).value;
    config.source
        .filter((item) => keys.includes(getLocationKey(item)))
        .forEach((item) => config.assignments.push({ pref: item.pref, name: item.name, scale }));
    renderQuakeAssignments(kind);
}

function removeQuakeAssignments(kind, all = false) {
    const config = getQuakeAssignmentConfig(kind);
    const scale = document.getElementById(config.scaleId).value;
    const selectedSelect = document.getElementById(config.selectedId);
    const keys = all
        ? config.assignments.filter((item) => item.scale === scale).map(getLocationKey)
        : getSelectedValues(selectedSelect);
    const retained = config.assignments.filter((item) => !keys.includes(getLocationKey(item)));
    if (kind === "area") selectedQuakeAreas = retained;
    else selectedQuakePoints = retained;
    renderQuakeAssignments(kind);
}

function renderTsunamiAssignments() {
    const grade = document.getElementById("tsunami-grade-select").value;
    const assignedNames = new Set(selectedTsunamiAreas.map((area) => area.name));
    const available = disasterReference.tsunamiAreas.filter((area) => !assignedNames.has(area.name));
    const selected = selectedTsunamiAreas.filter((area) => area.grade === grade);
    setSelectOptions(document.getElementById("tsunami-area-available"), available);
    setSelectOptions(document.getElementById("tsunami-area-selected"), selected);
}

function addTsunamiAssignments(all = false) {
    const source = document.getElementById("tsunami-area-available");
    const names = all
        ? Array.from(source.options).map((option) => option.value)
        : getSelectedValues(source);
    const grade = document.getElementById("tsunami-grade-select").value;
    disasterReference.tsunamiAreas
        .filter((area) => names.includes(area.name))
        .forEach((area) => selectedTsunamiAreas.push({ name: area.name, grade }));
    renderTsunamiAssignments();
}

function removeTsunamiAssignments(all = false) {
    const grade = document.getElementById("tsunami-grade-select").value;
    const names = all
        ? selectedTsunamiAreas.filter((area) => area.grade === grade).map((area) => area.name)
        : getSelectedValues(document.getElementById("tsunami-area-selected"));
    selectedTsunamiAreas = selectedTsunamiAreas.filter((area) => !names.includes(area.name));
    renderTsunamiAssignments();
}

function setHypocenterOptions(select, items) {
    select.innerHTML = items.map((item) => `
        <option value="${escapeHtml(item.name)}"
            data-latitude="${escapeHtml(item.latitude ?? "")}"
            data-longitude="${escapeHtml(item.longitude ?? "")}">${escapeHtml(item.name)}</option>
    `).join("");
}

function formatLocalDateTimeInput(date) {
    const adjusted = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
    return adjusted.toISOString().slice(0, 16);
}

async function loadDisasterReference() {
    const payload = await requestJson("/infomation_control/api/disaster-reference");
    disasterReference = payload.data;
    setHypocenterOptions(document.getElementById("eew-hypocenter"), disasterReference.hypocenters);
    setHypocenterOptions(document.getElementById("quake-hypocenter"), disasterReference.hypocenters);
    document.getElementById("quake-area-scale").innerHTML = createScaleOptions("3");
    document.getElementById("quake-point-scale").innerHTML = createScaleOptions("4");

    document.getElementById("eew-hypocenter").value = "大阪府";
    document.getElementById("quake-hypocenter").value = "大阪府北部";
    const currentLocalTime = formatLocalDateTimeInput(new Date());
    document.getElementById("eew-occurred-at").value = currentLocalTime;
    document.getElementById("quake-occurred-at").value = currentLocalTime;
    selectedEewAreas = disasterReference.eewAreas.filter((area) => ["大阪", "兵庫", "京都", "奈良"].includes(area.name));
    const defaultArea = disasterReference.observationAreas.find((area) => area.name.includes("大阪府北部")) ||
        disasterReference.observationAreas.find((area) => area.pref === "大阪府");
    if (defaultArea) selectedQuakeAreas.push({ ...defaultArea, scale: "3" });
    const ikunoPoint = disasterReference.observationPoints.find((point) => point.name.includes("生野区"));
    if (ikunoPoint) selectedQuakePoints.push({ ...ikunoPoint, scale: "4" });
    const defaultTsunami = disasterReference.tsunamiAreas.find((area) => area.name === "大阪府");
    if (defaultTsunami) selectedTsunamiAreas.push({ name: defaultTsunami.name, grade: "津波注意報" });
    renderEewAssignments();
    renderQuakeAssignments("area");
    renderQuakeAssignments("point");
    renderTsunamiAssignments();
}

function collectDisasterTestPayload(kind, earthquakeType = "", eewType = "announcement") {
    const common = { action: "earthquakeTest", kind };
    if (kind === "eew") {
        return {
            ...common,
            eewType,
            hypocenter: document.getElementById("eew-hypocenter").value,
            occurredAt: document.getElementById("eew-occurred-at").value,
            eewAreas: selectedEewAreas.map((area) => String(area.code)),
        };
    }
    if (kind === "earthquake") {
        const hypocenterSelect = document.getElementById("quake-hypocenter");
        const hypocenterOption = hypocenterSelect.selectedOptions[0];
        return {
            ...common,
            earthquakeType,
            hypocenter: hypocenterSelect.value,
            hypocenterLatitude: hypocenterOption?.dataset.latitude || "",
            hypocenterLongitude: hypocenterOption?.dataset.longitude || "",
            occurredAt: document.getElementById("quake-occurred-at").value,
            magnitude: document.getElementById("quake-magnitude").value,
            depth: document.getElementById("quake-depth").value,
            tsunamiType: document.getElementById("quake-tsunami-type").value,
            scale: earthquakeType === "scale-prompt"
                ? selectedQuakeAreas[0]?.scale || "3"
                : selectedQuakePoints[0]?.scale || "3",
            earthquakeAreas: selectedQuakeAreas,
            earthquakePoints: selectedQuakePoints,
        };
    }
    if (kind === "tsunami") {
        return {
            ...common,
            tsunamiAreas: selectedTsunamiAreas,
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

async function loadScreenList() {
    const payload = await requestJson("/infomation_control/api/screens");
    const screens = payload.screens || [];
    document.getElementById("screen-summary").textContent = screens.length
        ? `${screens.length}画面を検出: ${screens.map((screen) => `画面${screen.number} ${screen.width}x${screen.height}${screen.primary ? "（メイン）" : ""}`).join(" / ")}`
        : "接続中の画面を検出できません。";
    document.querySelectorAll("[data-capture-screen]").forEach((button) => {
        button.disabled = Number(button.dataset.captureScreen) > screens.length;
    });
}

async function captureScreen(screenNumber, button) {
    button.disabled = true;
    const originalText = button.textContent;
    button.textContent = "取得中";
    try {
        const payload = await requestJson(`/infomation_control/api/screenshot?screen=${screenNumber}`);
        const dataUrl = `data:${payload.mimeType};base64,${payload.dataBase64}`;
        const image = document.getElementById(`screenshot-${screenNumber}`);
        const download = document.getElementById(`download-screenshot-${screenNumber}`);
        image.src = dataUrl;
        download.href = dataUrl;
        download.classList.remove("is-disabled");
        showToast(`画面${screenNumber}を取得しました。`);
    } catch (error) {
        showToast(error.message, true);
    } finally {
        button.disabled = false;
        button.textContent = originalText;
    }
}

async function runSystemCommand(path, successMessage) {
    const payload = await requestJson(path);
    if (payload.ok) showToast(successMessage);
    return payload;
}

function arrayBufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    const step = 32768;
    for (let offset = 0; offset < bytes.length; offset += step) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + step));
    }
    return btoa(binary);
}

const updateExcludedRootNames = new Set([
    ".git", "_update", "temp", "logs", "monitor_css", "document",
]);
const defaultUpdateSourcePath = "D:\\開発\\infomation_system";
const updateSourceStorageKey = "infomation-system-update-source-path";

function getStoredUpdateSourcePath() {
    try {
        return localStorage.getItem(updateSourceStorageKey) || defaultUpdateSourcePath;
    } catch (_error) {
        return defaultUpdateSourcePath;
    }
}

function applyUpdateSourcePath(path) {
    const normalized = String(path || "").trim() || defaultUpdateSourcePath;
    const pathInput = document.getElementById("update-source-path");
    const folderInput = document.getElementById("update-file");
    pathInput.value = normalized;
    folderInput.setAttribute("nwworkingdir", normalized);
    folderInput.title = `既定の更新元: ${normalized}`;
}

function saveUpdateSourcePath() {
    const path = document.getElementById("update-source-path").value.trim();
    if (!/(^|[\\/])infomation_system[\\/]?$/i.test(path)) {
        throw new Error("更新元パスはinfomation_systemフォルダーを指定してください。");
    }

    try {
        localStorage.setItem(updateSourceStorageKey, path);
    } catch (_error) {
        throw new Error("このブラウザでは既定パスを保存できません。");
    }
    applyUpdateSourcePath(path);
    document.getElementById("update-status").textContent = `既定の更新元を ${path} に変更しました。`;
    showToast("更新元の既定設定を保存しました。");
}

function detectSelectedUpdateSourcePath(input) {
    const firstFile = Array.from(input.files || [])[0];
    if (!firstFile?.path || !firstFile.webkitRelativePath) return;
    const relativePath = firstFile.webkitRelativePath.replace(/\//g, "\\");
    const fullPath = String(firstFile.path).replace(/\//g, "\\");
    if (!fullPath.toLowerCase().endsWith(relativePath.toLowerCase())) return;
    applyUpdateSourcePath(fullPath.slice(0, -relativePath.length).replace(/[\\/]$/, ""));
}

function getUpdateRelativePath(file) {
    const sourcePath = String(file.webkitRelativePath || file.name).replace(/\\/g, "/");
    const parts = sourcePath.split("/").filter(Boolean);
    if (parts.length < 2 || parts[0].toLowerCase() !== "infomation_system") {
        throw new Error("infomation_systemフォルダーを選択してください。");
    }
    return parts.slice(1).join("/");
}

function isUpdateFileIncluded(relativePath) {
    const normalized = relativePath.replace(/\\/g, "/");
    const lower = normalized.toLowerCase();
    const rootName = lower.split("/")[0];
    if (updateExcludedRootNames.has(rootName)) return false;
    if (lower.startsWith("database/runtime/")) return false;
    if (lower === "bin/update_config.json") return false;
    return !lower.startsWith("document/~$");
}

function getSelectedUpdateFiles(input) {
    const files = Array.from(input.files || []).map((file) => ({
        file,
        relativePath: getUpdateRelativePath(file),
    })).filter((entry) => isUpdateFileIncluded(entry.relativePath));
    if (!files.length) throw new Error("更新対象ファイルがありません。");
    if (files.length > 65535) throw new Error("更新対象ファイル数がZIP形式の上限を超えています。");
    return files;
}

function createCrc32Table() {
    const table = new Uint32Array(256);
    for (let index = 0; index < table.length; index += 1) {
        let value = index;
        for (let bit = 0; bit < 8; bit += 1) {
            value = (value & 1) ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
        }
        table[index] = value >>> 0;
    }
    return table;
}

const updateCrc32Table = createCrc32Table();

async function getFileCrc32(file, onRead) {
    const reader = file.stream().getReader();
    let crc = 0xffffffff;
    try {
        while (true) {
            const result = await reader.read();
            if (result.done) break;
            for (const byte of result.value) {
                crc = updateCrc32Table[(crc ^ byte) & 0xff] ^ (crc >>> 8);
            }
            onRead(result.value.length);
        }
    } finally {
        reader.releaseLock();
    }
    return (crc ^ 0xffffffff) >>> 0;
}

function getDosDateTime(lastModified) {
    const date = new Date(lastModified || Date.now());
    const year = Math.min(2107, Math.max(1980, date.getFullYear()));
    return {
        date: ((year - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate(),
        time: (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2),
    };
}

function createZipLocalHeader(nameBytes, file, crc32) {
    const header = new Uint8Array(30 + nameBytes.length);
    const view = new DataView(header.buffer);
    view.setUint32(0, 0x04034b50, true);
    view.setUint16(4, 20, true);
    view.setUint16(6, 0x0800, true);
    view.setUint16(8, 0, true);
    const dos = getDosDateTime(file.lastModified);
    view.setUint16(10, dos.time, true);
    view.setUint16(12, dos.date, true);
    view.setUint32(14, crc32, true);
    view.setUint32(18, file.size, true);
    view.setUint32(22, file.size, true);
    view.setUint16(26, nameBytes.length, true);
    view.setUint16(28, 0, true);
    header.set(nameBytes, 30);
    return header;
}

function createZipCentralHeader(nameBytes, file, crc32, localOffset) {
    const header = new Uint8Array(46 + nameBytes.length);
    const view = new DataView(header.buffer);
    view.setUint32(0, 0x02014b50, true);
    view.setUint16(4, 20, true);
    view.setUint16(6, 20, true);
    view.setUint16(8, 0x0800, true);
    view.setUint16(10, 0, true);
    const dos = getDosDateTime(file.lastModified);
    view.setUint16(12, dos.time, true);
    view.setUint16(14, dos.date, true);
    view.setUint32(16, crc32, true);
    view.setUint32(20, file.size, true);
    view.setUint32(24, file.size, true);
    view.setUint16(28, nameBytes.length, true);
    view.setUint32(42, localOffset, true);
    header.set(nameBytes, 46);
    return header;
}

function createZipEndRecord(entryCount, centralSize, centralOffset) {
    const record = new Uint8Array(22);
    const view = new DataView(record.buffer);
    view.setUint32(0, 0x06054b50, true);
    view.setUint16(8, entryCount, true);
    view.setUint16(10, entryCount, true);
    view.setUint32(12, centralSize, true);
    view.setUint32(16, centralOffset, true);
    return record;
}

async function createUpdateZip(entries, onProgress) {
    const encoder = new TextEncoder();
    const fileBytes = entries.reduce((total, entry) => total + entry.file.size, 0);
    const localParts = [];
    const centralParts = [];
    let localOffset = 0;
    let readBytes = 0;

    for (let index = 0; index < entries.length; index += 1) {
        const entry = entries[index];
        if (entry.file.size > 0xffffffff) throw new Error(`4GBを超えるファイルは送信できません: ${entry.relativePath}`);
        const nameBytes = encoder.encode(entry.relativePath);
        const crc32 = await getFileCrc32(entry.file, (length) => {
            readBytes += length;
            onProgress(fileBytes ? readBytes / fileBytes : 1, entry.relativePath);
        });
        const localHeader = createZipLocalHeader(nameBytes, entry.file, crc32);
        localParts.push(localHeader, entry.file);
        centralParts.push(createZipCentralHeader(nameBytes, entry.file, crc32, localOffset));
        localOffset += localHeader.length + entry.file.size;
        if (localOffset > 0xffffffff) throw new Error("更新ZIPが4GBを超えています。");
    }

    const centralSize = centralParts.reduce((total, part) => total + part.length, 0);
    const zip = new Blob([
        ...localParts,
        ...centralParts,
        createZipEndRecord(entries.length, centralSize, localOffset),
    ], { type: "application/zip" });
    if (zip.size > 512 * 1024 * 1024) throw new Error("更新ZIPが512MBを超えています。");
    return zip;
}

async function sendUpdateZip(zip, fileName, onProgress) {
    const chunkSize = 512 * 1024;
    const started = await requestJson("/infomation_control/api/update-upload", {
        method: "POST",
        body: JSON.stringify({ operation: "start", fileName, size: zip.size }),
    });
    let uploadId = started.uploadId;
    try {
        let index = 0;
        for (let offset = 0; offset < zip.size; offset += chunkSize) {
            const buffer = await zip.slice(offset, Math.min(offset + chunkSize, zip.size)).arrayBuffer();
            await requestJson("/infomation_control/api/update-upload", {
                method: "POST",
                body: JSON.stringify({
                    operation: "chunk",
                    uploadId,
                    index,
                    dataBase64: arrayBufferToBase64(buffer),
                }),
            });
            index += 1;
            onProgress(Math.min(offset + chunkSize, zip.size) / zip.size);
        }
        await requestJson("/infomation_control/api/update-upload", {
            method: "POST",
            body: JSON.stringify({ operation: "finish", uploadId }),
        });
        uploadId = "";
    } finally {
        if (uploadId) {
            requestJson("/infomation_control/api/update-upload", {
                method: "POST",
                body: JSON.stringify({ operation: "cancel", uploadId }),
            }).catch(() => {});
        }
    }
}

async function uploadSystemUpdate() {
    const input = document.getElementById("update-file");
    const button = document.getElementById("apply-update");
    const progress = document.getElementById("update-progress");
    const status = document.getElementById("update-status");
    const entries = getSelectedUpdateFiles(input);
    const sourceSize = entries.reduce((total, entry) => total + entry.file.size, 0);
    if (!confirm(`infomation_system の更新対象 ${entries.length}ファイルを送信し、システムを再起動しますか？`)) return;

    button.disabled = true;
    progress.hidden = false;
    progress.value = 0;
    status.textContent = "更新ZIPを作成しています。";
    try {
        const zip = await createUpdateZip(entries, (ratio, path) => {
            progress.value = Math.round(ratio * 40);
            status.textContent = `ZIP作成中 ${progress.value}%: ${path}`;
        });
        const timestamp = new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0, 17);
        await sendUpdateZip(zip, `infomation_system_update_${timestamp}_browser.zip`, (ratio) => {
            progress.value = 40 + Math.round(ratio * 60);
            status.textContent = `送信中 ${progress.value}%`;
        });
        progress.value = 100;
        status.textContent = `更新を受け付けました（${entries.length}ファイル / 元データ ${Math.round(sourceSize / 1024 / 1024)}MB）。検証・適用後に自動再起動します。`;
        showToast("更新を受け付けました。まもなく再起動します。");
    } catch (error) {
        status.textContent = `更新失敗: ${error.message}`;
        throw error;
    } finally {
        button.disabled = false;
    }
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
        if (button.dataset.tab === "system") loadScreenList().catch((error) => showToast(error.message, true));
    });
});

document.getElementById("refresh-button").addEventListener("click", loadState);
document.querySelectorAll("[data-disaster-test]").forEach((button) => {
    button.addEventListener("click", () => runAction(collectDisasterTestPayload(
        button.dataset.disasterTest,
        button.dataset.earthquakeType || "",
        button.dataset.eewType || "announcement",
    )).catch((error) => showToast(error.message, true)));
});
document.getElementById("add-eew-area").addEventListener("click", () => changeEewAssignments(true));
document.getElementById("add-all-eew-areas").addEventListener("click", () => changeEewAssignments(true, true));
document.getElementById("remove-eew-area").addEventListener("click", () => changeEewAssignments(false));
document.getElementById("remove-all-eew-areas").addEventListener("click", () => changeEewAssignments(false, true));
document.getElementById("add-quake-area").addEventListener("click", () => addQuakeAssignments("area"));
document.getElementById("add-all-quake-areas").addEventListener("click", () => addQuakeAssignments("area", true));
document.getElementById("remove-quake-area").addEventListener("click", () => removeQuakeAssignments("area"));
document.getElementById("remove-all-quake-areas").addEventListener("click", () => removeQuakeAssignments("area", true));
document.getElementById("add-quake-point").addEventListener("click", () => addQuakeAssignments("point"));
document.getElementById("add-all-quake-points").addEventListener("click", () => addQuakeAssignments("point", true));
document.getElementById("remove-quake-point").addEventListener("click", () => removeQuakeAssignments("point"));
document.getElementById("remove-all-quake-points").addEventListener("click", () => removeQuakeAssignments("point", true));
document.getElementById("add-tsunami-area").addEventListener("click", () => addTsunamiAssignments());
document.getElementById("add-all-tsunami-areas").addEventListener("click", () => addTsunamiAssignments(true));
document.getElementById("remove-tsunami-area").addEventListener("click", () => removeTsunamiAssignments());
document.getElementById("remove-all-tsunami-areas").addEventListener("click", () => removeTsunamiAssignments(true));
document.getElementById("quake-area-scale").addEventListener("change", () => renderQuakeAssignments("area"));
document.getElementById("quake-point-scale").addEventListener("change", () => renderQuakeAssignments("point"));
document.getElementById("tsunami-grade-select").addEventListener("change", renderTsunamiAssignments);
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
document.querySelectorAll("[data-capture-screen]").forEach((button) => {
    button.addEventListener("click", () => captureScreen(Number(button.dataset.captureScreen), button));
});
document.getElementById("display-wake").addEventListener("click", () => {
    runSystemCommand("/time-signal/display/wake", "画面を点灯しました。").catch((error) => showToast(error.message, true));
});
document.getElementById("display-off").addEventListener("click", () => {
    if (!confirm("2画面を消灯しますか？")) return;
    runSystemCommand("/time-signal/display/off", "画面を消灯しました。").catch((error) => showToast(error.message, true));
});
document.getElementById("restart-system").addEventListener("click", () => {
    if (!confirm("インフォメーションシステムを再起動しますか？")) return;
    runSystemCommand("/time-signal/system/restart", "再起動を開始しました。").catch((error) => showToast(error.message, true));
});
document.getElementById("apply-update").addEventListener("click", () => {
    uploadSystemUpdate().catch((error) => showToast(error.message, true));
});
document.getElementById("save-update-source-path").addEventListener("click", () => {
    try {
        saveUpdateSourcePath();
    } catch (error) {
        showToast(error.message, true);
    }
});
document.getElementById("update-file").addEventListener("change", (event) => {
    try {
        detectSelectedUpdateSourcePath(event.currentTarget);
        const entries = getSelectedUpdateFiles(event.currentTarget);
        const sourceSize = entries.reduce((total, entry) => total + entry.file.size, 0);
        document.getElementById("update-status").textContent =
            `${entries.length}ファイルを更新対象として選択しました（${Math.round(sourceSize / 1024 / 1024)}MB）。`;
    } catch (error) {
        document.getElementById("update-status").textContent = error.message;
        showToast(error.message, true);
    }
});
document.getElementById("load-network").addEventListener("click", loadNetworkHistory);
document.getElementById("log-type").addEventListener("change", () => {
    updateLogControls();
    loadNetworkHistory();
});

setDefaultExpiry();
applyUpdateSourcePath(getStoredUpdateSourcePath());
updateLogControls();
updateTimetableSectionOptions();
loadDisasterReference().catch((error) => showToast(`災害地点データを取得できません: ${error.message}`, true));
loadState();
loadTimeSignalStatus();
loadNetworkHistory();
