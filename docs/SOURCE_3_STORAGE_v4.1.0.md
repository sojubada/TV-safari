# tvOS Browser v4.1.0 — 웹뷰 래퍼·저장소 (5-3 검토 대상)

WebKit 런타임 접근과 즐겨찾기 폴더입니다.

> 검토 지침은 `REVIEW_v4.1.0.md`를 먼저 읽어 주십시오.

## `BrowserWebView.h`  (101줄)

```objc
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class BrowserWebView;

@protocol BrowserWebViewDelegate <NSObject>

@optional
- (BOOL)webView:(id _Nonnull)webView shouldStartLoadWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (BOOL)webView:(id _Nonnull)webView shouldCreateNewTabWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (void)webViewDidStartLoad:(id _Nonnull)webView;
- (void)webViewDidFinishLoad:(id _Nonnull)webView;
- (void)webView:(id _Nonnull)webView didFailLoadWithError:(NSError * _Nonnull)error;
- (void)browserWebViewWebContentProcessDidTerminate:(BrowserWebView *)webView;

@end

@interface BrowserWebView : UIView

@property (nullable, nonatomic, weak) id<BrowserWebViewDelegate> delegate;
@property (nullable, nonatomic, readonly, strong) NSURLRequest *request;
@property (nullable, nonatomic, readonly, strong) UIScrollView *scrollView;
@property (nullable, nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, getter=canGoBack) BOOL canGoBack;
@property (nonatomic, readonly, getter=canGoForward) BOOL canGoForward;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic) BOOL scalesPageToFit;

/// Reading zoom chosen by the person, 1.0 == 100%. Applied on every
/// load and combined with scalesPageToFit.
@property (nonatomic) CGFloat userPageZoom;

/// Re-applies userPageZoom (and scalesPageToFit) to the live page.
- (void)applyPageScalingIfNeeded;

/// WebKit's floor on rendered text size, in points. 0 disables it.
- (void)setMinimumFontSize:(CGFloat)minimumFontSize;

- (instancetype)initWithUserAgent:(NSString * _Nullable)userAgent
      allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback NS_DESIGNATED_INITIALIZER;

- (void)loadRequest:(NSURLRequest * _Nullable)request;
- (void)reload;
- (void)goBack;
- (void)goForward;
- (nullable NSString *)stringByEvaluatingJavaScriptFromString:(NSString * _Nonnull)script;

// Why an evaluation produced nothing. Returning a bare nil made a timeout, a
// dead process and a script error look identical, which is how a probe meant
// to remove guesswork ended up producing it.
typedef NS_ENUM(NSInteger, BrowserScriptEvaluationStatus) {
    BrowserScriptEvaluationStatusOK = 0,
    BrowserScriptEvaluationStatusNoWebView,
    BrowserScriptEvaluationStatusUnsupported,
    BrowserScriptEvaluationStatusNoWebProcess,
    BrowserScriptEvaluationStatusReentrant,
    BrowserScriptEvaluationStatusTimedOut,
    BrowserScriptEvaluationStatusScriptError,
};

- (nullable NSString *)stringByEvaluatingJavaScriptFromString:(NSString * _Nonnull)script
                                                      timeout:(NSTimeInterval)timeout
                                                       status:(nullable BrowserScriptEvaluationStatus *)status
                                                 failureReason:(NSString * _Nullable * _Nullable)failureReason;

+ (NSString *)descriptionForScriptEvaluationStatus:(BrowserScriptEvaluationStatus)status;
- (NSString * _Nonnull)runtimeMediaPreferenceReport;
- (void)setUserAgent:(NSString * _Nullable)userAgent;
- (nullable NSString *)currentUserAgent;

// Tears the page's process down and loads it again. The way back from a
// process that is wedged rather than dead.
- (BOOL)restartWebContentProcess;
- (void)pauseAllMediaPlayback;

+ (void)installRuleListToConfiguration:(id)configuration;

// Turns on WebKit's MediaSource path, which Apple leaves off on this
// platform. Forcing a disabled code path is a candidate for the process
// dying on video playback, so it is a switch rather than an assumption.

// The underlying WKWebView, for the platform probe to interrogate. Nil when
// WebKit could not be reached at all.
- (nullable id)runtimeWebViewForProbing;

// How many times this web view's content process has died, and when it last
// happened. A dead process is a blank page on which no script can run.
@property (nonatomic, readonly) NSUInteger webContentTerminationCount;
@property (nonatomic, readonly) NSTimeInterval lastWebContentTerminationTime;

+ (nullable NSData *)cookieDataRepresentation;
+ (NSArray<NSHTTPCookie *> * _Nonnull)allCookies;
+ (void)restoreCookiesFromData:(NSData * _Nullable)cookieData;
+ (void)clearCachedDataWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)clearCookiesWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)resetWebsiteDataWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserWebView.m`  (1169줄)

```objc
#import "BrowserWebView.h"
#import "BrowserContentBlockerController.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kBrowserWebViewClassName = @"WKWebView";
static NSString * const kBrowserWebViewConfigurationClassName = @"WKWebViewConfiguration";
static NSString * const kBrowserWebsiteDataStoreClassName = @"WKWebsiteDataStore";


static void BrowserEnsureWebKitRuntimeLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(kBrowserWebViewClassName) != Nil) {
            return;
        }

        NSArray<NSString *> *candidatePaths = @[
            @"/System/Library/Frameworks/WebKit.framework/WebKit",
            @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
        ];

        for (NSString *candidatePath in candidatePaths) {
            if (dlopen(candidatePath.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(kBrowserWebViewClassName) != Nil) {
                break;
            }
        }
    });
}

// Pumping the run loop is how a synchronous result is squeezed out of
// WebKit's asynchronous API. The wait has to be bounded: if the web content
// process hangs or dies the completion handler never arrives, and an
// unbounded loop freezes the entire app with no way out but a force quit.
// The __block captures live on the heap, so a late callback writing to them
// after a timeout is harmless.
static NSTimeInterval const kBrowserScriptPumpTimeout = 2.0;
static NSTimeInterval const kBrowserCookiePumpTimeout = 5.0;

static BOOL BrowserPumpRunLoopUntil(BOOL *done, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!*done && [deadline timeIntervalSinceNow] > 0.0) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
    return *done;
}

static NSString *BrowserStringFromJavaScriptResult(id result) {
    if (result == nil || result == [NSNull null]) {
        return nil;
    }
    if ([result isKindOfClass:[NSString class]]) {
        return result;
    }
    if ([result respondsToSelector:@selector(stringValue)]) {
        return [result stringValue];
    }
    return [result description];
}

static BOOL BrowserSelectorNameMatchesMediaFilter(NSString *selectorName) {
    static NSArray<NSString *> *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"mediasource",
            @"managedmediasource",
            @"sourcebuffer",
            @"media",
            @"video",
            @"inline",
            @"autoplay",
            @"fullscreen",
            @"pictureinpicture",
            @"airplay",
            @"webm",
            @"vp9",
            @"av1",
            @"hls",
            @"mse",
            @"codec",
        ];
    });

    NSString *lowercaseSelectorName = selectorName.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lowercaseSelectorName containsString:keyword]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *BrowserFilteredSelectorNamesForClass(Class klass) {
    if (klass == Nil) {
        return @[];
    }

    NSMutableOrderedSet<NSString *> *selectorNames = [NSMutableOrderedSet orderedSet];
    for (Class currentClass = klass; currentClass != Nil && currentClass != [NSObject class]; currentClass = class_getSuperclass(currentClass)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(currentClass, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex += 1) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *selectorName = NSStringFromSelector(selector);
            if (selectorName.length > 0 && BrowserSelectorNameMatchesMediaFilter(selectorName)) {
                [selectorNames addObject:selectorName];
            }
        }
        free(methods);
    }

    return [selectorNames.array sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSString *BrowserGetterNameFromSetterName(NSString *setterName) {
    if (![setterName hasPrefix:@"set"] || ![setterName hasSuffix:@":"] || setterName.length <= 4) {
        return nil;
    }

    NSString *propertyStem = [setterName substringWithRange:NSMakeRange(3, setterName.length - 4)];
    if (propertyStem.length == 0) {
        return nil;
    }

    NSString *firstCharacter = [[propertyStem substringToIndex:1] lowercaseString];
    if (propertyStem.length == 1) {
        return firstCharacter;
    }

    return [firstCharacter stringByAppendingString:[propertyStem substringFromIndex:1]];
}

static NSString *BrowserBooleanValueDescriptionForObjectAndSelector(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL) {
        return nil;
    }

    if (returnType[0] != 'B' && returnType[0] != 'c') {
        return nil;
    }

    BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    return value ? @"YES" : @"NO";
}

static id BrowserObjectResultForGetter(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL || returnType[0] != '@') {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *BrowserPreviewString(NSString *string, NSUInteger maxLength) {
    if (string.length <= maxLength) {
        return string;
    }
    return [[string substringToIndex:maxLength] stringByAppendingString:@"\n…"];
}

static NSString *BrowserStringValueForKnownSelectors(id object, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        id result = BrowserObjectResultForGetter(object, selectorName);
        if (result == nil || result == [NSNull null]) {
            continue;
        }
        NSString *stringResult = nil;
        if ([result isKindOfClass:[NSString class]]) {
            stringResult = result;
        } else if ([result respondsToSelector:@selector(stringValue)]) {
            stringResult = [result stringValue];
        } else {
            stringResult = [result description];
        }

        if (stringResult.length > 0) {
            return stringResult;
        }
    }
    return nil;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *BrowserFeatureEntriesForPreferences(id preferences) {
    if (preferences == nil) {
        return @[];
    }

    NSArray<NSString *> *collectionSelectors = @[
        @"_experimentalFeatures",
        @"_internalDebugFeatures",
        @"_features",
    ];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries = [NSMutableArray array];
    for (NSString *collectionSelectorName in collectionSelectors) {
        id collection = BrowserObjectResultForGetter(preferences, collectionSelectorName);
        if (![collection conformsToProtocol:@protocol(NSFastEnumeration)]) {
            continue;
        }

        for (id feature in collection) {
            NSString *name = BrowserStringValueForKnownSelectors(feature, @[@"name", @"key", @"identifier", @"title", @"details"]);
            if (name.length == 0) {
                continue;
            }

            NSString *lowercaseName = name.lowercaseString;
            if (![lowercaseName containsString:@"media"] &&
                ![lowercaseName containsString:@"source"] &&
                ![lowercaseName containsString:@"vp9"] &&
                ![lowercaseName containsString:@"av1"] &&
                ![lowercaseName containsString:@"webm"] &&
                ![lowercaseName containsString:@"video"] &&
                ![lowercaseName containsString:@"mse"] &&
                ![lowercaseName containsString:@"managed"]) {
                continue;
            }

            NSString *enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"enabled");
            if (enabledValue == nil) {
                enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"isEnabled");
            }
            if (enabledValue == nil) {
                enabledValue = @"unknown";
            }

            NSString *key = BrowserStringValueForKnownSelectors(feature, @[@"key", @"identifier"]);
            NSString *source = [collectionSelectorName stringByReplacingOccurrencesOfString:@"_" withString:@""];
            [entries addObject:@{
                @"source": source ?: @"features",
                @"name": name,
                @"enabled": enabledValue,
                @"key": key ?: @"",
            }];
        }
    }

    return entries;
}

static void BrowserSetBooleanSelectorIfAvailable(id object, NSString *selectorName, BOOL value) {
    if (object == nil || selectorName.length == 0) {
        return;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

static void BrowserConfigurePrivateMediaPreferences(id configuration) {
    if (configuration == nil) {
        return;
    }

    SEL preferencesSelector = NSSelectorFromString(@"preferences");
    if (![configuration respondsToSelector:preferencesSelector]) {
        return;
    }

    id preferences = ((id (*)(id, SEL))objc_msgSend)(configuration, preferencesSelector);
    if (preferences == nil) {
        return;
    }

    // Measured on tvOS 16.6: the engine exposes no MediaSource object at all,
    // so these switches changed nothing a page could observe. WebKit full
    // screen and site-specific quirks only broke page scripts. All off, and
    // no longer configurable, so the browser cannot be put into a bad state.
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaSourceEnabled:", NO);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setManagedMediaSourceEnabled:", NO);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaCapabilityGrantsEnabled:", NO);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setVideoQualityIncludesDisplayCompositingEnabled:", NO);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setFullScreenEnabled:", NO);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setNeedsSiteSpecificQuirks:", NO);
}


@interface BrowserWebView ()

@property (nullable, nonatomic, strong) id runtimeWebView;
@property (nullable, nonatomic, strong) NSURLRequest *lastRequest;
@property (nullable, nonatomic, copy) NSString *lastTitle;
@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL evaluatingJavaScript;
@property (nonatomic, readwrite) NSUInteger webContentTerminationCount;
@property (nonatomic, readwrite) NSTimeInterval lastWebContentTerminationTime;

@end

@implementation BrowserWebView

+ (void)installRuleListToConfiguration:(id)configuration {
    if (configuration == nil) {
        return;
    }

    id ruleList = [[BrowserContentBlockerController sharedController] compiledRuleList];
    if (ruleList == nil) {
        return;
    }

    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    if (![configuration respondsToSelector:userContentControllerGetter]) {
        return;
    }

    id userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    SEL addContentRuleListSelector = NSSelectorFromString(@"addContentRuleList:");
    if (userContentController != nil && [userContentController respondsToSelector:addContentRuleListSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addContentRuleListSelector, ruleList);
    }
}

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithUserAgent:nil allowsInlineMediaPlayback:YES];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInitWithUserAgent:nil allowsInlineMediaPlayback:YES];
    }
    return self;
}

- (instancetype)initWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        [self commonInitWithUserAgent:userAgent allowsInlineMediaPlayback:allowsInlineMediaPlayback];
    }
    return self;
}

- (void)commonInitWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    BrowserEnsureWebKitRuntimeLoaded();

    self.backgroundColor = UIColor.whiteColor;
    self.userAgent = userAgent;
    self.scalesPageToFit = NO;

    Class configurationClass = NSClassFromString(kBrowserWebViewConfigurationClassName);
    Class webViewClass = NSClassFromString(kBrowserWebViewClassName);
    if (configurationClass == Nil || webViewClass == Nil) {
        return;
    }

    id configuration = ((id (*)(id, SEL))objc_msgSend)((id)configurationClass, @selector(new));
    // Forcing inline playback was the cause of the repeated web content
    // process crashes. tvOS expects media to go to the system player, so the
    // platform default stands and the caller's argument is ignored.
    (void)allowsInlineMediaPlayback;
    SEL allowsInlineMediaPlaybackSelector = NSSelectorFromString(@"setAllowsInlineMediaPlayback:");
    if (configuration != nil && [configuration respondsToSelector:allowsInlineMediaPlaybackSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(configuration, allowsInlineMediaPlaybackSelector, NO);
    }
    BrowserConfigurePrivateMediaPreferences(configuration);
    [BrowserWebView installRuleListToConfiguration:configuration];

    id webViewObject = ((id (*)(id, SEL))objc_msgSend)((id)webViewClass, @selector(alloc));
    SEL initializer = NSSelectorFromString(@"initWithFrame:configuration:");
    webViewObject = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webViewObject, initializer, self.bounds, configuration);
    if (webViewObject == nil) {
        return;
    }

    self.runtimeWebView = webViewObject;
    UIView *runtimeView = (UIView *)webViewObject;
    runtimeView.frame = self.bounds;
    runtimeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    runtimeView.backgroundColor = UIColor.whiteColor;

    // Lets Safari's Develop menu attach if this Apple TV is ever paired with
    // a Mac. tvOS 16.4+, so it is reached by selector rather than by symbol.
    SEL inspectableSelector = NSSelectorFromString(@"setInspectable:");
    if ([webViewObject respondsToSelector:inspectableSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(webViewObject, inspectableSelector, YES);
    }

    SEL navigationDelegateSelector = NSSelectorFromString(@"setNavigationDelegate:");
    if ([webViewObject respondsToSelector:navigationDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, navigationDelegateSelector, self);
    }

    SEL UIDelegateSelector = NSSelectorFromString(@"setUIDelegate:");
    if ([webViewObject respondsToSelector:UIDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, UIDelegateSelector, self);
    }

    [self addSubview:runtimeView];
    [self setUserAgent:userAgent];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    ((UIView *)self.runtimeWebView).frame = self.bounds;
    [self applyPageScalingIfNeeded];
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled {
    [super setUserInteractionEnabled:userInteractionEnabled];

    UIView *runtimeView = (UIView *)self.runtimeWebView;
    runtimeView.userInteractionEnabled = userInteractionEnabled;

    UIScrollView *scrollView = [self scrollView];
    scrollView.userInteractionEnabled = userInteractionEnabled;
}

- (id)runtimeWebViewForProbing {
    return self.runtimeWebView;
}

- (UIScrollView *)scrollView {
    SEL selector = NSSelectorFromString(@"scrollView");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURL *)currentURL {
    SEL selector = NSSelectorFromString(@"URL");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURLRequest *)request {
    NSURL *currentURL = [self currentURL];
    if (currentURL != nil) {
        return [NSURLRequest requestWithURL:currentURL];
    }
    return self.lastRequest;
}

- (NSString *)title {
    SEL selector = NSSelectorFromString(@"title");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return self.lastTitle;
    }
    NSString *title = ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    return title ?: self.lastTitle;
}

- (BOOL)canGoBack {
    SEL selector = NSSelectorFromString(@"canGoBack");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (BOOL)canGoForward {
    SEL selector = NSSelectorFromString(@"canGoForward");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (void)loadRequest:(NSURLRequest *)request {
    if (request == nil || self.runtimeWebView == nil) {
        return;
    }
    self.lastRequest = request;
    SEL selector = NSSelectorFromString(@"loadRequest:");
    if ([self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, request);
    }
}

- (void)reload {
    SEL selector = NSSelectorFromString(@"reload");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goBack {
    SEL selector = NSSelectorFromString(@"goBack");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goForward {
    SEL selector = NSSelectorFromString(@"goForward");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

+ (NSString *)descriptionForScriptEvaluationStatus:(BrowserScriptEvaluationStatus)status {
    switch (status) {
        case BrowserScriptEvaluationStatusOK: return @"ok";
        case BrowserScriptEvaluationStatusNoWebView: return @"no web view";
        case BrowserScriptEvaluationStatusUnsupported: return @"evaluateJavaScript: unavailable";
        case BrowserScriptEvaluationStatusNoWebProcess: return @"web content process is gone";
        case BrowserScriptEvaluationStatusReentrant: return @"another evaluation was already running";
        case BrowserScriptEvaluationStatusTimedOut: return @"timed out waiting for the page";
        case BrowserScriptEvaluationStatusScriptError: return @"the script raised an error";
    }
    return @"unknown";
}

- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script {
    return [self stringByEvaluatingJavaScriptFromString:script
                                                timeout:kBrowserScriptPumpTimeout
                                                 status:NULL
                                           failureReason:NULL];
}

- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script
                                             timeout:(NSTimeInterval)timeout
                                              status:(BrowserScriptEvaluationStatus *)status
                                       failureReason:(NSString * __autoreleasing *)failureReason {
    void (^report)(BrowserScriptEvaluationStatus, NSString *) = ^(BrowserScriptEvaluationStatus value, NSString *reason) {
        if (status != NULL) {
            *status = value;
        }
        if (failureReason != NULL) {
            *failureReason = reason;
        }
    };

    if (script.length == 0 || self.runtimeWebView == nil) {
        report(BrowserScriptEvaluationStatusNoWebView, nil);
        return nil;
    }

    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (![self.runtimeWebView respondsToSelector:selector]) {
        report(BrowserScriptEvaluationStatusUnsupported, nil);
        return nil;
    }

    // A pid of zero means the content process is not there, and nothing can
    // run. Worth separating from a page that is merely slow.
    SEL pidSelector = NSSelectorFromString(@"_webProcessIdentifier");
    if ([self.runtimeWebView respondsToSelector:pidSelector]) {
        int webProcessIdentifier = ((int (*)(id, SEL))objc_msgSend)(self.runtimeWebView, pidSelector);
        if (webProcessIdentifier == 0) {
            report(BrowserScriptEvaluationStatusNoWebProcess, nil);
            return nil;
        }
    }

    // Pumping the run loop below lets UIKit deliver another press or touch,
    // which can land back here. Nesting these waits compounds the stall and
    // interleaves two scripts, so the outer one wins and the inner one bails.
    if (self.evaluatingJavaScript) {
        report(BrowserScriptEvaluationStatusReentrant, nil);
        return nil;
    }
    self.evaluatingJavaScript = YES;

    __block id evaluationResult = nil;
    __block NSError *evaluationError = nil;
    __block BOOL finished = NO;
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.runtimeWebView, selector, script, ^(id result, NSError *error) {
        evaluationResult = result;
        evaluationError = error;
        finished = YES;
    });
    BOOL completed = BrowserPumpRunLoopUntil(&finished, timeout > 0.0 ? timeout : kBrowserScriptPumpTimeout);
    self.evaluatingJavaScript = NO;

    if (!completed) {
        report(BrowserScriptEvaluationStatusTimedOut, nil);
        return nil;
    }
    if (evaluationError != nil) {
        report(BrowserScriptEvaluationStatusScriptError, evaluationError.localizedDescription);
        return nil;
    }
    report(BrowserScriptEvaluationStatusOK, nil);
    return BrowserStringFromJavaScriptResult(evaluationResult);
}

- (void)pauseAllMediaPlayback {
    if (self.runtimeWebView == nil) {
        return;
    }

    // Prefer WebKit's internal media pause APIs when available.
    SEL pauseWithCompletionHandlerSelector = NSSelectorFromString(@"pauseAllMediaPlaybackWithCompletionHandler:");
    if ([self.runtimeWebView respondsToSelector:pauseWithCompletionHandlerSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseWithCompletionHandlerSelector, nil);
    } else {
        SEL pauseSelector = NSSelectorFromString(@"pauseAllMediaPlayback:");
        if ([self.runtimeWebView respondsToSelector:pauseSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseSelector, nil);
        } else {
            SEL privatePauseSelector = NSSelectorFromString(@"_pauseAllMediaPlayback");
            if ([self.runtimeWebView respondsToSelector:privatePauseSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, privatePauseSelector);
            }
        }
    }

    // JS fallback for page media elements and common iframe-based players.
    NSString *pauseScript =
        @"(function(){"
            "function safe(fn){ try { fn(); } catch (error) {} }"
            "var media = document.querySelectorAll('video,audio');"
            "for (var i = 0; i < media.length; i++) {"
                "var element = media[i];"
                "safe(function(){ element.pause(); });"
                "safe(function(){ element.autoplay = false; });"
                "safe(function(){ element.removeAttribute('autoplay'); });"
            "}"
            "var iframePlayers = document.querySelectorAll('iframe');"
            "for (var j = 0; j < iframePlayers.length; j++) {"
                "var frame = iframePlayers[j];"
                "var src = String(frame.src || '').toLowerCase();"
                "if (!src) { continue; }"
                "safe(function(){"
                    "if (src.indexOf('youtube.com') !== -1 || src.indexOf('youtube-nocookie.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({event:'command',func:'pauseVideo',args:''}), '*');"
                    "}"
                "});"
                "safe(function(){"
                    "if (src.indexOf('vimeo.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({method:'pause'}), '*');"
                    "}"
                "});"
            "}"
        "})();";
    [self stringByEvaluatingJavaScriptFromString:pauseScript];
}

- (NSString *)runtimeMediaPreferenceReport {
    if (self.runtimeWebView == nil) {
        return @"Runtime web view unavailable.";
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *objectSelectors = @[
        @{@"label": @"WKWebView", @"selector": @""},
        @{@"label": @"Configuration", @"selector": @"configuration"},
        @{@"label": @"Configuration._preferences", @"selector": @"configuration._preferences"},
        @{@"label": @"Configuration.preferences", @"selector": @"configuration.preferences"},
        @{@"label": @"Configuration.defaultWebpagePreferences", @"selector": @"configuration.defaultWebpagePreferences"},
        @{@"label": @"Configuration.websiteDataStore", @"selector": @"configuration.websiteDataStore"},
        @{@"label": @"WKWebView._configuration", @"selector": @"_configuration"},
        @{@"label": @"WKWebView._page", @"selector": @"_page"},
    ];

    NSMutableDictionary<NSValue *, NSString *> *seenObjects = [NSMutableDictionary dictionary];
    NSMutableString *report = [NSMutableString string];

    for (NSDictionary<NSString *, NSString *> *entry in objectSelectors) {
        NSString *label = entry[@"label"] ?: @"Object";
        NSString *selectorPath = entry[@"selector"] ?: @"";
        id currentObject = self.runtimeWebView;

        if (selectorPath.length > 0) {
            NSArray<NSString *> *components = [selectorPath componentsSeparatedByString:@"."];
            for (NSString *component in components) {
                currentObject = BrowserObjectResultForGetter(currentObject, component);
                if (currentObject == nil) {
                    break;
                }
            }
        }

        if (currentObject == nil) {
            [report appendFormat:@"[%@] unavailable\n\n", label];
            continue;
        }

        NSValue *objectKey = [NSValue valueWithNonretainedObject:currentObject];
        NSString *previousLabel = seenObjects[objectKey];
        if (previousLabel != nil) {
            [report appendFormat:@"[%@] same object as %@ (%@)\n\n", label, previousLabel, NSStringFromClass([currentObject class])];
            continue;
        }
        seenObjects[objectKey] = label;

        NSArray<NSString *> *selectorNames = BrowserFilteredSelectorNamesForClass([currentObject class]);
        NSMutableArray<NSString *> *booleanLines = [NSMutableArray array];
        for (NSString *selectorName in selectorNames) {
            NSString *getterName = nil;
            if ([selectorName hasPrefix:@"set"] && [selectorName hasSuffix:@":"]) {
                getterName = BrowserGetterNameFromSetterName(selectorName);
            } else {
                getterName = selectorName;
            }

            NSString *valueDescription = BrowserBooleanValueDescriptionForObjectAndSelector(currentObject, getterName);
            if (valueDescription != nil) {
                [booleanLines addObject:[NSString stringWithFormat:@"%@ = %@", getterName, valueDescription]];
            }
        }

        [report appendFormat:@"[%@] %@\n", label, NSStringFromClass([currentObject class])];
        if (booleanLines.count > 0) {
            [report appendString:@"Boolean getters:\n"];
            for (NSString *line in booleanLines) {
                [report appendFormat:@"- %@\n", line];
            }
        } else {
            [report appendString:@"Boolean getters:\n- none resolved\n"];
        }

        [report appendString:@"Matching selectors:\n"];
        if (selectorNames.count == 0) {
            [report appendString:@"- none\n\n"];
            continue;
        }

        for (NSString *selectorName in selectorNames) {
            [report appendFormat:@"- %@\n", selectorName];
        }

        if ([label isEqualToString:@"Configuration.preferences"]) {
            NSArray<NSDictionary<NSString *, NSString *> *> *featureEntries = BrowserFeatureEntriesForPreferences(currentObject);
            [report appendString:@"Feature entries:\n"];
            if (featureEntries.count == 0) {
                [report appendString:@"- none\n"];
            } else {
                for (NSDictionary<NSString *, NSString *> *featureEntry in featureEntries) {
                    NSString *featureSource = featureEntry[@"source"] ?: @"features";
                    NSString *featureName = featureEntry[@"name"] ?: @"Unknown";
                    NSString *featureEnabled = featureEntry[@"enabled"] ?: @"unknown";
                    NSString *featureKey = featureEntry[@"key"];
                    if (featureKey.length > 0) {
                        [report appendFormat:@"- [%@] %@ (%@) = %@\n", featureSource, featureName, featureKey, featureEnabled];
                    } else {
                        [report appendFormat:@"- [%@] %@ = %@\n", featureSource, featureName, featureEnabled];
                    }
                }
            }
        }
        [report appendString:@"\n"];
    }

    return BrowserPreviewString(report, 24000);
}

- (void)setUserAgent:(NSString *)userAgent {
    _userAgent = [userAgent copy];
    SEL selector = NSSelectorFromString(@"setCustomUserAgent:");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, _userAgent);
    }
}

- (NSString *)currentUserAgent {
    return self.userAgent;
}

- (BOOL)restartWebContentProcess {
    SEL killSelector = NSSelectorFromString(@"_killWebContentProcess");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:killSelector]) {
        [self reload];
        return NO;
    }
    ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, killSelector);
    // The kill arrives as a termination, and the delegate's recovery reloads.
    return YES;
}

- (void)setScalesPageToFit:(BOOL)scalesPageToFit {
    _scalesPageToFit = scalesPageToFit;
    [self applyPageScalingIfNeeded];
}

// WebKit's own floor on rendered text. A television is read from across a
// room, so raising it lifts the small print without the layout surgery a
// script would need, and WebKit applies it during layout at no cost.
- (void)setMinimumFontSize:(CGFloat)minimumFontSize {
    if (self.runtimeWebView == nil) {
        return;
    }
    SEL configurationSelector = NSSelectorFromString(@"configuration");
    if (![self.runtimeWebView respondsToSelector:configurationSelector]) {
        return;
    }
    id configuration = ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, configurationSelector);
    SEL preferencesSelector = NSSelectorFromString(@"preferences");
    if (configuration == nil || ![configuration respondsToSelector:preferencesSelector]) {
        return;
    }
    id preferences = ((id (*)(id, SEL))objc_msgSend)(configuration, preferencesSelector);
    SEL setter = NSSelectorFromString(@"setMinimumFontSize:");
    if (preferences != nil && [preferences respondsToSelector:setter]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(preferences, setter, minimumFontSize);
    }
}

// This engine's zoom magnifies without relaying out, so a page wider than the
// screen keeps its left margin at the origin and the text is pushed off the
// right. Centring the horizontal offset puts the column back in the middle
// where it belongs. The content size is only correct after the next layout.
- (void)centreHorizontalScrollAfterZoom {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIScrollView *scrollView = [weakSelf scrollView];
        if (scrollView == nil) {
            return;
        }
        CGFloat overflow = scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds);
        if (overflow <= 1.0) {
            return;
        }
        CGPoint offset = scrollView.contentOffset;
        offset.x = overflow / 2.0;
        scrollView.contentOffset = offset;
    });
}

- (void)applyPageScalingIfNeeded {
    if (self.runtimeWebView == nil) {
        return;
    }

    UIScrollView *scrollView = [self scrollView];
    if (scrollView == nil || CGRectIsEmpty(scrollView.bounds)) {
        return;
    }

    CGFloat zoomValue = self.userPageZoom > 0.0 ? self.userPageZoom : 1.0;
    if (self.scalesPageToFit) {
        CGFloat contentWidth = scrollView.contentSize.width;
        CGFloat boundsWidth = CGRectGetWidth(scrollView.bounds);
        if (contentWidth > 1.0 && boundsWidth > 1.0) {
            zoomValue *= MIN(1.0, MAX(0.25, boundsWidth / contentWidth));
        }
    }
    zoomValue = MIN(3.0, MAX(0.25, zoomValue));

    SEL pageZoomSelector = NSSelectorFromString(@"setPageZoom:");
    if ([self.runtimeWebView respondsToSelector:pageZoomSelector]) {
        ((void (*)(id, SEL, double))objc_msgSend)(self.runtimeWebView, pageZoomSelector, zoomValue);
        [self centreHorizontalScrollAfterZoom];
        return;
    }

    NSString *script = zoomValue == 1.0
        ? @"document.documentElement.style.zoom=''; document.body.style.zoom='';"
        : [NSString stringWithFormat:@"document.documentElement.style.zoom='%0.4f'; document.body.style.zoom='%0.4f';", zoomValue, zoomValue];
    [self stringByEvaluatingJavaScriptFromString:script];
}

- (void)webView:(id)webView didStartProvisionalNavigation:(id)navigation {
    self.loading = YES;
    if ([self.delegate respondsToSelector:@selector(webViewDidStartLoad:)]) {
        [self.delegate webViewDidStartLoad:self];
    }
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    self.loading = NO;
    self.lastTitle = [self title];
    self.lastRequest = [self request];
    [self applyPageScalingIfNeeded];
    if ([self.delegate respondsToSelector:@selector(webViewDidFinishLoad:)]) {
        [self.delegate webViewDidFinishLoad:self];
    }
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

// The content process dying leaves a blank white page behind and every
// script evaluation returning nothing. It was only clearing the loading
// flag, so the app looked like it had simply rendered an empty page.
- (void)webViewWebContentProcessDidTerminate:(id)webView {
    (void)webView;
    self.loading = NO;
    self.webContentTerminationCount += 1;
    self.lastWebContentTerminationTime = [NSDate timeIntervalSinceReferenceDate];
    NSLog(@"[WebContent] process terminated (count=%lu) url=%@",
          (unsigned long)self.webContentTerminationCount,
          self.request.URL.absoluteString ?: @"");
    if ([self.delegate respondsToSelector:@selector(browserWebViewWebContentProcessDidTerminate:)]) {
        [self.delegate browserWebViewWebContentProcessDidTerminate:self];
    }
}

- (NSURLRequest *)requestFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return nil;
    }
    SEL requestSelector = NSSelectorFromString(@"request");
    if (![navigationAction respondsToSelector:requestSelector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(navigationAction, requestSelector);
}

- (NSInteger)navigationTypeFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return 0;
    }
    SEL navigationTypeSelector = NSSelectorFromString(@"navigationType");
    if (![navigationAction respondsToSelector:navigationTypeSelector]) {
        return 0;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(navigationAction, navigationTypeSelector);
}

- (void)webView:(id)webView decidePolicyForNavigationAction:(id)navigationAction decisionHandler:(void (^)(NSInteger policy))decisionHandler {
    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];
    BOOL isMainFrameRequest = YES;

    SEL targetFrameSelector = NSSelectorFromString(@"targetFrame");
    if ([navigationAction respondsToSelector:targetFrameSelector]) {
        id targetFrame = ((id (*)(id, SEL))objc_msgSend)(navigationAction, targetFrameSelector);
        SEL mainFrameSelector = NSSelectorFromString(@"isMainFrame");
        if (targetFrame != nil && [targetFrame respondsToSelector:mainFrameSelector]) {
            isMainFrameRequest = ((BOOL (*)(id, SEL))objc_msgSend)(targetFrame, mainFrameSelector);
        }
    }

    BOOL shouldAllow = YES;
    if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
        shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
    }

    if (shouldAllow && isMainFrameRequest && request != nil) {
        self.lastRequest = request;
    }

    if (decisionHandler != nil) {
        decisionHandler(shouldAllow ? 1 : 0);
    }
}

- (id)webView:(id)webView
createWebViewWithConfiguration:(id)configuration
forNavigationAction:(id)navigationAction
windowFeatures:(id)windowFeatures {
    (void)webView;
    (void)configuration;
    (void)windowFeatures;

    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];

    BOOL delegateHandlesNewTabRequests = [self.delegate respondsToSelector:@selector(webView:shouldCreateNewTabWithRequest:navigationType:)];
    BOOL handledInTab = NO;
    if (delegateHandlesNewTabRequests) {
        handledInTab = [self.delegate webView:self shouldCreateNewTabWithRequest:request navigationType:navigationType];
    }

    if (!delegateHandlesNewTabRequests && !handledInTab && request != nil) {
        BOOL shouldAllow = YES;
        if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
            shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
        }
        if (shouldAllow) {
            [self loadRequest:request];
        }
    }

    return nil;
}

+ (id)defaultWebsiteDataStore {
    BrowserEnsureWebKitRuntimeLoaded();
    Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
    SEL selector = NSSelectorFromString(@"defaultDataStore");
    if (dataStoreClass == Nil || ![dataStoreClass respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, selector);
}

+ (id)defaultCookieStore {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"httpCookieStore");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(dataStore, selector);
}

+ (NSArray<NSHTTPCookie *> *)allCookies {
    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"getAllCookies:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        return NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies ?: @[];
    }

    __block NSArray<NSHTTPCookie *> *cookies = nil;
    __block BOOL finished = NO;
    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, selector, ^(NSArray<NSHTTPCookie *> *fetchedCookies) {
        cookies = fetchedCookies;
        finished = YES;
    });
    BrowserPumpRunLoopUntil(&finished, kBrowserCookiePumpTimeout);
    return cookies ?: @[];
}

+ (NSData *)cookieDataRepresentation {
    NSArray<NSHTTPCookie *> *cookies = [self allCookies];
    NSError *error = nil;
    NSData *cookieData = [NSKeyedArchiver archivedDataWithRootObject:cookies requiringSecureCoding:NO error:&error];
    return error == nil ? cookieData : nil;
}

+ (void)restoreCookiesFromData:(NSData *)cookieData {
    if (cookieData.length == 0) {
        return;
    }

    NSError *error = nil;
    NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [NSHTTPCookie class], nil];
    NSArray<NSHTTPCookie *> *cookies = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses fromData:cookieData error:&error];
    if (![cookies isKindOfClass:[NSArray class]]) {
        return;
    }

    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"setCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        for (NSHTTPCookie *cookie in cookies) {
            [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];
        }
        return;
    }

    __block NSInteger remainingCount = cookies.count;
    __block BOOL finished = cookies.count == 0;
    for (NSHTTPCookie *cookie in cookies) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, selector, cookie, ^{
            remainingCount -= 1;
            finished = remainingCount == 0;
        });
    }
    BrowserPumpRunLoopUntil(&finished, kBrowserCookiePumpTimeout);
}

+ (NSSet<NSString *> *)allWebsiteDataTypes {
    Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
    SEL selector = NSSelectorFromString(@"allWebsiteDataTypes");
    if (dataStoreClass == Nil || ![dataStoreClass respondsToSelector:selector]) {
        return [NSSet set];
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, selector);
}

+ (void)removeWebsiteDataTypes:(NSSet<NSString *> *)websiteDataTypes completion:(void (^)(void))completion {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        if (completion != nil) {
            completion();
        }
        return;
    }

    NSDate *beginningOfTime = [NSDate dateWithTimeIntervalSince1970:0];
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(dataStore, selector, websiteDataTypes, beginningOfTime, ^{
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

+ (void)clearCachedDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    NSMutableSet<NSString *> *websiteDataTypes = [[self allWebsiteDataTypes] mutableCopy];
    for (NSString *dataType in websiteDataTypes.allObjects) {
        if ([dataType.lowercaseString containsString:@"cookie"]) {
            [websiteDataTypes removeObject:dataType];
        }
    }

    [self removeWebsiteDataTypes:websiteDataTypes completion:completion];
}

+ (void)clearCookiesWithCompletion:(void (^)(void))completion {
    id cookieStore = [self defaultCookieStore];
    SEL getAllCookiesSelector = NSSelectorFromString(@"getAllCookies:");
    SEL deleteCookieSelector = NSSelectorFromString(@"deleteCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:getAllCookiesSelector] || ![cookieStore respondsToSelector:deleteCookieSelector]) {
        NSHTTPCookieStorage *storage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
        for (NSHTTPCookie *cookie in storage.cookies) {
            [storage deleteCookie:cookie];
        }
        if (completion != nil) {
            completion();
        }
        return;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, getAllCookiesSelector, ^(NSArray<NSHTTPCookie *> *cookies) {
        if (cookies.count == 0) {
            if (completion != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
            return;
        }

        __block NSInteger remainingCount = cookies.count;
        for (NSHTTPCookie *cookie in cookies) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, deleteCookieSelector, cookie, ^{
                remainingCount -= 1;
                if (remainingCount == 0 && completion != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion();
                    });
                }
            });
        }
    });
}

+ (void)resetWebsiteDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    [self removeWebsiteDataTypes:[self allWebsiteDataTypes] completion:completion];
}

@end
```

## `BrowserFavoritesStore.h`  (26줄)

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserFavoritesStore : NSObject

- (NSArray<NSArray<NSString *> *> *)favorites;
- (BOOL)isFavoriteURLString:(nullable NSString *)URLString;
- (void)addFavoriteWithURLString:(nullable NSString *)URLString title:(nullable NSString *)title;
- (void)removeFavoriteWithURLString:(nullable NSString *)URLString;
- (void)removeFavoriteAtIndex:(NSInteger)index;
- (NSUInteger)count;

// Folders. A favorite stores its folder as a third element, so entries saved
// before folders existed stay readable and simply belong to no folder.
- (NSArray<NSString *> *)folderNames;
- (NSArray<NSArray<NSString *> *> *)favoritesInFolder:(nullable NSString *)folderName;
- (nullable NSString *)folderForURLString:(nullable NSString *)URLString;
- (void)setFolder:(nullable NSString *)folderName forURLString:(nullable NSString *)URLString;
- (void)createFolderNamed:(NSString *)folderName;
- (void)removeFolderNamed:(NSString *)folderName;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserFavoritesStore.m`  (262줄)

```objc
#import "BrowserFavoritesStore.h"

static NSString * const kFavoritesUserDefaultsKey = @"FAVORITES";
static NSString * const kFavoriteFoldersUserDefaultsKey = @"FAVORITE_FOLDERS";

@implementation BrowserFavoritesStore

- (NSString *)normalizedURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return @"";
    }

    NSURL *url = [NSURL URLWithString:URLString];
    if (url == nil) {
        return URLString;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (components == nil) {
        return URLString;
    }

    components.scheme = components.scheme.lowercaseString;
    components.host = components.host.lowercaseString;
    components.fragment = nil;

    NSString *path = components.path;
    if (path.length > 1 && [path hasSuffix:@"/"]) {
        components.path = [path substringToIndex:path.length - 1];
    } else if (path.length == 0 && components.host != nil) {
        components.path = @"";
    }

    NSString *normalized = components.URL.absoluteString;
    if (normalized == nil) {
        return URLString;
    }

    if ([normalized hasSuffix:@"/"] && normalized.length > components.scheme.length + 3) {
        normalized = [normalized substringToIndex:normalized.length - 1];
    }

    return normalized;
}

- (NSArray<NSArray<NSString *> *> *)favorites {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoritesUserDefaultsKey];
    if ([stored isKindOfClass:[NSArray class]]) {
        return stored;
    }
    return @[];
}

- (void)saveFavorites:(NSArray<NSArray<NSString *> *> *)favorites {
    [[NSUserDefaults standardUserDefaults] setObject:favorites forKey:kFavoritesUserDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)isFavoriteURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return NO;
    }

    NSString *target = [self normalizedURLString:URLString];
    if (target.length == 0) {
        return NO;
    }

    NSArray *currentFavorites = [self favorites];
    for (NSArray *entry in currentFavorites) {
        if (entry.count > 0) {
            NSString *existingURLString = entry[0];
            if ([existingURLString isKindOfClass:[NSString class]]) {
                NSString *existingTarget = [self normalizedURLString:existingURLString];
                if ([existingTarget isEqualToString:target]) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

- (void)addFavoriteWithURLString:(NSString *)URLString title:(NSString *)title {
    if (URLString.length == 0) {
        return;
    }

    if ([self isFavoriteURLString:URLString]) {
        return;
    }

    NSString *trimmedTitle = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *finalTitle = trimmedTitle.length > 0 ? trimmedTitle : URLString;

    NSMutableArray *currentFavorites = [[self favorites] mutableCopy];
    [currentFavorites addObject:@[URLString, finalTitle]];
    [self saveFavorites:currentFavorites];
}

- (void)removeFavoriteWithURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return;
    }

    NSString *target = [self normalizedURLString:URLString];
    if (target.length == 0) {
        return;
    }

    NSMutableArray *currentFavorites = [[self favorites] mutableCopy];
    NSMutableIndexSet *indexesToRemove = [NSMutableIndexSet indexSet];

    [currentFavorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger idx, BOOL *stop) {
        if (entry.count > 0) {
            NSString *existingURLString = entry[0];
            if ([existingURLString isKindOfClass:[NSString class]]) {
                NSString *existingTarget = [self normalizedURLString:existingURLString];
                if ([existingTarget isEqualToString:target]) {
                    [indexesToRemove addIndex:idx];
                }
            }
        }
    }];

    if (indexesToRemove.count > 0) {
        [currentFavorites removeObjectsAtIndexes:indexesToRemove];
        [self saveFavorites:currentFavorites];
    }
}

- (void)removeFavoriteAtIndex:(NSInteger)index {
    NSMutableArray *currentFavorites = [[self favorites] mutableCopy];
    if (index >= 0 && (NSUInteger)index < currentFavorites.count) {
        [currentFavorites removeObjectAtIndex:index];
        [self saveFavorites:currentFavorites];
    }
}

- (NSUInteger)count {
    return [self favorites].count;
}


#pragma mark - Folders

// A favorite is stored as [url, title] and now optionally [url, title, folder].
// Reading the third element defensively means nothing saved before folders
// existed has to be migrated.
- (NSString *)folderOfEntry:(NSArray<NSString *> *)entry {
    if (![entry isKindOfClass:[NSArray class]] || entry.count < 3) {
        return nil;
    }
    NSString *folder = entry[2];
    return [folder isKindOfClass:[NSString class]] && folder.length > 0 ? folder : nil;
}

- (NSArray<NSString *> *)folderNames {
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];

    NSArray *declared = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoriteFoldersUserDefaultsKey];
    for (id name in ([declared isKindOfClass:[NSArray class]] ? declared : @[])) {
        if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0) {
            [names addObject:name];
        }
    }
    for (NSArray<NSString *> *entry in [self favorites]) {
        NSString *folder = [self folderOfEntry:entry];
        if (folder != nil) {
            [names addObject:folder];
        }
    }
    return [names.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (NSArray<NSArray<NSString *> *> *)favoritesInFolder:(NSString *)folderName {
    NSMutableArray<NSArray<NSString *> *> *matches = [NSMutableArray array];
    for (NSArray<NSString *> *entry in [self favorites]) {
        NSString *folder = [self folderOfEntry:entry];
        BOOL belongs = folderName.length > 0 ? [folder isEqualToString:folderName] : (folder == nil);
        if (belongs) {
            [matches addObject:entry];
        }
    }
    return matches;
}

- (NSString *)folderForURLString:(NSString *)URLString {
    NSString *normalized = [self normalizedURLString:URLString ?: @""];
    for (NSArray<NSString *> *entry in [self favorites]) {
        if (entry.count >= 1 && [[self normalizedURLString:entry[0]] isEqualToString:normalized]) {
            return [self folderOfEntry:entry];
        }
    }
    return nil;
}

- (void)setFolder:(NSString *)folderName forURLString:(NSString *)URLString {
    NSString *normalized = [self normalizedURLString:URLString ?: @""];
    if (normalized.length == 0) {
        return;
    }
    NSMutableArray<NSArray<NSString *> *> *updated = [NSMutableArray array];
    for (NSArray<NSString *> *entry in [self favorites]) {
        if (entry.count >= 1 && [[self normalizedURLString:entry[0]] isEqualToString:normalized]) {
            NSString *title = entry.count >= 2 ? entry[1] : @"";
            [updated addObject:folderName.length > 0 ? @[entry[0], title, folderName]
                                                     : @[entry[0], title]];
        } else {
            [updated addObject:entry];
        }
    }
    [self saveFavorites:updated];
    if (folderName.length > 0) {
        [self createFolderNamed:folderName];
    }
}

- (void)createFolderNamed:(NSString *)folderName {
    if (folderName.length == 0) {
        return;
    }
    NSArray *declared = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoriteFoldersUserDefaultsKey];
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    for (id name in ([declared isKindOfClass:[NSArray class]] ? declared : @[])) {
        if ([name isKindOfClass:[NSString class]]) {
            [names addObject:name];
        }
    }
    [names addObject:folderName];
    [[NSUserDefaults standardUserDefaults] setObject:names.array forKey:kFavoriteFoldersUserDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Removing a folder keeps every favorite in it; they return to the top level.
- (void)removeFolderNamed:(NSString *)folderName {
    if (folderName.length == 0) {
        return;
    }
    NSMutableArray<NSArray<NSString *> *> *updated = [NSMutableArray array];
    for (NSArray<NSString *> *entry in [self favorites]) {
        if ([[self folderOfEntry:entry] isEqualToString:folderName]) {
            [updated addObject:@[entry[0], entry.count >= 2 ? entry[1] : @""]];
        } else {
            [updated addObject:entry];
        }
    }
    [self saveFavorites:updated];

    NSArray *declared = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoriteFoldersUserDefaultsKey];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id name in ([declared isKindOfClass:[NSArray class]] ? declared : @[])) {
        if ([name isKindOfClass:[NSString class]] && ![name isEqualToString:folderName]) {
            [names addObject:name];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:names forKey:kFavoriteFoldersUserDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
```

## `BrowserPreferencesStore.h`  (55줄)

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPreferencesStore : NSObject

+ (NSString *)desktopUserAgent;
+ (NSString *)mobileUserAgent;

@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL mobileModeEnabled;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) NSUInteger textFontSize;
@property (nonatomic) BOOL scalePagesToFit;
@property (nonatomic) BOOL dontShowHintsOnLaunch;
@property (nonatomic, copy) NSString *homePageURLString;
@property (nonatomic) BOOL jsScrollFallbackEnabled;
@property (nonatomic) BOOL dpadScrollEnabled;
@property (nonatomic) BOOL edgeAutoScrollEnabled;
@property (nonatomic) BOOL tapToClickEnabled;
@property (nonatomic) BOOL openLinksInNewTabOnClick;
@property (nonatomic) BOOL forcedDarkModeEnabled;
@property (nonatomic) BOOL contentBlockingEnabled;
@property (nonatomic) NSUInteger readerFontSize;

/// Whole-page reading zoom in percent. 100 == no zoom. Clamped 50...250.
@property (nonatomic) NSUInteger pageZoomPercent;

/// CSS width pages are laid out at before being scaled to fill the screen.
/// 0 means no fitting. Korean news sites cap their layout near 1275.
@property (nonatomic) NSUInteger pageLayoutWidth;

/// Floor on rendered text size in points. 0 turns it off. Clamped 0...48.
@property (nonatomic) NSUInteger minimumFontSize;

/// Thickens page text. Thin strokes wash out at television viewing distance.
@property (nonatomic) BOOL boldTextEnabled;

/// Releases the max-width on a page's main column so a centred desktop
/// layout uses the whole width of a television.
@property (nonatomic) BOOL widenContentEnabled;

/// Target width of the reading column in CSS pixels. A line wants 35-45
/// Korean characters; the whole 1920 holds more than seventy.
@property (nonatomic) NSUInteger readingColumnWidth;

/// Target body text size in CSS pixels inside that column.
@property (nonatomic) NSUInteger readingBodyFontSize;
@property (nonatomic) BOOL lightenHeavySitesEnabled;

- (void)ensureUserAgentConsistency;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserPreferencesStore.m`  (339줄)

```objc
#import "BrowserPreferencesStore.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static NSString * const kMobileModeDefaultsKey = @"MobileMode";
static NSString * const kShowTopNavigationBarDefaultsKey = @"ShowTopNavigationBar";
static NSString * const kTextFontSizeDefaultsKey = @"TextFontSize";
static NSString * const kScalePagesToFitDefaultsKey = @"ScalePagesToFit";
static NSString * const kDontShowHintsOnLaunchDefaultsKey = @"DontShowHintsOnLaunch";
static NSString * const kHomepageDefaultsKey = @"homepage";
static NSString * const kJSScrollFallbackEnabledDefaultsKey = @"JSScrollFallbackEnabled";
static NSString * const kDpadScrollEnabledDefaultsKey = @"DpadScrollEnabled";
static NSString * const kEdgeAutoScrollEnabledDefaultsKey = @"EdgeAutoScrollEnabled";
static NSString * const kTapToClickEnabledDefaultsKey = @"TapToClickEnabled";
static NSString * const kOpenLinksInNewTabOnClickDefaultsKey = @"OpenLinksInNewTabOnClick";
static NSString * const kForcedDarkModeEnabledDefaultsKey = @"ForcedDarkModeEnabled";
static NSString * const kContentBlockingEnabledDefaultsKey = @"ContentBlockingEnabled";
static NSString * const kPageZoomPercentDefaultsKey = @"PageZoomPercent";
static NSString * const kPageLayoutWidthDefaultsKey = @"PageLayoutWidth";
static NSString * const kMinimumFontSizeDefaultsKey = @"MinimumFontSize";
static NSString * const kBoldTextEnabledDefaultsKey = @"BoldTextEnabled";
static NSString * const kWidenContentEnabledDefaultsKey = @"WidenContentEnabled";
static NSString * const kReadingColumnWidthDefaultsKey = @"ReadingColumnWidth";
static NSString * const kReadingBodyFontSizeDefaultsKey = @"ReadingBodyFontSize";
static NSString * const kReaderFontSizeDefaultsKey = @"ReaderFontSize";
static NSString * const kLightenHeavySitesEnabledDefaultsKey = @"LightenHeavySitesEnabled";

static NSUInteger const kDefaultTextFontSize = 100;
static NSUInteger const kMinimumTextFontSize = 50;
static NSUInteger const kMaximumTextFontSize = 200;

// Reader text, in points at 1080p. 1080 points across a 55-inch panel is
// 0.63 mm per point, so at 3 m one point subtends about 0.73 arcmin. 68
// points puts x-height near 25 arcmin, which is the comfortable band for
// reading at that distance rather than merely making out the words.
static NSUInteger const kDefaultReaderFontSize = 68;
static NSUInteger const kMinimumReaderFontSize = 44;
static NSUInteger const kMaximumReaderFontSize = 96;

@implementation BrowserPreferencesStore

// tvOS 16.6 carries the WebKit that shipped with Safari 16.6. Claiming 17
// asks sites for code paths this engine does not have.
+ (NSString *)desktopUserAgent {
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15";
}

+ (NSString *)mobileUserAgent {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1";
}

- (NSUserDefaults *)defaults {
    return [NSUserDefaults standardUserDefaults];
}

- (void)ensureUserAgentConsistency {
    // A stored agent from the earlier pair is replaced, so the version
    // correction reaches installs that already have one saved.
    static NSString * const kSupersededDesktopUserAgent =
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    static NSString * const kSupersededMobileUserAgent =
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";

    NSString *current = self.userAgent;
    if ([current isEqualToString:kSupersededDesktopUserAgent]) {
        self.userAgent = BrowserPreferencesStore.desktopUserAgent;
        return;
    }
    if ([current isEqualToString:kSupersededMobileUserAgent]) {
        self.userAgent = BrowserPreferencesStore.mobileUserAgent;
        return;
    }
    if (current.length > 0) {
        return;
    }
    self.userAgent = self.mobileModeEnabled ? BrowserPreferencesStore.mobileUserAgent : BrowserPreferencesStore.desktopUserAgent;
}

- (NSString *)userAgent {
    NSString *userAgent = [[self defaults] stringForKey:kUserAgentDefaultsKey];
    if (userAgent.length > 0) {
        return userAgent;
    }
    return self.mobileModeEnabled ? BrowserPreferencesStore.mobileUserAgent : BrowserPreferencesStore.desktopUserAgent;
}

- (void)setUserAgent:(NSString *)userAgent {
    [[self defaults] setObject:userAgent ?: @"" forKey:kUserAgentDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)mobileModeEnabled {
    return [[self defaults] boolForKey:kMobileModeDefaultsKey];
}

- (void)setMobileModeEnabled:(BOOL)mobileModeEnabled {
    [[self defaults] setBool:mobileModeEnabled forKey:kMobileModeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)topNavigationBarVisible {
    NSNumber *showTopNavBar = [[self defaults] objectForKey:kShowTopNavigationBarDefaultsKey];
    return showTopNavBar ? showTopNavBar.boolValue : YES;
}

- (void)setTopNavigationBarVisible:(BOOL)topNavigationBarVisible {
    [[self defaults] setObject:@(topNavigationBarVisible) forKey:kShowTopNavigationBarDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)textFontSize {
    NSNumber *textFontSizeValue = [[self defaults] objectForKey:kTextFontSizeDefaultsKey];
    if (textFontSizeValue == nil) {
        return kDefaultTextFontSize;
    }
    NSUInteger textFontSize = textFontSizeValue.unsignedIntegerValue;
    return MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
}

- (void)setTextFontSize:(NSUInteger)textFontSize {
    textFontSize = MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
    [[self defaults] setObject:@(textFontSize) forKey:kTextFontSizeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)scalePagesToFit {
    return [[self defaults] boolForKey:kScalePagesToFitDefaultsKey];
}

- (void)setScalePagesToFit:(BOOL)scalePagesToFit {
    [[self defaults] setBool:scalePagesToFit forKey:kScalePagesToFitDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)dontShowHintsOnLaunch {
    return [[self defaults] boolForKey:kDontShowHintsOnLaunchDefaultsKey];
}

- (void)setDontShowHintsOnLaunch:(BOOL)dontShowHintsOnLaunch {
    [[self defaults] setBool:dontShowHintsOnLaunch forKey:kDontShowHintsOnLaunchDefaultsKey];
    [[self defaults] synchronize];
}

- (NSString *)homePageURLString {
    NSString *value = [[self defaults] stringForKey:kHomepageDefaultsKey];
    return value ?: @"";
}

- (void)setHomePageURLString:(NSString *)homePageURLString {
    [[self defaults] setObject:homePageURLString ?: @"" forKey:kHomepageDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)jsScrollFallbackEnabled {
    NSNumber *value = [[self defaults] objectForKey:kJSScrollFallbackEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setJsScrollFallbackEnabled:(BOOL)jsScrollFallbackEnabled {
    [[self defaults] setObject:@(jsScrollFallbackEnabled) forKey:kJSScrollFallbackEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)dpadScrollEnabled {
    NSNumber *value = [[self defaults] objectForKey:kDpadScrollEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setDpadScrollEnabled:(BOOL)dpadScrollEnabled {
    [[self defaults] setObject:@(dpadScrollEnabled) forKey:kDpadScrollEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)edgeAutoScrollEnabled {
    NSNumber *value = [[self defaults] objectForKey:kEdgeAutoScrollEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setEdgeAutoScrollEnabled:(BOOL)edgeAutoScrollEnabled {
    [[self defaults] setObject:@(edgeAutoScrollEnabled) forKey:kEdgeAutoScrollEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)tapToClickEnabled {
    NSNumber *value = [[self defaults] objectForKey:kTapToClickEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setTapToClickEnabled:(BOOL)tapToClickEnabled {
    [[self defaults] setObject:@(tapToClickEnabled) forKey:kTapToClickEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)openLinksInNewTabOnClick {
    NSNumber *value = [[self defaults] objectForKey:kOpenLinksInNewTabOnClickDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setOpenLinksInNewTabOnClick:(BOOL)openLinksInNewTabOnClick {
    [[self defaults] setObject:@(openLinksInNewTabOnClick) forKey:kOpenLinksInNewTabOnClickDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)forcedDarkModeEnabled {
    NSNumber *value = [[self defaults] objectForKey:kForcedDarkModeEnabledDefaultsKey];
    return value ? value.boolValue : NO;
}

- (void)setForcedDarkModeEnabled:(BOOL)forcedDarkModeEnabled {
    [[self defaults] setObject:@(forcedDarkModeEnabled) forKey:kForcedDarkModeEnabledDefaultsKey];
    [[self defaults] synchronize];
}

// Off by default. This installs a hook over window.fetch and XMLHttpRequest
// on every page, and it exists only to feed the external YouTube player,
// which is not the playback path in use. A site's own scripts run through
// those two, so the hook is a page-wide risk for no current benefit.
// The desktop build of a site like YouTube is the heaviest thing it serves,
// and this device's web process cannot hold it: it dies and the page goes
// blank. Those sites get the phone agent, which is a fraction of the weight.
- (BOOL)lightenHeavySitesEnabled {
    NSNumber *value = [[self defaults] objectForKey:kLightenHeavySitesEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}
- (void)setLightenHeavySitesEnabled:(BOOL)lightenHeavySitesEnabled {
    [[self defaults] setObject:@(lightenHeavySitesEnabled) forKey:kLightenHeavySitesEnabledDefaultsKey];
    [[self defaults] synchronize];
}

// A TV is read from across a room, so whole-page zoom is the primary
// readability control: it scales layout and images with the text, and costs
// the web process nothing because WebKit does it, not a script.
// Defaults chosen for a television rather than a desk: news body text runs
// around 16px, which is under ten arcminutes at three metres, and the thin
// faces Korean news sites use lose their strokes at this pixel density.
- (NSUInteger)minimumFontSize {
    NSNumber *value = [[self defaults] objectForKey:kMinimumFontSizeDefaultsKey];
    NSUInteger size = value ? value.unsignedIntegerValue : 22;
    return MIN((NSUInteger)48, size);
}
- (void)setMinimumFontSize:(NSUInteger)minimumFontSize {
    [[self defaults] setObject:@(MIN((NSUInteger)48, minimumFontSize)) forKey:kMinimumFontSizeDefaultsKey];
    [[self defaults] synchronize];
}

// 1500 by 34 puts roughly 44 Korean characters on a line, which is the top of
// the comfortable range, and 34px at three metres is about the size of the
// reader mode text that already reads well.
- (NSUInteger)readingColumnWidth {
    NSNumber *value = [[self defaults] objectForKey:kReadingColumnWidthDefaultsKey];
    NSUInteger width = value ? value.unsignedIntegerValue : 1500;
    return MIN((NSUInteger)1920, MAX((NSUInteger)700, width));
}
- (void)setReadingColumnWidth:(NSUInteger)readingColumnWidth {
    NSUInteger clamped = MIN((NSUInteger)1920, MAX((NSUInteger)700, readingColumnWidth));
    [[self defaults] setObject:@(clamped) forKey:kReadingColumnWidthDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)readingBodyFontSize {
    NSNumber *value = [[self defaults] objectForKey:kReadingBodyFontSizeDefaultsKey];
    NSUInteger size = value ? value.unsignedIntegerValue : 34;
    return MIN((NSUInteger)72, MAX((NSUInteger)18, size));
}
- (void)setReadingBodyFontSize:(NSUInteger)readingBodyFontSize {
    NSUInteger clamped = MIN((NSUInteger)72, MAX((NSUInteger)18, readingBodyFontSize));
    [[self defaults] setObject:@(clamped) forKey:kReadingBodyFontSizeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)widenContentEnabled {
    return [[self defaults] boolForKey:kWidenContentEnabledDefaultsKey];
}
- (void)setWidenContentEnabled:(BOOL)widenContentEnabled {
    [[self defaults] setBool:widenContentEnabled forKey:kWidenContentEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)boldTextEnabled {
    NSNumber *value = [[self defaults] objectForKey:kBoldTextEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}
- (void)setBoldTextEnabled:(BOOL)boldTextEnabled {
    [[self defaults] setObject:@(boldTextEnabled) forKey:kBoldTextEnabledDefaultsKey];
    [[self defaults] synchronize];
}

// 1280 by default: just above the 1275 these sites lay out at, so the page
// fills the screen at a scale of about one and a half.
- (NSUInteger)pageLayoutWidth {
    NSNumber *value = [[self defaults] objectForKey:kPageLayoutWidthDefaultsKey];
    NSUInteger width = value ? value.unsignedIntegerValue : 1280;
    if (width == 0) {
        return 0;
    }
    return MIN((NSUInteger)1920, MAX((NSUInteger)800, width));
}
- (void)setPageLayoutWidth:(NSUInteger)pageLayoutWidth {
    NSUInteger clamped = pageLayoutWidth == 0 ? 0
        : MIN((NSUInteger)1920, MAX((NSUInteger)800, pageLayoutWidth));
    [[self defaults] setObject:@(clamped) forKey:kPageLayoutWidthDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)pageZoomPercent {
    NSNumber *value = [[self defaults] objectForKey:kPageZoomPercentDefaultsKey];
    NSUInteger percent = value ? value.unsignedIntegerValue : 100;
    return MIN((NSUInteger)250, MAX((NSUInteger)50, percent));
}
- (void)setPageZoomPercent:(NSUInteger)pageZoomPercent {
    NSUInteger clamped = MIN((NSUInteger)250, MAX((NSUInteger)50, pageZoomPercent));
    [[self defaults] setObject:@(clamped) forKey:kPageZoomPercentDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)readerFontSize {
    NSNumber *value = [[self defaults] objectForKey:kReaderFontSizeDefaultsKey];
    if (value == nil) {
        return kDefaultReaderFontSize;
    }
    NSUInteger size = value.unsignedIntegerValue;
    return MIN(MAX(size, kMinimumReaderFontSize), kMaximumReaderFontSize);
}
- (void)setReaderFontSize:(NSUInteger)readerFontSize {
    NSUInteger clamped = MIN(MAX(readerFontSize, kMinimumReaderFontSize), kMaximumReaderFontSize);
    [[self defaults] setObject:@(clamped) forKey:kReaderFontSizeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)contentBlockingEnabled {
    NSNumber *value = [[self defaults] objectForKey:kContentBlockingEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setContentBlockingEnabled:(BOOL)contentBlockingEnabled {
    [[self defaults] setObject:@(contentBlockingEnabled) forKey:kContentBlockingEnabledDefaultsKey];
    [[self defaults] synchronize];
}

@end
```
