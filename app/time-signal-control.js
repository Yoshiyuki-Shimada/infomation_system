(() => {
    const apiBase = "http://127.0.0.1:18765/time-signal";
    const button = document.getElementById("time-signal-toggle");
    const menu = document.getElementById("time-signal-menu");
    const statusElement = document.getElementById("time-signal-status");
    if (!button || !menu || !statusElement) return;

    const autoCloseMs = 60000;
    let paused = false;
    let disabled = false;
    let actionRunning = false;
    let autoCloseTimer = null;

    function isQuietHours(date = new Date()) {
        const minutes = date.getHours() * 60 + date.getMinutes();
        return minutes >= 0 && minutes < 355;
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

    function getNextSignalTime(now = new Date()) {
        const next = new Date(now);
        next.setSeconds(0, 0);
        const remainder = next.getMinutes() % 10;
        const addMinutes = remainder === 0 ? 10 : 10 - remainder;
        next.setMinutes(next.getMinutes() + addMinutes);
        return next;
    }

    function getNextHalfHourAfter(date) {
        const next = new Date(date);
        next.setSeconds(0, 0);
        const minute = next.getMinutes();
        const addMinutes = minute < 30 ? 30 - minute : 60 - minute;
        next.setMinutes(minute + (addMinutes === 0 ? 30 : addMinutes));
        return next;
    }

    function addMinutes(date, minutes) {
        const next = new Date(date);
        next.setMinutes(next.getMinutes() + minutes);
        return next;
    }

    function getResumeOptions(now = new Date()) {
        const base = getNextSignalTime(now);
        const firstOptions = [10, 20, 30, 40, 50, 60].map((minutes) => addMinutes(base, minutes));
        const anchor = getNextHalfHourAfter(firstOptions[firstOptions.length - 1]);
        const anchorOptions = [0, 30, 60, 90, 120].map((minutes) => addMinutes(anchor, minutes));
        return firstOptions.concat(anchorOptions).map((date) => ({
            label: formatResumeLabel(date),
            untilMs: date.getTime(),
        }));
    }

    async function callApi(path) {
        const response = await fetch(`${apiBase}${path}`, { cache: "no-store" });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
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
        actionRunning = false;
        closeMenu();
        button.disabled = disabled;
        button.textContent = paused ? "\u6642\u5831\u518d\u958b" : "\u6642\u5831\u505c\u6b62";
        document.body.classList.toggle("time-signal-paused", paused);

        if (disabled) {
            statusElement.textContent = "0:00\u301c5:55\u306f\u64cd\u4f5c\u3067\u304d\u307e\u305b\u3093";
            return;
        }

        statusElement.textContent = paused ? formatUntil(status.until) : "\u6642\u5831\u306f\u901a\u5e38\u3069\u304a\u308a\u9cf4\u308a\u307e\u3059";
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

    function buildMenu() {
        menu.innerHTML = "";

        const dialog = document.createElement("div");
        dialog.className = "time-signal-menu-dialog";

        const title = document.createElement("div");
        title.className = "time-signal-menu-title";
        title.textContent = "\u6642\u5831\u518d\u958b\u6642\u523b\u3092\u9078\u629e";
        dialog.appendChild(title);

        const optionList = document.createElement("div");
        optionList.className = "time-signal-option-list";

        getResumeOptions().forEach((option) => {
            const optionButton = document.createElement("button");
            optionButton.type = "button";
            optionButton.className = "time-signal-option";
            optionButton.textContent = option.label;
            optionButton.addEventListener("pointerdown", (event) => handleOptionPress(event, option, optionButton));
            optionButton.addEventListener("click", (event) => handleOptionPress(event, option, optionButton));
            optionList.appendChild(optionButton);
        });

        dialog.appendChild(optionList);
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