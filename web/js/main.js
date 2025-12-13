// main.js - 控制主页搜索行为（Bing 搜索）
document.addEventListener("DOMContentLoaded", function() {
    const input = document.getElementById("searchInput");

    // 允许按 Enter 键搜索
    input.addEventListener("keydown", function(e) {
        if (e.key === "Enter") {
            performSearch();
        }
    });

    // 点击按钮搜索
    window.onSearch = performSearch;

    function performSearch() {
        const query = input.value.trim();
        const resultArea = document.getElementById("resultArea");

        if (!query) {
            // 如果为空，提示用户
            resultArea.textContent = "请输入关键词";
            return;
        }

        // 清除提示信息
        resultArea.textContent = "";

        // 跳转到 Bing 搜索结果页面
        const url = "https://www.bing.com/search?q=" + encodeURIComponent(query);
        window.location.href = url;
    }
});
