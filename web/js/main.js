function onSearch() {
  const input = document.getElementById("searchInput");
  const q = input.value.trim();
  const resultArea = document.getElementById("resultArea");

  if (!q) {
    resultArea.textContent = "Please enter a keyword to search.";
    return;
  }

  // ** 这里不跳转外部 **
  // 暂时只展示你输入的关键词
  resultArea.textContent = "You searched for: " + q;

  /**  
   * 未来扩展思路:
   * fetch("https://你的搜索API?query=" + encodeURIComponent(q))
   *   .then(res => res.json())
   *   .then(data => showResults(data));
   */
}
