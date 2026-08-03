(() => {
    const root = document.documentElement;
    const visibleClass = "signage-pointer-visible";
    const hiddenDelayMs = 3000;
    const moveThresholdPx = 3;
    let hideTimer = null;
    let lastMousePosition = null;

    function hidePointer() {
        root.classList.remove(visibleClass);
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

    function handlePointerMove(event) {
        if (event.pointerType && event.pointerType !== "mouse") return;
        if (!hasMouseReallyMoved(event)) return;
        showPointerTemporarily();
    }

    function handleMouseMove(event) {
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
    document.addEventListener("touchstart", preventPinchZoom, { passive: false });
    document.addEventListener("touchmove", preventPinchZoom, { passive: false });
    document.addEventListener("wheel", preventCtrlWheelZoom, { passive: false });
    hidePointer();
})();