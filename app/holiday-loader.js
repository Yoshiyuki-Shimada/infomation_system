const HOLIDAY_RELOAD_MS = 6 * 60 * 60 * 1000;

function getJapaneseHolidayMap() {
    return window.japaneseHolidayData?.holidays || {};
}

function reloadJapaneseHolidayData() {
    const oldScript = document.getElementById("japanese-holiday-data-script");
    if (oldScript) oldScript.remove();

    const script = document.createElement("script");
    script.id = "japanese-holiday-data-script";
    script.src = `temp/holidays.js?t=${Date.now()}`;
    script.onerror = () => script.remove();
    document.head.appendChild(script);
}

setInterval(reloadJapaneseHolidayData, HOLIDAY_RELOAD_MS);
