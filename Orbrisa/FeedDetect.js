// Orbrisa – lists the RSS / Atom feeds a page announces in its <head>.
(function () {
  try {
    var out = [], seen = {};
    var links = document.querySelectorAll('link[rel~="alternate"][type*="rss"], link[rel~="alternate"][type*="atom"], link[rel~="alternate"][type*="feed"]');
    for (var i = 0; i < links.length; i++) {
      var href = links[i].getAttribute('href');
      if (!href) { continue; }
      var url = new URL(href, location.href).href;
      if (seen[url]) { continue; }
      seen[url] = 1;
      out.push({ url: url, title: (links[i].getAttribute('title') || '').trim() });
    }
    var site = '';
    var m = document.querySelector('meta[property="og:site_name"]');
    if (m) { site = (m.getAttribute('content') || '').trim(); }
    return JSON.stringify({ feeds: out, site: site || location.hostname.replace(/^www\./, ''), page: location.href });
  } catch (e) {
    return JSON.stringify({ feeds: [] });
  }
})();
