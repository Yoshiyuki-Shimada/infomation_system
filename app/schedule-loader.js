function loadScript(src) {
    return new Promise((resolve, reject) => {
        console.log(`読み込み開始: ${src}`);

        const script = document.createElement("script");

        script.src = src;

        script.onload = () => {
            console.log(`読み込み成功: ${src}`);
            resolve(src);
        };

        script.onerror = () => {
            console.error(`読み込み失敗: ${src}`);
            reject(new Error(`読み込み失敗: ${src}`));
        };

        document.head.appendChild(script);
    });
}

async function loadScheduleScripts() {
    console.log("読み込み対象ダイヤファイル:", scheduleScriptFiles);

    for (const file of scheduleScriptFiles) {
        await loadScript(file);
    }

    console.log("登録済みダイヤ:", scheduleDataList);
}

const scheduleLoadPromise = loadScheduleScripts();
