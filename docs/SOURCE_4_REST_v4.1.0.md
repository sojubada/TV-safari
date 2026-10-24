# tvOS Browser v4.1.0 — 나머지

이번 변경과 직접 관련은 적지만 맥락을 위해 첨부합니다.

> 검토 지침은 `REVIEW_v4.1.0.md`를 먼저 읽어 주십시오.

## `BrowserContentBlockerController.h`  (21줄)

```objc
#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserContentBlockerController : NSObject

@property (nonatomic, readonly) BOOL ruleListSupported;
@property (nonatomic, readonly, copy) NSString *compilationStatusString;
@property (nonatomic, readonly) NSUInteger ruleCount;

+ (instancetype)sharedController;
- (void)prepareRuleListIfNeeded;
- (nullable id)compiledRuleList;
- (NSString *)applyContentBlockingToWebView:(nullable BrowserWebView *)webView enabled:(BOOL)enabled;
- (NSString *)diagnosticsReport;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserContentBlockerController.m`  (249줄)

```objc
#import "BrowserContentBlockerController.h"

#import "BrowserWebView.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kBrowserContentRuleListStoreClassName = @"WKContentRuleListStore";
static const NSTimeInterval kBrowserRuleListCompileTimeout = 3.0;

@interface BrowserContentBlockerController ()

@property (nonatomic, readwrite) BOOL ruleListSupported;
@property (nonatomic, copy) NSString *compilationStatusString;
@property (nonatomic, strong, nullable) id compiledRuleListObject;
@property (nonatomic, assign) BOOL compilationAttempted;

@end

@implementation BrowserContentBlockerController

+ (instancetype)sharedController {
    static BrowserContentBlockerController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [BrowserContentBlockerController new];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _compilationStatusString = @"Not Attempted";
        _ruleListSupported = NO;
        _compiledRuleListObject = nil;
        _compilationAttempted = false;
    }
    return self;
}

- (NSArray<NSDictionary *> *)contentBlockingRulesJSON {
    return @[
        @{@"trigger": @{@"url-filter": @".*googlesyndication\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*google-analytics\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*googletagmanager\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*doubleclick\\.net.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*adservice\\.google\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*pagead2\\.googlesyndication\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*connect\\.facebook\\.net.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*analytics\\.twitter\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*scorecardresearch\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*criteo\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*outbrain\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*taboola\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*amazon-adsystem\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*adnxs\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*quantserve\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*krxd\\.net.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*rubiconproject\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*pubmatic\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*moatads\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*quantcount\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*adroll\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*casalemedia\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*openx\\.net.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*bluekai\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*exoclick\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*popads\\.net.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*adserver\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*histats\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*addthis\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*sharethis\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*hotjar\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*luckyorange\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*segment\\.io.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*amplitude\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*mixpanel\\.com.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*clarity\\.ms.*"}, @"action": @{@"type": @"block"}},
        @{@"trigger": @{@"url-filter": @".*adsbygoogle.*"}, @"action": @{@"type": @"block"}},

        // Cosmetic rule. The keys here must be NSString literals: a bare C
        // string is not an object and will not compile as a dictionary key.
        //
        // The class matches use ~=, which matches one whole space-separated
        // token. *= matched substrings, so "ad-" also hit load-more,
        // read-more, upload-date, thread-list and page-head-wrapper, and
        // hiding those takes real content with it. iframe[src*="ads"] went
        // for the same reason: it matched any src with "ads" anywhere,
        // including /uploads/ and /downloads/.
        @{@"trigger": @{@"url-filter": @".*"},
          @"action": @{@"type": @"css-display-none",
                       @"selector": @".ads, .ad, .advert, .advertisement, .ad-banner, .ad-container, .adsbygoogle, #ads, #ad, #advert, #advertisement, [class~=\"ad\"], [class~=\"ads\"], [class~=\"advert\"], [class~=\"advertisement\"], [class~=\"sponsored\"], [id~=\"sponsored\"], [class*=\"banner-ad\"], iframe[src*=\"doubleclick\"]"}}
    ];
}

- (NSUInteger)ruleCount {
    return [self contentBlockingRulesJSON].count;
}

- (void)prepareRuleListIfNeeded {
    if (self.compilationAttempted) {
        return;
    }
    self.compilationAttempted = YES;

    Class storeClass = NSClassFromString(kBrowserContentRuleListStoreClassName);
    SEL defaultStoreSelector = NSSelectorFromString(@"defaultStore");
    if (storeClass == Nil || ![storeClass respondsToSelector:defaultStoreSelector]) {
        self.ruleListSupported = NO;
        self.compilationStatusString = @"Failed: WKContentRuleListStore unavailable";
        return;
    }

    id store = ((id (*)(id, SEL))objc_msgSend)((id)storeClass, defaultStoreSelector);
    SEL compileSelector = NSSelectorFromString(@"compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:");
    if (store == nil || ![store respondsToSelector:compileSelector]) {
        self.ruleListSupported = NO;
        self.compilationStatusString = @"Failed: compile selector unavailable";
        return;
    }

    NSArray<NSDictionary *> *rules = [self contentBlockingRulesJSON];
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:rules options:0 error:&jsonError];
    if (jsonData == nil) {
        self.ruleListSupported = NO;
        self.compilationStatusString = [NSString stringWithFormat:@"Failed JSON: %@", jsonError.localizedDescription];
        return;
    }

    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (jsonString.length == 0) {
        self.ruleListSupported = NO;
        self.compilationStatusString = @"Failed: JSON string empty";
        return;
    }

    self.ruleListSupported = YES;
    __block BOOL finished = NO;
    __weak typeof(self) weakSelf = self;

    void (^completionHandler)(id, NSError *) = ^(id ruleList, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf != nil) {
            if (error != nil) {
                strongSelf.compiledRuleListObject = nil;
                strongSelf.compilationStatusString = [NSString stringWithFormat:@"Failed Error: %@", error.localizedDescription];
            } else if (ruleList != nil) {
                strongSelf.compiledRuleListObject = ruleList;
                strongSelf.compilationStatusString = @"Success (Rule List Active)";
            } else {
                strongSelf.compiledRuleListObject = nil;
                strongSelf.compilationStatusString = @"Failed: Rule list nil";
            }
        }
        finished = YES;
    };

    ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, compileSelector, @"BrowserAdBlockRules-v1", jsonString, completionHandler);

    // This runs during launch, before the first web view exists, because the
    // compiled list has to be in hand when the configuration is built. An
    // unbounded wait would therefore hang the app on a tvOS WebKit that
    // accepts the selector but never calls back, so the wait is bounded and
    // falls through to the JavaScript path instead.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kBrowserRuleListCompileTimeout];
    while (!finished && [deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }

    if (!finished) {
        self.compilationStatusString = @"Failed: compile timed out";
    }
}

- (id)compiledRuleList {
    [self prepareRuleListIfNeeded];
    return self.compiledRuleListObject;
}

- (NSString *)applyContentBlockingToWebView:(BrowserWebView *)webView enabled:(BOOL)enabled {
    if (webView == nil) {
        return @"0";
    }

    if (!enabled) {
        return @"0";
    }

    // Second priority only. When the rule list compiled, WebKit is already
    // applying the same cosmetic selectors natively, so running this as well
    // would spend a synchronous JavaScript evaluation on every page load to
    // hide what is hidden already.
    if (self.compiledRuleListObject != nil) {
        return @"0";
    }
    NSString *jsScript =
        @"(function(){"
            "var count = 0;"
            "function hideElements(selector) {"
                "try {"
                    "var els = document.querySelectorAll(selector);"
                    "for (var i = 0; i < els.length; i++) {"
                        "var el = els[i];"
                        "if (el && el.style && el.style.display !== 'none') {"
                            "el.style.setProperty('display', 'none', 'important');"
                            "count++;"
                        "}"
                    "}"
                "} catch (e) {}"
            "}"
            "hideElements('.ads, .ad, .advert, .advertisement, .ad-banner, .ad-container, .adsbygoogle, #ads, #ad, #advert, #advertisement');"
            "hideElements('[class~=\"ad\"], [class~=\"ads\"], [class~=\"advert\"], [class~=\"advertisement\"], [class~=\"sponsored\"], [id~=\"sponsored\"], [class*=\"banner-ad\"]');"
            "try {"
                "var frames = document.querySelectorAll('iframe');"
                "for (var j = 0; j < frames.length; j++) {"
                    "var frame = frames[j];"
                    "var src = String(frame.src || '').toLowerCase();"
                    "if (src.indexOf('doubleclick') !== -1 || src.indexOf('googlesyndication') !== -1 || src.indexOf('/ads/') !== -1 || src.indexOf('adserver') !== -1) {"
                        "frame.style.setProperty('display', 'none', 'important');"
                        "count++;"
                    "}"
                "}"
            "} catch (e) {}"
            "return String(count);"
        "})();";

    NSString *result = [webView stringByEvaluatingJavaScriptFromString:jsScript] ?: @"0";
    return result;
}

- (NSString *)diagnosticsReport {
    [self prepareRuleListIfNeeded];
    NSString *storeFound = self.ruleListSupported ? @"YES" : @"NO";
    NSString *activePath = (self.compiledRuleListObject != nil) ? @"Rule List (1st Priority)" : @"JS Visual Blocking (2nd Priority Fallback)";
    return [NSString stringWithFormat:
            @"WKContentRuleListStore Class Found: %@\n"
             "Compilation Status: %@\n"
             "Active Blocking Path: %@\n"
             "Rule Count: %lu",
            storeFound,
            self.compilationStatusString,
            activePath,
            (unsigned long)[self ruleCount]];
}

@end
```

## `BrowserDarkModeController.h`  (15줄)

```objc
#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserDarkModeController : NSObject

- (NSString *)applyDarkModeToWebView:(nullable BrowserWebView *)webView;
- (NSString *)removeDarkModeFromWebView:(nullable BrowserWebView *)webView;
- (void)syncDarkModeState:(BOOL)enabled forWebView:(nullable BrowserWebView *)webView;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserDarkModeController.m`  (103줄)

```objc
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
```

## `BrowserReaderModeController.h`  (16줄)

```objc
#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserReaderModeController : NSObject

- (BOOL)isReaderModeActiveForWebView:(nullable BrowserWebView *)webView;
- (NSString *)enableReaderModeForWebView:(nullable BrowserWebView *)webView fontSize:(NSUInteger)fontSize;
- (void)disableReaderModeForWebView:(nullable BrowserWebView *)webView;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserReaderModeController.m`  (209줄)

```objc
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

- (NSString *)readerModeJavaScriptWithFontSize:(NSUInteger)fontSize {
    return [NSString stringWithFormat:@"(function(){"
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
            "var bodyFontSize = %lu;"
            "var titleFontSize = Math.round(bodyFontSize * 1.32);"
            "var headingFontSize = Math.round(bodyFontSize * 1.12);"
            "var codeFontSize = Math.round(bodyFontSize * 0.82);"
            "var blockSpacing = Math.round(bodyFontSize * 0.66);"
            "var css = 'body { background: #15171a !important; color: #e8e6e3 !important; font-family: -apple-system, sans-serif !important; margin: 0 !important; padding: 0 !important; } ' +"
                      "'.reader-container { max-width: 1500px; margin: 0 auto; padding: 72px 70px 140px; font-size: ' + bodyFontSize + 'px; line-height: 1.6; word-wrap: break-word; } ' +"
                      "'.reader-title { font-size: ' + titleFontSize + 'px; font-weight: 700; line-height: 1.25; margin-bottom: 48px; color: #ffffff; } ' +"
                      "'.reader-content h2, .reader-content h3, .reader-content h4 { font-size: ' + headingFontSize + 'px; line-height: 1.3; color: #ffffff; margin-top: 56px; margin-bottom: 24px; } ' +"
                      "'.reader-content p { margin-bottom: ' + blockSpacing + 'px; } ' +"
                      "'.reader-content a { color: #7fb3ff !important; text-decoration: none; } ' +"
                      "'.reader-content img, .reader-content figure, .reader-content video { max-width: 100%%; height: auto; margin: 40px 0; display: block; border-radius: 10px; } ' +"
                      "'.reader-content blockquote { border-left: 8px solid #4a4d52; margin: 40px 0; padding-left: 34px; color: #b0afab; font-style: italic; } ' +"
                      "'.reader-content pre, .reader-content code { background: #222428; border-radius: 8px; padding: 6px 10px; font-family: monospace; font-size: ' + codeFontSize + 'px; } ' +"
                      "'.reader-content pre { padding: 28px; overflow-x: auto; } ' +"
                      "'.reader-content ul, .reader-content ol { margin-bottom: 34px; padding-left: 52px; } ' +"
                      "'.reader-content li { margin-bottom: 18px; } ' +"
                      "'.reader-content table { width: 100%%; border-collapse: collapse; margin-bottom: 34px; font-size: ' + codeFontSize + 'px; } ' +"
                      "'.reader-content th, .reader-content td { border: 1px solid #4a4d52; padding: 18px; text-align: left; } ' +"
                      "'.reader-content th { background: #222428; }';"
            "var html = '<head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"></head>' +"
                       "'<body><div class=\"reader-container\" id=\"__browser_reader_container\">' +"
                       "'<div class=\"reader-title\">' + title + '</div>' +"
                       "'<div class=\"reader-content\">' + finalHTML + '</div>' +"
                       "'</div></body>';"
            ""
            "docEl.setAttribute('data-browser-reader-mode', '1');"
            "docEl.removeAttribute('style');"
            "docEl.style.setProperty('overflow', 'visible', 'important');"
            "docEl.style.setProperty('height', 'auto', 'important');"
            "docEl.innerHTML = html;"
            ""
            // A <style> written as part of an innerHTML string is not reliably
            // applied here, which left the extracted article unstyled: full
            // width and at the document's default size. Building the element
            // with the DOM API and appending it afterwards always applies.
            "var styleElement = document.createElement('style');"
            "styleElement.id = '__browser_reader_style';"
            "styleElement.textContent = css;"
            "(document.head || docEl).appendChild(styleElement);"
            ""
            // Belt and braces: the container carries the layout inline too, so
            // the column and body size hold even if the sheet is ignored.
            "var container = document.getElementById('__browser_reader_container');"
            "if (container) {"
                "container.setAttribute('style',"
                    "'max-width: 1500px; margin: 0 auto;'"
                    "+ ' padding: 72px 70px 140px;'"
                    "+ ' font-size: ' + bodyFontSize + 'px;'"
                    "+ ' line-height: 1.6;'"
                    "+ ' color: #e8e6e3;'"
                    "+ ' word-wrap: break-word;');"
            "}"
            "if (document.body) {"
                "document.body.setAttribute('style',"
                    "'background: #15171a; color: #e8e6e3; margin: 0; padding: 0;'"
                    "+ ' font-family: -apple-system, sans-serif;');"
            "}"
            ""
            "window.scrollTo(0,0);"
            ""
            // Report the size actually in force, so a styling failure shows up
            // as a number instead of looking like a page that merely needs
            // tuning.
            "var appliedSize = '';"
            "try {"
                "if (container && window.getComputedStyle) {"
                    "appliedSize = window.getComputedStyle(container).fontSize || '';"
                "}"
            "} catch (error) {}"
            "return 'success:' + appliedSize;"
            "})()", (unsigned long)fontSize];
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

- (NSString *)enableReaderModeForWebView:(BrowserWebView *)webView fontSize:(NSUInteger)fontSize {
    if (webView == nil) {
        return @"error";
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self readerModeJavaScriptWithFontSize:fontSize]];
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
```

## `BrowserNavigationService.h`  (20줄)

```objc
#import <Foundation/Foundation.h>

@class BrowserTabViewModel;
@class BrowserPreferencesStore;

@interface BrowserNavigationService : NSObject

- (instancetype)initWithPreferencesStore:(BrowserPreferencesStore *)preferencesStore;
- (NSURLRequest *)homePageRequest;
- (NSURLRequest *)requestForURLString:(NSString *)URLString;
- (NSURLRequest *)requestForEnteredAddressString:(NSString *)addressString;
- (NSURLRequest *)googleSearchRequestForQuery:(NSString *)query;
- (NSURLRequest *)googleSearchRequestForFailedRequestURLString:(NSString *)requestURLString;
- (void)updateTab:(BrowserTabViewModel *)tab
    withPageTitle:(NSString *)pageTitle
  currentURLString:(NSString *)currentURLString;
- (BOOL)shouldIgnoreLoadError:(NSError *)error;

@end
```

## `BrowserNavigationService.m`  (157줄)

```objc
#import "BrowserNavigationService.h"

#import "BrowserPreferencesStore.h"
#import "BrowserTabViewModel.h"

static NSString * const kHistoryDefaultsKey = @"HISTORY";
static NSUInteger const kMaximumHistoryCount = 100;

@interface BrowserNavigationService ()

@property (nonatomic) BrowserPreferencesStore *preferencesStore;

@end

@implementation BrowserNavigationService

- (instancetype)init {
    return [self initWithPreferencesStore:[BrowserPreferencesStore new]];
}

- (instancetype)initWithPreferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
    }
    return self;
}

- (NSURLRequest *)homePageRequest {
    NSString *homePageURLString = self.preferencesStore.homePageURLString;
    if (homePageURLString.length == 0) {
        homePageURLString = @"http://www.google.com";
    }
    return [self requestForURLString:homePageURLString];
}

- (NSURLRequest *)requestForEnteredAddressString:(NSString *)addressString {
    NSString *trimmedAddress = [self trimmedString:addressString];
    if (trimmedAddress.length == 0) {
        return nil;
    }
    
    if (![trimmedAddress hasPrefix:@"http://"] && ![trimmedAddress hasPrefix:@"https://"]) {
        trimmedAddress = [@"http://" stringByAppendingString:trimmedAddress];
    }
    return [self requestForURLString:trimmedAddress];
}

- (NSURLRequest *)googleSearchRequestForQuery:(NSString *)query {
    NSString *sanitizedQuery = [self sanitizedSearchQuery:query];
    if (sanitizedQuery.length == 0) {
        return nil;
    }
    
    NSString *searchURLString = [NSString stringWithFormat:@"https://www.google.com/search?q=%@", sanitizedQuery];
    return [self requestForURLString:searchURLString];
}

- (NSURLRequest *)googleSearchRequestForFailedRequestURLString:(NSString *)requestURLString {
    NSString *searchQuery = [self trimmedString:requestURLString];
    if (searchQuery.length == 0) {
        return nil;
    }
    
    if ([searchQuery hasSuffix:@"/"]) {
        searchQuery = [searchQuery substringToIndex:searchQuery.length - 1];
    }
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"http://" withString:@""];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"https://" withString:@""];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"www." withString:@""];
    
    return [self googleSearchRequestForQuery:searchQuery];
}

- (void)updateTab:(BrowserTabViewModel *)tab
    withPageTitle:(NSString *)pageTitle
  currentURLString:(NSString *)currentURLString {
    if (tab == nil) {
        return;
    }
    
    NSString *safeTitle = pageTitle ?: @"";
    NSString *safeURLString = currentURLString ?: @"";
    tab.title = safeTitle.length > 0 ? safeTitle : @"New Tab";
    tab.URLString = safeURLString;
    
    [self persistHistoryItemWithURLString:safeURLString title:safeTitle];
}

- (BOOL)shouldIgnoreLoadError:(NSError *)error {
    NSInteger errorCode = error.code;
    return errorCode == 999 || errorCode == 204;
}

- (NSURLRequest *)requestForURLString:(NSString *)URLString {
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    NSString *userAgent = self.preferencesStore.userAgent;
    if (userAgent.length > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
    return request;
}

- (NSString *)trimmedString:(NSString *)string {
    if (string == nil) {
        return @"";
    }
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)sanitizedSearchQuery:(NSString *)query {
    NSString *trimmedQuery = [self trimmedString:query];
    if (trimmedQuery.length == 0) {
        return @"";
    }
    
    NSString *searchQuery = [trimmedQuery stringByReplacingOccurrencesOfString:@" " withString:@"+"];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"." withString:@"+"];
    while ([searchQuery containsString:@"++"]) {
        searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"++" withString:@"+"];
    }
    
    return [searchQuery stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

- (void)persistHistoryItemWithURLString:(NSString *)URLString title:(NSString *)title {
    if (URLString.length == 0) {
        return;
    }
    
    NSArray *historyItem = @[URLString, title ?: @""];
    NSMutableArray *historyItems = [NSMutableArray arrayWithObject:historyItem];
    NSArray *storedHistory = [[NSUserDefaults standardUserDefaults] arrayForKey:kHistoryDefaultsKey];
    if (storedHistory.count > 0) {
        NSArray *latestItem = storedHistory.firstObject;
        if ([latestItem isKindOfClass:[NSArray class]] && latestItem.count > 0 && [latestItem[0] isEqualToString:URLString]) {
            [historyItems removeObjectAtIndex:0];
        }
        [historyItems addObjectsFromArray:storedHistory];
    }
    
    while (historyItems.count > kMaximumHistoryCount) {
        [historyItems removeLastObject];
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:historyItems forKey:kHistoryDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
```

## `BrowserSessionStore.h`  (13줄)

```objc
#import <Foundation/Foundation.h>

@class BrowserViewModel;
@class BrowserNavigationService;

@interface BrowserSessionStore : NSObject

- (BOOL)restoreSessionIntoViewModel:(BrowserViewModel *)viewModel;
- (void)saveSessionForViewModel:(BrowserViewModel *)viewModel;
- (nullable NSURLRequest *)consumeSavedURLToReopenRequestWithNavigationService:(BrowserNavigationService *)navigationService;

@end
```

## `BrowserSessionStore.m`  (96줄)

```objc
#import "BrowserSessionStore.h"

#import "BrowserNavigationService.h"
#import "BrowserTabViewModel.h"
#import "BrowserViewModel.h"

static NSString * const kBrowserSessionDefaultsKey = @"BrowserSession";
static NSString * const kBrowserSessionTabsKey = @"tabs";
static NSString * const kBrowserSessionActiveTabIndexKey = @"activeTabIndex";
static NSString * const kBrowserSessionVersionKey = @"version";
static NSString * const kBrowserSavedURLToReopenDefaultsKey = @"savedURLtoReopen";
static NSNumber *BrowserSessionVersion(void) {
    return @1;
}

@implementation BrowserSessionStore

- (BOOL)restoreSessionIntoViewModel:(BrowserViewModel *)viewModel {
    NSDictionary *sessionRepresentation = [self restoredSessionRepresentation];
    if (![sessionRepresentation isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    
    NSArray *tabRepresentations = [sessionRepresentation[kBrowserSessionTabsKey] isKindOfClass:[NSArray class]] ? sessionRepresentation[kBrowserSessionTabsKey] : nil;
    if (tabRepresentations.count == 0) {
        return NO;
    }
    
    NSMutableArray<BrowserTabViewModel *> *tabs = [NSMutableArray array];
    for (NSDictionary *tabRepresentation in tabRepresentations) {
        if (![tabRepresentation isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        BrowserTabViewModel *tab = [[BrowserTabViewModel alloc] initWithSessionRepresentation:tabRepresentation];
        if (tab != nil) {
            [tabs addObject:tab];
        }
    }
    
    if (tabs.count == 0) {
        return NO;
    }
    
    NSInteger activeTabIndex = [sessionRepresentation[kBrowserSessionActiveTabIndexKey] respondsToSelector:@selector(integerValue)] ? [sessionRepresentation[kBrowserSessionActiveTabIndexKey] integerValue] : 0;
    [viewModel restoreTabs:tabs activeTabIndex:activeTabIndex];
    return YES;
}

- (void)saveSessionForViewModel:(BrowserViewModel *)viewModel {
    if (viewModel.tabs.count == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kBrowserSessionDefaultsKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return;
    }
    
    NSMutableArray *tabRepresentations = [NSMutableArray arrayWithCapacity:viewModel.tabs.count];
    for (BrowserTabViewModel *tab in viewModel.tabs) {
        [tabRepresentations addObject:[tab sessionRepresentation]];
    }
    
    NSDictionary *sessionRepresentation = @{
        kBrowserSessionVersionKey: BrowserSessionVersion(),
        kBrowserSessionActiveTabIndexKey: @(viewModel.activeTabIndex),
        kBrowserSessionTabsKey: tabRepresentations
    };

    [[NSUserDefaults standardUserDefaults] setObject:sessionRepresentation forKey:kBrowserSessionDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSDictionary *)restoredSessionRepresentation {
    NSDictionary *defaultsRepresentation = [[NSUserDefaults standardUserDefaults] objectForKey:kBrowserSessionDefaultsKey];
    if ([defaultsRepresentation isKindOfClass:[NSDictionary class]]) {
        return defaultsRepresentation;
    }

    return nil;
}

- (NSURLRequest *)consumeSavedURLToReopenRequestWithNavigationService:(BrowserNavigationService *)navigationService {
    NSString *savedURLString = [[NSUserDefaults standardUserDefaults] stringForKey:kBrowserSavedURLToReopenDefaultsKey];
    if (savedURLString.length == 0) {
        return nil;
    }

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kBrowserSavedURLToReopenDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if (navigationService == nil) {
        return nil;
    }
    return [navigationService requestForURLString:savedURLString];
}

@end
```

## `BrowserTabOverviewController.h`  (44줄)

```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserTabViewModel;
@class BrowserTopBarView;
@class BrowserViewModel;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserTabOverviewControllerHost <NSObject>

- (BOOL)browserTabOverviewControllerCursorModeEnabled;
- (void)browserTabOverviewControllerSetCursorModeEnabled:(BOOL)enabled;
- (void)browserTabOverviewControllerPresentViewController:(UIViewController *)viewController;
- (void)browserTabOverviewControllerCreateNewTabLoadingHomePage:(BOOL)loadHomePage;
- (void)browserTabOverviewControllerSwitchToTabAtIndex:(NSInteger)tabIndex;
- (void)browserTabOverviewControllerCloseTabAtIndex:(NSInteger)tabIndex;

@end

@interface BrowserTabOverviewController : NSObject

@property (nonatomic, readonly, getter=isVisible) BOOL visible;

- (instancetype)initWithHost:(id<BrowserTabOverviewControllerHost>)host
                   viewModel:(BrowserViewModel *)viewModel
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)show;
- (void)dismiss;
- (void)reload;
- (void)updateCardAtIndex:(NSInteger)tabIndex;
- (void)handleAlternateAction;
- (BOOL)containsPoint:(CGPoint)viewPoint;
- (BOOL)handleSelectionAtPoint:(CGPoint)viewPoint;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserTabOverviewController.m`  (575줄)

```objc
#import "BrowserTabOverviewController.h"

#import "BrowserTabViewModel.h"
#import "BrowserViewModel.h"

static CGFloat const kTopBarHorizontalInset = 40.0;
static CGFloat const kTopBarMaxWidth = 1760.0;
static CGFloat const kTopBarHeight = 86.0;
static CGFloat const kTabOverviewPanelTopInset = 120.0;
static CGFloat const kTabOverviewPanelBottomInset = 88.0;
static CGFloat const kTabOverviewPanelSideInset = 54.0;
static CGFloat const kTabOverviewHeaderTopInset = 34.0;
static CGFloat const kTabOverviewTitleHeight = 64.0;
static CGFloat const kTabOverviewSubtitleTop = 94.0;
static CGFloat const kTabOverviewSubtitleHeight = 36.0;
static CGFloat const kTabOverviewContentTopInset = 166.0;
static CGFloat const kTabOverviewFooterHeight = 28.0;
static CGFloat const kTabCardWidth = 584.0;
static CGFloat const kTabCardHeight = 535.0;
static CGFloat const kTabCardThumbnailHeight = 347.0;
static CGFloat const kTabCardSpacing = 50.4;
static CGFloat const kTabCardGlowInset = 18.0;
static CGFloat const kTabCardTitleTop = 369.0;
static CGFloat const kTabCardTitleHeight = 36.0;
static CGFloat const kTabCardURLTop = 409.0;
static CGFloat const kTabCardURLHeight = 64.0;

@class BrowserTabOverviewViewController;

@interface BrowserTopAlignedLabel : UILabel
@end

@implementation BrowserTopAlignedLabel

- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)numberOfLines {
    CGRect textRect = [super textRectForBounds:bounds limitedToNumberOfLines:numberOfLines];
    textRect.origin.y = bounds.origin.y;
    return textRect;
}

- (void)drawTextInRect:(CGRect)rect {
    CGRect textRect = [self textRectForBounds:rect limitedToNumberOfLines:self.numberOfLines];
    [super drawTextInRect:textRect];
}

@end

@interface BrowserTabOverviewController ()

@property (nonatomic, weak) id<BrowserTabOverviewControllerHost> host;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic, readwrite, getter=isVisible) BOOL visible;
@property (nonatomic) BOOL cursorModeBeforeShowing;
@property (nonatomic, weak) BrowserTabOverviewViewController *presentedOverviewViewController;

- (NSInteger)numberOfDisplayItems;
- (NSInteger)activeTabDisplayItemIndex;
- (nullable BrowserTabViewModel *)tabForDisplayItemIndex:(NSInteger)displayItemIndex;
- (void)handleSelectionForDisplayItemIndex:(NSInteger)displayItemIndex;
- (void)handleCloseRequestForDisplayItemIndex:(NSInteger)displayItemIndex;
- (void)handleAlternateAction;
- (void)reloadPresentedOverviewIfNeeded;
- (void)overviewViewControllerDidDisappear:(BrowserTabOverviewViewController *)viewController;

@end

@interface BrowserTabOverviewCollectionViewCell : UICollectionViewCell

- (void)configureAsAddCard;
- (void)configureWithTab:(BrowserTabViewModel *)tab activeTab:(BOOL)activeTab;

@end

@interface BrowserTabOverviewCollectionViewCell ()

@property (nonatomic) UIView *cardBackgroundView;
@property (nonatomic) UIImageView *thumbnailView;
@property (nonatomic) UIView *addIconBackdropView;
@property (nonatomic) UIImageView *addIconView;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *urlLabel;
@property (nonatomic) UILabel *hintLabel;
@property (nonatomic) BOOL addCard;
@property (nonatomic) BOOL activeTab;

@end

@implementation BrowserTabOverviewCollectionViewCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

        _cardBackgroundView = [[UIView alloc] initWithFrame:self.contentView.bounds];
        _cardBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cardBackgroundView.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
        _cardBackgroundView.layer.cornerRadius = 30.0;
        _cardBackgroundView.clipsToBounds = YES;
        [self.contentView addSubview:_cardBackgroundView];

        _thumbnailView = [[UIImageView alloc] initWithFrame:CGRectMake(0.0, 0.0, kTabCardWidth, kTabCardThumbnailHeight)];
        _thumbnailView.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
        _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnailView.clipsToBounds = YES;
        [_cardBackgroundView addSubview:_thumbnailView];

        _addIconBackdropView = [[UIView alloc] initWithFrame:CGRectMake((kTabCardWidth - 144.0) / 2.0, (kTabCardHeight - 144.0) / 2.0, 144.0, 144.0)];
        _addIconBackdropView.backgroundColor = UIColor.clearColor;
        _addIconBackdropView.hidden = YES;
        [_cardBackgroundView addSubview:_addIconBackdropView];

        _addIconView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"plus"]];
        _addIconView.frame = CGRectMake(12.0, 12.0, 120.0, 120.0);
        _addIconView.contentMode = UIViewContentModeScaleAspectFit;
        [_addIconBackdropView addSubview:_addIconView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(30.0, kTabCardTitleTop, kTabCardWidth - 60.0, kTabCardTitleHeight)];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        [_cardBackgroundView addSubview:_titleLabel];

        _urlLabel = [[BrowserTopAlignedLabel alloc] initWithFrame:CGRectMake(30.0, kTabCardURLTop, kTabCardWidth - 60.0, kTabCardURLHeight)];
        _urlLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        _urlLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _urlLabel.numberOfLines = 2;
        [_cardBackgroundView addSubview:_urlLabel];

        _hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(30.0, kTabCardHeight - 44.0, kTabCardWidth - 60.0, 24.0)];
        _hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.58];
        _hintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _hintLabel.textAlignment = NSTextAlignmentRight;
        _hintLabel.hidden = YES;
        [_cardBackgroundView addSubview:_hintLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.transform = CGAffineTransformIdentity;
}

- (void)configureAsAddCard {
    self.addCard = YES;
    self.activeTab = NO;
    self.thumbnailView.hidden = YES;
    self.thumbnailView.image = nil;
    self.addIconBackdropView.hidden = NO;
    self.titleLabel.text = @"New Tab";
    self.urlLabel.text = @"Open the home page";
    self.hintLabel.hidden = YES;
    [self updateAppearance];
}

- (void)configureWithTab:(BrowserTabViewModel *)tab activeTab:(BOOL)activeTab {
    self.addCard = NO;
    self.activeTab = activeTab;
    self.thumbnailView.hidden = NO;
    self.thumbnailView.image = tab.snapshotImage;
    self.addIconBackdropView.hidden = YES;
    self.titleLabel.text = tab.title.length > 0 ? tab.title : @"New Tab";
    self.urlLabel.text = tab.URLString.length > 0 ? tab.URLString : @"Home page";
    self.hintLabel.text = @"Play/Pause to Close";
    self.hintLabel.hidden = !self.isFocused;
    [self updateAppearance];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    [coordinator addCoordinatedAnimations:^{
        [self updateAppearance];
    } completion:nil];
}

- (void)updateAppearance {
    BOOL focused = self.isFocused;
    self.cardBackgroundView.backgroundColor = self.addCard
        ? [UIColor colorWithWhite:focused ? 0.20 : 0.16 alpha:1.0]
        : [UIColor colorWithWhite:(self.activeTab ? 0.18 : 0.14) alpha:1.0];

    self.layer.shadowColor = [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0].CGColor;
    self.layer.shadowOffset = CGSizeZero;
    self.layer.shadowOpacity = (focused || self.activeTab) ? 0.78 : 0.0;
    self.layer.shadowRadius = focused ? 18.0 : 12.0;
    self.transform = focused ? CGAffineTransformMakeScale(1.06, 1.06) : CGAffineTransformIdentity;
    self.hintLabel.hidden = self.addCard || !focused;
}

@end

@interface BrowserTabOverviewViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>

- (instancetype)initWithOverviewController:(BrowserTabOverviewController *)overviewController;
- (void)reload;
- (void)updateCardAtTabIndex:(NSInteger)tabIndex;
- (void)handleAlternateAction;

@end

@interface BrowserTabOverviewViewController ()

@property (nonatomic, weak) BrowserTabOverviewController *overviewController;
@property (nonatomic) UIView *dimView;
@property (nonatomic) UIVisualEffectView *panelView;
@property (nonatomic) UICollectionView *collectionView;
@property (nonatomic) UILabel *footerLabel;
@property (nonatomic) NSInteger preferredFocusItemIndex;

@end

@implementation BrowserTabOverviewViewController

- (instancetype)initWithOverviewController:(BrowserTabOverviewController *)overviewController {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _overviewController = overviewController;
        _preferredFocusItemIndex = NSNotFound;
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (CGFloat)panelWidth {
    CGFloat width = MIN(CGRectGetWidth(self.view.bounds) - (kTopBarHorizontalInset * 2.0), kTopBarMaxWidth);
    return MAX(width, 860.0);
}

- (CGFloat)panelHeight {
    CGFloat maxHeight = CGRectGetHeight(self.view.bounds) - kTabOverviewPanelTopInset - kTabOverviewPanelBottomInset;
    return MAX(maxHeight, 760.0);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIView *dimView = [UIView new];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    [self.view addSubview:dimView];
    self.dimView = dimView;

    UIVisualEffectView *panelView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    panelView.translatesAutoresizingMaskIntoConstraints = NO;
    panelView.alpha = 0.98;
    panelView.layer.cornerRadius = kTopBarHeight / 2.0;
    panelView.layer.masksToBounds = YES;
    [self.view addSubview:panelView];
    self.panelView = panelView;

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Tabs";
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    [panelView.contentView addSubview:titleLabel];

    UILabel *subtitleLabel = [UILabel new];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = @"Switch tabs, open a new one, or close the focused tab.";
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [panelView.contentView addSubview:subtitleLabel];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumLineSpacing = kTabCardSpacing;
    layout.minimumInteritemSpacing = kTabCardSpacing;
    layout.sectionInset = UIEdgeInsetsMake(kTabCardGlowInset, kTabCardGlowInset, kTabCardGlowInset, kTabCardGlowInset);
    layout.itemSize = CGSizeMake(kTabCardWidth, kTabCardHeight);

    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    collectionView.backgroundColor = UIColor.clearColor;
    collectionView.clipsToBounds = NO;
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.showsVerticalScrollIndicator = NO;
    collectionView.remembersLastFocusedIndexPath = YES;
    collectionView.dataSource = self;
    collectionView.delegate = self;
    [collectionView registerClass:[BrowserTabOverviewCollectionViewCell class] forCellWithReuseIdentifier:@"TabCard"];
    [panelView.contentView addSubview:collectionView];
    self.collectionView = collectionView;

    UILabel *footerLabel = [UILabel new];
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    footerLabel.text = @"Select: Open   Play/Pause: Close Focused Tab   Menu: Dismiss";
    footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    footerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    footerLabel.textAlignment = NSTextAlignmentCenter;
    [panelView.contentView addSubview:footerLabel];
    self.footerLabel = footerLabel;

    CGFloat panelWidth = [self panelWidth];
    CGFloat panelHeight = [self panelHeight];
    [NSLayoutConstraint activateConstraints:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kTabOverviewPanelTopInset],
        [panelView.widthAnchor constraintEqualToConstant:panelWidth],
        [panelView.heightAnchor constraintEqualToConstant:panelHeight],

        [titleLabel.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor constant:kTabOverviewPanelSideInset],
        [titleLabel.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor constant:kTabOverviewHeaderTopInset],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:panelView.contentView.trailingAnchor constant:-kTabOverviewPanelSideInset],
        [titleLabel.heightAnchor constraintEqualToConstant:kTabOverviewTitleHeight],

        [subtitleLabel.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor constant:kTabOverviewPanelSideInset],
        [subtitleLabel.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor constant:kTabOverviewSubtitleTop],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor constant:-kTabOverviewPanelSideInset],
        [subtitleLabel.heightAnchor constraintEqualToConstant:kTabOverviewSubtitleHeight],

        [collectionView.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor constant:kTabOverviewPanelSideInset],
        [collectionView.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor constant:-kTabOverviewPanelSideInset],
        [collectionView.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor constant:kTabOverviewContentTopInset],
        [collectionView.bottomAnchor constraintEqualToAnchor:footerLabel.topAnchor constant:-18.0],

        [footerLabel.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor constant:kTabOverviewPanelSideInset],
        [footerLabel.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor constant:-kTabOverviewPanelSideInset],
        [footerLabel.bottomAnchor constraintEqualToAnchor:panelView.contentView.bottomAnchor constant:-24.0],
        [footerLabel.heightAnchor constraintEqualToConstant:kTabOverviewFooterHeight],
    ]];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.overviewController overviewViewControllerDidDisappear:self];
}

- (void)reload {
    NSInteger itemCount = [self.overviewController numberOfDisplayItems];
    if (self.preferredFocusItemIndex == NSNotFound) {
        self.preferredFocusItemIndex = [self currentFocusedItemIndex];
    }
    if (self.preferredFocusItemIndex == NSNotFound) {
        self.preferredFocusItemIndex = [self.overviewController activeTabDisplayItemIndex];
    }
    if (itemCount > 0) {
        self.preferredFocusItemIndex = MIN(MAX(self.preferredFocusItemIndex, 0), itemCount - 1);
    }
    [self.collectionView reloadData];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsFocusUpdate];
        [self updateFocusIfNeeded];
    });
}

- (void)updateCardAtTabIndex:(NSInteger)tabIndex {
    NSInteger itemIndex = tabIndex;
    if (itemIndex < 0 || itemIndex >= self.overviewController.viewModel.tabs.count) {
        [self reload];
        return;
    }
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:itemIndex inSection:0];
    if ([[self.collectionView indexPathsForVisibleItems] containsObject:indexPath]) {
        [self.collectionView reloadItemsAtIndexPaths:@[indexPath]];
    } else {
        [self.collectionView reloadData];
    }
}

- (void)handleAlternateAction {
    NSInteger focusedItemIndex = [self currentFocusedItemIndex];
    if (focusedItemIndex == NSNotFound || focusedItemIndex >= self.overviewController.viewModel.tabs.count) {
        return;
    }
    self.preferredFocusItemIndex = focusedItemIndex;
    [self.overviewController handleCloseRequestForDisplayItemIndex:focusedItemIndex];
}

- (NSInteger)currentFocusedItemIndex {
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
        if (cell.isFocused) {
            return indexPath.item;
        }
    }
    return NSNotFound;
}

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return section == 0 ? [self.overviewController numberOfDisplayItems] : 0;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BrowserTabOverviewCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"TabCard" forIndexPath:indexPath];
    if (indexPath.item == self.overviewController.viewModel.tabs.count) {
        [cell configureAsAddCard];
        return cell;
    }

    BrowserTabViewModel *tab = [self.overviewController tabForDisplayItemIndex:indexPath.item];
    BOOL activeTab = indexPath.item == [self.overviewController activeTabDisplayItemIndex];
    [cell configureWithTab:tab activeTab:activeTab];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    [self.overviewController handleSelectionForDisplayItemIndex:indexPath.item];
}

- (NSIndexPath *)indexPathForPreferredFocusedViewInCollectionView:(UICollectionView *)collectionView {
    NSInteger itemCount = [self.overviewController numberOfDisplayItems];
    if (itemCount == 0) {
        return nil;
    }
    NSInteger preferredItemIndex = self.preferredFocusItemIndex;
    if (preferredItemIndex == NSNotFound) {
        preferredItemIndex = [self.overviewController activeTabDisplayItemIndex];
    }
    preferredItemIndex = MIN(MAX(preferredItemIndex, 0), itemCount - 1);
    return [NSIndexPath indexPathForItem:preferredItemIndex inSection:0];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.collectionView];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        [self.overviewController dismiss];
        return;
    }
    if (press != nil && press.type == UIPressTypePlayPause) {
        [self handleAlternateAction];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@implementation BrowserTabOverviewController

- (instancetype)initWithHost:(id<BrowserTabOverviewControllerHost>)host
                   viewModel:(BrowserViewModel *)viewModel
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView {
    (void)rootView;
    (void)topMenuView;
    (void)cursorView;
    self = [super init];
    if (self) {
        _host = host;
        _viewModel = viewModel;
    }
    return self;
}

- (NSInteger)numberOfDisplayItems {
    return self.viewModel.tabs.count + 1;
}

- (NSInteger)activeTabDisplayItemIndex {
    return self.viewModel.activeTabIndex == NSNotFound ? 0 : self.viewModel.activeTabIndex;
}

- (BrowserTabViewModel *)tabForDisplayItemIndex:(NSInteger)displayItemIndex {
    if (displayItemIndex < 0 || displayItemIndex >= self.viewModel.tabs.count) {
        return nil;
    }
    return self.viewModel.tabs[displayItemIndex];
}

- (void)show {
    if (self.visible) {
        [self reload];
        return;
    }

    self.cursorModeBeforeShowing = [self.host browserTabOverviewControllerCursorModeEnabled];
    self.visible = YES;
    [self.host browserTabOverviewControllerSetCursorModeEnabled:NO];

    BrowserTabOverviewViewController *viewController = [[BrowserTabOverviewViewController alloc] initWithOverviewController:self];
    self.presentedOverviewViewController = viewController;
    [self.host browserTabOverviewControllerPresentViewController:viewController];
}

- (void)dismiss {
    if (!self.visible) {
        return;
    }

    BrowserTabOverviewViewController *viewController = self.presentedOverviewViewController;
    if (viewController == nil) {
        [self overviewViewControllerDidDisappear:nil];
        return;
    }
    [viewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)reload {
    [self reloadPresentedOverviewIfNeeded];
}

- (void)updateCardAtIndex:(NSInteger)tabIndex {
    [self.presentedOverviewViewController updateCardAtTabIndex:tabIndex];
}

- (BOOL)containsPoint:(CGPoint)viewPoint {
    (void)viewPoint;
    return NO;
}

- (BOOL)handleSelectionAtPoint:(CGPoint)viewPoint {
    (void)viewPoint;
    return NO;
}

- (void)handleSelectionForDisplayItemIndex:(NSInteger)displayItemIndex {
    if (displayItemIndex >= self.viewModel.tabs.count) {
        BrowserTabOverviewViewController *viewController = self.presentedOverviewViewController;
        if (viewController == nil) {
            [self.host browserTabOverviewControllerCreateNewTabLoadingHomePage:YES];
            return;
        }

        [viewController dismissViewControllerAnimated:YES completion:^{
            [self.host browserTabOverviewControllerCreateNewTabLoadingHomePage:YES];
        }];
        return;
    }

    [self.host browserTabOverviewControllerSwitchToTabAtIndex:displayItemIndex];
    [self dismiss];
}

- (void)handleCloseRequestForDisplayItemIndex:(NSInteger)displayItemIndex {
    NSInteger tabIndex = displayItemIndex;
    if (tabIndex < 0 || tabIndex >= self.viewModel.tabs.count || self.viewModel.tabs.count <= 1) {
        return;
    }

    [self.host browserTabOverviewControllerCloseTabAtIndex:tabIndex];
    [self reloadPresentedOverviewIfNeeded];
}

- (void)handleAlternateAction {
    [self.presentedOverviewViewController handleAlternateAction];
}

- (void)reloadPresentedOverviewIfNeeded {
    [self.presentedOverviewViewController reload];
}

- (void)overviewViewControllerDidDisappear:(BrowserTabOverviewViewController *)viewController {
    if (viewController != nil && viewController != self.presentedOverviewViewController) {
        return;
    }

    self.presentedOverviewViewController = nil;
    if (!self.visible) {
        return;
    }

    self.visible = NO;
    [self.host browserTabOverviewControllerSetCursorModeEnabled:self.cursorModeBeforeShowing];
}

@end
```

## `BrowserTabViewModel.h`  (19줄)

```objc
#import <UIKit/UIKit.h>

@interface BrowserTabViewModel : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy) NSString *requestURL;
@property (nonatomic, copy) NSString *previousURL;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *URLString;
@property (nonatomic, strong) UIImage *snapshotImage;
@property (nonatomic) CGPoint savedScrollOffset;
@property (nonatomic) BOOL hasSavedScrollOffset;
@property (nonatomic) BOOL needsScrollRestore;

- (instancetype)initWithSessionRepresentation:(NSDictionary *)sessionRepresentation;
- (NSDictionary *)sessionRepresentation;

@end
```

## `BrowserTabViewModel.m`  (60줄)

```objc
#import "BrowserTabViewModel.h"

@implementation BrowserTabViewModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = [[[NSUUID UUID] UUIDString] copy];
        _requestURL = @"";
        _previousURL = @"";
        _title = @"New Tab";
        _URLString = @"";
        _savedScrollOffset = CGPointZero;
        _hasSavedScrollOffset = NO;
        _needsScrollRestore = NO;
    }
    return self;
}

- (instancetype)initWithSessionRepresentation:(NSDictionary *)sessionRepresentation {
    self = [self init];
    if (self == nil) {
        return nil;
    }
    
    NSString *requestURL = [sessionRepresentation[@"requestURL"] isKindOfClass:[NSString class]] ? sessionRepresentation[@"requestURL"] : @"";
    NSString *previousURL = [sessionRepresentation[@"previousURL"] isKindOfClass:[NSString class]] ? sessionRepresentation[@"previousURL"] : @"";
    NSString *title = [sessionRepresentation[@"title"] isKindOfClass:[NSString class]] ? sessionRepresentation[@"title"] : @"New Tab";
    NSString *URLString = [sessionRepresentation[@"URLString"] isKindOfClass:[NSString class]] ? sessionRepresentation[@"URLString"] : @"";
    NSNumber *scrollOffsetX = [sessionRepresentation[@"scrollOffsetX"] isKindOfClass:[NSNumber class]] ? sessionRepresentation[@"scrollOffsetX"] : nil;
    NSNumber *scrollOffsetY = [sessionRepresentation[@"scrollOffsetY"] isKindOfClass:[NSNumber class]] ? sessionRepresentation[@"scrollOffsetY"] : nil;
    
    self.requestURL = requestURL;
    self.previousURL = previousURL;
    self.title = title.length > 0 ? title : @"New Tab";
    self.URLString = URLString;
    if (scrollOffsetX != nil && scrollOffsetY != nil) {
        self.savedScrollOffset = CGPointMake(scrollOffsetX.doubleValue, scrollOffsetY.doubleValue);
        self.hasSavedScrollOffset = YES;
        self.needsScrollRestore = YES;
    }
    
    return self;
}

- (NSDictionary *)sessionRepresentation {
    NSMutableDictionary *representation = [NSMutableDictionary dictionary];
    representation[@"requestURL"] = self.requestURL ?: @"";
    representation[@"previousURL"] = self.previousURL ?: @"";
    representation[@"title"] = self.title ?: @"New Tab";
    representation[@"URLString"] = self.URLString ?: @"";
    if (self.hasSavedScrollOffset) {
        representation[@"scrollOffsetX"] = @(self.savedScrollOffset.x);
        representation[@"scrollOffsetY"] = @(self.savedScrollOffset.y);
    }
    return representation;
}

@end
```

## `BrowserViewModel.h`  (21줄)

```objc
#import <Foundation/Foundation.h>

@class BrowserTabViewModel;

@interface BrowserViewModel : NSObject

@property (nonatomic, strong, readonly) NSMutableArray *tabs;
@property (nonatomic) NSInteger activeTabIndex;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) BOOL tabOverviewVisible;
@property (nonatomic) NSUInteger textFontSize;

- (BrowserTabViewModel *)activeTab;
- (BrowserTabViewModel *)addTab;
- (BrowserTabViewModel *)ensureActiveTab;
- (BrowserTabViewModel *)removeTabAtIndex:(NSInteger)tabIndex;
- (void)restoreTabs:(NSArray<BrowserTabViewModel *> *)tabs activeTabIndex:(NSInteger)activeTabIndex;
- (void)switchToTabAtIndex:(NSInteger)tabIndex;

@end
```

## `BrowserViewModel.m`  (104줄)

```objc
#import "BrowserViewModel.h"

#import "BrowserTabViewModel.h"

static NSUInteger const kDefaultTextFontSize = 100;
static NSUInteger const kMinimumTextFontSize = 50;
static NSUInteger const kMaximumTextFontSize = 200;
static NSUInteger const kMaximumTabCount = 5;
@implementation BrowserViewModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _tabs = [NSMutableArray array];
        _activeTabIndex = NSNotFound;
        _topNavigationBarVisible = YES;
        _textFontSize = kDefaultTextFontSize;
    }
    return self;
}

- (BrowserTabViewModel *)activeTab {
    if (self.activeTabIndex == NSNotFound || self.activeTabIndex < 0 || self.activeTabIndex >= self.tabs.count) {
        return nil;
    }
    return self.tabs[self.activeTabIndex];
}

- (BrowserTabViewModel *)addTab {
    if (self.tabs.count >= kMaximumTabCount) {
        return nil;
    }
    
    BrowserTabViewModel *tab = [BrowserTabViewModel new];
    [self.tabs addObject:tab];
    self.activeTabIndex = self.tabs.count - 1;
    return tab;
}

- (BrowserTabViewModel *)ensureActiveTab {
    BrowserTabViewModel *tab = [self activeTab];
    if (tab != nil) {
        return tab;
    }
    return [self addTab];
}

- (BrowserTabViewModel *)removeTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.tabs.count) {
        return nil;
    }
    
    BrowserTabViewModel *removedTab = self.tabs[tabIndex];
    [self.tabs removeObjectAtIndex:tabIndex];
    
    if (self.tabs.count == 0) {
        self.activeTabIndex = NSNotFound;
    } else if (tabIndex == self.activeTabIndex) {
        self.activeTabIndex = MIN(tabIndex, self.tabs.count - 1);
    } else if (tabIndex < self.activeTabIndex) {
        self.activeTabIndex -= 1;
    }
    
    return removedTab;
}

- (void)restoreTabs:(NSArray<BrowserTabViewModel *> *)tabs activeTabIndex:(NSInteger)activeTabIndex {
    [self.tabs removeAllObjects];
    if (tabs.count > 0) {
        [self.tabs addObjectsFromArray:tabs];
    }
    
    if (self.tabs.count == 0) {
        self.activeTabIndex = NSNotFound;
        return;
    }
    
    if (activeTabIndex < 0 || activeTabIndex >= self.tabs.count) {
        self.activeTabIndex = 0;
        return;
    }
    
    self.activeTabIndex = activeTabIndex;
}

- (void)switchToTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.tabs.count) {
        return;
    }
    self.activeTabIndex = tabIndex;
}

- (void)setTopNavigationBarVisible:(BOOL)topNavigationBarVisible {
    _topNavigationBarVisible = topNavigationBarVisible;
}

- (void)setTextFontSize:(NSUInteger)textFontSize {
    textFontSize = MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
    _textFontSize = textFontSize;
}


@end
```

## `AppDelegate.h`  (18줄)

```objc
//
//  AppDelegate.h
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;


@end
```

## `AppDelegate.m`  (83줄)

```objc
//
//  AppDelegate.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "AppDelegate.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (void)restoreCookiesFromDefaults {
    NSData *cookieData = [[NSUserDefaults standardUserDefaults] objectForKey:@"ApplicationCookie"];
    if (cookieData.length == 0) {
        return;
    }

    [BrowserWebView restoreCookiesFromData:cookieData];
}

- (void)saveCookiesToDefaults {
    NSData *cookieData = [BrowserWebView cookieDataRepresentation];
    if (cookieData == nil) {
        return;
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:cookieData forKey:@"ApplicationCookie"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	// Override point for customization after application launch.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"MobileMode"]) {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.mobileUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    else {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.desktopUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    [self restoreCookiesFromDefaults];
	return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
	// Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
	// Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    [self saveCookiesToDefaults];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	// Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
	// If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    [self saveCookiesToDefaults];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	// Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    [self restoreCookiesFromDefaults];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	// Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    [self restoreCookiesFromDefaults];
}

- (void)applicationWillTerminate:(UIApplication *)application {
	// Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [self saveCookiesToDefaults];
}

@end
```

## `UIApplication+BrowserSelectPressForwarding.m`  (266줄)

```objc
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const BrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";
static BOOL sBrowserNativeScrubTracking = NO;
static CGFloat sBrowserNativePendingScrubPixels = 0.0;
static CGPoint sBrowserNativeLastTouchLocation = {0, 0};
static CFTimeInterval sBrowserNativeLastArrowPressTimestamp = 0.0;
static UIPressType sBrowserNativeLastArrowPressType = (UIPressType)-1;
static CGFloat const kBrowserNativeScrubPixelStep = 18.0;
static CFTimeInterval const kBrowserNativeArrowDoubleTapInterval = 0.35;

static NSString *BrowserPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

static UIViewController *BrowserFindViewControllerOfClass(UIViewController *viewController, Class targetClass) {
    if (viewController == nil || targetClass == Nil) {
        return nil;
    }

    if ([viewController isKindOfClass:targetClass]) {
        return viewController;
    }

    if (viewController.presentedViewController != nil) {
        UIViewController *match = BrowserFindViewControllerOfClass(viewController.presentedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    for (UIViewController *childViewController in viewController.childViewControllers) {
        UIViewController *match = BrowserFindViewControllerOfClass(childViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(navigationController.visibleViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabBarController = (UITabBarController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(tabBarController.selectedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

static UIViewController *BrowserFindPresentedNativeVideoPlayerViewController(UIApplication *application, Class nativeVideoPlayerClass) {
    for (UIWindow *window in application.windows) {
        if (window.hidden || window.rootViewController == nil) {
            continue;
        }

        UIViewController *match = BrowserFindViewControllerOfClass(window.rootViewController, nativeVideoPlayerClass);
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

@interface UIApplication (BrowserSelectPressForwarding)

- (void)browser_sendEvent:(UIEvent *)event;

@end

@implementation UIApplication (BrowserSelectPressForwarding)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalMethod = class_getInstanceMethod(self, @selector(sendEvent:));
        Method replacementMethod = class_getInstanceMethod(self, @selector(browser_sendEvent:));
        if (originalMethod != NULL && replacementMethod != NULL) {
            method_exchangeImplementations(originalMethod, replacementMethod);
        }
    });
}

- (void)browser_sendEvent:(UIEvent *)event {
    Class nativeVideoPlayerClass = NSClassFromString(@"BrowserNativeVideoPlayerViewController");
    UIViewController *nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);

    if (event.type == UIEventTypeTouches) {
        SEL allTouchesSelector = NSSelectorFromString(@"allTouches");
        if ([event respondsToSelector:allTouchesSelector]) {
            NSSet<UITouch *> *touches = ((id (*)(id, SEL))objc_msgSend)(event, allTouchesSelector);
            for (UITouch *touch in touches) {
                if (touch.type != UITouchTypeIndirect) {
                    continue;
                }

                CGPoint location = [touch locationInView:nil];
                if (touch.phase == UITouchPhaseBegan) {
                    sBrowserNativeScrubTracking = (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil);
                    sBrowserNativePendingScrubPixels = 0.0;
                    sBrowserNativeLastTouchLocation = location;
                    continue;
                }

                if (!sBrowserNativeScrubTracking || nativeVideoPlayerViewController == nil) {
                    continue;
                }

                if (touch.phase == UITouchPhaseMoved) {
                    CGFloat deltaX = location.x - sBrowserNativeLastTouchLocation.x;
                    sBrowserNativeLastTouchLocation = location;
                    sBrowserNativePendingScrubPixels += deltaX;

                    SEL scrubSelector = NSSelectorFromString(@"scrubByHorizontalDelta:");
                    if ([nativeVideoPlayerViewController respondsToSelector:scrubSelector]) {
                        while (fabs(sBrowserNativePendingScrubPixels) >= kBrowserNativeScrubPixelStep) {
                            CGFloat step = sBrowserNativePendingScrubPixels > 0.0 ? kBrowserNativeScrubPixelStep : -kBrowserNativeScrubPixelStep;
                            ((void (*)(id, SEL, CGFloat))objc_msgSend)(nativeVideoPlayerViewController, scrubSelector, step);
                            sBrowserNativePendingScrubPixels -= step;
                            NSLog(@"[InputTrace][App] scrub step delta=%.2f", step);
                        }
                    }
                }

                if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                    sBrowserNativeScrubTracking = NO;
                    sBrowserNativePendingScrubPixels = 0.0;
                }
            }
        }

        [self browser_sendEvent:event];
        return;
    }

    if (event.type != UIEventTypePresses) {
        [self browser_sendEvent:event];
        return;
    }

    SEL allPressesSelector = NSSelectorFromString(@"allPresses");
    if (![event respondsToSelector:allPressesSelector]) {
        [self browser_sendEvent:event];
        return;
    }

    NSSet<UIPress *> *presses = ((id (*)(id, SEL))objc_msgSend)(event, allPressesSelector);
    for (UIPress *press in presses) {
        nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
            NSLog(@"[InputTrace][App] press=%@ phase=%@ top=%@",
                  BrowserPressTypeString(press.type),
                  BrowserPressPhaseString(press.phase),
                  nativeVideoPlayerViewController == nil ? @"(nil)" : NSStringFromClass([nativeVideoPlayerViewController class]));
        }

        if (press.type == UIPressTypeMenu && press.phase == UIPressPhaseBegan) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                NSLog(@"[InputTrace][App] swallow Menu for native player");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [nativeVideoPlayerViewController dismissViewControllerAnimated:YES completion:nil];
                });
                return;
            }
        }

        if (press.type == UIPressTypePlayPause && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL togglePlaybackSelector = NSSelectorFromString(@"togglePlayback");
                if ([nativeVideoPlayerViewController respondsToSelector:togglePlaybackSelector]) {
                    NSLog(@"[InputTrace][App] swallow PlayPause for native player");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(nativeVideoPlayerViewController, togglePlaybackSelector);
                    });
                    return;
                }
            }
        }

        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL togglePlaybackSelector = NSSelectorFromString(@"togglePlayback");
                if ([nativeVideoPlayerViewController respondsToSelector:togglePlaybackSelector]) {
                    NSLog(@"[InputTrace][App] swallow Select for native player");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(nativeVideoPlayerViewController, togglePlaybackSelector);
                    });
                    return;
                }
            }
        }

        if ((press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow) && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL skipSelector = NSSelectorFromString(@"skipByInterval:");
                if ([nativeVideoPlayerViewController respondsToSelector:skipSelector]) {
                    CFTimeInterval now = CACurrentMediaTime();
                    BOOL isDoubleTap = (sBrowserNativeLastArrowPressType == press.type) &&
                                       ((now - sBrowserNativeLastArrowPressTimestamp) <= kBrowserNativeArrowDoubleTapInterval);
                    sBrowserNativeLastArrowPressType = press.type;
                    sBrowserNativeLastArrowPressTimestamp = now;

                    if (isDoubleTap) {
                        NSTimeInterval delta = (press.type == UIPressTypeRightArrow) ? 5.0 : -5.0;
                        NSLog(@"[InputTrace][App] swallow %@ double tap for native player (delta=%0.1f)",
                              BrowserPressTypeString(press.type), delta);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(nativeVideoPlayerViewController, skipSelector, delta);
                        });
                        sBrowserNativeLastArrowPressType = (UIPressType)-1;
                        sBrowserNativeLastArrowPressTimestamp = 0.0;
                    } else {
                        NSLog(@"[InputTrace][App] swallow %@ single tap for native player (waiting for double tap)",
                              BrowserPressTypeString(press.type));
                    }
                    return;
                }
            }
        }
    }

    [self browser_sendEvent:event];

    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            NSLog(@"[InputTrace][App] post BrowserGlobalSelectPressEndedNotification");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalSelectPressEndedNotification object:nil];
            });
            break;
        }
    }
}

@end
```
