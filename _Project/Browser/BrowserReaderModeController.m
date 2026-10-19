#import "BrowserReaderModeController.h"
#import "BrowserWebView.h"

@implementation BrowserReaderModeController

- (BOOL)isReaderModeActiveForWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return NO;
    }
    NSString *script = @"(function(){ return document.documentElement && document.documentElement.getAttribute('data-browser-reader-mode') === '1' ? 'true' : 'false'; })();";
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    return [result isEqualToString:@"true"];
}

- (NSString *)readerModeJavaScript {
    return @"(function(){"
            "var docEl = document.documentElement;"
            "if (!docEl) { return 'error-no-document'; }"
            "if (docEl.getAttribute('data-browser-reader-mode') === '1') { return 'already-active'; }"
            "var title = document.title || '';"
            "var ogTitle = document.querySelector('meta[property=\"og:title\"]');"
            "if (ogTitle && ogTitle.content) { title = ogTitle.content; }"
            "else {"
                "var h1 = document.querySelector('h1');"
                "if (h1 && h1.textContent) { title = h1.textContent; }"
            "}"
            "title = title.replace(/\\s+/g, ' ').trim();"
            "title = title.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');"
            ""
            "var candidates = document.querySelectorAll('article, main, section, div, td');"
            "var bestNode = null;"
            "var bestScore = 0;"
            "for (var i = 0; i < candidates.length; i++) {"
                "var node = candidates[i];"
                "var textLength = node.textContent.replace(/\\s+/g, '').length;"
                "if (textLength < 150) { continue; }"
                "var links = node.querySelectorAll('a');"
                "var linkTextLength = 0;"
                "for (var j = 0; j < links.length; j++) {"
                    "linkTextLength += links[j].textContent.replace(/\\s+/g, '').length;"
                "}"
                "if (textLength > 0 && (linkTextLength / textLength) > 0.5) { continue; }"
                ""
                "var score = textLength;"
                "var tag = node.tagName.toLowerCase();"
                "if (tag === 'article' || tag === 'main') { score += 300; }"
                "var className = (node.className || '').toLowerCase();"
                "var idStr = (node.id || '').toLowerCase();"
                "var classId = className + ' ' + idStr;"
                "if (classId.match(/(article|content|post|entry|body|story)/)) { score += 150; }"
                "if (classId.match(/(^|[\\s_-])(nav|menu|header|footer|sidebar|comment|comments|share|related|ad|ads|banner|promo|popup)([\\s_-]|$)/)) { score -= 150; }"
                "var paragraphs = node.querySelectorAll('p');"
                "score += paragraphs.length * 20;"
                ""
                "if (score > bestScore) {"
                    "bestScore = score;"
                    "bestNode = node;"
                "}"
            "}"
            ""
            "if (!bestNode) { return 'not-enough-content'; }"
            "var parent = bestNode.parentElement;"
            "if (parent) {"
                "var parentTextLength = parent.textContent.replace(/\\s+/g, '').length;"
                "var nodeTextLength = bestNode.textContent.replace(/\\s+/g, '').length;"
                "if (parentTextLength > nodeTextLength && (nodeTextLength / parentTextLength) > 0.8) {"
                    "bestNode = parent;"
                "}"
            "}"
            "var clone = bestNode.cloneNode(true);"
            "var removeSelectors = ['script', 'style', 'noscript', 'form', 'button', 'nav', 'aside', 'footer', 'header', '.ad', '.banner', '.share', '.comment'];"
            "for (var k = 0; k < removeSelectors.length; k++) {"
                "var badNodes = clone.querySelectorAll(removeSelectors[k]);"
                "for (var l = 0; l < badNodes.length; l++) {"
                    "if (badNodes[l].parentNode) { badNodes[l].parentNode.removeChild(badNodes[l]); }"
                "}"
            "}"
            "var allElements = clone.querySelectorAll('*');"
            "for (var m = 0; m < allElements.length; m++) {"
                "var el = allElements[m];"
                "var elClassId = ((el.className || '') + ' ' + (el.id || '')).toLowerCase();"
                "if (elClassId.match(/(^|[\\s_-])(ad|ads|adv|advert|advertisement|banner|promo|promoted|share|sharing|social|comment|comments)([\\s_-]|$)/) && el.parentNode) {"
                    "el.parentNode.removeChild(el);"
                "}"
            "}"
            ""
            "var finalHTML = clone.innerHTML;"
            "var tempDiv = document.createElement('div');"
            "tempDiv.innerHTML = finalHTML;"
            "var finalTextLength = tempDiv.textContent.replace(/\\s+/g, '').length;"
            "if (finalTextLength < 400) { return 'not-enough-content'; }"
            ""
            "window.__browserReaderOriginalHTML = docEl.innerHTML;"
            "window.__browserReaderOriginalStyle = docEl.getAttribute('style');"
            ""
            "var css = 'body { background: #15171a !important; color: #e8e6e3 !important; font-family: -apple-system, sans-serif !important; margin: 0 !important; padding: 0 !important; } ' +"
                      "'.reader-container { max-width: 1100px; margin: 0 auto; padding: 60px 80px; font-size: 34px; line-height: 1.7; word-wrap: break-word; } ' +"
                      "'.reader-title { font-size: 48px; font-weight: bold; margin-bottom: 40px; color: #ffffff; } ' +"
                      "'.reader-content h2, .reader-content h3, .reader-content h4 { font-size: 38px; color: #ffffff; margin-top: 40px; margin-bottom: 20px; } ' +"
                      "'.reader-content p { margin-bottom: 24px; } ' +"
                      "'.reader-content a { color: #7fb3ff !important; text-decoration: none; } ' +"
                      "'.reader-content img, .reader-content figure, .reader-content video { max-width: 100%; height: auto; margin: 24px 0; display: block; border-radius: 8px; } ' +"
                      "'.reader-content blockquote { border-left: 6px solid #4a4d52; margin: 24px 0; padding-left: 24px; color: #b0afab; font-style: italic; } ' +"
                      "'.reader-content pre, .reader-content code { background: #222428; border-radius: 6px; padding: 4px 8px; font-family: monospace; font-size: 30px; } ' +"
                      "'.reader-content pre { padding: 24px; overflow-x: auto; } ' +"
                      "'.reader-content ul, .reader-content ol { margin-bottom: 24px; padding-left: 40px; } ' +"
                      "'.reader-content li { margin-bottom: 12px; } ' +"
                      "'.reader-content table { width: 100%; border-collapse: collapse; margin-bottom: 24px; } ' +"
                      "'.reader-content th, .reader-content td { border: 1px solid #4a4d52; padding: 12px; text-align: left; } ' +"
                      "'.reader-content th { background: #222428; }';"
            "var html = '<head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">' +"
                       "'<style>' + css + '</style></head>' +"
                       "'<body><div class=\"reader-container\">' +"
                       "'<div class=\"reader-title\">' + title + '</div>' +"
                       "'<div class=\"reader-content\">' + finalHTML + '</div>' +"
                       "'</div></body>';"
            ""
            "docEl.setAttribute('data-browser-reader-mode', '1');"
            "docEl.removeAttribute('style');"
            "docEl.style.setProperty('overflow', 'visible', 'important');"
            "docEl.style.setProperty('height', 'auto', 'important');"
            "docEl.innerHTML = html;"
            "window.scrollTo(0,0);"
            "return 'success';"
            "})()";
}

- (NSString *)disableReaderModeJavaScript {
    return @"(function(){"
            "var docEl = document.documentElement;"
            "if (!docEl) { return 'error'; }"
            "if (docEl.getAttribute('data-browser-reader-mode') !== '1') { return 'not-active'; }"
            "if (window.__browserReaderOriginalHTML) {"
                "docEl.innerHTML = window.__browserReaderOriginalHTML;"
                "docEl.removeAttribute('data-browser-reader-mode');"
                "if (window.__browserReaderOriginalStyle) { docEl.setAttribute('style', window.__browserReaderOriginalStyle); }"
                "else { docEl.removeAttribute('style'); }"
                "window.__browserReaderOriginalHTML = null;"
                "window.__browserReaderOriginalStyle = null;"
                "return 'restored';"
            "}"
            "return 'reload-required';"
            "})()";
}

- (NSString *)enableReaderModeForWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"error";
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self readerModeJavaScript]];
    NSLog(@"[InputTrace][ReaderMode] enable result=%@", result);
    return result ?: @"error";
}

- (void)disableReaderModeForWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self disableReaderModeJavaScript]];
    NSLog(@"[InputTrace][ReaderMode] disable result=%@", result);
    if ([result isEqualToString:@"reload-required"]) {
        [webView reload];
    }
}

@end
