document.getElementById('searchForm').addEventListener('submit', function(e) {
    e.preventDefault();
    const query = document.getElementById('query').value.trim();
    if(query) {
        window.location.href = `https://www.bing.com/search?q=${encodeURIComponent(query)}`;
    }
});
