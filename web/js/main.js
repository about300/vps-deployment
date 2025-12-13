function search() {
  var query = document.getElementById("search-input").value.trim();
  if (query) {
    window.location.href = "https://www.bing.com/search?q=" + encodeURIComponent(query);
  }
}
