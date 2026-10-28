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

/// Shows a page the app built itself, with no network behind it. Used for the
/// diagnostic log, which lives in a folder nothing else on the box can reach.
- (void)loadHTMLString:(NSString *)html;
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