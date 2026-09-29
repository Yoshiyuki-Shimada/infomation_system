(() => {
    const apiBase = "http://127.0.0.1:18765/time-signal";
    const networkButton = document.getElementById("network-status-toggle");
    const restartButton = document.getElementById("system-restart-toggle");
    const networkModal = document.getElementById("network-dashboard-modal");
    const restartModal = document.getElementById("restart-confirm-modal");

    if (!networkButton || !restartButton || !networkModal || !restartModal) return;

    const restartAutoCloseMs = 60000;
    const defaultHistoryLimit = 500;
    const networkTargetDefinitions = [
        { id: "internet", name: "インターネット", address: "8.8.8.8" },
        { id: "gateway", name: "ローカルネットワーク（デフォルトゲートウェイ）", address: "-" },
        { id: "dns-default", name: "DNS名前解決（システム既定）", address: "google.com" },
        { id: "dns-google", name: "DNS名前解決（Google DNS）", address: "google.com / 8.8.8.8" },
        { id: "tcp-google-443", name: "TCP通信（443）", address: "www.google.com:443" },
        { id: "web-google", name: "Web通信（Google）", address: "https://www.google.com" },
        { id: "web-microsoft", name: "Web通信（Microsoft）", address: "https://www.microsoft.com" },
    ];
    let dashboardRefreshTimer = null;
    let restartAutoCloseTimer = null;
    const dashboardState = {
        summary: null,
        history: [],
        view: "summary",
        targetId: "internet",
        filter: "all",
        range: "30m",
        sortOrder: "desc",
        historyHasMore: false,
        loadingMore: false,
        customStart: null,
        customEnd: null,
        queryStartDate: null,
        queryEndDate: null,
        dateEditorOpen: false,
        dateEditorView: "range",
        dateActiveField: "start",
        dateDigits: {
            start: "",
            end: "",
        },
        dateValidationMessage: "",
        availableYears: [],
        loading: false,
        errorMessage: "",
        selectedRecord: null,
        dashboardErrorDetailOpen: false,
    };

    function escapeHtml(value) {
        return String(value ?? "")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
    }

    function formatDateTime(value) {
        if (!value) return "-";
        const date = new Date(value);
        if (Number.isNaN(date.getTime())) return "-";
        return `${date.getFullYear()}/${String(date.getMonth() + 1).padStart(2, "0")}/${String(date.getDate()).padStart(2, "0")} ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}:${String(date.getSeconds()).padStart(2, "0")}`;
    }

    function formatDate(value) {
        const date = new Date(value);
        if (Number.isNaN(date.getTime())) return "-";
        return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
    }

    function formatTime(value) {
        const date = new Date(value);
        if (Number.isNaN(date.getTime())) return "-";
        return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}:${String(date.getSeconds()).padStart(2, "0")}`;
    }

    function formatMs(value) {
        if (value === null || value === undefined || value === "") return "-";
        return `${Number(value)}ms`;
    }

    function formatPercent(value) {
        const number = Number(value || 0);
        return `${number.toFixed(1)}%`;
    }

    function isErrorResult(record) {
        return record.result !== "OK";
    }

    function getUniqueTargets(summary = dashboardState.summary) {
        const seenIds = new Set();
        const summaryTargets = Array.isArray(summary?.targets) ? summary.targets : [];
        const summaryById = new Map();

        summaryTargets.forEach((target) => {
            const targetId = String(target?.id || "");
            if (targetId && !summaryById.has(targetId)) summaryById.set(targetId, target);
        });

        const targets = networkTargetDefinitions.map((definition) => ({
            ...definition,
            ...(summaryById.get(definition.id) || {}),
        }));
        summaryTargets.forEach((target) => {
            const targetId = String(target?.id || "");
            if (targetId && !networkTargetDefinitions.some((definition) => definition.id === targetId)) {
                targets.push(target);
            }
        });

        return targets.filter((target) => {
            const targetId = String(target?.id || "");
            if (!targetId || seenIds.has(targetId)) return false;
            seenIds.add(targetId);
            return true;
        });
    }

    function getTarget(targetId) {
        const targets = getUniqueTargets();
        return targets.find((target) => target.id === targetId) || targets[0] || null;
    }

    function hasCommunicationError(summary) {
        const targets = getUniqueTargets(summary);
        return targets.some((target) => target.quality === "通信エラー");
    }

    function getStatusClass(summary) {
        if (summary?.offlineMode) return "is-offline";
        if (hasCommunicationError(summary)) return "is-error";
        return "is-online";
    }

    function dateToDigits(value) {
        const date = value ? new Date(value) : new Date();
        if (Number.isNaN(date.getTime())) return "";
        return `${date.getFullYear()}${String(date.getMonth() + 1).padStart(2, "0")}${String(date.getDate()).padStart(2, "0")}${String(date.getHours()).padStart(2, "0")}${String(date.getMinutes()).padStart(2, "0")}`;
    }

    function digitsToDate(value) {
        const digits = String(value || "").replace(/\D/g, "");
        if (digits.length !== 12) return null;

        const year = Number(digits.slice(0, 4));
        const month = Number(digits.slice(4, 6));
        const day = Number(digits.slice(6, 8));
        const hour = Number(digits.slice(8, 10));
        const minute = Number(digits.slice(10, 12));
        const date = new Date(year, month - 1, day, hour, minute, 0, 0);

        if (date.getFullYear() !== year) return null;
        if (date.getMonth() !== month - 1) return null;
        if (date.getDate() !== day) return null;
        if (date.getHours() !== hour) return null;
        if (date.getMinutes() !== minute) return null;
        return date;
    }

    function formatDigitsForDisplay(value) {
        const digits = String(value || "").replace(/\D/g, "");
        const segments = [
            digits.slice(0, 4),
            digits.slice(4, 6),
            digits.slice(6, 8),
            digits.slice(8, 10),
            digits.slice(10, 12),
        ];
        let text = segments[0];
        if (segments[1]) text += `/${segments[1]}`;
        if (segments[2]) text += `/${segments[2]}`;
        if (segments[3]) text += ` ${segments[3]}`;
        if (segments[4]) text += `:${segments[4]}`;
        return text || "数字で入力";
    }

    function getAvailableDateYears() {
        const years = dashboardState.availableYears
            .map((value) => Number(value))
            .filter((value) => Number.isInteger(value) && value > 0)
            .sort((left, right) => left - right);
        return [...new Set(years)];
    }

    function getNearestAvailableYear(year) {
        const years = getAvailableDateYears();
        if (years.length === 0 || years.includes(year)) return year;
        return years.reduce((nearest, candidate) =>
            Math.abs(candidate - year) < Math.abs(nearest - year)
                ? candidate
                : nearest,
        );
    }

    function getDateEditorParts(field) {
        const storedDate = digitsToDate(dashboardState.dateDigits[field]);
        const fallbackDate = field === "start"
            ? dashboardState.customStart
            : dashboardState.customEnd;
        const date = storedDate || fallbackDate || new Date();
        return {
            year: getNearestAvailableYear(date.getFullYear()),
            month: date.getMonth() + 1,
            day: date.getDate(),
            hour: date.getHours(),
            minute: date.getMinutes(),
        };
    }

    function setDateEditorParts(field, parts) {
        const lastDay = new Date(parts.year, parts.month, 0).getDate();
        const day = Math.min(parts.day, lastDay);
        dashboardState.dateDigits[field] = [
            String(parts.year).padStart(4, "0"),
            String(parts.month).padStart(2, "0"),
            String(day).padStart(2, "0"),
            String(parts.hour).padStart(2, "0"),
            String(parts.minute).padStart(2, "0"),
        ].join("");
    }

    function cycleDateValue(value, minimum, maximum, delta) {
        const size = maximum - minimum + 1;
        return ((value - minimum + delta) % size + size) % size + minimum;
    }

    function adjustDateEditorPart(part, delta) {
        const field = dashboardState.dateActiveField;
        const parts = getDateEditorParts(field);

        if (part === "year") {
            const years = getAvailableDateYears();
            if (years.length > 0) {
                const currentIndex = Math.max(0, years.indexOf(parts.year));
                const nextIndex = cycleDateValue(currentIndex, 0, years.length - 1, delta);
                parts.year = years[nextIndex];
            }
        }
        if (part === "month") parts.month = cycleDateValue(parts.month, 1, 12, delta);
        if (part === "day") {
            const lastDay = new Date(parts.year, parts.month, 0).getDate();
            parts.day = cycleDateValue(parts.day, 1, lastDay, delta);
        }
        if (part === "hour") parts.hour = cycleDateValue(parts.hour, 0, 23, delta);
        if (part === "minute") parts.minute = cycleDateValue(parts.minute, 0, 59, delta);

        setDateEditorParts(field, parts);
        dashboardState.dateValidationMessage = "";
        renderDashboard();
    }
    function formatDateTimeForQuery(value) {
        if (!(value instanceof Date) || Number.isNaN(value.getTime())) return "";
        return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}T${String(value.getHours()).padStart(2, "0")}:${String(value.getMinutes()).padStart(2, "0")}:00`;
    }

    function validateDateRangeDigits() {
        const startDigits = String(dashboardState.dateDigits.start || "").replace(/\D/g, "");
        const endDigits = String(dashboardState.dateDigits.end || "").replace(/\D/g, "");

        if (startDigits.length !== 12 || endDigits.length !== 12) {
            return { ok: false, message: "開始日時と終了日時を12桁で入力してください。" };
        }

        const startDate = digitsToDate(startDigits);
        const endDate = digitsToDate(endDigits);
        if (!startDate || !endDate) {
            return { ok: false, message: "実在する日付・時刻を入力してください。" };
        }
        const availableYears = getAvailableDateYears();
        if (availableYears.length === 0) {
            return { ok: false, message: "履歴データがないため、年を指定できません。" };
        }
        if (
            !availableYears.includes(startDate.getFullYear()) ||
            !availableYears.includes(endDate.getFullYear())
        ) {
            return { ok: false, message: "履歴データが存在する年を選択してください。" };
        }
        if (endDate < startDate) {
            return { ok: false, message: "終了日時は開始日時以降にしてください。" };
        }

        return { ok: true, startDate, endDate, message: "" };
    }

    function getClosedRelativeRange(minutes) {
        const now = new Date();
        const endDate = new Date(now.getTime() - 1000);
        const startDate = new Date(endDate.getTime() - minutes * 60 * 1000);
        return { startDate, endDate };
    }

    function getSelectedRangeDates() {
        if (dashboardState.range === "date") {
            return {
                startDate: dashboardState.customStart,
                endDate: dashboardState.customEnd,
            };
        }
        if (dashboardState.range === "1h") return getClosedRelativeRange(60);
        return getClosedRelativeRange(30);
    }

    function getRangeStartDate() {
        return getSelectedRangeDates().startDate;
    }

    function getRangeEndDate() {
        return getSelectedRangeDates().endDate;
    }

    function formatSampleHeaderLabel(baseCount) {
        return `直近${baseCount}回`;
    }

    function getSampleHeaderLabel(baseCount) {
        return formatSampleHeaderLabel(baseCount);
    }

    function formatMeasuredPercent(value, sampleCount, baseCount) {
        const count = Number(sampleCount || 0);
        if (count < baseCount) return "計測中";
        return formatPercent(value);
    }

    function formatQualityLabel(value, sampleCount) {
        if (value === "オフライン" || value === "通信エラー") return value;
        if (Number(sampleCount || 0) < 600) return "計測中";
        return value || "判定中";
    }

    function getWindowQuality(target, baseCount) {
        const sampleField = `loss${baseCount}SampleCount`;
        const lossField = `loss${baseCount}Percent`;
        const count = Number(target?.[sampleField] || 0);
        if (count < baseCount) return "計測中";
        const loss = Number(target?.[lossField] || 0);
        if (loss >= 10) return "通信が非常に不安定";
        if (loss >= 5) return "通信品質異常";
        if (loss >= 2) return "通信品質低下";
        if (loss >= 1) return "要観察";
        return "正常";
    }

    function getTargetPresentation(target) {
        const quality = formatQualityLabel(target?.quality, target?.loss600SampleCount);
        const longQualities = [
            target?.quality3600 || getWindowQuality(target, 3600),
            target?.quality21600 || getWindowQuality(target, 21600),
        ];
        const hasQualityHistory = quality === "正常" && longQualities.some((value) =>
            value !== "正常" && value !== "計測中",
        );

        if (quality === "オフライン") {
            return { type: "offline", label: quality, menuIcon: "off-line.png", centerIcon: "off-line.png" };
        }
        if (hasQualityHistory) {
            return { type: "history", label: "正常（品質低下履歴あり）", menuIcon: "verification.png", centerIcon: "verification.png" };
        }
        if (quality === "計測中") {
            return { type: "measuring", label: quality, menuIcon: "hourglass.png", centerIcon: "hourglass.png" };
        }
        if (quality === "正常") {
            return { type: "normal", label: quality, menuIcon: "internet_ok.png", centerIcon: "ok.png" };
        }
        return { type: "warning", label: quality, menuIcon: "caution.png", centerIcon: "caution.png" };
    }

    function formatCount(value) {
        return new Intl.NumberFormat("ja-JP").format(Number(value || 0));
    }

    function getMeasurementCount(target) {
        const explicitCount = Number(target?.measurementCount);
        if (Number.isFinite(explicitCount) && explicitCount > 0) return explicitCount;

        return Math.max(
            Number(target?.loss100SampleCount || 0),
            Number(target?.loss600SampleCount || 0),
            Number(target?.loss3600SampleCount || 0),
            Number(target?.loss21600SampleCount || 0),
        );
    }

    function getHistoryQuery(offset = 0, limit = defaultHistoryLimit) {
        const params = new URLSearchParams();
        params.set("limit", dashboardState.view === "detail" ? String(limit) : "20");

        if (dashboardState.view === "detail") {
            const startDate = getRangeStartDate();
            const endDate = getRangeEndDate();
            dashboardState.queryStartDate = startDate;
            dashboardState.queryEndDate = endDate;
            params.set("target", dashboardState.targetId);
            params.set("offset", String(Math.max(0, offset)));
            params.set("order", dashboardState.sortOrder);
            params.set("filter", dashboardState.filter);
            if (startDate instanceof Date && !Number.isNaN(startDate.getTime())) {
                params.set("start", formatDateTimeForQuery(startDate));
            }
            if (endDate instanceof Date && !Number.isNaN(endDate.getTime())) {
                params.set("end", formatDateTimeForQuery(endDate));
            }
        }

        return params.toString();
    }

    async function callApi(path) {
        const response = await fetch(`${apiBase}${path}`, { cache: "no-store" });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
    }

    async function loadNetworkStatus(options = {}) {
        const append = Boolean(options.append);
        const summaryOnly = Boolean(options.summaryOnly);
        if (summaryOnly) {
            const payload = await callApi("/network/status?summaryOnly=1");
            dashboardState.summary = payload.summary || null;
            return;
        }

        const offset = append ? dashboardState.history.length : 0;
        const limit = dashboardState.view === "detail" ? defaultHistoryLimit : 20;
        const payload = await callApi(`/network/status?${getHistoryQuery(offset, limit)}`);
        const rows = Array.isArray(payload.history) ? payload.history : (payload.history ? [payload.history] : []);

        dashboardState.summary = payload.summary || null;
        dashboardState.history = append ? dashboardState.history.concat(rows) : rows;
        dashboardState.historyHasMore = Boolean(payload.hasMore) && rows.length > 0;
        dashboardState.errorMessage = payload.historyError || "";
        dashboardState.availableYears = Array.isArray(payload.availableYears)
            ? payload.availableYears
            : [];
    }

    function filterHistory() {
        return dashboardState.history.filter((record) => {
            if (record.targetId !== dashboardState.targetId) return false;
            if (dashboardState.filter !== "all" && record.result !== dashboardState.filter) return false;
            return true;
        });
    }

    function buildStatusBadge(summary) {
        const statusText = summary?.offlineMode ? "オフライン" : (hasCommunicationError(summary) ? "通信エラー" : "オンライン");
        return `<div class="network-dashboard-status ${getStatusClass(summary)}"><span></span>${escapeHtml(statusText)}</div>`;
    }

    function buildTargetMenu(targets) {
        return targets.map((target) => {
            const presentation = getTargetPresentation(target);
            return `
                <button class="network-target-menu-item ${target.id === dashboardState.targetId ? "is-active" : ""}" type="button" data-action="target" data-target-id="${escapeHtml(target.id)}">
                    <img src="img/${escapeHtml(presentation.menuIcon)}" alt="">
                    <span><strong>${escapeHtml(target.name || target.id)}</strong><small>状態：<b class="is-${presentation.type}">${escapeHtml(presentation.label)}</b></small></span>
                </button>
            `;
        }).join("");
    }

    function buildLossRow(target, count) {
        const quality = getWindowQuality(target, count);
        const sampleCount = Number(target?.[`loss${count}SampleCount`] || 0);
        const value = sampleCount < count ? "" : formatPercent(target?.[`loss${count}Percent`]);
        const statusType = quality === "正常" ? "normal" : quality === "計測中" ? "measuring" : "warning";
        const icon = quality === "正常" ? "ok.png" : quality === "計測中" ? "hourglass.png" : "caution.png";
        return `
            <div class="network-loss-row">
                <span>直近</span><strong>${formatCount(count)}回</strong>
                <span>${escapeHtml(value)}</span>
                <b class="is-${statusType}"><img src="img/${icon}" alt="">${escapeHtml(quality)}</b>
            </div>
        `;
    }

    function buildSelectedTargetPanel(target) {
        if (!target) return `<section class="network-selected-panel"></section>`;
        const presentation = getTargetPresentation(target);
        return `
            <section class="network-selected-panel">
                <h3>${escapeHtml(target.name || target.id)}</h3>
                <div class="network-path-visual">
                    <img class="network-endpoint-image" src="img/computer.png" alt="コンピューター">
                    <div class="network-path-line"><img src="img/${escapeHtml(presentation.centerIcon)}" alt=""></div>
                    <img class="network-endpoint-image" src="img/network.png" alt="インターネット">
                </div>
                <div class="network-selected-status is-${presentation.type}">${escapeHtml(presentation.label)}</div>
                <div class="network-summary-section-title">対象</div>
                <div class="network-selected-address">${escapeHtml(target.address || "-")}</div>
                <div class="network-summary-section-title">直近状況</div>
                <dl class="network-summary-metrics network-selected-metrics">
                    <dt>結果</dt><dd>${escapeHtml(target.result || "-")}</dd>
                    <dt>応答時間</dt><dd>${escapeHtml(formatMs(target.responseTimeMs))}</dd>
                    <dt>連続失敗</dt><dd>${formatCount(target.consecutiveFailures)} 回</dd>
                    <dt>累計検証回数</dt><dd>${formatCount(getMeasurementCount(target))} 回</dd>
                </dl>
                <div class="network-summary-section-title">パケットロス率</div>
                <div class="network-loss-list">
                    ${buildLossRow(target, 100)}
                    ${buildLossRow(target, 600)}
                    ${buildLossRow(target, 3600)}
                    ${buildLossRow(target, 21600)}
                </div>
                <button class="network-card-detail" type="button" data-action="detail" data-target-id="${escapeHtml(target.id)}">詳細ログ確認</button>
            </section>
        `;
    }

    function buildOperationsPanel(summary) {
        const updates = summary?.dataUpdates || [];
        const items = updates.map((item) => `
            <div class="network-data-update-item">
                <div>${escapeHtml(item.name)}</div>
                <dl>
                    <dt>更新間隔</dt><dd>${escapeHtml(item.updateInterval || "-")}</dd>
                    <dt>最終更新</dt><dd>${escapeHtml(item.lastUpdated || "-")}</dd>
                </dl>
            </div>
        `).join("");
        const today = summary?.today || {};
        const errorPanel = dashboardState.errorMessage ? `
            <div class="network-summary-section-title">通信状況取得エラー表示</div>
            <div class="network-summary-error-box">${escapeHtml(dashboardState.errorMessage)}</div>
            <button class="network-card-detail" type="button" data-action="dashboard-error-detail">詳細ログ確認</button>
        ` : "";

        return `
            <section class="network-operations-panel">
                <div class="network-summary-section-title">データ更新時刻</div>
                ${items}
                <div class="network-summary-section-title">本日の通信状況</div>
                <dl class="network-summary-metrics">
                    <dt>オフライン回数</dt><dd>${escapeHtml(today.offlineCount || 0)} 回</dd>
                    <dt>最大連続ロス</dt><dd>${escapeHtml(today.maxConsecutiveLoss || 0)} 回</dd>
                    <dt>累計オフライン</dt><dd>${escapeHtml(today.totalOfflineSeconds || 0)} 秒</dd>
                    <dt>最終ロス</dt><dd>${escapeHtml(formatDateTime(today.lastLossAt))}</dd>
                </dl>
                <div class="network-summary-section-title">最終再起動日時</div>
                <dl class="network-summary-metrics">
                    <dt>最終再起動</dt><dd>${escapeHtml(formatDateTime(summary?.lastBootTime || summary?.monitorStartedAt))}</dd>
                </dl>
                ${errorPanel}
            </section>
        `;
    }

    function renderSummaryView() {
        const summary = dashboardState.summary;
        const targets = getUniqueTargets(summary);
        const selectedTarget = getTarget(dashboardState.targetId);
        const updatedAt = formatDateTime(summary?.updateTime);

        networkModal.innerHTML = `
            <div class="network-modal-backdrop" data-action="close"></div>
            <div class="network-modal-dialog" role="dialog" aria-modal="true" aria-label="通信状況表示ダッシュボード">
                <div class="network-modal-title">通信状況表示ダッシュボード</div>
                <div class="network-modal-header-row">
                    ${buildStatusBadge(summary)}
                    <div class="network-last-updated">最終更新 ${escapeHtml(updatedAt)}</div>
                </div>
                <div class="network-dashboard-layout">
                    <nav class="network-target-menu">${buildTargetMenu(targets)}</nav>
                    ${buildSelectedTargetPanel(selectedTarget)}
                    ${buildOperationsPanel(summary)}
                </div>
                <div class="network-modal-actions">
                    <button class="network-secondary-button" type="button" data-action="close">閉じる</button>
                </div>
                ${buildErrorDetailModal()}
            </div>
        `;
    }

    function buildTargetTabs() {
        const targets = getUniqueTargets();
        const labels = {
            internet: "Ping 8.8.8.8",
            gateway: "デフォルトゲートウェイ",
            "dns-default": "nslookup（既定DNS）",
            "dns-google": "nslookup（8.8.8.8）",
            "tcp-google-443": "TCP（443）",
            "web-google": "Web（Google）",
            "web-microsoft": "Web（Microsoft）",
        };
        return targets.map((target) => `
            <button class="network-tab ${target.id === dashboardState.targetId ? "is-active" : ""}" type="button" data-action="target" data-target-id="${escapeHtml(target.id)}">
                ${escapeHtml(labels[target.id] || target.name || target.id)}
            </button>
        `).join("");
    }

    function buildFilterButtons() {
        const filters = [
            ["all", "全て"],
            ["タイムアウト", "タイムアウト"],
            ["オフライン", "オフライン"],
            ["宛先到達不能", "宛先到達不能"],
            ["一般エラー", "一般エラー"],
            ["その他エラー", "その他エラー"],
        ];
        return filters.map(([value, label]) => `
            <button class="network-filter ${dashboardState.filter === value ? "is-active" : ""}" type="button" data-action="filter" data-filter="${escapeHtml(value)}">${escapeHtml(label)}</button>
        `).join("");
    }

    function buildRangeButtons() {
        const ranges = [["30m", "直近30分"], ["1h", "直近1時間"], ["date", "日時指定"]];
        return ranges.map(([value, label]) => `
            <button class="network-range ${dashboardState.range === value ? "is-active" : ""}" type="button" data-action="range" data-range="${escapeHtml(value)}">${escapeHtml(label)}</button>
        `).join("");
    }

    function buildSortButtons() {
        const sorts = [["desc", "降順"], ["asc", "昇順"]];
        return sorts.map(([value, label]) => `
            <button class="network-sort ${dashboardState.sortOrder === value ? "is-active" : ""}" type="button" data-action="sort" data-order="${escapeHtml(value)}">${escapeHtml(label)}</button>
        `).join("");
    }

    function getRecordKey(record) {
        return `${record.targetId || ""}|${record.timestamp || ""}|${record.result || ""}|${record.consecutiveFailures || 0}`;
    }

    function formatRecordLossPercent(record, fieldName, sampleFieldName, baseCount) {
        if (record.quality === "オフライン") return "-";
        return formatMeasuredPercent(record[fieldName], record[sampleFieldName], baseCount);
    }

    function buildHistoryRows(records) {
        if (dashboardState.loading) {
            return `<tr><td colspan="11" class="network-empty-row">通信履歴を取得しています</td></tr>`;
        }
        if (records.length === 0) {
            return `<tr><td colspan="11" class="network-empty-row">表示できる測定結果がありません</td></tr>`;
        }

        return records.map((record) => `
            <tr class="${isErrorResult(record) ? "has-error" : ""}">
                <td>${escapeHtml(formatDate(record.timestamp))}</td>
                <td>${escapeHtml(formatTime(record.timestamp))}</td>
                <td>${escapeHtml(record.result || "-")}</td>
                <td>${escapeHtml(formatMs(record.responseTimeMs))}</td>
                <td>${escapeHtml(record.consecutiveFailures || 0)}</td>
                <td>${escapeHtml(formatRecordLossPercent(record, "loss100Percent", "loss100SampleCount", 100))}</td>
                <td>${escapeHtml(formatRecordLossPercent(record, "loss600Percent", "loss600SampleCount", 600))}</td>
                <td>${escapeHtml(formatRecordLossPercent(record, "loss3600Percent", "loss3600SampleCount", 3600))}</td>
                <td>${escapeHtml(formatRecordLossPercent(record, "loss21600Percent", "loss21600SampleCount", 21600))}</td>
                <td>${escapeHtml(formatQualityLabel(record.quality, record.loss600SampleCount))}</td>
                <td><button class="network-detail-button" type="button" data-action="error-detail" data-record-key="${escapeHtml(getRecordKey(record))}">詳細</button></td>
            </tr>
        `).join("");
    }

    function getTargetPeriodText() {
        const startDate = dashboardState.queryStartDate || getSelectedRangeDates().startDate;
        const endDate = dashboardState.queryEndDate || getSelectedRangeDates().endDate;
        if (!startDate && !endDate) return "-";
        return `${formatDateTime(startDate)} - ${formatDateTime(endDate)}`;
    }

    function renderDetailView() {
        const summary = dashboardState.summary;
        const target = getTarget(dashboardState.targetId);
        const records = filterHistory();
        const errorHtml = dashboardState.errorMessage
            ? `<div class="network-dashboard-error">通信状況を取得できませんでした。${escapeHtml(dashboardState.errorMessage)}</div>`
            : "";

        networkModal.innerHTML = `
            <div class="network-modal-backdrop" data-action="close"></div>
            <div class="network-modal-dialog network-detail-dialog" role="dialog" aria-modal="true" aria-label="通信状況詳細">
                <div class="network-modal-title">通信状況表示ダッシュボード</div>
                ${errorHtml}
                <div class="network-modal-header-row">
                    ${buildStatusBadge(summary)}
                    <div class="network-last-updated">最終更新 ${escapeHtml(formatDateTime(summary?.updateTime))}</div>
                </div>
                <div class="network-detail-tabs">${buildTargetTabs()}</div>
                <div class="network-detail-body">
                    <div class="network-detail-info">
                        <div>対象：${escapeHtml(target?.address || "-")}</div>
                        <div>対象期間：${escapeHtml(getTargetPeriodText())}</div>
                        <div>表示件数：${escapeHtml(records.length)} 件</div>
                    </div>
                    <div class="network-detail-controls">
                        <div class="network-sort-group">${buildSortButtons()}</div>
                        <div class="network-range-group">${buildRangeButtons()}</div>
                        <div class="network-filter-group">${buildFilterButtons()}</div>
                    </div>
                    <div class="network-history-table-wrap">
                        <table class="network-history-table">
                            <thead>
                                <tr>
                                    <th>日付</th><th>時刻</th><th>結果</th><th>応答時間</th><th>連続失敗</th><th>${escapeHtml(getSampleHeaderLabel(100))}のロス率</th><th>${escapeHtml(getSampleHeaderLabel(600))}のロス率</th><th>${escapeHtml(getSampleHeaderLabel(3600))}のロス率</th><th>${escapeHtml(getSampleHeaderLabel(21600))}のロス率</th><th>判定</th><th>詳細</th>
                                </tr>
                            </thead>
                            <tbody>${buildHistoryRows(records)}${dashboardState.loadingMore ? `<tr><td colspan="11" class="network-empty-row">追加の通信履歴を取得しています</td></tr>` : ""}</tbody>
                        </table>
                    </div>
                </div>
                <div class="network-modal-actions">
                    <button class="network-back-button" type="button" data-action="summary">戻る</button>
                    <button class="network-secondary-button" type="button" data-action="close">閉じる</button>
                </div>
            </div>
            ${buildDateRangeEditor()}
            ${buildErrorDetailModal()}
        `;
    }

    function buildDateStepperEditor() {
        const field = dashboardState.dateActiveField;
        const parts = getDateEditorParts(field);
        const fields = [
            ["year", parts.year, "年", 4],
            ["month", parts.month, "月", 2],
            ["day", parts.day, "日", 2],
            ["hour", parts.hour, "時", 2],
            ["minute", parts.minute, "分", 2],
        ];
        const columns = fields.map(([part, value, label, digits]) => `
            <div class="network-date-stepper-column ${part === "year" ? "is-year" : ""}">
                <button type="button" data-action="date-adjust" data-part="${part}" data-delta="1" aria-label="${label}を1増やす" ${part === "year" && getAvailableDateYears().length === 0 ? "disabled" : ""}>＋</button>
                <div class="network-date-stepper-value">
                    <strong>${escapeHtml(String(value).padStart(digits, "0"))}</strong>
                    <span>${label}</span>
                </div>
                <button type="button" data-action="date-adjust" data-part="${part}" data-delta="-1" aria-label="${label}を1減らす" ${part === "year" && getAvailableDateYears().length === 0 ? "disabled" : ""}>－</button>
            </div>
        `).join("");
        const otherField = field === "start" ? "end" : "start";
        const otherLabel = field === "start" ? "終了日時の指定" : "開始日時の指定";

        return `
            <div class="network-date-modal-title">${field === "start" ? "開始日時" : "終了日時"}の入力</div>
            <div class="network-date-stepper-grid">${columns}</div>
            <div class="network-date-year-help">年は履歴データが存在する年だけ選択できます。</div>
            ${dashboardState.dateValidationMessage ? `<div class="network-date-error">${escapeHtml(dashboardState.dateValidationMessage)}</div>` : ""}
            <div class="network-date-modal-actions">
                <button class="network-date-apply" type="button" data-action="date-stepper-confirm">確定</button>
                <button class="network-date-switch" type="button" data-action="date-switch-field" data-field="${otherField}">${otherLabel}</button>
            </div>
        `;
    }

    function buildDateRangeEditor() {
        if (!dashboardState.dateEditorOpen) return "";
        const activeField = dashboardState.dateActiveField;
        const content = dashboardState.dateEditorView === "stepper"
            ? buildDateStepperEditor()
            : `
                <div class="network-date-modal-title">対象期間を設定</div>
                <div class="network-date-field-grid">
                    <button class="network-date-field ${activeField === "start" ? "is-active" : ""}" type="button" data-action="date-field" data-field="start">
                        <span>開始日時</span><strong>${escapeHtml(formatDigitsForDisplay(dashboardState.dateDigits.start))}</strong>
                    </button>
                    <button class="network-date-field ${activeField === "end" ? "is-active" : ""}" type="button" data-action="date-field" data-field="end">
                        <span>終了日時</span><strong>${escapeHtml(formatDigitsForDisplay(dashboardState.dateDigits.end))}</strong>
                    </button>
                </div>
                ${dashboardState.dateValidationMessage ? `<div class="network-date-error">${escapeHtml(dashboardState.dateValidationMessage)}</div>` : ""}
                <div class="network-date-modal-actions">
                    <button class="network-date-apply" type="button" data-action="apply-date-range">適用</button>
                    <button class="network-date-cancel" type="button" data-action="close-date-editor">閉じる</button>
                </div>
            `;

        return `
            <div class="network-date-modal-backdrop" data-action="close-date-editor"></div>
            <div class="network-date-modal-dialog ${dashboardState.dateEditorView === "stepper" ? "is-stepper" : ""}" role="dialog" aria-modal="true" aria-label="日時指定">
                ${content}
            </div>
        `;
    }
    function buildErrorDetailModal() {
        const record = dashboardState.selectedRecord;
        if (dashboardState.dashboardErrorDetailOpen && dashboardState.errorMessage) {
            return `
                <div class="network-error-detail-backdrop" data-action="close-error-detail"></div>
                <div class="network-error-detail-dialog" role="dialog" aria-modal="true" aria-label="通信状況取得エラー詳細">
                    <div class="network-error-detail-title">通信状況取得エラー</div>
                    <pre>${escapeHtml(dashboardState.errorMessage)}</pre>
                </div>
            `;
        }
        if (!record) return "";
        const detailTitle = record.result === "OK" ? "応答内容" : "エラー内容";

        return `
            <div class="network-error-detail-backdrop" data-action="close-error-detail"></div>
            <div class="network-error-detail-dialog" role="dialog" aria-modal="true" aria-label="通信エラー詳細">
                <div>IP：${escapeHtml(record.address || "-")}</div>
                <div>日付　${escapeHtml(formatDate(record.timestamp))}</div>
                <div>時刻　${escapeHtml(formatTime(record.timestamp))}</div>
                <div>結果　${escapeHtml(record.result || "-")}</div>
                <div class="network-error-detail-title">${detailTitle}</div>
                <pre>${escapeHtml(record.errorDetail || "詳細情報はありません。")}</pre>
            </div>
        `;
    }

    function renderDashboard() {
        if (dashboardState.view === "detail") {
            renderDetailView();
        } else {
            renderSummaryView();
        }
    }
    function getHistoryScrollTop() {
        const tableWrap = networkModal.querySelector(".network-history-table-wrap");
        return tableWrap ? tableWrap.scrollTop : 0;
    }

    function restoreHistoryScrollTop(scrollTop) {
        requestAnimationFrame(() => {
            const tableWrap = networkModal.querySelector(".network-history-table-wrap");
            if (tableWrap) tableWrap.scrollTop = scrollTop;
        });
    }

    function renderDashboardPreservingHistoryScroll() {
        const scrollTop = getHistoryScrollTop();
        renderDashboard();
        restoreHistoryScrollTop(scrollTop);
    }

    async function refreshDashboard(options = {}) {
        if (dashboardState.dateEditorOpen && !options.force) return;
        if (dashboardState.view === "detail" && !options.force) return;

        try {
            dashboardState.loading = dashboardState.view === "detail" && options.force;
            if (dashboardState.loading && !networkModal.hidden) renderDashboard();
            await loadNetworkStatus({
                append: false,
                summaryOnly: dashboardState.view === "summary",
            });
            dashboardState.loading = false;
            if (!networkModal.hidden) renderDashboard();
        } catch (error) {
            dashboardState.loading = false;
            dashboardState.errorMessage = error.message;
            if (!networkModal.hidden) renderDashboard();
        }
    }
    async function loadMoreHistory() {
        if (dashboardState.view !== "detail") return;
        if (dashboardState.loading || dashboardState.loadingMore) return;
        if (!dashboardState.historyHasMore) return;

        const tableWrap = networkModal.querySelector(".network-history-table-wrap");
        const previousScrollTop = tableWrap ? tableWrap.scrollTop : 0;
        dashboardState.loadingMore = true;
        try {
            await loadNetworkStatus({ append: true });
        } catch (error) {
            dashboardState.errorMessage = error.message;
        } finally {
            dashboardState.loadingMore = false;
            renderDashboard();
            const nextTableWrap = networkModal.querySelector(".network-history-table-wrap");
            if (nextTableWrap) nextTableWrap.scrollTop = previousScrollTop;
        }
    }

    function resetHistoryAndRefresh() {
        dashboardState.history = [];
        dashboardState.historyHasMore = false;
        dashboardState.loadingMore = false;
        refreshDashboard({ force: true });
    }

    function handleHistoryScroll(event) {
        const target = event.target;
        if (!(target instanceof Element)) return;
        if (!target.classList.contains("network-history-table-wrap")) return;

        const remaining = target.scrollHeight - target.scrollTop - target.clientHeight;
        if (remaining <= 80) loadMoreHistory();
    }

    function openDashboard() {
        dashboardState.view = "summary";
        dashboardState.dateEditorOpen = false;
        dashboardState.selectedRecord = null;
        networkModal.hidden = false;
        refreshDashboard({ force: true });
        if (dashboardRefreshTimer) clearInterval(dashboardRefreshTimer);
        dashboardRefreshTimer = setInterval(() => refreshDashboard(), 1000);
    }

    function closeDashboard() {
        networkModal.hidden = true;
        networkModal.innerHTML = "";
        if (dashboardRefreshTimer) {
            clearInterval(dashboardRefreshTimer);
            dashboardRefreshTimer = null;
        }
    }

    function openRestartConfirm() {
        restartModal.hidden = false;
        restartModal.innerHTML = `
            <div class="restart-modal-backdrop" data-action="close-restart"></div>
            <div class="restart-modal-dialog" role="dialog" aria-modal="true" aria-label="再起動確認">
                <div class="restart-modal-title">再起動しますか？</div>
                <div class="restart-modal-text">はいを押すと、この端末を再起動します。</div>
                <div class="restart-modal-actions">
                    <button class="restart-yes-button" type="button" data-action="restart-yes">はい</button>
                    <button class="restart-no-button" type="button" data-action="close-restart">いいえ</button>
                </div>
            </div>
        `;
        if (restartAutoCloseTimer) clearTimeout(restartAutoCloseTimer);
        restartAutoCloseTimer = setTimeout(closeRestartConfirm, restartAutoCloseMs);
    }

    function closeRestartConfirm() {
        restartModal.hidden = true;
        restartModal.innerHTML = "";
        if (restartAutoCloseTimer) {
            clearTimeout(restartAutoCloseTimer);
            restartAutoCloseTimer = null;
        }
    }

    async function restartSystem() {
        try {
            await callApi("/system/restart");
            restartModal.querySelector(".restart-modal-text").textContent = "再起動指示を送信しました。";
        } catch {
            restartModal.querySelector(".restart-modal-text").textContent = "再起動指示を送信できませんでした。";
        }
    }

    function openDetail(targetId) {
        dashboardState.targetId = targetId || dashboardState.targetId;
        dashboardState.view = "detail";
        dashboardState.selectedRecord = null;
        dashboardState.dateEditorOpen = false;
        dashboardState.history = [];
        dashboardState.historyHasMore = false;
        refreshDashboard({ force: true });
    }

    function applyDateRange() {
        const validation = validateDateRangeDigits();
        if (!validation.ok) {
            dashboardState.dateValidationMessage = validation.message;
            renderDashboard();
            return;
        }

        dashboardState.customStart = validation.startDate;
        dashboardState.customEnd = validation.endDate;
        dashboardState.range = "date";
        dashboardState.selectedRecord = null;
        dashboardState.dateEditorOpen = false;
        dashboardState.dateEditorView = "range";
        dashboardState.dateValidationMessage = "";
        resetHistoryAndRefresh();
    }

    function openDateStepper(field) {
        dashboardState.dateActiveField = field === "end" ? "end" : "start";
        const parts = getDateEditorParts(dashboardState.dateActiveField);
        setDateEditorParts(dashboardState.dateActiveField, parts);
        dashboardState.dateEditorView = "stepper";
        dashboardState.dateValidationMessage = "";
        renderDashboard();
    }

    function showDateRangeSummary() {
        dashboardState.dateEditorView = "range";
        dashboardState.dateValidationMessage = "";
        renderDashboard();
    }
    networkButton.addEventListener("click", openDashboard);
    restartButton.addEventListener("click", openRestartConfirm);

    networkModal.addEventListener("scroll", handleHistoryScroll, true);

    networkModal.addEventListener("click", (event) => {
        if (!(event.target instanceof Element)) return;
        const actionElement = event.target.closest("[data-action]");
        if (!actionElement) return;

        const action = actionElement.dataset.action;
        if (action === "close") closeDashboard();
        if (action === "summary") {
            dashboardState.view = "summary";
            dashboardState.dateEditorOpen = false;
            dashboardState.selectedRecord = null;
            dashboardState.dashboardErrorDetailOpen = false;
            resetHistoryAndRefresh();
        }
        if (action === "detail") openDetail(actionElement.dataset.targetId);
        if (action === "target") {
            dashboardState.targetId = actionElement.dataset.targetId || dashboardState.targetId;
            dashboardState.selectedRecord = null;
            dashboardState.dashboardErrorDetailOpen = false;
            resetHistoryAndRefresh();
        }
        if (action === "filter") {
            dashboardState.filter = actionElement.dataset.filter || "all";
            dashboardState.selectedRecord = null;
            resetHistoryAndRefresh();
        }
        if (action === "sort") {
            dashboardState.sortOrder = actionElement.dataset.order === "asc" ? "asc" : "desc";
            dashboardState.selectedRecord = null;
            resetHistoryAndRefresh();
        }
        if (action === "range") {
            const range = actionElement.dataset.range || "30m";
            dashboardState.selectedRecord = null;
            if (range === "date") {
                const now = new Date();
                dashboardState.dateDigits.start = dateToDigits(dashboardState.customStart || new Date(now.getTime() - 30 * 60 * 1000));
                dashboardState.dateDigits.end = dateToDigits(dashboardState.customEnd || now);
                dashboardState.dateActiveField = "start";
                dashboardState.dateEditorView = "range";
                dashboardState.dateValidationMessage = "";
                dashboardState.dateEditorOpen = true;
                renderDashboard();
                return;
            }
            dashboardState.range = range;
            dashboardState.dateEditorOpen = false;
            resetHistoryAndRefresh();
        }
        if (action === "error-detail") {
            const recordKey = actionElement.dataset.recordKey || "";
            dashboardState.selectedRecord = filterHistory().find((record) => getRecordKey(record) === recordKey) || null;
            renderDashboardPreservingHistoryScroll();
        }
        if (action === "dashboard-error-detail") {
            dashboardState.dashboardErrorDetailOpen = true;
            renderDashboard();
        }
        if (action === "close-error-detail") {
            dashboardState.selectedRecord = null;
            dashboardState.dashboardErrorDetailOpen = false;
            renderDashboardPreservingHistoryScroll();
        }
        if (action === "date-field") {
            openDateStepper(actionElement.dataset.field || "start");
        }
        if (action === "date-adjust") {
            const delta = Number(actionElement.dataset.delta) < 0 ? -1 : 1;
            adjustDateEditorPart(actionElement.dataset.part || "", delta);
        }
        if (action === "date-stepper-confirm") showDateRangeSummary();
        if (action === "date-switch-field") {
            openDateStepper(actionElement.dataset.field || "start");
        }
        if (action === "close-date-editor") {
            dashboardState.dateEditorOpen = false;
            dashboardState.dateEditorView = "range";
            dashboardState.dateValidationMessage = "";
            renderDashboard();
        }
        if (action === "apply-date-range") applyDateRange();
    });

    restartModal.addEventListener("click", (event) => {
        if (!(event.target instanceof Element)) return;
        const actionElement = event.target.closest("[data-action]");
        if (!actionElement) return;

        const action = actionElement.dataset.action;
        if (action === "close-restart") closeRestartConfirm();
        if (action === "restart-yes") restartSystem();
    });
})();
