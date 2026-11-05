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

@end

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
+ (void)clearCookiesWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)resetWebsiteDataWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
