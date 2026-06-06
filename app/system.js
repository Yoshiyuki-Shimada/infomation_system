let isTickerRunning = false;
let infoQueue = [];
let queueIndex = 0;
let slideIndex = 0;

// 1秒ごとの時計/バス更新
scheduleLoadPromise
    .then(() => {
        refresh();
        setInterval(refresh, 1000);
    })
    .catch((error) => {
        console.error(error);
        const debugMode = document.getElementById("debug-mode");

        if (debugMode) {
            debugMode.textContent = "● ダイヤデータ読み込み失敗";
        }
    });

// 30秒ごとのスライド切り替え
setInterval(showSlide, 30000);

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
