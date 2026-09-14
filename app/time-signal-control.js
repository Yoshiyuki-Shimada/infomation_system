(() => {
    const apiBase = "http://127.0.0.1:18765/time-signal";
    const button = document.getElementById("time-signal-toggle");
    const menu = document.getElementById("time-signal-menu");
    const statusElement = document.getElementById("time-signal-status");
    const displayPowerOffButton = document.getElementById("display-power-off-toggle");
    if (!button || !menu || !statusElement) return;

    const autoCloseMs = 60000;
    let paused = false;
    let disabled = false;
    let actionRunning = false;
    let intervalMinutes = 30;
    let autoCloseTimer = null;

    const quietControlResumeMinutes = 355;
    const morningSignalResumeMinutes = 360;

    function getMinutesOfDay(date) {
        return date.getHours() * 60 + date.getMinutes();
    }

    function isQuietHours(date = new Date()) {
        const minutes = getMinutesOfDay(date);
        return minutes >= 0 && minutes < quietControlResumeMinutes;
    }

    function formatUntil(value) {
        if (!value) return "";
        const date = new Date(value);
        if (Number.isNaN(date.getTime())) return "";
        return `${date.getHours()}:${String(date.getMinutes()).padStart(2, "0")}\u307e\u3067\u505c\u6b62\u4e2d`;
    }

    function formatResumeLabel(date) {
        return `${date.getHours()}:${String(date.getMinutes()).padStart(2, "0")}\uff5e`;
    }

    function getNextSignalTime(now = new Date(), interval = intervalMinutes) {
        const next = new Date(now);
        next.setSeconds(0, 0);
        const remainder = next.getMinutes() % interval;
        const addMinutes = remainder === 0 ? interval : interval - remainder;
        next.setMinutes(next.getMinutes() + addMinutes);
        return next;
    }
    function addMinutes(date, minutes) {
        const next = new Date(date);
        next.setMinutes(next.getMinutes() + minutes);
        return next;
    }

    function normalizeResumeOptionDate(date) {
        const minutes = getMinutesOfDay(date);
        if (minutes <= 0 || minutes >= morningSignalResumeMinutes) return date;

        const normalized = new Date(date);
        normalized.setHours(6, 0, 0, 0);
        return normalized;
    }

    function getResumeOptions(now = new Date()) {
        const base = getNextSignalTime(now, intervalMinutes);
        const offsets = intervalMinutes === 10
            ? [10, 20, 30, 40, 50, 60, 90, 120, 150, 180, 210, 240]
            : [30, 60, 90, 120, 150, 180, 210, 240, 270];
        const uniqueOptions = [];
        const seenUntilMs = new Set();

        offsets.forEach((offset) => {
            const normalizedDate = normalizeResumeOptionDate(addMinutes(base, offset));
            const untilMs = normalizedDate.getTime();
            if (seenUntilMs.has(untilMs)) return;

            seenUntilMs.add(untilMs);
            uniqueOptions.push({
                label: formatResumeLabel(normalizedDate),
                untilMs,
            });
        });

        return uniqueOptions;
    }
    async function callApi(path) {
        const response = await fetch(`${apiBase}${path}`, { cache: "no-store" });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
    }

    async function turnDisplayOff() {
        if (!displayPowerOffButton || displayPowerOffButton.disabled) return;

        const originalText = displayPowerOffButton.textContent;
        displayPowerOffButton.disabled = true;
        displayPowerOffButton.textContent = "消灯中";

        try {
            await callApi("/display/off");
            displayPowerOffButton.textContent = originalText;
        } catch {
            displayPowerOffButton.textContent = "消灯失敗";
            setTimeout(() => {
                displayPowerOffButton.textContent = originalText;
            }, 2500);
        } finally {
            setTimeout(() => {
                displayPowerOffButton.disabled = false;
            }, 1200);
        }
    }

    function clearAutoCloseTimer() {
        if (!autoCloseTimer) return;
        clearTimeout(autoCloseTimer);
        autoCloseTimer = null;
    }

    function closeMenu() {
        clearAutoCloseTimer();
        menu.hidden = true;
        document.body.classList.remove("time-signal-menu-open");
    }

    function resetAutoCloseTimer() {
        clearAutoCloseTimer();
        if (menu.hidden) return;
        autoCloseTimer = setTimeout(closeMenu, autoCloseMs);
    }

    function renderStatus(status) {
        disabled = Boolean(status.disabled) || isQuietHours();
        paused = Boolean(status.paused) && !disabled;
        intervalMinutes = Number(status.intervalMinutes) === 10 ? 10 : 30;
        actionRunning = false;
        closeMenu();
        button.disabled = disabled;
        button.textContent = "時報設定";
        document.body.classList.toggle("time-signal-paused", paused);
        document.body.classList.toggle("time-signal-disabled", disabled);

        if (disabled) {
            statusElement.textContent = "0:00～5:55は操作できません";
            return;
        }

        statusElement.textContent = paused
            ? formatUntil(status.until)
            : `時報有効　${intervalMinutes}分間隔で鳴ります。`;
    }
    async function refreshStatus() {
        try {
            const status = await callApi("/status");
            renderStatus(status);
        } catch {
            disabled = true;
            paused = false;
            actionRunning = false;
            button.disabled = true;
            button.textContent = "\u6642\u5831\u505c\u6b62";
            closeMenu();
            statusElement.textContent = "\u6642\u5831\u5236\u5fa1\u3092\u6e96\u5099\u4e2d";
        }
    }

    async function pauseUntil(option, optionButton) {
        if (actionRunning || disabled) return;

        actionRunning = true;
        optionButton.disabled = true;
        statusElement.textContent = "\u8a2d\u5b9a\u4e2d";

        try {
            const status = await callApi(`/pause?untilMs=${encodeURIComponent(option.untilMs)}`);
            renderStatus(status);
        } catch {
            actionRunning = false;
            optionButton.disabled = false;
            statusElement.textContent = "\u8a2d\u5b9a\u3067\u304d\u307e\u305b\u3093\u3067\u3057\u305f";
            resetAutoCloseTimer();
        }
    }

    function handleOptionPress(event, option, optionButton) {
        event.preventDefault();
        event.stopPropagation();
        resetAutoCloseTimer();
        pauseUntil(option, optionButton);
    }

    async function setIntervalMinutes(nextInterval, optionButton) {
        if (actionRunning || disabled) return;

        actionRunning = true;
        optionButton.disabled = true;
        try {
            const status = await callApi(`/interval?minutes=${nextInterval}`);
            renderStatus(status);
        } catch {
            actionRunning = false;
            optionButton.disabled = false;
            statusElement.textContent = "時報間隔を設定できませんでした";
        }
    }

    function buildMenu() {
        menu.innerHTML = "";

        const dialog = document.createElement("div");
        dialog.className = "time-signal-menu-dialog";

        const title = document.createElement("div");
        title.className = "time-signal-menu-title";
        title.textContent = "時報設定";
        dialog.appendChild(title);

        const intervalSection = document.createElement("section");
        intervalSection.className = "time-signal-menu-section";
        const intervalTitle = document.createElement("div");
        intervalTitle.className = "time-signal-menu-section-title";
        intervalTitle.textContent = "時報間隔";
        intervalSection.appendChild(intervalTitle);

        const intervalList = document.createElement("div");
        intervalList.className = "time-signal-option-list time-signal-interval-list";
        [30, 10].forEach((value) => {
            const optionButton = document.createElement("button");
            optionButton.type = "button";
            optionButton.className = "time-signal-option";
            if (value === intervalMinutes) optionButton.classList.add("selected");
            optionButton.textContent = `${value}分間隔`;
            optionButton.addEventListener("pointerdown", (event) => {
                event.preventDefault();
                event.stopPropagation();
                resetAutoCloseTimer();
                setIntervalMinutes(value, optionButton);
            });
            intervalList.appendChild(optionButton);
        });
        intervalSection.appendChild(intervalList);
        dialog.appendChild(intervalSection);

        const pauseSection = document.createElement("section");
        pauseSection.className = "time-signal-menu-section";
        const pauseTitle = document.createElement("div");
        pauseTitle.className = "time-signal-menu-section-title";
        pauseTitle.textContent = "時報停止（再開時刻）";
        pauseSection.appendChild(pauseTitle);
        const optionList = document.createElement("div");
        optionList.className = "time-signal-option-list";
        getResumeOptions().forEach((option) => {
            const optionButton = document.createElement("button");
            optionButton.type = "button";
            optionButton.className = "time-signal-option";
            optionButton.textContent = option.label;
            optionButton.disabled = paused;
            optionButton.addEventListener("pointerdown", (event) => handleOptionPress(event, option, optionButton));
            optionList.appendChild(optionButton);
        });
        pauseSection.appendChild(optionList);
        dialog.appendChild(pauseSection);

        menu.appendChild(dialog);
    }
    function openMenu() {
        buildMenu();
        menu.hidden = false;
        document.body.classList.add("time-signal-menu-open");
        resetAutoCloseTimer();
    }

    button.addEventListener("click", async () => {
        if (disabled || actionRunning) return;

        if (paused) {
            actionRunning = true;
            statusElement.textContent = "\u518d\u958b\u4e2d";

            try {
                const status = await callApi("/resume");
                renderStatus(status);
            } catch {
                actionRunning = false;
                statusElement.textContent = "\u518d\u958b\u3067\u304d\u307e\u305b\u3093\u3067\u3057\u305f";
            }
            return;
        }

        if (menu.hidden) {
            openMenu();
            return;
        }
        closeMenu();
    });

    if (displayPowerOffButton) {
        displayPowerOffButton.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            closeMenu();
            turnDisplayOff();
        });
    }

    menu.addEventListener("pointerdown", (event) => {
        resetAutoCloseTimer();
        if (event.target === menu) closeMenu();
    });

    document.addEventListener("keydown", (event) => {
        if (menu.hidden) return;
        resetAutoCloseTimer();
        if (event.key === "Escape") closeMenu();
    });

    refreshStatus();
    setInterval(refreshStatus, 30000);
})();