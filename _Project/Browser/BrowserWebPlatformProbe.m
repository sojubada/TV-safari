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

    SEL mediaSourceGetter = NSSelectorFromString(@"_mediaSourceEnabled");
    if (preferences != nil && [preferences respondsToSelector:mediaSourceGetter]) {
        BOOL mediaSourceEnabled = ((BOOL (*)(id, SEL))objc_msgSend)(preferences, mediaSourceGetter);
        [report appendFormat:@"\nMediaSource actually enabled: %@\n", mediaSourceEnabled ? @"YES" : @"NO"];
    }

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

static NSTimeInterval const kBrowserProbeEvaluationTimeout = 10.0;

+ (NSString *)evaluate:(NSString *)script onWebView:(BrowserWebView *)webView {
    BrowserScriptEvaluationStatus status = BrowserScriptEvaluationStatusOK;
    NSString *reason = nil;
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script
                                                               timeout:kBrowserProbeEvaluationTimeout
                                                                status:&status
                                                         failureReason:&reason];
    if (result.length > 0) {
        return result;
    }

    NSMutableString *explanation = [NSMutableString string];
    [explanation appendFormat:@"No result: %@\n",
     [BrowserWebView descriptionForScriptEvaluationStatus:status]];
    if (reason.length > 0) {
        [explanation appendFormat:@"%@\n", reason];
    }
    [explanation appendFormat:@"\nweb content deaths: %lu\n",
     (unsigned long)webView.webContentTerminationCount];

    switch (status) {
        case BrowserScriptEvaluationStatusNoWebProcess:
            [explanation appendString:@"\nThe page has no process behind it. That is a blank\n"
                                       "screen by definition. Reload, or use Restart Page\n"
                                       "Process in the privacy menu.\n"];
            break;
        case BrowserScriptEvaluationStatusTimedOut:
            [explanation appendFormat:@"\nThe process is alive but did not answer within %.0f\n"
                                       "seconds, so the page is busy rather than gone. A site\n"
                                       "this heavy is the usual cause; its mobile version is\n"
                                       "much lighter.\n", kBrowserProbeEvaluationTimeout];
            break;
        default:
            break;
    }
    return explanation;
}

+ (NSString *)engineReportForWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"No web view.";
    }
    return [self evaluate:[self engineJavaScript] onWebView:webView];
}

// Only adds listeners and wraps console while still calling through. It does
// not replace fetch or XMLHttpRequest the way the YouTube hook did, so a
// site's own networking is untouched.
@end
