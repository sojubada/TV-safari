#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPreferencesStore : NSObject

+ (NSString *)desktopUserAgent;
+ (NSString *)mobileUserAgent;

@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL mobileModeEnabled;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) NSUInteger textFontSize;
@property (nonatomic) BOOL fullscreenVideoPlaybackEnabled;
@property (nonatomic) BOOL scalePagesToFit;
@property (nonatomic) BOOL dontShowHintsOnLaunch;
@property (nonatomic, copy) NSString *homePageURLString;
// Remote control behaviour carried over from TV-safari. All on by default.
/// Ring up/down scrolls a page; holding it scrolls continuously.
@property (nonatomic) BOOL dpadScrollEnabled;
/// The page scrolls by itself while the cursor rests at the top or bottom edge.
@property (nonatomic) BOOL edgeAutoScrollEnabled;
/// A light tap on the touch surface clicks, like a laptop trackpad.
@property (nonatomic) BOOL tapToClickEnabled;
/// When the page itself doesn't move, scroll the box under the cursor
/// (sites that scroll inside a container rather than the page).
@property (nonatomic) BOOL jsScrollFallbackEnabled;

- (void)ensureUserAgentConsistency;

@end

NS_ASSUME_NONNULL_END
