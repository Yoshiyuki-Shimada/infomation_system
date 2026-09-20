function updateScheduleStatusIcon() {
    const icon = document.getElementById("schedule-status-icon");
    if (!icon) return;

    const schedule = window.signageData?.calendarSchedule;
    if (!schedule || schedule.status !== "ok") {
        icon.hidden = true;
        return;
    }

    icon.hidden = false;
    icon.src = schedule.hasConflict
        ? "img/schedule/schedule_warning.png"
        : "img/schedule/schedule_ok.png";
    icon.alt = schedule.hasConflict ? "予定の重複あり" : "予定の重複なし";
}

// 1秒ごとの時計/バス更新
scheduleLoadPromise
    .then(() => {
        refresh();
        updateScheduleStatusIcon();
        setInterval(refresh, 1000);
        setInterval(updateScheduleStatusIcon, 1000);
    })
    .catch((error) => {
        console.error(error);
        const debugMode = document.getElementById("debug-mode");

        if (debugMode) {
            debugMode.textContent = "● ダイヤデータ読み込み失敗";
        }
    });

// スライド切り替えは、各スライドの表示時間に合わせて showSlide 側で予約します

// 1秒ごとにデータ再取得実行
setInterval(fetchNewData, 1000);

// 初回起動
window.onload = () => {
    updateSignage();
};

//モニターがTVのときのCSS読み込み
const link = document.createElement("link");
link.rel = "stylesheet";
link.href = "monitor_css/monitor.css";

link.onload = () => console.log("TVモード");
link.onerror = () => console.log("PCモード");

document.head.appendChild(link);
