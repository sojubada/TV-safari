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