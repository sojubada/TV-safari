#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserWebViewDelegate <NSObject>

@optional
- (BOOL)webView:(id _Nonnull)webView shouldStartLoadWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (BOOL)webView:(id _Nonnull)webView shouldCreateNewTabWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (void)webViewDidStartLoad:(id _Nonnull)webView;
- (void)webViewDidCommitNavigation:(id _Nonnull)webView;
- (void)webViewDidFinishLoad:(id _Nonnull)webView;
- (void)webView:(id _Nonnull)webView didFailLoadWithError:(NSError * _Nonnull)error;
/// A load was asked for. Sent before WebKit is, so a watchdog can start even
/// when the page process never answers (it then never sends DidStartLoad).
- (void)webView:(id _Nonnull)webView didRequestLoadOfURL:(NSURL * _Nullable)URL;
/// The web content process ended. Without a reload the page keeps showing
/// what it had drawn and nothing below it ever appears.
- (void)browserWebViewWebContentProcessDidTerminate:(id _Nonnull)webView;

@end

/// One line for the log: whether the tvOS 16 media fix is in and how media is set up.
FOUNDATION_EXPORT NSString *BrowserMediaSafetySummary(void);
/// NSUserDefaults key. NO (default): pages are kept off AVFoundation, the
/// tvOS 16 crash path. YES: Orbrisa's original media setup.
FOUNDATION_EXPORT NSString * const BrowserMediaPlaybackEnabledDefaultsKey;
/// NSUserDefaults key for the ad and tracker blocker (on unless set to NO).
FOUNDATION_EXPORT NSString * const BrowserContentBlockingEnabledDefaultsKey;

FOUNDATION_EXPORT NSString * const BrowserForceDarkPagesDidChangeNotification;

@interface BrowserWebView : UIView

@property (nullable, nonatomic, weak) id<BrowserWebViewDelegate> delegate;
@property (nullable, nonatomic, readonly, strong) NSURLRequest *request;
@property (nullable, nonatomic, readonly, strong) UIScrollView *scrollView;
@property (nullable, nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, getter=canGoBack) BOOL canGoBack;
@property (nonatomic, readonly, getter=canGoForward) BOOL canGoForward;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic) BOOL scalesPageToFit;

- (instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithUserAgent:(NSString * _Nullable)userAgent
      allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback NS_DESIGNATED_INITIALIZER;

- (void)loadRequest:(NSURLRequest * _Nullable)request;
/// Cancels whatever is loading.
- (void)stopLoading;
/// Shows a page made in the app (the diagnostic log).
- (void)loadHTMLString:(NSString *)html;
/// How many times this web view's page process has ended.
@property (nonatomic, readonly) NSUInteger webContentTerminationCount;
- (void)reload;
- (void)goBack;
- (void)goForward;
- (nullable NSString *)stringByEvaluatingJavaScriptFromString:(NSString * _Nonnull)script;
- (NSString * _Nonnull)runtimeMediaPreferenceReport;
- (void)setUserAgent:(NSString * _Nullable)userAgent;
- (void)pauseAllMediaPlayback;
/// Dark mode for websites: light pages are shown dark. Saved across launches.
@property (class, nonatomic) BOOL forceDarkPages;
/// With dark mode on: 0 = automatic (follows the Apple TV), 1 = light, 2 = dark – for the pages and the app.
@property (class, nonatomic) NSInteger appearanceMode;
/// YES when pages should be shown dark right now (dark mode on, and the mode says dark).
+ (BOOL)websitesShouldBeDark;
/// Applies the light/dark choice to the app's windows (automatic when dark mode is off).
+ (void)applyAppearanceToWindows;
/// Presses "accept all" on cookie banners automatically. On by default.
@property (class, nonatomic) BOOL autoAcceptCookies;
/// YES while the app is already waiting for an answer from a page (nested waits are skipped).
+ (BOOL)isWaitingForPage;
/// Lets the run loop run for a moment while waiting for the page, without stacking up further waits.
+ (void)waitBrieflyForPage:(NSTimeInterval)interval;
/// Video streams the page loaded in the background (HLS .m3u8 or video files), newest page only.
/// Each entry: @"url", @"type" (hls / file / dash), @"source" (media / network), @"page".
@property (nonatomic, readonly, copy) NSArray<NSDictionary<NSString *, NSString *> *> *capturedMediaStreams;
/// The stream the Apple TV player can most likely play (HLS first, then a plain video file), or nil.
- (nullable NSDictionary<NSString *, NSString *> *)bestCapturedMediaStream;
/// All streams the Apple TV player could play, best first (adverts, previews and stream pieces left out or last).
- (NSArray<NSDictionary<NSString *, NSString *> *> *)playableCapturedMediaStreams;
/// A stream that turned out to be an advert (short clip that ended): never offered again on this page.
- (void)markCapturedStreamAsAdvert:(NSString *)URLString;
/// The best stream taken from the player's own configuration on the page (the real video, no advert), if any.
- (nullable NSDictionary<NSString *, NSString *> *)pageConfigMediaStream;
/// Skips adverts on the page (to their end) and starts the real video, so the page loads its real stream.
- (void)skipPageAdvertsAndPlayMainVideo;
/// The user agent the page is loaded with.
@property (nonatomic, readonly, copy) NSString *browserUserAgent;
/// Colours everything around the page itself (the space above it under the top bar and any overscroll area).
- (void)setPageEdgeColor:(UIColor *)color;

+ (nullable NSData *)cookieDataRepresentation;
+ (NSArray<NSHTTPCookie *> * _Nonnull)allCookies;
+ (void)restoreCookiesFromData:(NSData * _Nullable)cookieData;
+ (void)clearCachedDataWithCompletion:(void (^ _Nullable)(void))completion;
/// Removes only what can be fetched again (disk/memory/fetch caches, service
/// worker caches). Cookies, logins and site storage stay.
+ (void)trimCachesWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)clearCookiesWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)resetWebsiteDataWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
