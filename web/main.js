async function convertSub() {
    const subUrl = document.getElementById('subUrl').value.trim();
    const target = document.getElementById('target').value;
    if (!subUrl) {
        alert("请输入订阅地址");
        return;
    }
    const api = `/api/sub?target=${encodeURIComponent(target)}&url=${encodeURIComponent(subUrl)}`;
    document.getElementById('result').textContent = "正在转换…";
    try {
        const response = await fetch(api);
        if (!response.ok) {
            throw new Error("转换失败");
        }
        const text = await response.text();
        document.getElementById('result').textContent = text;
    } catch (err) {
        document.getElementById('result').textContent = "错误: " + err.message;
    }
}
