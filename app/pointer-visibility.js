(() => {
    const root = document.documentElement;
    const visibleClass = "signage-pointer-visible";
    const hiddenDelayMs = 3000;
    const startupIgnoreMs = 5000;
    const moveThresholdPx = 3;
    const startedAt = Date.now();
    let hideTimer = null;
    let lastMousePosition = null;

    function hidePointer() {
        root.classList.remove(visibleClass);
        root.style.cursor = "none";
        if (document.body) document.body.style.cursor = "none";
        hideTimer = null;
    }

    function showPointerTemporarily() {
        root.classList.add(visibleClass);
        if (hideTimer) {
            clearTimeout(hideTimer);
        }
        hideTimer = setTimeout(hidePointer, hiddenDelayMs);
    }

    function hasMouseReallyMoved(event) {
        const current = { x: event.clientX, y: event.clientY };
        if (!lastMousePosition) {
            lastMousePosition = current;
            return false;
        }

        const dx = Math.abs(current.x - lastMousePosition.x);
        const dy = Math.abs(current.y - lastMousePosition.y);
        lastMousePosition = current;
        return dx >= moveThresholdPx || dy >= moveThresholdPx;
    }

    function shouldIgnoreStartupMove(event) {
        if (Date.now() - startedAt >= startupIgnoreMs) return false;
        lastMousePosition = { x: event.clientX, y: event.clientY };
        hidePointer();
        return true;
    }

    function handlePointerMove(event) {
        if (event.pointerType && event.pointerType !== "mouse") {
            hidePointer();
            return;
        }
        if (shouldIgnoreStartupMove(event)) return;
        if (!hasMouseReallyMoved(event)) return;
        showPointerTemporarily();
    }

    function handleMouseMove(event) {
        if (shouldIgnoreStartupMove(event)) return;
        if (!hasMouseReallyMoved(event)) return;
        showPointerTemporarily();
    }

    function preventPinchZoom(event) {
        if (event.touches && event.touches.length > 1) {
            event.preventDefault();
        }
    }

    function preventCtrlWheelZoom(event) {
        if (event.ctrlKey) {
            event.preventDefault();
        }
    }

    document.addEventListener("pointermove", handlePointerMove, {
        passive: true,
    });
    document.addEventListener("mousemove", handleMouseMove, { passive: true });
    document.addEventListener("pointerdown", hidePointer, {
        passive: true,
        capture: true,
    });
    document.addEventListener("touchstart", (event) => {
        hidePointer();
        preventPinchZoom(event);
    }, { passive: false, capture: true });
    document.addEventListener("touchmove", preventPinchZoom, { passive: false });
    document.addEventListener("wheel", preventCtrlWheelZoom, { passive: false });
    const startupHideTimer = setInterval(() => {
        hidePointer();
        if (Date.now() - startedAt >= startupIgnoreMs) {
            clearInterval(startupHideTimer);
        }
    }, 100);
    document.addEventListener("DOMContentLoaded", hidePointer, { once: true });
    window.addEventListener("load", hidePointer, { once: true });
    document.addEventListener("visibilitychange", () => {
        if (!document.hidden) hidePointer();
    });
    hidePointer();
})();
