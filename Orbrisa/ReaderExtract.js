// Orbrisa Reader – finds the main article on the current page and returns it as JSON.
// Runs inside the page via stringByEvaluatingJavaScriptFromString; the last expression is the result.
(function () {
  try {
    var MAX_BLOCKS = 400;
    var SKIP = 'nav,aside,footer,header,form,button,select,noscript,script,style,svg,figcaption,[role="navigation"],[role="banner"],[role="contentinfo"],[aria-hidden="true"],.share,.social,.related,.comments,.comment,.newsletter,.advert,.ad,.ads,.promo,.cookie,.paywall';

    function clean(s) { return (s || '').replace(/\s+/g, ' ').trim(); }
    function text(el) { return clean(el.innerText || el.textContent); }
    function meta(name) {
      var m = document.querySelector('meta[property="' + name + '"],meta[name="' + name + '"]');
      return m ? clean(m.getAttribute('content')) : '';
    }
    function abs(u) { try { return new URL(u, location.href).href; } catch (e) { return ''; } }
    function visible(el) {
      var s = window.getComputedStyle(el);
      return s.display !== 'none' && s.visibility !== 'hidden';
    }
    function skipped(el, root) {
      for (var n = el; n && n !== root; n = n.parentElement) {
        if (n.matches && n.matches(SKIP)) { return true; }
      }
      return false;
    }

    // 1. Score containers by the paragraph text inside them.
    var scores = new Map();
    var paragraphs = document.querySelectorAll('p');
    for (var i = 0; i < paragraphs.length; i++) {
      var p = paragraphs[i];
      var len = text(p).length;
      if (len < 40 || skipped(p, document.body)) { continue; }
      var bonus = len + (text(p).split(',').length * 10);
      var parent = p.parentElement;
      if (parent) { scores.set(parent, (scores.get(parent) || 0) + bonus); }
      if (parent && parent.parentElement) {
        scores.set(parent.parentElement, (scores.get(parent.parentElement) || 0) + bonus / 2);
      }
    }
    var best = null, bestScore = 0;
    scores.forEach(function (score, el) {
      if (score > bestScore) { best = el; bestScore = score; }
    });
    var article = document.querySelector('article, [itemprop="articleBody"]');
    if (article && best && article.contains(best) === false && best.contains(article) === false) {
      // keep the paragraph winner
    } else if (article && (!best || (scores.get(article) || 0) > bestScore * 0.6)) {
      best = article;
    }
    if (!best) { return JSON.stringify({ blocks: [] }); }

    // 2. Collect blocks in reading order.
    var blocks = [], words = 0, seenImages = {};
    var nodes = best.querySelectorAll('h1,h2,h3,h4,p,li,blockquote,pre,img');
    for (var j = 0; j < nodes.length && blocks.length < MAX_BLOCKS; j++) {
      var el = nodes[j];
      if (skipped(el, best) || !visible(el)) { continue; }
      var tag = el.tagName.toLowerCase();
      if (tag !== 'blockquote' && el.closest('blockquote') && best.contains(el.closest('blockquote')) && el.closest('blockquote') !== el) { continue; }
      if ((tag === 'p') && el.closest('li') && best.contains(el.closest('li'))) { continue; }
      if (tag === 'img') {
        var src = abs(el.currentSrc || el.getAttribute('src') || el.getAttribute('data-src') || '');
        var w = el.naturalWidth || parseInt(el.getAttribute('width') || '0', 10);
        if (!src || src.indexOf('data:') === 0 || w < 300 || seenImages[src]) { continue; }
        seenImages[src] = 1;
        blocks.push({ t: 'img', src: src });
        continue;
      }
      var t = text(el);
      if (!t) { continue; }
      if (tag === 'p' && t.length < 2) { continue; }
      var type = tag.charAt(0) === 'h' ? 'h' : (tag === 'li' ? 'li' : (tag === 'blockquote' ? 'q' : (tag === 'pre' ? 'pre' : 'p')));
      blocks.push({ t: type, s: t });
      words += t.split(' ').length;
    }

    var title = meta('og:title') || (document.querySelector('h1') ? text(document.querySelector('h1')) : '') || clean(document.title);
    if (blocks.length && blocks[0].t === 'h' && blocks[0].s === title) { blocks.shift(); }
    return JSON.stringify({
      title: title,
      site: meta('og:site_name') || location.hostname.replace(/^www\./, ''),
      byline: meta('author') || meta('article:author'),
      summary: meta('og:description') || meta('description'),
      image: abs(meta('og:image')),
      url: location.href,
      words: words,
      blocks: blocks
    });
  } catch (e) {
    return JSON.stringify({ error: String(e), blocks: [] });
  }
})();
