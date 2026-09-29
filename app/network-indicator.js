(() => {
    const apiUrl =
        "http://127.0.0.1:18765/time-signal/network/status?summaryOnly=1";
    const icon = document.getElementById("network-health-icon");
    const header = document.getElementById("signage-header");
    const idleView = document.getElementById("idle-view");

    if (!icon || !header || !idleView) return;

    let displayedState = "measuring";
    let candidateState = "";
    let candidateCount = 0;
    let consecutiveRequestFailures = 0;

    const qualityPriority = {
        "正常": 0,
        "計測中": 1,
        "要観察": 2,
        "通信品質低下": 3,
        "通信品質異常": 4,
        "通信が非常に不安定": 5,
        "通信エラー": 6,
        "オフライン": 7,
    };

    function isFallbackClockVisible() {
        return (
            window.getComputedStyle(header).display === "none" ||
            window.getComputedStyle(idleView).display !== "none"
        );
    }

    function getNetworkIndicatorState(summary) {
        if (summary?.offlineMode || !summary?.linkStatus?.connected) {
            return "caution";
        }

        const targets = Array.isArray(summary?.targets)
            ? summary.targets
            : [];
        const qualities = targets
            .map((target) => target?.quality)
            .filter((quality) => quality in qualityPriority);

        if (qualities.length === 0) return null;

        const worstPriority = Math.max(
            ...qualities.map((quality) => qualityPriority[quality]),
        );
        if (worstPriority >= qualityPriority["要観察"]) return "caution";
        if (worstPriority === qualityPriority["計測中"]) return "measuring";
        return "ok";
    }

    function updateIconVisibility() {
        icon.hidden = isFallbackClockVisible();
    }

    function displayNetworkState(state) {
        const display = {
            ok: { src: "img/internet_ok.png", alt: "通信正常" },
            measuring: { src: "img/hourglass.png", alt: "通信品質計測中" },
            caution: { src: "img/caution.png", alt: "通信注意" },
        }[state];
        if (!display) return;
        displayedState = state;
        icon.src = display.src;
        icon.alt = display.alt;
    }

    function acceptNetworkState(state) {
        if (!state || state === displayedState) {
            candidateState = "";
            candidateCount = 0;
            return;
        }

        if (candidateState !== state) {
            candidateState = state;
            candidateCount = 0;
        }
        candidateCount += 1;
        const requiredCount = state === "caution" ? 3 : 2;
        if (candidateCount >= requiredCount) {
            displayNetworkState(state);
            candidateState = "";
            candidateCount = 0;
        }
    }

    async function refreshNetworkIndicator() {
        try {
            const response = await fetch(apiUrl, { cache: "no-store" });
            if (!response.ok) throw new Error("HTTP " + response.status);

            const payload = await response.json();
            const state = getNetworkIndicatorState(payload.summary);
            consecutiveRequestFailures = 0;
            acceptNetworkState(state);
        } catch (error) {
            consecutiveRequestFailures += 1;
            if (consecutiveRequestFailures >= 10) {
                acceptNetworkState("caution");
            }
            console.warn("通信状況アイコンの更新に失敗しました。", error);
        }

        updateIconVisibility();
    }

    displayNetworkState(displayedState);
    refreshNetworkIndicator();
    setInterval(refreshNetworkIndicator, 1000);
})();
