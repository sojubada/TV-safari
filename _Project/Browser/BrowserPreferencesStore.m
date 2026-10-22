#import "BrowserPreferencesStore.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static NSString * const kMobileModeDefaultsKey = @"MobileMode";
static NSString * const kShowTopNavigationBarDefaultsKey = @"ShowTopNavigationBar";
static NSString * const kTextFontSizeDefaultsKey = @"TextFontSize";
static NSString * const kEnableFullscreenVideoPlaybackDefaultsKey = @"EnableFullscreenVideoPlayback";
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
static NSString * const kMinimumFontSizeDefaultsKey = @"MinimumFontSize";
static NSString * const kBoldTextEnabledDefaultsKey = @"BoldTextEnabled";
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

- (BOOL)fullscreenVideoPlaybackEnabled {
    return [[self defaults] boolForKey:kEnableFullscreenVideoPlaybackDefaultsKey];
}

- (void)setFullscreenVideoPlaybackEnabled:(BOOL)fullscreenVideoPlaybackEnabled {
    [[self defaults] setBool:fullscreenVideoPlaybackEnabled forKey:kEnableFullscreenVideoPlaybackDefaultsKey];
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

- (BOOL)boldTextEnabled {
    NSNumber *value = [[self defaults] objectForKey:kBoldTextEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}
- (void)setBoldTextEnabled:(BOOL)boldTextEnabled {
    [[self defaults] setObject:@(boldTextEnabled) forKey:kBoldTextEnabledDefaultsKey];
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