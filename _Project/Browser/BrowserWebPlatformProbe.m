#import "BrowserWebPlatformProbe.h"

#import "BrowserWebView.h"

#import <objc/message.h>
#import <objc/runtime.h>

static void BrowserAppendClassLine(NSMutableString *report, NSString *className) {
    Class klass = NSClassFromString(className);
    [report appendFormat:@"%@ %@\n", klass != Nil ? @"[o]" : @"[x]", className];
}

static void BrowserAppendSelectorLine(NSMutableString *report, id object, NSString *selectorName) {
    BOOL responds = object != nil && [object respondsToSelector:NSSelectorFromString(selectorName)];
    [report appendFormat:@"%@ %@\n", responds ? @"[o]" : @"[x]", selectorName];
}

@implementation BrowserWebPlatformProbe

+ (NSString *)runtimeReportForWebView:(BrowserWebView *)webView {
    NSMutableString *report = [NSMutableString string];

    [report appendFormat:@"web content deaths: %lu\n",
     (unsigned long)webView.webContentTerminationCount];
    if (webView.webContentTerminationCount > 0) {
        NSTimeInterval ago = [NSDate timeIntervalSinceReferenceDate] - webView.lastWebContentTerminationTime;
        [report appendFormat:@"last death: %.0f s ago\n", ago];
        [report appendString:@"A dead content process is a blank page on which\n"
                              "no script runs, which is what an empty probe means.\n"];
    }
    [report appendString:@"\n— Classes —\n"];
    for (NSString *className in @[@"WKWebView",
                                  @"WKWebViewConfiguration",
                                  @"WKPreferences",
                                  @"WKUserContentController",
                                  @"WKUserScript",
                                  @"WKWebsiteDataStore",
                                  @"WKContentRuleListStore",
                                  @"WKWebpagePreferences",
                                  @"WKFrameInfo",
                                  @"WKSnapshotConfiguration",
                                  @"WKDownload",
                                  @"WKFindConfiguration"]) {
        BrowserAppendClassLine(report, className);
    }

    id runtimeWebView = [webView runtimeWebViewForProbing];
    if (runtimeWebView == nil) {
        [report appendString:@"\nNo live web view: selector probes skipped.\n"];
        return report;
    }

    [report appendFormat:@"\n— WKWebView (%@) —\n", NSStringFromClass([runtimeWebView class])];
    for (NSString *selectorName in @[@"setInspectable:",
                                     @"isInspectable",
                                     @"_setInspectable:",
                                     @"_webProcessIdentifier",
                                     @"takeSnapshotWithConfiguration:completionHandler:",
                                     @"createPDFWithConfiguration:completionHandler:",
                                     @"findString:withConfiguration:completionHandler:",
                                     @"callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:",
                                     @"evaluateJavaScript:inFrame:inContentWorld:completionHandler:",
                                     @"closeAllMediaPresentations",
                                     @"pauseAllMediaPlaybackWithCompletionHandler:",
                                     @"setAllMediaPlaybackSuspended:completionHandler:",
                                     @"_setPageZoom:",
                                     @"setPageZoom:",
                                     @"_killWebContentProcess",
                                     @"_close"]) {
        BrowserAppendSelectorLine(report, runtimeWebView, selectorName);
    }

    SEL pidSelector = NSSelectorFromString(@"_webProcessIdentifier");
    if ([runtimeWebView respondsToSelector:pidSelector]) {
        int webPID = ((int (*)(id, SEL))objc_msgSend)(runtimeWebView, pidSelector);
        int ourPID = (int)NSProcessInfo.processInfo.processIdentifier;
        [report appendFormat:@"\nweb content pid = %d, app pid = %d\n", webPID, ourPID];
        if (webPID > 0 && webPID != ourPID) {
            [report appendString:@"Separate web content process: JavaScript runs under WebKit's own\n"
                                  "process and entitlements, not this app's.\n"];
        } else if (webPID == 0) {
            [report appendString:@"No separate process reported.\n"];
        }
    }

    SEL configurationSelector = NSSelectorFromString(@"configuration");
    id configuration = [runtimeWebView respondsToSelector:configurationSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(runtimeWebView, configurationSelector)
        : nil;
    SEL preferencesSelector = NSSelectorFromString(@"preferences");
    id preferences = (configuration != nil && [configuration respondsToSelector:preferencesSelector])
        ? ((id (*)(id, SEL))objc_msgSend)(configuration, preferencesSelector)
        : nil;

    [report appendFormat:@"\n— WKPreferences (%@) —\n",
     preferences != nil ? NSStringFromClass([preferences class]) : @"unavailable"];
    for (NSString *selectorName in @[@"_setDeveloperExtrasEnabled:",
                                     @"_developerExtrasEnabled",
                                     @"_setMediaSourceEnabled:",
                                     @"_mediaSourceEnabled",
                                     @"_setManagedMediaSourceEnabled:",
                                     @"_setNeedsSiteSpecificQuirks:",
                                     @"_setJavaScriptCanAccessClipboard:",
                                     @"setJavaScriptEnabled:",
                                     @"_setFullScreenEnabled:",
                                     @"_setAllowsPictureInPictureMediaPlayback:"]) {
        BrowserAppendSelectorLine(report, preferences, selectorName);
    }

    return report;
}

+ (NSString *)engineJavaScript {
    return
    @"(function(){"
        "var lines = [];"
        "function add(label, value) { lines.push(label + ': ' + value); }"
        "function has(expression) {"
            "try { return eval(expression) ? 'yes' : 'no'; } catch (error) { return 'no'; }"
        "}"
        // Syntax-level features cannot be feature-detected with typeof: a
        // parse error kills the whole script. Each one is compiled on its own
        // so one failure does not hide the rest.
        "function syntax(source) {"
            "try { new Function(source); return 'yes'; } catch (error) { return 'no'; }"
        "}"
        "add('userAgent', navigator.userAgent);"
        "add('platform', navigator.platform || '');"
        "add('deviceMemory', navigator.deviceMemory || 'n/a');"
        "add('hardwareConcurrency', navigator.hardwareConcurrency || 'n/a');"
        "lines.push('');"
        "lines.push('— syntax —');"
        "add('optional chaining', syntax('var a = {}; return a?.b;'));"
        "add('nullish coalescing', syntax('return null ?? 1;'));"
        "add('class fields', syntax('class A { x = 1; }'));"
        "add('static blocks', syntax('class A { static { } }'));"
        "add('logical assignment', syntax('var a = 1; a ||= 2;'));"
        "add('async generator', syntax('async function* g(){}'));"
        "lines.push('');"
        "lines.push('— platform —');"
        "add('customElements', has('window.customElements'));"
        "add('ShadowRoot', has('window.ShadowRoot'));"
        "add('Proxy', has('window.Proxy'));"
        "add('fetch', has('window.fetch'));"
        "add('WebAssembly', has('window.WebAssembly'));"
        "add('structuredClone', has('window.structuredClone'));"
        "add('Object.hasOwn', has('Object.hasOwn'));"
        "add('Array.at', has('Array.prototype.at'));"
        "add('String.replaceAll', has('String.prototype.replaceAll'));"
        "add('ResizeObserver', has('window.ResizeObserver'));"
        "add('IntersectionObserver', has('window.IntersectionObserver'));"
        "add('Intl.Segmenter', has('window.Intl && Intl.Segmenter'));"
        "lines.push('');"
        "lines.push('— media —');"
        "add('MediaSource', has('window.MediaSource'));"
        "add('ManagedMediaSource', has('window.ManagedMediaSource'));"
        "add('EME', has('navigator.requestMediaKeySystemAccess'));"
        "try {"
            "if (window.MediaSource && MediaSource.isTypeSupported) {"
                "var types = ["
                    "'video/mp4; codecs=\"avc1.42E01E\"',"
                    "'video/mp4; codecs=\"avc1.640028\"',"
                    "'video/mp4; codecs=\"hvc1.1.6.L93.B0\"',"
                    "'video/webm; codecs=\"vp9\"',"
                    "'video/mp4; codecs=\"av01.0.05M.08\"',"
                    "'audio/mp4; codecs=\"mp4a.40.2\"',"
                    "'audio/webm; codecs=\"opus\"'"
                "];"
                "for (var i = 0; i < types.length; i++) {"
                    "add('MSE ' + types[i], MediaSource.isTypeSupported(types[i]) ? 'yes' : 'no');"
                "}"
            "} else {"
                "lines.push('MediaSource.isTypeSupported unavailable');"
            "}"
        "} catch (error) { lines.push('MSE probe failed: ' + error); }"
        "var video = document.createElement('video');"
        "if (video && video.canPlayType) {"
            "add('canPlayType hls', video.canPlayType('application/vnd.apple.mpegurl') || 'no');"
            "add('canPlayType mp4', video.canPlayType('video/mp4') || 'no');"
            "add('canPlayType webm', video.canPlayType('video/webm') || 'no');"
        "}"
        "return lines.join('\\n');"
    "})()";
}

+ (NSString *)engineReportForWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"No web view.";
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self engineJavaScript]];
    return result.length > 0 ? result : @"The probe returned nothing. Script evaluation itself failed.";
}

// Only adds listeners and wraps console while still calling through. It does
// not replace fetch or XMLHttpRequest the way the YouTube hook did, so a
// site's own networking is untouched.
+ (NSString *)errorCaptureScript {
    return
    @"(function(){"
        "if (window.__browserErrorCaptureInstalled) { return; }"
        "window.__browserErrorCaptureInstalled = true;"
        "window.__browserCapturedErrors = [];"
        "function record(kind, text) {"
            "try {"
                "var list = window.__browserCapturedErrors;"
                "if (list.length >= 40) { return; }"
                "list.push(kind + ': ' + String(text).slice(0, 300));"
            "} catch (error) {}"
        "}"
        "window.addEventListener('error', function(event) {"
            "try {"
                "if (event && event.target && event.target !== window && event.target.tagName) {"
                    "record('load', event.target.tagName + ' ' + (event.target.src || event.target.href || ''));"
                    "return;"
                "}"
                "var where = event.filename ? (' @' + event.filename + ':' + event.lineno) : '';"
                "record('error', (event.message || 'script error') + where);"
            "} catch (inner) {}"
        "}, true);"
        "window.addEventListener('unhandledrejection', function(event) {"
            "record('promise', (event && event.reason) ? event.reason : 'unhandled rejection');"
        "});"
        "try {"
            "['error', 'warn'].forEach(function(level) {"
                "var original = console[level];"
                "console[level] = function() {"
                    "record(level, Array.prototype.join.call(arguments, ' '));"
                    "if (original) { return original.apply(console, arguments); }"
                "};"
            "});"
        "} catch (error) {}"
    "})();";
}

+ (NSString *)pageErrorReportForWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"No web view.";
    }

    NSString *script =
        @"(function(){"
            "if (!window.__browserErrorCaptureInstalled) { return 'CAPTURE NOT INSTALLED'; }"
            "var list = window.__browserCapturedErrors || [];"
            "var head = 'url: ' + String(location.href).slice(0, 120) + '\\n'"
                     "+ 'readyState: ' + document.readyState + '\\n'"
                     "+ 'body children: ' + ((document.body && document.body.children.length) || 0) + '\\n'"
                     "+ 'text length: ' + ((document.body && document.body.innerText) ? document.body.innerText.length : 0) + '\\n'"
                     "+ 'scripts: ' + document.querySelectorAll('script').length + '\\n\\n';"
            "if (list.length === 0) { return head + 'No script errors recorded.'; }"
            "return head + list.join('\\n');"
        "})()";

    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    return result.length > 0 ? result : @"The probe returned nothing. Script evaluation itself failed.";
}

@end
