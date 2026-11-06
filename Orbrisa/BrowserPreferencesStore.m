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
static NSString * const kMobileFallbackHostsDefaultsKey = @"MobileFallbackHosts";
static NSString * const kLightenHeavySitesEnabledDefaultsKey = @"LightenHeavySitesEnabled";

static NSUInteger const kDefaultTextFontSize = 100;
static NSUInteger const kMinimumTextFontSize = 50;
static NSUInteger const kMaximumTextFontSize = 200;

@implementation BrowserPreferencesStore

+ (NSString *)desktopUserAgent {
    // tvOS 16.6 carries the engine that shipped with Safari 16.6. Claiming 17
    // got pages served code paths this engine does not have, and scripts that
    // fail half way leave a page with nothing below its first screen.
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15";
}

+ (NSString *)mobileUserAgent {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1";
}

- (NSUserDefaults *)defaults {
    return [NSUserDefaults standardUserDefaults];
}

- (void)ensureUserAgentConsistency {
    if (self.userAgent.length > 0) {
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
    [[self defaults] setBool:jsScrollFallbackEnabled forKey:kJSScrollFallbackEnabledDefaultsKey];
}

- (BOOL)dpadScrollEnabled {
    NSNumber *value = [[self defaults] objectForKey:kDpadScrollEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setDpadScrollEnabled:(BOOL)dpadScrollEnabled {
    [[self defaults] setBool:dpadScrollEnabled forKey:kDpadScrollEnabledDefaultsKey];
}

- (BOOL)edgeAutoScrollEnabled {
    NSNumber *value = [[self defaults] objectForKey:kEdgeAutoScrollEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setEdgeAutoScrollEnabled:(BOOL)edgeAutoScrollEnabled {
    [[self defaults] setBool:edgeAutoScrollEnabled forKey:kEdgeAutoScrollEnabledDefaultsKey];
}

- (BOOL)tapToClickEnabled {
    NSNumber *value = [[self defaults] objectForKey:kTapToClickEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setTapToClickEnabled:(BOOL)tapToClickEnabled {
    [[self defaults] setBool:tapToClickEnabled forKey:kTapToClickEnabledDefaultsKey];
}

- (NSArray<NSString *> *)mobileFallbackHosts {
    return [[self defaults] arrayForKey:kMobileFallbackHostsDefaultsKey] ?: @[];
}

- (BOOL)isMobileFallbackHost:(NSString *)host {
    if (host.length == 0) {
        return NO;
    }
    NSString *lowercase = host.lowercaseString;
    for (NSString *stored in [self mobileFallbackHosts]) {
        if ([lowercase isEqualToString:stored] ||
            [lowercase hasSuffix:[@"." stringByAppendingString:stored]]) {
            return YES;
        }
    }
    return NO;
}

- (void)addMobileFallbackHost:(NSString *)host {
    if (host.length == 0 || [self isMobileFallbackHost:host]) {
        return;
    }
    NSMutableArray<NSString *> *hosts = [[self mobileFallbackHosts] mutableCopy];
    [hosts addObject:host.lowercaseString];
    // Bounded, so a long run of unlucky pages cannot grow it without end.
    while (hosts.count > 200) {
        [hosts removeObjectAtIndex:0];
    }
    [[self defaults] setObject:hosts forKey:kMobileFallbackHostsDefaultsKey];
}

- (void)clearMobileFallbackHosts {
    [[self defaults] removeObjectForKey:kMobileFallbackHostsDefaultsKey];
}

- (BOOL)lightenHeavySitesEnabled {
    NSNumber *value = [[self defaults] objectForKey:kLightenHeavySitesEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setLightenHeavySitesEnabled:(BOOL)lightenHeavySitesEnabled {
    [[self defaults] setBool:lightenHeavySitesEnabled forKey:kLightenHeavySitesEnabledDefaultsKey];
}

@end
