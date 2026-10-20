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