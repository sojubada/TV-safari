#import "BrowserDarkModeController.h"

#import "BrowserWebView.h"

@implementation BrowserDarkModeController

- (NSString *)applyDarkModeJavaScript {
    return @"(function(){"
            "var docEl = document.documentElement;"
            "if (!docEl) { return 'no-document'; }"
            "if (docEl.hasAttribute('data-browser-reader-mode')) {"
                "var existingReaderStyle = document.getElementById('__browser_forced_dark');"
                "if (existingReaderStyle && existingReaderStyle.parentNode) {"
                    "existingReaderStyle.parentNode.removeChild(existingReaderStyle);"
                "}"
                "return 'reader-mode';"
            "}"
            "var existing = document.getElementById('__browser_forced_dark');"
            "if (existing) { return 'already-applied'; }"
            "function parseRGBA(str) {"
                "if (!str || typeof str !== 'string') { return null; }"
                "var m = str.match(/rgba?\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)(?:\\s*,\\s*([\\d.]+))?\\s*\\)/i);"
                "if (!m) { return null; }"
                "var r = parseFloat(m[1]);"
                "var g = parseFloat(m[2]);"
                "var b = parseFloat(m[3]);"
                "var a = (typeof m[4] !== 'undefined' && m[4] !== '') ? parseFloat(m[4]) : 1.0;"
                "if (isNaN(r) || isNaN(g) || isNaN(b) || isNaN(a)) { return null; }"
                "return { r: r, g: g, b: b, a: a };"
            "}"
            "var bgColor = null;"
            "if (window.getComputedStyle) {"
                "if (document.body) {"
                    "var bodyBg = window.getComputedStyle(document.body).backgroundColor;"
                    "var parsedBody = parseRGBA(bodyBg);"
                    "if (parsedBody && parsedBody.a > 0) {"
                        "bgColor = parsedBody;"
                    "}"
                "}"
                "if (!bgColor && docEl) {"
                    "var htmlBg = window.getComputedStyle(docEl).backgroundColor;"
                    "var parsedHtml = parseRGBA(htmlBg);"
                    "if (parsedHtml && parsedHtml.a > 0) {"
                        "bgColor = parsedHtml;"
                    "}"
                "}"
            "}"
            "if (bgColor && bgColor.a > 0) {"
                "var luminance = (0.299 * bgColor.r + 0.587 * bgColor.g + 0.114 * bgColor.b) / 255.0;"
                "if (luminance < 0.4) {"
                    "return 'already-dark';"
                "}"
            "}"
            "var style = document.createElement('style');"
            "style.id = '__browser_forced_dark';"
            "style.textContent = 'html { filter: invert(1) hue-rotate(180deg) !important; background: #121212 !important; }\\n' +"
                                "'img, video, iframe, canvas, svg, picture, embed, object, [style*=\"background-image\"] { filter: invert(1) hue-rotate(180deg) !important; }';"
            "docEl.appendChild(style);"
            "return 'applied';"
           "})()";
}

- (NSString *)removeDarkModeJavaScript {
    return @"(function(){"
            "var existing = document.getElementById('__browser_forced_dark');"
            "if (existing && existing.parentNode) {"
                "existing.parentNode.removeChild(existing);"
                "return 'removed';"
            "}"
            "return 'none';"
           "})()";
}

- (NSString *)applyDarkModeToWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"";
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self applyDarkModeJavaScript]] ?: @"";
    NSLog(@"[InputTrace][DarkMode] apply result=%@", result);
    return result;
}

- (NSString *)removeDarkModeFromWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"";
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self removeDarkModeJavaScript]] ?: @"";
    NSLog(@"[InputTrace][DarkMode] remove result=%@", result);
    return result;
}

- (void)syncDarkModeState:(BOOL)enabled forWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }
    if (enabled) {
        [self applyDarkModeToWebView:webView];
    } else {
        [self removeDarkModeFromWebView:webView];
    }
}

@end