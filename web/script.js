function convert(target) {
    let url = document.getElementById("raw").value.trim();
    let rule = document.getElementById("rule").value;
    let custom = document.getElementById("custom").value.trim();

    if (!url) {
        alert("请输入订阅链接/VLESS节点");
        return;
    }

    let base = window.location.origin + "/sub?target=" + target + "&url=" + encodeURIComponent(url);

    if (rule === "custom" && custom) {
        base += "&config=" + encodeURIComponent(custom);
    } else if (rule && rule !== "custom") {
        base += "&config=" + encodeURIComponent(rule);
    }

    document.getElementById("output").innerHTML =
        `<a href="${base}" target="_blank" style="color:white">${base}</a>`;
}

document.getElementById("rule").addEventListener("change", function(){
    document.getElementById("custom").style.display =
        (this.value === "custom") ? "block" : "none";
});
