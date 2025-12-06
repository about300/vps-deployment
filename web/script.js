// 搜索 / 跳转
function search() {
    const query = document.getElementById('searchInput').value.trim();
    if (!query) return;
    // 简单跳转，如果是 URL 就跳转，否则搜索
    if (/^https?:\/\//i.test(query)) {
        window.location.href = query;
    } else {
        window.location.href = 'https://www.bing.com/search?q=' + encodeURIComponent(query);
    }
}

// 简单 VLESS 转 Clash YAML
function convertSub() {
    const input = document.getElementById('subInput').value.trim();
    if (!input) return alert('请输入 VLESS 链接');

    try {
        const url = new URL(input.replace(/^vless:\/\//i,'http://')); // 临时转换为 URL
        const id = url.username;
        const host = url.hostname;
        const port = url.port || 443;
        const params = new URLSearchParams(url.search);
        const flow = params.get('flow') || 'xtls-rprx-vision';
        const security = params.get('security') || 'reality';
        const sni = params.get('sni') || host;

        const yaml = `
proxies:
  - name: "${host}-${port}"
    type: vless
    server: ${host}
    port: ${port}
    uuid: ${id}
    flow: ${flow}
    tls: true
    skip-cert-verify: true
    servername: ${sni}
`;
        document.getElementById('subOutput').textContent = yaml;
    } catch (e) {
        alert('转换失败，请检查输入格式');
    }
}
