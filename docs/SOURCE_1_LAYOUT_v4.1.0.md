# tvOS Browser v4.1.0 — 레이아웃·화면 채우기 (5-1 검토 대상)

이번 버전의 핵심 변경과 커서 좌표계가 걸려 있는 파일들입니다. **이것만 봐도 5-1 검토는 가능합니다.**

> 검토 지침은 `REVIEW_v4.1.0.md`를 먼저 읽어 주십시오.

## `BrowserTabCoordinator.h`  (76줄)

```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserNavigationService;
@class BrowserPreferencesStore;
@class BrowserSessionStore;
@class BrowserTabViewModel;
@class BrowserTopBarView;
@class BrowserViewModel;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserTabCoordinatorHost <NSObject>

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController;
- (void)browserTabCoordinatorUpdateTextFontSize;
- (BOOL)browserTabCoordinatorIsCursorModeEnabled;
- (BOOL)browserTabCoordinatorIsTabOverviewVisible;

@end

@interface BrowserTabCoordinator : NSObject

@property (nonatomic, readonly, nullable) BrowserWebView *activeWebView;
@property (nonatomic, readonly, nullable) BrowserTabViewModel *activeTab;
@property (nonatomic, copy) NSString *requestURL;
@property (nonatomic, copy) NSString *previousURL;

- (instancetype)initWithHost:(id<BrowserTabCoordinatorHost>)host
                   viewModel:(BrowserViewModel *)viewModel
            preferencesStore:(BrowserPreferencesStore *)preferencesStore
           navigationService:(BrowserNavigationService *)navigationService
                sessionStore:(BrowserSessionStore *)sessionStore
           browserContainerView:(UIView *)browserContainerView
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView
     manualScrollPanRecognizer:(UIPanGestureRecognizer *)manualScrollPanRecognizer
             webViewDelegate:(id)webViewDelegate
         scrollViewAllowBounces:(BOOL)scrollViewAllowBounces NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)restoreInitialStateOrCreateFirstTab;
- (void)webViewDidAppear;
- (void)loadHomePage;
- (void)createNewTabLoadingHomePage:(BOOL)loadHomePage;
- (BOOL)createNewTabWithRequest:(NSURLRequest *)request;
- (void)switchToTabAtIndex:(NSInteger)tabIndex;
- (void)closeTabAtIndex:(NSInteger)tabIndex;
- (void)recreateActiveWebViewPreservingCurrentURL;
- (void)captureSnapshotForCurrentTab;
- (void)prepareTabOverviewThumbnails;
- (void)persistSession;
- (void)handleWebViewPanGesture:(UIPanGestureRecognizer *)gestureRecognizer;
- (void)webViewDidStartLoad:(id)webView;
- (void)webViewDidFinishLoad:(id)webView;
- (void)prepareTabForRequest:(NSURLRequest *)request webView:(id)webView;
/// Left inset applied to the active web view, used by the probe workbench so
/// the page is narrowed rather than covered.
@property (nonatomic) CGFloat webViewLeadingInset;

/// CSS width the page is laid out at before being scaled to fill the
/// screen. 0 lays out at the screen width, as a desktop browser would.
@property (nonatomic) CGFloat pageLayoutWidth;

- (void)updateTopNavAndWebView;
- (void)setTopNavigationVisible:(BOOL)visible;
- (BrowserTabViewModel *)tabForWebView:(id)webView;
- (BOOL)isPrimaryDocumentRequest:(NSURLRequest *)request;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserTabCoordinator.m`  (702줄)

```objc
#import "BrowserTabCoordinator.h"

#import "BrowserNavigationService.h"
#import "BrowserPreferencesStore.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTopBarView.h"
#import "BrowserViewModel.h"
#import "BrowserWebView.h"

static CGFloat const kThumbnailStagingOffset = 4096.0;

@interface BrowserTabCoordinator ()

@property (nonatomic, weak) id<BrowserTabCoordinatorHost> host;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic, weak) UIView *browserContainerView;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, weak) BrowserTopBarView *topMenuView;
@property (nonatomic, weak) UIImageView *cursorView;
@property (nonatomic, weak) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, weak) id webViewDelegate;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic) NSMutableDictionary<NSString *, BrowserWebView *> *webViewsByTabIdentifier;
@property (nonatomic) UIView *thumbnailStagingView;
@property (nonatomic, readwrite, nullable) BrowserWebView *activeWebView;

@end

@implementation BrowserTabCoordinator

- (instancetype)initWithHost:(id<BrowserTabCoordinatorHost>)host
                   viewModel:(BrowserViewModel *)viewModel
            preferencesStore:(BrowserPreferencesStore *)preferencesStore
           navigationService:(BrowserNavigationService *)navigationService
                sessionStore:(BrowserSessionStore *)sessionStore
          browserContainerView:(UIView *)browserContainerView
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView
     manualScrollPanRecognizer:(UIPanGestureRecognizer *)manualScrollPanRecognizer
             webViewDelegate:(id)webViewDelegate
         scrollViewAllowBounces:(BOOL)scrollViewAllowBounces {
    self = [super init];
    if (self) {
        _host = host;
        _viewModel = viewModel;
        _preferencesStore = preferencesStore;
        _navigationService = navigationService;
        _sessionStore = sessionStore;
        _browserContainerView = browserContainerView;
        _rootView = rootView;
        _topMenuView = topMenuView;
        _cursorView = cursorView;
        _manualScrollPanRecognizer = manualScrollPanRecognizer;
        _webViewDelegate = webViewDelegate;
        _scrollViewAllowBounces = scrollViewAllowBounces;
        _webViewsByTabIdentifier = [NSMutableDictionary dictionary];
        [_preferencesStore ensureUserAgentConsistency];
        [self ensureThumbnailStagingView];
    }
    return self;
}

- (BrowserTabViewModel *)activeTab {
    return [self.viewModel activeTab];
}

- (NSString *)requestURL {
    return self.activeTab.requestURL;
}

- (void)setRequestURL:(NSString *)requestURL {
    self.activeTab.requestURL = requestURL ?: @"";
}

- (NSString *)previousURL {
    return self.activeTab.previousURL;
}

- (void)setPreviousURL:(NSString *)previousURL {
    self.activeTab.previousURL = previousURL ?: @"";
}

- (BOOL)topNavigationVisible {
    return self.viewModel.topNavigationBarVisible;
}

- (CGFloat)topMenuBrowserOffset {
    return self.topNavigationVisible ? self.topMenuView.frame.size.height : 0.0;
}

- (void)setTopNavigationVisible:(BOOL)visible {
    self.viewModel.topNavigationBarVisible = visible;
    self.topMenuView.hidden = !visible;
    [self updateTopNavAndWebView];
}

// Korean news sites cap their desktop layout at 1110-1275 CSS pixels and
// centre it; there is no breakpoint above 668px that widens it. On a 1920
// point screen that leaves 320 points of margin on each side, which is why
// the television looks emptier than a 1600 wide monitor showing the same
// page — the page is identical, only the surrounding space differs.
//
// So the screen is fitted to the page rather than the page to the screen.
// The web view is laid out at the fitting width and the whole thing is scaled
// up to fill the display: the proportions become the ones a desktop monitor
// shows, and everything on it is larger by the same factor.
//
// Setting a frame on a view with a transform is undefined, so bounds and
// centre are set around it.
- (void)updateTopNavAndWebView {
    BrowserWebView *webView = self.activeWebView;
    if (webView == nil) {
        return;
    }

    CGFloat inset = MAX(0.0, MIN(self.webViewLeadingInset, CGRectGetWidth(self.rootView.bounds) - 200.0));
    CGFloat top = self.rootView.bounds.origin.y + (self.topNavigationVisible ? self.topMenuBrowserOffset : 0.0);
    CGFloat availableWidth = self.rootView.bounds.size.width - inset;
    CGFloat availableHeight = self.rootView.bounds.size.height - (self.topNavigationVisible ? self.topMenuBrowserOffset : 0.0);
    if (availableWidth < 1.0 || availableHeight < 1.0) {
        return;
    }

    CGFloat layoutWidth = self.pageLayoutWidth;
    CGFloat scale = 1.0;
    if (layoutWidth > 200.0 && layoutWidth < availableWidth) {
        scale = availableWidth / layoutWidth;
    } else {
        layoutWidth = availableWidth;
    }

    webView.transform = CGAffineTransformIdentity;
    webView.bounds = CGRectMake(0.0, 0.0, layoutWidth, availableHeight / scale);
    if (scale != 1.0) {
        webView.transform = CGAffineTransformMakeScale(scale, scale);
    }
    webView.center = CGPointMake(self.rootView.bounds.origin.x + inset + availableWidth / 2.0,
                                 top + availableHeight / 2.0);
}

- (void)setPageLayoutWidth:(CGFloat)pageLayoutWidth {
    _pageLayoutWidth = pageLayoutWidth;
    [self updateTopNavAndWebView];
}

- (void)setWebViewLeadingInset:(CGFloat)webViewLeadingInset {
    _webViewLeadingInset = webViewLeadingInset;
    [self updateTopNavAndWebView];
}

- (CGSize)thumbnailViewportSize {
    CGFloat width = CGRectGetWidth(self.rootView.bounds);
    CGFloat height = CGRectGetHeight(self.rootView.bounds) - self.topMenuBrowserOffset;
    return CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
}

- (void)ensureThumbnailStagingView {
    if (self.thumbnailStagingView != nil || self.rootView == nil) {
        return;
    }

    CGSize viewportSize = [self thumbnailViewportSize];
    UIView *stagingView = [[UIView alloc] initWithFrame:CGRectMake(kThumbnailStagingOffset,
                                                                   0.0,
                                                                   viewportSize.width,
                                                                   viewportSize.height)];
    stagingView.backgroundColor = UIColor.clearColor;
    stagingView.userInteractionEnabled = NO;
    stagingView.clipsToBounds = YES;
    [self.rootView addSubview:stagingView];
    self.thumbnailStagingView = stagingView;
}

- (void)updateThumbnailStagingViewFrame {
    [self ensureThumbnailStagingView];
    if (self.thumbnailStagingView == nil) {
        return;
    }

    CGSize viewportSize = [self thumbnailViewportSize];
    self.thumbnailStagingView.frame = CGRectMake(kThumbnailStagingOffset,
                                                 0.0,
                                                 viewportSize.width,
                                                 viewportSize.height);
}

- (void)prepareWebViewLayoutForSnapshot:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }

    if (webView.superview == self.thumbnailStagingView) {
        webView.frame = self.thumbnailStagingView.bounds;
    }
    [webView setNeedsLayout];
    [webView layoutIfNeeded];

    UIScrollView *scrollView = webView.scrollView;
    [scrollView setNeedsLayout];
    [scrollView layoutIfNeeded];
    [self.rootView setNeedsLayout];
    [self.rootView layoutIfNeeded];
}

- (void)parkWebViewForThumbnailing:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }

    [self updateThumbnailStagingViewFrame];
    webView.userInteractionEnabled = NO;
    UIScrollView *scrollView = webView.scrollView;
    scrollView.scrollEnabled = NO;
    scrollView.bounces = self.scrollViewAllowBounces;
    if (webView.superview != self.thumbnailStagingView) {
        [webView removeFromSuperview];
        [self.thumbnailStagingView addSubview:webView];
    }
    webView.frame = self.thumbnailStagingView.bounds;
}

- (BOOL)isWebViewStaged:(BrowserWebView *)webView {
    return webView != nil && webView.superview == self.thumbnailStagingView;
}

- (BrowserWebView *)createConfiguredWebView {
    BrowserWebView *webView = [[BrowserWebView alloc] initWithUserAgent:self.preferencesStore.userAgent
                                            allowsInlineMediaPlayback:YES];
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    webView.clipsToBounds = NO;
    webView.delegate = self.webViewDelegate;
    webView.layoutMargins = UIEdgeInsetsZero;
    webView.opaque = NO;
    webView.backgroundColor = UIColor.blackColor;

    UIScrollView *scrollView = webView.scrollView;
    scrollView.layoutMargins = UIEdgeInsetsZero;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scrollView.contentOffset = CGPointZero;
    scrollView.contentInset = UIEdgeInsetsZero;
    scrollView.clipsToBounds = NO;
    scrollView.backgroundColor = UIColor.blackColor;
    scrollView.bounces = self.scrollViewAllowBounces;
    [scrollView.panGestureRecognizer addTarget:self action:@selector(handleWebViewPanGesture:)];
    scrollView.scrollEnabled = NO;

    BOOL shouldScalePagesToFit = self.preferencesStore.scalePagesToFit;
    webView.scalesPageToFit = shouldScalePagesToFit;
    webView.contentMode = shouldScalePagesToFit ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleToFill;
    webView.userInteractionEnabled = NO;
    return webView;
}

- (void)refreshActiveTabUI {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        self.topMenuView.URLLabel.text = @"";
        return;
    }

    NSURLRequest *request = self.activeWebView.request;
    NSString *currentURL = tab.URLString.length > 0 ? tab.URLString : request.URL.absoluteString;
    self.topMenuView.URLLabel.text = currentURL.length > 0 ? currentURL : @"New Tab";

    if (request != nil) {
        [self.host browserTabCoordinatorUpdateTextFontSize];
    }
}

- (BOOL)restoreBrowserSession {
    return [self.sessionStore restoreSessionIntoViewModel:self.viewModel];
}

- (void)restoreInitialStateOrCreateFirstTab {
    self.topMenuView.hidden = !self.viewModel.topNavigationBarVisible;
    if (![self restoreBrowserSession]) {
        [self createNewTabLoadingHomePage:NO];
        return;
    }
    [self initWebView];
    [self refreshActiveTabUI];
}

- (void)webViewDidAppear {
    NSURLRequest *savedReopenRequest = [self.sessionStore consumeSavedURLToReopenRequestWithNavigationService:self.navigationService];
    if (savedReopenRequest != nil) {
        [self.activeWebView loadRequest:savedReopenRequest];
    } else if (self.activeWebView.request == nil) {
        [self loadStoredContentForTab:self.activeTab webView:self.activeWebView fallbackToHomePage:YES];
    }
}

- (void)loadHomePage {
    NSURLRequest *homePageRequest = [self.navigationService homePageRequest];
    if (homePageRequest != nil) {
        [self.activeWebView loadRequest:homePageRequest];
    }
}

- (void)initWebView {
    self.topMenuView.hidden = !self.viewModel.topNavigationBarVisible;

    BrowserTabViewModel *tab = [self.viewModel ensureActiveTab];
    if (tab == nil) {
        return;
    }

    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    if (webView == nil) {
        webView = [self createConfiguredWebView];
        self.webViewsByTabIdentifier[tab.identifier] = webView;
    }
    self.activeWebView = webView;
    [self attachActiveWebView];
}

- (void)attachActiveWebView {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        return;
    }

    BrowserWebView *activeWebView = self.webViewsByTabIdentifier[tab.identifier];
    if (activeWebView == nil) {
        return;
    }

    [self updateThumbnailStagingViewFrame];
    for (BrowserTabViewModel *candidate in self.viewModel.tabs) {
        BrowserWebView *candidateWebView = self.webViewsByTabIdentifier[candidate.identifier];
        if (candidateWebView == nil || candidateWebView == activeWebView) {
            continue;
        }
        [self parkWebViewForThumbnailing:candidateWebView];
    }

    self.activeWebView = activeWebView;
    [self.topMenuView.loadingSpinner stopAnimating];
    [self.activeWebView removeFromSuperview];
    [self.browserContainerView addSubview:self.activeWebView];
    [self updateTopNavAndWebView];

    UIScrollView *scrollView = self.activeWebView.scrollView;
    [scrollView setNeedsLayout];
    [scrollView layoutIfNeeded];
    [self.rootView setNeedsLayout];
    [self.rootView layoutIfNeeded];
    scrollView.bounces = self.scrollViewAllowBounces;

    BOOL shouldAllowWebInteraction = ![self.host browserTabCoordinatorIsCursorModeEnabled] &&
        ![self.host browserTabCoordinatorIsTabOverviewVisible];
    scrollView.scrollEnabled = shouldAllowWebInteraction;
    self.activeWebView.userInteractionEnabled = shouldAllowWebInteraction;
    self.manualScrollPanRecognizer.enabled = shouldAllowWebInteraction;

    [self refreshActiveTabUI];
}

- (void)updateStoredScrollOffsetForTab:(BrowserTabViewModel *)tab {
    if (tab == nil) {
        return;
    }

    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    if (webView == nil) {
        return;
    }

    UIScrollView *scrollView = webView.scrollView;
    tab.savedScrollOffset = scrollView.contentOffset;
    tab.hasSavedScrollOffset = YES;
}

- (void)persistSession {
    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        [self updateStoredScrollOffsetForTab:tab];
    }
    [self.sessionStore saveSessionForViewModel:self.viewModel];
}

- (void)loadStoredContentForTab:(BrowserTabViewModel *)tab
                        webView:(BrowserWebView *)webView
             fallbackToHomePage:(BOOL)fallbackToHomePage {
    if (webView == nil) {
        return;
    }

    NSString *URLString = tab.URLString.length > 0 ? tab.URLString : tab.requestURL;
    if (URLString.length == 0) {
        if (fallbackToHomePage) {
            NSURLRequest *homePageRequest = [self.navigationService homePageRequest];
            if (homePageRequest != nil) {
                [webView loadRequest:homePageRequest];
            }
        }
        return;
    }

    NSURLRequest *request = [self.navigationService requestForURLString:URLString];
    if (request != nil) {
        [webView loadRequest:request];
    } else if (fallbackToHomePage) {
        NSURLRequest *homePageRequest = [self.navigationService homePageRequest];
        if (homePageRequest != nil) {
            [webView loadRequest:homePageRequest];
        }
    }
}

- (void)restoreSavedScrollOffsetForTab:(BrowserTabViewModel *)tab webView:(BrowserWebView *)webView {
    if (tab == nil || !tab.needsScrollRestore || !tab.hasSavedScrollOffset) {
        return;
    }

    UIScrollView *scrollView = webView.scrollView;
    CGPoint savedScrollOffset = tab.savedScrollOffset;
    dispatch_async(dispatch_get_main_queue(), ^{
        [scrollView layoutIfNeeded];
        CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
        CGFloat maxOffsetY = MAX(0.0, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds));
        CGPoint clampedScrollOffset = CGPointMake(MIN(MAX(savedScrollOffset.x, 0.0), maxOffsetX),
                                                  MIN(MAX(savedScrollOffset.y, 0.0), maxOffsetY));
        [scrollView setContentOffset:clampedScrollOffset animated:NO];
        tab.savedScrollOffset = clampedScrollOffset;
        tab.hasSavedScrollOffset = YES;
        [self captureSnapshotForTab:tab];
        [self persistSession];
    });
    tab.needsScrollRestore = NO;
}

- (void)captureSnapshotForTab:(BrowserTabViewModel *)tab {
    if (tab == nil) {
        return;
    }

    if (!tab.needsScrollRestore) {
        [self updateStoredScrollOffsetForTab:tab];
    }

    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    if (webView == nil || CGRectIsEmpty(webView.bounds)) {
        return;
    }

    [self prepareWebViewLayoutForSnapshot:webView];
    UIGraphicsBeginImageContextWithOptions(webView.bounds.size, YES, 0.0);
    [webView drawViewHierarchyInRect:webView.bounds afterScreenUpdates:NO];
    UIImage *snapshotImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (snapshotImage != nil) {
        tab.snapshotImage = snapshotImage;
    }
}

- (void)captureSnapshotForCurrentTab {
    [self captureSnapshotForTab:self.activeTab];
}

- (void)prepareTabOverviewThumbnails {
    [self updateThumbnailStagingViewFrame];

    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
        if (tab == self.activeTab) {
            [self captureSnapshotForTab:tab];
            continue;
        }

        if (webView == nil) {
            webView = [self createConfiguredWebView];
            self.webViewsByTabIdentifier[tab.identifier] = webView;
        }

        [self parkWebViewForThumbnailing:webView];
        if (webView.request == nil) {
            [self loadStoredContentForTab:tab webView:webView fallbackToHomePage:NO];
            continue;
        }

        [self captureSnapshotForTab:tab];
    }
}

- (void)showMaxTabsAlert {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Maximum Tabs Reached"
                                                                             message:@"This build keeps up to five tabs open at once."
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Dismiss"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self.host browserTabCoordinatorPresentViewController:alertController];
}

- (void)createNewTabLoadingHomePage:(BOOL)loadHomePage {
    BrowserTabViewModel *tab = [self.viewModel addTab];
    if (tab == nil) {
        [self showMaxTabsAlert];
        return;
    }

    (void)tab;
    [self initWebView];
    [self refreshActiveTabUI];
    [self.rootView bringSubviewToFront:self.cursorView];

    if (loadHomePage) {
        [self loadHomePage];
    }
    [self persistSession];
}

- (BOOL)createNewTabWithRequest:(NSURLRequest *)request {
    if (request == nil || request.URL == nil) {
        return NO;
    }

    [self captureSnapshotForTab:self.activeTab];
    if ([self.viewModel addTab] == nil) {
        [self showMaxTabsAlert];
        return NO;
    }

    [self initWebView];
    [self refreshActiveTabUI];
    [self.rootView bringSubviewToFront:self.cursorView];
    [self.activeWebView loadRequest:request];
    [self persistSession];
    return YES;
}

- (void)switchToTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.viewModel.tabs.count) {
        return;
    }

    BrowserTabViewModel *currentTab = self.activeTab;
    [self captureSnapshotForTab:currentTab];

    [self.viewModel switchToTabAtIndex:tabIndex];
    [self initWebView];
    [self.rootView bringSubviewToFront:self.cursorView];
    if (self.activeWebView.request == nil) {
        [self loadStoredContentForTab:self.activeTab webView:self.activeWebView fallbackToHomePage:YES];
    }
    [self persistSession];
}

- (void)closeTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.viewModel.tabs.count) {
        return;
    }

    BOOL closingActiveTab = tabIndex == self.viewModel.activeTabIndex;
    BrowserTabViewModel *tab = self.viewModel.tabs[tabIndex];
    [self.webViewsByTabIdentifier[tab.identifier] removeFromSuperview];
    [self.webViewsByTabIdentifier removeObjectForKey:tab.identifier];
    [self.viewModel removeTabAtIndex:tabIndex];

    if (self.viewModel.tabs.count == 0) {
        [self createNewTabLoadingHomePage:YES];
        return;
    }

    if (closingActiveTab) {
        [self initWebView];
        if (self.activeWebView.request == nil) {
            [self loadStoredContentForTab:self.activeTab webView:self.activeWebView fallbackToHomePage:YES];
        }
    }

    [self refreshActiveTabUI];
    [self persistSession];
}

- (void)recreateActiveWebViewPreservingCurrentURL {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        return;
    }

    NSString *currentURL = self.activeWebView.request.URL.absoluteString;
    [self.webViewsByTabIdentifier[tab.identifier] removeFromSuperview];
    [self.webViewsByTabIdentifier removeObjectForKey:tab.identifier];
    tab.requestURL = currentURL ?: @"";
    tab.previousURL = @"";
    tab.URLString = currentURL ?: @"";
    [self initWebView];

    if (currentURL.length > 0) {
        NSURLRequest *request = [self.navigationService requestForURLString:currentURL];
        if (request != nil) {
            [self.activeWebView loadRequest:request];
        }
    } else {
        [self loadHomePage];
    }
    [self persistSession];
}

- (void)handleWebViewPanGesture:(UIPanGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state != UIGestureRecognizerStateEnded &&
        gestureRecognizer.state != UIGestureRecognizerStateCancelled &&
        gestureRecognizer.state != UIGestureRecognizerStateFailed) {
        return;
    }

    UIView *gestureView = gestureRecognizer.view;
    if (![gestureView isKindOfClass:[UIScrollView class]]) {
        return;
    }

    UIScrollView *scrollView = (UIScrollView *)gestureView;
    if (scrollView != self.activeWebView.scrollView) {
        return;
    }

    [self persistSession];
}

- (BOOL)isPrimaryDocumentRequest:(NSURLRequest *)request {
    NSURL *requestURL = request.URL;
    NSURL *mainDocumentURL = request.mainDocumentURL;
    if (requestURL == nil) {
        return NO;
    }
    if (mainDocumentURL == nil) {
        return YES;
    }
    return [requestURL isEqual:mainDocumentURL];
}

- (BrowserTabViewModel *)tabForWebView:(id)webView {
    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        if (self.webViewsByTabIdentifier[tab.identifier] == webView) {
            return tab;
        }
    }
    return nil;
}

- (void)prepareTabForRequest:(NSURLRequest *)request webView:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil || ![self isPrimaryDocumentRequest:request]) {
        return;
    }
    NSString *requestURL = request.URL.absoluteString ?: @"";
    if (tab.URLString.length > 0 && ![tab.URLString isEqualToString:requestURL]) {
        tab.savedScrollOffset = CGPointZero;
        tab.hasSavedScrollOffset = NO;
        tab.needsScrollRestore = NO;
    }
    tab.requestURL = requestURL;
}

- (void)webViewDidStartLoad:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    if (tab == self.activeTab && ![tab.previousURL isEqualToString:tab.requestURL]) {
        [self.topMenuView.loadingSpinner startAnimating];
    }
    tab.previousURL = tab.requestURL;
}

- (void)webViewDidFinishLoad:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    if (tab == self.activeTab) {
        [self.topMenuView.loadingSpinner stopAnimating];
    }

    NSString *theTitle = [webView stringByEvaluatingJavaScriptFromString:@"document.title"];
    NSURLRequest *request = [webView request];
    NSString *currentURL = request.URL.absoluteString ?: @"";
    [self.navigationService updateTab:tab withPageTitle:theTitle currentURLString:currentURL];

    if (tab == self.activeTab) {
        [self refreshActiveTabUI];
    } else if ([self isWebViewStaged:webView]) {
        [webView pauseAllMediaPlayback];
    }
    [self restoreSavedScrollOffsetForTab:tab webView:webView];
    if (!tab.needsScrollRestore) {
        [self captureSnapshotForTab:tab];
        [self persistSession];
    }
}

@end
```

## `BrowserTopBarView.h`  (57줄)

```objc
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BrowserTopBarAction) {
    BrowserTopBarActionBack = 0,
    BrowserTopBarActionRefresh,
    BrowserTopBarActionForward,
    BrowserTopBarActionHome,
    BrowserTopBarActionTabs,
    BrowserTopBarActionURL,
    BrowserTopBarActionFullscreen,
    BrowserTopBarActionMenu,
    BrowserTopBarActionExit,
    BrowserTopBarActionBookmarks,
    BrowserTopBarActionReading,
    BrowserTopBarActionPrivacy,
    BrowserTopBarActionSettings
};

@class BrowserTopBarView;

@protocol BrowserTopBarViewDelegate <NSObject>

- (void)browserTopBarView:(BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action;

@end

@interface BrowserTopBarView : UIVisualEffectView

@property (nonatomic, weak, nullable) id<BrowserTopBarViewDelegate> delegate;
@property (nonatomic, readonly) UIImageView *exitImageView;
@property (nonatomic, readonly) UIImageView *backImageView;
@property (nonatomic, readonly) UIImageView *refreshImageView;
@property (nonatomic, readonly) UIImageView *forwardImageView;
@property (nonatomic, readonly) UIImageView *homeImageView;
@property (nonatomic, readonly) UIImageView *tabsImageView;
@property (nonatomic, readonly) UIImageView *settingsImageView;
@property (nonatomic, readonly) UIImageView *privacyImageView;
@property (nonatomic, readonly) UIImageView *readingImageView;
@property (nonatomic, readonly) UIImageView *bookmarksImageView;
@property (nonatomic, readonly) UIImageView *fullscreenImageView;
@property (nonatomic, readonly) UIImageView *menuImageView;
@property (nonatomic, readonly) UILabel *URLLabel;
@property (nonatomic, readonly) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, readonly, getter=isFocusModeActive) BOOL focusModeActive;

- (CGRect)interactiveFrameForView:(UIView *)view;
// Screen x of the icon for an action, so a menu can drop down beneath it.
- (CGFloat)screenCenterXForAction:(BrowserTopBarAction)action;
- (void)setFocusModeActive:(BOOL)focusModeActive;
- (nullable UIView *)preferredFocusItem;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserTopBarView.m`  (624줄)

```objc
#import "BrowserTopBarView.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

static CGFloat const kTopBarHorizontalInset = 40.0;
static CGFloat const kTopBarVerticalInset = 8.0;
static CGFloat const kTopBarHeight = 86.0;
static CGFloat const kTopBarMaxWidth = 1760.0;
static CGFloat const kTopBarIconSize = 52.0;
static CGFloat const kTopBarLeadingPadding = 28.0;
static CGFloat const kTopBarTrailingPadding = 26.0;
static CGFloat const kTopBarIconSpacing = 24.0;
static CGFloat const kTopBarLabelSpacing = 20.0;
static CGFloat const kTopBarSpinnerSpacing = 22.0;
static CGFloat const kTopBarFocusHighlightInset = 10.0;
static CGFloat const kTopBarUniformFocusHeight = 72.0;
static CGFloat const kTopBarSymbolPointSize = 34.0;
static CGFloat const kTopBarSeparatorWidth = 2.0;
static CGFloat const kTopBarSeparatorHeight = 38.0;
static CGFloat const kTopBarSeparatorSpacing = 20.0;

@interface BrowserTopBarFocusButton : UIButton

@property (nonatomic) BrowserTopBarAction topBarAction;

@end

@implementation BrowserTopBarFocusButton

- (BOOL)canBecomeFocused {
    return self.enabled && !self.hidden && self.alpha > 0.01;
}

- (UIFocusSoundIdentifier)soundIdentifierForFocusUpdateInContext:(__unused UIFocusUpdateContext *)context {
    return UIFocusSoundIdentifierDefault;
}

@end

@interface BrowserTopBarView ()

@property (nonatomic) UIView *chromeContainerView;
@property (nonatomic) UIVisualEffectView *chromeEffectView;
@property (nonatomic) UIImageView *exitImageView;
@property (nonatomic) UIView *exitSeparatorView;
@property (nonatomic) UIImageView *backImageView;
@property (nonatomic) UIImageView *refreshImageView;
@property (nonatomic) UIImageView *forwardImageView;
@property (nonatomic) UIImageView *homeImageView;
@property (nonatomic) UIImageView *tabsImageView;
@property (nonatomic) UIImageView *settingsImageView;
@property (nonatomic) UIImageView *privacyImageView;
@property (nonatomic) UIImageView *readingImageView;
@property (nonatomic) UIImageView *bookmarksImageView;
@property (nonatomic) UIImageView *fullscreenImageView;
@property (nonatomic) UIImageView *menuImageView;
@property (nonatomic) UILabel *URLLabel;
@property (nonatomic) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic) UIView *focusGlowView;
@property (nonatomic) UIView *focusHighlightView;
@property (nonatomic) NSArray<BrowserTopBarFocusButton *> *focusButtons;
@property (nonatomic) BrowserTopBarFocusButton *exitFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *backFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *refreshFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *forwardFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *homeFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *tabsFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *URLFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *settingsFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *privacyFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *readingFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *bookmarksFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *fullscreenFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *menuFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *lastFocusedButton;
@property (nonatomic, getter=isFocusModeActive) BOOL focusModeActive;

@end

@implementation BrowserTopBarView

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithEffect:(UIVisualEffect *)effect {
    self = [super initWithEffect:effect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];

    for (UIView *subview in [self.contentView.subviews copy]) {
        if (subview != self.chromeContainerView) {
            [subview removeFromSuperview];
        }
    }
}

- (void)commonInit {
    self.effect = nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.userInteractionEnabled = YES;
    self.contentView.clipsToBounds = NO;

    self.chromeContainerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.chromeContainerView.backgroundColor = UIColor.clearColor;
    self.chromeContainerView.userInteractionEnabled = YES;
    self.chromeContainerView.clipsToBounds = NO;
    [self.contentView addSubview:self.chromeContainerView];

    self.chromeEffectView = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.chromeEffectView.userInteractionEnabled = YES;
    self.chromeEffectView.clipsToBounds = YES;
    [self.chromeContainerView addSubview:self.chromeEffectView];

    self.focusGlowView = [[UIView alloc] initWithFrame:CGRectZero];
    self.focusGlowView.backgroundColor = UIColor.clearColor;
    self.focusGlowView.userInteractionEnabled = NO;
    self.focusGlowView.hidden = YES;
    self.focusGlowView.layer.shadowColor = [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0].CGColor;
    self.focusGlowView.layer.shadowOffset = CGSizeZero;
    self.focusGlowView.layer.shadowOpacity = 0.0;
    self.focusGlowView.layer.shadowRadius = 18.0;
    [self.chromeContainerView insertSubview:self.focusGlowView belowSubview:self.chromeEffectView];

    self.focusHighlightView = [[UIView alloc] initWithFrame:CGRectZero];
    self.focusHighlightView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    self.focusHighlightView.layer.cornerRadius = 22.0;
    self.focusHighlightView.alpha = 0.0;
    self.focusHighlightView.hidden = YES;
    self.focusHighlightView.userInteractionEnabled = NO;
    [self.chromeEffectView.contentView addSubview:self.focusHighlightView];

    _exitImageView = [self newIconViewWithSymbolName:@"power" fallbackImageNamed:nil];
    _backImageView = [self newIconViewWithSymbolName:@"chevron.backward" fallbackImageNamed:@"go-back-left-arrow"];
    _refreshImageView = [self newIconViewWithSymbolName:@"arrow.clockwise" fallbackImageNamed:@"refresh-button"];
    _forwardImageView = [self newIconViewWithSymbolName:@"chevron.forward" fallbackImageNamed:@"right-arrow-forward"];
    _homeImageView = [self newIconViewWithSymbolName:@"house" fallbackImageNamed:@"house-outline"];
    _tabsImageView = [self newIconViewWithSymbolName:@"square.on.square" fallbackImageNamed:@"multi-tab"];
    _settingsImageView = [self newIconViewWithSymbolName:@"gearshape" fallbackImageNamed:nil];
    _privacyImageView = [self newIconViewWithSymbolName:@"shield" fallbackImageNamed:nil];
    _readingImageView = [self newIconViewWithSymbolName:@"textformat.size" fallbackImageNamed:nil];
    _bookmarksImageView = [self newIconViewWithSymbolName:@"star" fallbackImageNamed:nil];
    _fullscreenImageView = [self newIconViewWithSymbolName:@"arrow.up.left.and.arrow.down.right" fallbackImageNamed:@"resize-arrows"];
    _menuImageView = [self newIconViewWithSymbolName:@"ellipsis.circle" fallbackImageNamed:@"menu-2"];

    _exitSeparatorView = [[UIView alloc] initWithFrame:CGRectZero];
    _exitSeparatorView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    _exitSeparatorView.layer.cornerRadius = kTopBarSeparatorWidth / 2.0;
    _exitSeparatorView.userInteractionEnabled = NO;
    [self.chromeEffectView.contentView addSubview:_exitSeparatorView];

    _URLLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _URLLabel.text = @"tvOS Browser";
    _URLLabel.textAlignment = NSTextAlignmentCenter;
    _URLLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    _URLLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _URLLabel.adjustsFontSizeToFitWidth = NO;
    _URLLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.chromeEffectView.contentView addSubview:_URLLabel];

    _loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingSpinner.color = [UIColor colorWithWhite:1.0 alpha:0.92];
    _loadingSpinner.tintColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _loadingSpinner.hidesWhenStopped = YES;
    [self.chromeEffectView.contentView addSubview:_loadingSpinner];

    NSArray<UIImageView *> *iconViews = @[
        _exitImageView,
        _backImageView,
        _refreshImageView,
        _forwardImageView,
        _homeImageView,
        _tabsImageView,
        _settingsImageView,
        _privacyImageView,
        _readingImageView,
        _bookmarksImageView,
        _fullscreenImageView,
        _menuImageView
    ];
    for (UIImageView *imageView in iconViews) {
        [self.chromeEffectView.contentView addSubview:imageView];
    }

    _exitFocusButton = [self newFocusButtonForAction:BrowserTopBarActionExit accessibilityLabel:@"Quit Browser"];
    _backFocusButton = [self newFocusButtonForAction:BrowserTopBarActionBack accessibilityLabel:@"Back"];
    _refreshFocusButton = [self newFocusButtonForAction:BrowserTopBarActionRefresh accessibilityLabel:@"Reload"];
    _forwardFocusButton = [self newFocusButtonForAction:BrowserTopBarActionForward accessibilityLabel:@"Forward"];
    _homeFocusButton = [self newFocusButtonForAction:BrowserTopBarActionHome accessibilityLabel:@"Home"];
    _tabsFocusButton = [self newFocusButtonForAction:BrowserTopBarActionTabs accessibilityLabel:@"Tabs"];
    _URLFocusButton = [self newFocusButtonForAction:BrowserTopBarActionURL accessibilityLabel:@"Enter URL or Search"];
    _settingsFocusButton = [self newFocusButtonForAction:BrowserTopBarActionSettings accessibilityLabel:@"Settings"];
    _privacyFocusButton = [self newFocusButtonForAction:BrowserTopBarActionPrivacy accessibilityLabel:@"Privacy and Blocking"];
    _readingFocusButton = [self newFocusButtonForAction:BrowserTopBarActionReading accessibilityLabel:@"Reading and Text Size"];
    _bookmarksFocusButton = [self newFocusButtonForAction:BrowserTopBarActionBookmarks accessibilityLabel:@"Favorites and History"];
    _fullscreenFocusButton = [self newFocusButtonForAction:BrowserTopBarActionFullscreen accessibilityLabel:@"Top Navigation Visibility"];
    _menuFocusButton = [self newFocusButtonForAction:BrowserTopBarActionMenu accessibilityLabel:@"Menu"];
    _focusButtons = @[
        _exitFocusButton,
        _backFocusButton,
        _refreshFocusButton,
        _forwardFocusButton,
        _homeFocusButton,
        _tabsFocusButton,
        _URLFocusButton,
        _bookmarksFocusButton,
        _readingFocusButton,
        _privacyFocusButton,
        _settingsFocusButton,
        _menuFocusButton
    ];
    for (BrowserTopBarFocusButton *button in _focusButtons) {
        [self.chromeEffectView.contentView addSubview:button];
    }

    [self applyVisualStyle];
    [self setFocusModeActive:NO];
}

// One symbol family at one weight and one point size, so the row reads as a
// set instead of eight separately drawn PNGs. The bundled art stays as the
// fallback for anything the running tvOS does not have a symbol for.
- (UIImageView *)newIconViewWithSymbolName:(NSString *)symbolName
                        fallbackImageNamed:(NSString *)fallbackImageName {
    UIImage *image = nil;
    if (symbolName.length > 0) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:kTopBarSymbolPointSize
                                                            weight:UIImageSymbolWeightSemibold];
        image = [UIImage systemImageNamed:symbolName withConfiguration:configuration];
    }

    BOOL usingSymbol = image != nil;
    if (image == nil && fallbackImageName.length > 0) {
        image = [UIImage imageNamed:fallbackImageName];
    }

    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.userInteractionEnabled = NO;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    if (usingSymbol) {
        imageView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        imageView.alpha = 1.0;
    } else {
        imageView.alpha = 0.95;
    }
    return imageView;
}

- (BrowserTopBarFocusButton *)newFocusButtonForAction:(BrowserTopBarAction)action
                                   accessibilityLabel:(NSString *)accessibilityLabel {
    BrowserTopBarFocusButton *button = [BrowserTopBarFocusButton buttonWithType:UIButtonTypeCustom];
    button.topBarAction = action;
    button.backgroundColor = UIColor.clearColor;
    button.hidden = YES;
    button.enabled = NO;
    button.accessibilityLabel = accessibilityLabel;
    button.accessibilityTraits = UIAccessibilityTraitButton;
    [button addTarget:self action:@selector(handleFocusButtonPrimaryAction:) forControlEvents:UIControlEventPrimaryActionTriggered];
    return button;
}

- (void)applyVisualStyle {
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        self.effect = nil;

        UIGlassEffect *glassEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        glassEffect.interactive = YES;
        glassEffect.tintColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        self.chromeEffectView.effect = glassEffect;
        self.chromeEffectView.alpha = 1.0;
        self.chromeContainerView.layer.shadowOpacity = 0.0;
        self.chromeContainerView.layer.shadowOffset = CGSizeZero;
        self.chromeContainerView.layer.shadowRadius = 0.0;
        self.chromeContainerView.layer.borderWidth = 0.0;
        return;
    }
#endif

    self.effect = nil;
    self.chromeEffectView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.chromeEffectView.alpha = 0.98;
    self.chromeContainerView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.chromeContainerView.layer.shadowOpacity = 0.28;
    self.chromeContainerView.layer.shadowOffset = CGSizeMake(0.0, 12.0);
    self.chromeContainerView.layer.shadowRadius = 22.0;
    self.chromeContainerView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    self.chromeContainerView.layer.borderWidth = 1.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    self.contentView.frame = self.bounds;

    CGFloat width = MIN(CGRectGetWidth(self.bounds) - (kTopBarHorizontalInset * 2.0), kTopBarMaxWidth);
    width = MAX(width, 860.0);
    CGFloat originX = floor((CGRectGetWidth(self.bounds) - width) / 2.0);
    CGRect chromeFrame = CGRectMake(originX, kTopBarVerticalInset, width, kTopBarHeight);

    self.chromeContainerView.frame = chromeFrame;
    self.chromeContainerView.layer.cornerRadius = chromeFrame.size.height / 2.0;
    self.chromeContainerView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.chromeContainerView.bounds
                                                                           cornerRadius:self.chromeContainerView.layer.cornerRadius].CGPath;

    self.chromeEffectView.frame = self.chromeContainerView.bounds;
    self.chromeEffectView.layer.cornerRadius = self.chromeContainerView.layer.cornerRadius;

    CGFloat iconY = floor((CGRectGetHeight(chromeFrame) - kTopBarIconSize) / 2.0);
    CGFloat leftX = kTopBarLeadingPadding;

    for (BrowserTopBarFocusButton *button in self.focusButtons) {
        UIView *icon = [self iconViewForAction:button.topBarAction];
        icon.transform = CGAffineTransformIdentity;
    }

    // Quit sits at the far left, fenced off by a hairline so it is never
    // mistaken for part of the navigation group next to it.
    self.exitImageView.frame = CGRectMake(leftX, iconY, kTopBarIconSize, kTopBarIconSize);
    leftX = CGRectGetMaxX(self.exitImageView.frame) + kTopBarSeparatorSpacing;
    self.exitSeparatorView.frame = CGRectMake(leftX,
                                              floor((CGRectGetHeight(chromeFrame) - kTopBarSeparatorHeight) / 2.0),
                                              kTopBarSeparatorWidth,
                                              kTopBarSeparatorHeight);
    leftX = CGRectGetMaxX(self.exitSeparatorView.frame) + kTopBarSeparatorSpacing;

    NSArray<UIImageView *> *leftIcons = @[
        self.backImageView,
        self.refreshImageView,
        self.forwardImageView,
        self.homeImageView,
        self.tabsImageView
    ];
    for (UIImageView *imageView in leftIcons) {
        imageView.frame = CGRectMake(leftX, iconY, kTopBarIconSize, kTopBarIconSize);
        leftX += kTopBarIconSize + kTopBarIconSpacing;
    }

    // Reading left to right: star, text size, shield, gear, then the menu at
    // the far right. The top navigation toggle is gone from the bar; it lives
    // in the menu, and five icons sit more calmly than six.
    self.fullscreenImageView.hidden = YES;
    self.fullscreenFocusButton.hidden = YES;

    CGFloat rightX = CGRectGetWidth(chromeFrame) - kTopBarTrailingPadding - kTopBarIconSize;
    self.menuImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.menuImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.settingsImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.settingsImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.privacyImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.privacyImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.readingImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.readingImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.bookmarksImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    self.fullscreenImageView.frame = CGRectZero;

    CGFloat spinnerSide = 34.0;
    rightX = CGRectGetMinX(self.bookmarksImageView.frame) - kTopBarSpinnerSpacing - spinnerSide;
    self.loadingSpinner.frame = CGRectMake(rightX,
                                           floor((CGRectGetHeight(chromeFrame) - spinnerSide) / 2.0),
                                           spinnerSide,
                                           spinnerSide);

    CGFloat labelOriginX = CGRectGetMaxX(self.tabsImageView.frame) + kTopBarLabelSpacing;
    CGFloat labelTrailingX = CGRectGetMinX(self.loadingSpinner.frame) - kTopBarLabelSpacing;
    CGFloat labelWidth = MAX(160.0, labelTrailingX - labelOriginX);
    self.URLLabel.frame = CGRectMake(labelOriginX,
                                     0.0,
                                     labelWidth,
                                     CGRectGetHeight(chromeFrame));

    self.exitFocusButton.frame = [self focusFrameForIconView:self.exitImageView];
    self.backFocusButton.frame = [self focusFrameForIconView:self.backImageView];
    self.refreshFocusButton.frame = [self focusFrameForIconView:self.refreshImageView];
    self.forwardFocusButton.frame = [self focusFrameForIconView:self.forwardImageView];
    self.homeFocusButton.frame = [self focusFrameForIconView:self.homeImageView];
    self.tabsFocusButton.frame = [self focusFrameForIconView:self.tabsImageView];
    self.URLFocusButton.frame = [self focusFrameForLabel:self.URLLabel];
    self.settingsFocusButton.frame = [self focusFrameForIconView:self.settingsImageView];
    self.privacyFocusButton.frame = [self focusFrameForIconView:self.privacyImageView];
    self.readingFocusButton.frame = [self focusFrameForIconView:self.readingImageView];
    self.bookmarksFocusButton.frame = [self focusFrameForIconView:self.bookmarksImageView];
    self.menuFocusButton.frame = [self focusFrameForMenuIconView:self.menuImageView];

    if (!self.focusModeActive) {
        [self resetFocusVisualState];
        return;
    }

    [self updateHighlightFrameForCurrentFocus];
    [self applyFocusAppearanceToButton:self.lastFocusedButton];
}

- (CGRect)interactiveFrameForView:(UIView *)view {
    return [self convertRect:view.bounds fromView:view];
}

- (CGFloat)screenCenterXForAction:(BrowserTopBarAction)action {
    UIView *icon = [self iconViewForAction:action];
    if (icon == nil) {
        return 0.0;
    }
    CGRect frameInWindow = [icon convertRect:icon.bounds toView:nil];
    return CGRectGetMidX(frameInWindow);
}

- (CGRect)uniformFocusFrameForRect:(CGRect)frame horizontalInset:(CGFloat)horizontalInset {
    CGFloat normalizedHeight = MIN(kTopBarUniformFocusHeight, CGRectGetHeight(self.chromeEffectView.bounds));
    CGFloat originY = floor((CGRectGetHeight(self.chromeEffectView.bounds) - normalizedHeight) / 2.0);
    frame.origin.x -= horizontalInset;
    frame.size.width += horizontalInset * 2.0;
    frame.origin.y = originY;
    frame.size.height = normalizedHeight;
    return CGRectIntegral(frame);
}

- (CGRect)focusFrameForIconView:(UIView *)view {
    CGRect frame = view.frame;
    return [self uniformFocusFrameForRect:frame horizontalInset:12.0];
}

- (CGRect)focusFrameForMenuIconView:(UIView *)view {
    return [self focusFrameForIconView:view];
}

- (CGRect)focusFrameForLabel:(UIView *)view {
    CGRect frame = view.frame;
    return [self uniformFocusFrameForRect:frame horizontalInset:16.0];
}

- (CGRect)highlightFrameForButton:(BrowserTopBarFocusButton *)button {
    CGRect frame = button.frame;
    frame = CGRectInset(frame, kTopBarFocusHighlightInset, 0.0);
    return CGRectIntegral(frame);
}

- (CGRect)glowFrameForButton:(BrowserTopBarFocusButton *)button {
    CGRect frame = [self highlightFrameForButton:button];
    return CGRectInset(frame, -4.0, -4.0);
}

- (void)ensureFocusGlowViewAttached {
    if (self.focusGlowView.superview == self.chromeContainerView) {
        return;
    }
    [self.focusGlowView removeFromSuperview];
    [self.chromeContainerView insertSubview:self.focusGlowView belowSubview:self.chromeEffectView];
}

// The pill is drawn behind the icons, so it is inserted below the first of
// them rather than on top.
- (void)ensureHighlightBelowIcons {
    UIView *container = self.chromeEffectView.contentView;
    if (self.focusHighlightView.superview != container) {
        [container addSubview:self.focusHighlightView];
    }
    [container insertSubview:self.focusHighlightView atIndex:0];
}

- (UIView *)iconViewForAction:(BrowserTopBarAction)action {
    switch (action) {
        case BrowserTopBarActionExit: return self.exitImageView;
        case BrowserTopBarActionBack: return self.backImageView;
        case BrowserTopBarActionRefresh: return self.refreshImageView;
        case BrowserTopBarActionForward: return self.forwardImageView;
        case BrowserTopBarActionHome: return self.homeImageView;
        case BrowserTopBarActionTabs: return self.tabsImageView;
        case BrowserTopBarActionReading: return self.readingImageView;
        case BrowserTopBarActionBookmarks: return self.bookmarksImageView;
        case BrowserTopBarActionPrivacy: return self.privacyImageView;
        case BrowserTopBarActionSettings: return self.settingsImageView;
        case BrowserTopBarActionFullscreen: return self.fullscreenImageView;
        case BrowserTopBarActionMenu: return self.menuImageView;
        case BrowserTopBarActionURL: return self.URLLabel;
    }
    return nil;
}

- (void)applyFocusAppearanceToButton:(BrowserTopBarFocusButton *)focusedButton {
    UIColor *restingTint = [UIColor colorWithWhite:1.0 alpha:0.92];
    UIColor *focusedTint = [UIColor colorWithRed:0.07 green:0.09 blue:0.10 alpha:1.0];
    UIView *focusedIcon = focusedButton != nil ? [self iconViewForAction:focusedButton.topBarAction] : nil;

    for (BrowserTopBarFocusButton *button in self.focusButtons) {
        UIView *icon = [self iconViewForAction:button.topBarAction];
        BOOL isFocused = (icon != nil && icon == focusedIcon);
        CGFloat scale = isFocused ? 1.12 : 1.0;
        icon.transform = CGAffineTransformMakeScale(scale, scale);
        if ([icon isKindOfClass:[UILabel class]]) {
            ((UILabel *)icon).textColor = isFocused ? focusedTint : [UIColor colorWithWhite:1.0 alpha:0.72];
        } else {
            icon.tintColor = isFocused ? focusedTint : restingTint;
        }
    }
}

- (void)resetFocusVisualState {
    [self.focusGlowView.layer removeAllAnimations];
    [self.focusHighlightView.layer removeAllAnimations];
    self.focusGlowView.hidden = YES;
    self.focusGlowView.alpha = 0.0;
    self.focusGlowView.frame = CGRectZero;
    self.focusGlowView.layer.shadowOpacity = 0.0;
    self.focusGlowView.layer.shadowPath = nil;

    self.focusHighlightView.hidden = YES;
    self.focusHighlightView.alpha = 0.0;
    self.focusHighlightView.frame = CGRectZero;
    [self applyFocusAppearanceToButton:nil];

    [self.focusGlowView removeFromSuperview];
    [self.layer setNeedsDisplay];
}

- (void)updateHighlightFrameForCurrentFocus {
    if (!self.focusModeActive || self.lastFocusedButton == nil || !self.lastFocusedButton.focused) {
        return;
    }
    [self showFocusDecorationForButton:self.lastFocusedButton];
}

- (void)showFocusDecorationForButton:(BrowserTopBarFocusButton *)button {
    [self ensureFocusGlowViewAttached];
    CGRect glowFrame = [self glowFrameForButton:button];
    self.focusGlowView.hidden = NO;
    self.focusGlowView.alpha = 1.0;
    self.focusGlowView.frame = glowFrame;
    self.focusGlowView.layer.cornerRadius = MIN(CGRectGetHeight(glowFrame) / 2.0, 24.0);
    self.focusGlowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.focusGlowView.bounds
                                                                     cornerRadius:self.focusGlowView.layer.cornerRadius].CGPath;
    self.focusGlowView.layer.shadowOpacity = 0.55;

    CGRect pillFrame = [self highlightFrameForButton:button];
    [self ensureHighlightBelowIcons];
    self.focusHighlightView.hidden = NO;
    self.focusHighlightView.alpha = 1.0;
    self.focusHighlightView.frame = pillFrame;
    self.focusHighlightView.layer.cornerRadius = MIN(CGRectGetHeight(pillFrame) / 2.0, 26.0);
    [self applyFocusAppearanceToButton:button];
}

- (void)setFocusModeActive:(BOOL)focusModeActive {
    if (_focusModeActive == focusModeActive) {
        return;
    }

    _focusModeActive = focusModeActive;
    for (BrowserTopBarFocusButton *button in self.focusButtons) {
        button.hidden = !focusModeActive;
        button.enabled = focusModeActive;
    }

    if (!focusModeActive) {
        self.lastFocusedButton = nil;
        [self resetFocusVisualState];
    } else {
        [self setNeedsLayout];
    }
}

- (UIView *)preferredFocusItem {
    if (!self.focusModeActive) {
        return nil;
    }
    return self.lastFocusedButton ?: self.URLFocusButton;
}

- (void)handleFocusButtonPrimaryAction:(BrowserTopBarFocusButton *)button {
    id<BrowserTopBarViewDelegate> delegate = self.delegate;
    if (delegate == nil) {
        return;
    }
    [delegate browserTopBarView:self didTriggerAction:button.topBarAction];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];

    BrowserTopBarFocusButton *nextFocusedButton = [context.nextFocusedView isKindOfClass:[BrowserTopBarFocusButton class]] ? (BrowserTopBarFocusButton *)context.nextFocusedView : nil;
    BrowserTopBarFocusButton *previousFocusedButton = [context.previouslyFocusedView isKindOfClass:[BrowserTopBarFocusButton class]] ? (BrowserTopBarFocusButton *)context.previouslyFocusedView : nil;

    if (nextFocusedButton != nil) {
        self.lastFocusedButton = nextFocusedButton;
    }

    [coordinator addCoordinatedAnimations:^{
        if (!self.focusModeActive || nextFocusedButton == nil) {
            self.focusGlowView.alpha = 0.0;
            self.focusGlowView.layer.shadowOpacity = 0.0;
            self.focusHighlightView.alpha = 0.0;
            return;
        }

        [self showFocusDecorationForButton:nextFocusedButton];
        previousFocusedButton.alpha = 1.0;
        nextFocusedButton.alpha = 1.0;
    } completion:^{
        if (!self.focusModeActive || nextFocusedButton == nil) {
            [self resetFocusVisualState];
        }
    }];
}

@end
```

## `BrowserRemoteInputController.h`  (70줄)

```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, BrowserPageActivationSource) {
    BrowserPageActivationSourceTap = 0,
    BrowserPageActivationSourceClick,
    BrowserPageActivationSourceLongClick,
};

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserRemoteInputControllerHost <NSObject>

- (nullable UIScrollView *)browserRemoteInputControllerActiveScrollView;
- (nullable UIViewController *)browserRemoteInputControllerPresentedViewController;
/// True whenever the remote drives focus rather than the pointer: the top
/// bar, and the probe workbench. The pointer and the focus engine cannot
/// both own the direction pad.
- (BOOL)browserRemoteInputControllerFocusNavigationActive;
- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus;
- (void)browserRemoteInputControllerActivateTopBarFocus;
- (void)browserRemoteInputControllerDeactivateTopBarFocus;
- (BOOL)browserRemoteInputControllerTabOverviewVisible;
- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point;
- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point;
- (void)browserRemoteInputControllerDismissTabOverview;
- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction;
- (void)browserRemoteInputControllerHandlePrimaryActionWithSource:(BrowserPageActivationSource)source;
- (void)browserRemoteInputControllerHandleMenuPress;
- (void)browserRemoteInputControllerHandlePlayPausePress;
- (void)browserRemoteInputControllerHandleAdvancedMenuPress;
- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point;
- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled;
- (void)browserRemoteInputControllerPersistSession;
- (BOOL)browserRemoteInputControllerScrollActiveContainerByDelta:(CGPoint)delta atCursorPoint:(CGPoint)cursorPoint;
- (BOOL)browserRemoteInputControllerJSScrollFallbackEnabled;
- (BOOL)browserRemoteInputControllerDpadScrollEnabled;
- (BOOL)browserRemoteInputControllerEdgeAutoScrollEnabled;
- (BOOL)browserRemoteInputControllerTapToClickEnabled;
- (void)browserRemoteInputControllerGoBack;
- (void)browserRemoteInputControllerGoForward;

@end

@interface BrowserRemoteInputController : NSObject

@property (nonatomic, readonly) UIImageView *cursorView;
@property (nonatomic, readonly) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readonly) UITapGestureRecognizer *playPauseDoubleTapRecognizer;
@property (nonatomic, readonly, getter=isCursorModeEnabled) BOOL cursorModeEnabled;

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)handleGlobalSelectPressEndedNotification;
- (void)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (void)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)handleTouchesEnded;
- (void)handleTouchesCancelled;
- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled;
- (void)refreshInteractionState;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserRemoteInputController.m`  (1030줄)

```objc
#import "BrowserRemoteInputController.h"

// The JavaScript scroll fallback runs synchronously (it pumps the run loop until
// WebKit answers), so it must never be driven at display-link rate. Deltas are
// accumulated and flushed at most this often.
static const CFTimeInterval kBrowserJSScrollMinimumInterval = 0.05;
static const CFTimeInterval kBrowserSelectLongClickThreshold = 0.5;

static UIImage *BrowserDefaultCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Cursor"];
    });
    return image;
}

static UIImage *BrowserPointerCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Pointer"];
    });
    return image;
}

static NSString *BrowserPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

@interface BrowserRemoteInputController ()

@property (nonatomic, weak) id<BrowserRemoteInputControllerHost> host;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, readwrite) UIImageView *cursorView;
@property (nonatomic, readwrite) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readwrite) UITapGestureRecognizer *playPauseDoubleTapRecognizer;
@property (nonatomic, readwrite, getter=isCursorModeEnabled) BOOL cursorModeEnabled;
@property (nonatomic) CGPoint lastTouchLocation;
@property (nonatomic) CADisplayLink *manualScrollDisplayLink;
@property (nonatomic) CGPoint manualScrollVelocity;
@property (nonatomic) CFTimeInterval manualScrollLastTimestamp;
@property (nonatomic) CFTimeInterval manualScrollLastMovementTimestamp;
@property (nonatomic) CFTimeInterval lastDirectSelectPressTimestamp;
@property (nonatomic) CFTimeInterval lastSelectPressTimestamp;
@property (nonatomic) BOOL awaitingSecondSelectPress;

@property (nonatomic) BOOL trackingTouchForTap;
@property (nonatomic) CFTimeInterval currentTouchStartTime;
@property (nonatomic) CGPoint currentTouchStartCursorOrigin;
@property (nonatomic) CGFloat currentTouchMaxCursorDistance;
@property (nonatomic) BOOL selectPressDuringCurrentTouch;
@property (nonatomic) CFTimeInterval lastSelectPressActivityTimestamp;
@property (nonatomic) CFTimeInterval selectPressStartTime;
@property (nonatomic, nullable) NSTimer *cursorIdleTimer;
@property (nonatomic) CFTimeInterval lastCursorActivityTimestamp;

@property (nonatomic, nullable) CADisplayLink *dpadPageScrollDisplayLink;
@property (nonatomic) CFTimeInterval dpadPageScrollStartTime;
@property (nonatomic) CFTimeInterval dpadPageScrollDuration;
@property (nonatomic) CGFloat dpadPageScrollTargetTotalY;
@property (nonatomic) CGFloat dpadPageScrollAppliedY;

@property (nonatomic, nullable) NSTimer *dpadHoldTimer;
@property (nonatomic, nullable) CADisplayLink *dpadContinuousScrollDisplayLink;
@property (nonatomic) CFTimeInterval dpadContinuousLastTimestamp;
@property (nonatomic) NSInteger activeDpadDirection;
@property (nonatomic) BOOL dpadContinuousScrollActive;

@property (nonatomic, nullable) CADisplayLink *edgeAutoScrollDisplayLink;
@property (nonatomic) CFTimeInterval edgeAutoScrollLastTimestamp;
@property (nonatomic) CGFloat edgeAutoScrollVelocityY;

@property (nonatomic) BOOL jsScrollInFlight;
@property (nonatomic) BOOL lastJSScrollDidMove;
@property (nonatomic) CFTimeInterval lastJSScrollTimestamp;
@property (nonatomic) CGPoint pendingJSScrollDelta;

@end

@implementation BrowserRemoteInputController

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView {
    self = [super init];
    if (self) {
        _host = host;
        _rootView = rootView;
        _lastTouchLocation = CGPointMake(-1, -1);
        _cursorModeEnabled = YES;
        _lastJSScrollDidMove = YES;
        _pendingJSScrollDelta = CGPointZero;

        _cursorView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
        _cursorView.center = CGPointMake(CGRectGetMidX([UIScreen mainScreen].bounds), CGRectGetMidY([UIScreen mainScreen].bounds));
        _cursorView.image = BrowserDefaultCursor();

        _playPauseDoubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlayPauseDoubleTap:)];
        _playPauseDoubleTapRecognizer.numberOfTapsRequired = 2;
        _playPauseDoubleTapRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        [rootView addGestureRecognizer:_playPauseDoubleTapRecognizer];

        _manualScrollPanRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleManualScrollPan:)];
        _manualScrollPanRecognizer.allowedTouchTypes = @[ @(UITouchTypeIndirect) ];
        _manualScrollPanRecognizer.cancelsTouchesInView = NO;
        _manualScrollPanRecognizer.enabled = NO;
        [rootView addGestureRecognizer:_manualScrollPanRecognizer];

        [self noteCursorActivity];
    }
    return self;
}

- (void)dealloc {
    [self.cursorIdleTimer invalidate];
    self.cursorIdleTimer = nil;
    [self stopManualScrollInertia];
    [self stopDpadPageScrollAnimation];
    [self stopDpadHoldAndContinuousScroll];
    [self stopEdgeAutoScroll];
}

- (CGFloat)viewportHeight {
    CGFloat height = CGRectGetHeight(self.rootView.bounds);
    if (height <= 0.0) {
        height = CGRectGetHeight([UIScreen mainScreen].bounds);
    }
    return height > 0.0 ? height : 1080.0;
}

- (CGFloat)viewportWidth {
    CGFloat width = CGRectGetWidth(self.rootView.bounds);
    if (width <= 0.0) {
        width = CGRectGetWidth([UIScreen mainScreen].bounds);
    }
    return width > 0.0 ? width : 1920.0;
}

- (BOOL)isCursorInTopBarActivationZone {
    CGFloat screenHeight = [self viewportHeight];
    return self.cursorView.center.y < (screenHeight * 0.12);
}

- (BOOL)canPerformCustomScroll {
    return [self.host browserRemoteInputControllerPresentedViewController] == nil &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerFocusNavigationActive];
}

- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled {
    BOOL wasCursorModeEnabled = self.cursorModeEnabled;
    _cursorModeEnabled = cursorModeEnabled;
    self.lastTouchLocation = CGPointMake(-1, -1);
    self.trackingTouchForTap = NO;
    [self stopManualScrollInertia];
    if (!cursorModeEnabled) {
        [self stopEdgeAutoScroll];
    }
    [self refreshInteractionState];
    if (!wasCursorModeEnabled && cursorModeEnabled) {
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)refreshInteractionState {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    BOOL topBarFocusActive = [self.host browserRemoteInputControllerFocusNavigationActive];
    BOOL tabOverviewVisible = [self.host browserRemoteInputControllerTabOverviewVisible];
    BOOL presentedActive = ([self.host browserRemoteInputControllerPresentedViewController] != nil);

    if (topBarFocusActive || tabOverviewVisible || presentedActive) {
        [self stopEdgeAutoScroll];
        [self stopDpadPageScrollAnimation];
        [self stopDpadHoldAndContinuousScroll];
    } else if (!self.cursorModeEnabled) {
        [self stopEdgeAutoScroll];
    }

    BOOL shouldAllowWebInteraction = !self.cursorModeEnabled &&
        !tabOverviewVisible &&
        !topBarFocusActive;
    scrollView.scrollEnabled = shouldAllowWebInteraction;
    self.manualScrollPanRecognizer.enabled = shouldAllowWebInteraction;
    [self.host browserRemoteInputControllerSetWebInteractionEnabled:shouldAllowWebInteraction];
    self.cursorView.hidden = !self.cursorModeEnabled ||
        tabOverviewVisible ||
        topBarFocusActive ||
        presentedActive;
    if (!self.cursorView.hidden) {
        [self noteCursorActivity];
    }
}

- (BOOL)applyManualScrollDelta:(CGPoint)delta {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    if (scrollView != nil) {
        CGPoint contentOffset = scrollView.contentOffset;
        CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
        CGFloat maxOffsetY = MAX(0.0, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds));
        CGFloat nextOffsetX = MIN(MAX(contentOffset.x + delta.x, 0.0), maxOffsetX);
        CGFloat nextOffsetY = MIN(MAX(contentOffset.y + delta.y, 0.0), maxOffsetY);
        CGPoint nextOffset = CGPointMake(nextOffsetX, nextOffsetY);
        if (!CGPointEqualToPoint(contentOffset, nextOffset)) {
            [scrollView setContentOffset:nextOffset animated:NO];
            return YES;
        }
    }

    if (![self.host browserRemoteInputControllerJSScrollFallbackEnabled]) {
        return NO;
    }

    return [self enqueueJavaScriptScrollDelta:delta];
}

// The fallback evaluates JavaScript synchronously, which pumps the run loop.
// Calling it from a CADisplayLink on every frame both stutters badly and risks
// re-entering the link callback, so deltas are accumulated and flushed on a
// fixed interval. While throttled the last known result is reported so the
// in-flight scroll animations do not treat the pause as "hit the end".
- (BOOL)enqueueJavaScriptScrollDelta:(CGPoint)delta {
    self.pendingJSScrollDelta = CGPointMake(self.pendingJSScrollDelta.x + delta.x,
                                            self.pendingJSScrollDelta.y + delta.y);

    if (self.jsScrollInFlight) {
        return self.lastJSScrollDidMove;
    }

    if ((CACurrentMediaTime() - self.lastJSScrollTimestamp) < kBrowserJSScrollMinimumInterval) {
        return self.lastJSScrollDidMove;
    }

    CGPoint flushedDelta = self.pendingJSScrollDelta;
    self.pendingJSScrollDelta = CGPointZero;
    if (fabs(flushedDelta.x) < 0.01 && fabs(flushedDelta.y) < 0.01) {
        return self.lastJSScrollDidMove;
    }

    self.jsScrollInFlight = YES;
    BOOL didMove = [self.host browserRemoteInputControllerScrollActiveContainerByDelta:flushedDelta
                                                                         atCursorPoint:self.cursorView.frame.origin];
    self.jsScrollInFlight = NO;
    self.lastJSScrollTimestamp = CACurrentMediaTime();
    self.lastJSScrollDidMove = didMove;
    return didMove;
}

// Applies whatever is left in the accumulator regardless of the throttle, so a
// finishing animation does not drop its last few points of travel.
- (void)flushPendingJavaScriptScroll {
    CGPoint pendingDelta = self.pendingJSScrollDelta;
    self.pendingJSScrollDelta = CGPointZero;

    if (self.jsScrollInFlight ||
        (fabs(pendingDelta.x) < 0.01 && fabs(pendingDelta.y) < 0.01) ||
        ![self.host browserRemoteInputControllerJSScrollFallbackEnabled]) {
        return;
    }

    self.jsScrollInFlight = YES;
    self.lastJSScrollDidMove = [self.host browserRemoteInputControllerScrollActiveContainerByDelta:pendingDelta
                                                                                     atCursorPoint:self.cursorView.frame.origin];
    self.jsScrollInFlight = NO;
    self.lastJSScrollTimestamp = CACurrentMediaTime();
}

- (void)resetPendingJavaScriptScroll {
    self.pendingJSScrollDelta = CGPointZero;
    self.lastJSScrollDidMove = YES;
}

- (void)stopManualScrollInertia {
    [self.manualScrollDisplayLink invalidate];
    self.manualScrollDisplayLink = nil;
    self.manualScrollVelocity = CGPointZero;
    self.manualScrollLastTimestamp = 0;
    self.manualScrollLastMovementTimestamp = 0;
    [self resetPendingJavaScriptScroll];
}

- (void)startManualScrollInertiaWithVelocity:(CGPoint)velocity {
    [self stopEdgeAutoScroll];
    [self stopDpadPageScrollAnimation];
    [self stopManualScrollInertia];
    if (fabs(velocity.x) < 25.0 && fabs(velocity.y) < 25.0) {
        return;
    }

    self.manualScrollVelocity = velocity;
    self.manualScrollLastTimestamp = 0;
    self.manualScrollDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleManualScrollDisplayLink:)];
    [self.manualScrollDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)handleManualScrollDisplayLink:(CADisplayLink *)displayLink {
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerFocusNavigationActive]) {
        [self stopManualScrollInertia];
        return;
    }

    if (self.manualScrollLastTimestamp <= 0) {
        self.manualScrollLastTimestamp = displayLink.timestamp;
        return;
    }

    CFTimeInterval deltaTime = displayLink.timestamp - self.manualScrollLastTimestamp;
    self.manualScrollLastTimestamp = displayLink.timestamp;

    CGPoint step = CGPointMake(self.manualScrollVelocity.x * deltaTime, self.manualScrollVelocity.y * deltaTime);
    BOOL didMove = [self applyManualScrollDelta:step];

    CGFloat decay = pow(0.92, deltaTime * 60.0);
    self.manualScrollVelocity = CGPointMake(self.manualScrollVelocity.x * decay, self.manualScrollVelocity.y * decay);

    if (!didMove ||
        (fabs(self.manualScrollVelocity.x) < 10.0 && fabs(self.manualScrollVelocity.y) < 10.0)) {
        [self stopManualScrollInertia];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

#pragma mark - D-Pad Page Scroll & Hold Scroll

- (void)stopDpadPageScrollAnimation {
    [self.dpadPageScrollDisplayLink invalidate];
    self.dpadPageScrollDisplayLink = nil;
    self.dpadPageScrollStartTime = 0;
    self.dpadPageScrollDuration = 0;
    self.dpadPageScrollTargetTotalY = 0;
    self.dpadPageScrollAppliedY = 0;
    [self resetPendingJavaScriptScroll];
}

- (void)startDpadPageScrollWithDeltaY:(CGFloat)deltaY {
    [self stopManualScrollInertia];
    [self stopEdgeAutoScroll];
    [self stopDpadPageScrollAnimation];

    self.dpadPageScrollDuration = 0.25;
    self.dpadPageScrollTargetTotalY = deltaY;
    self.dpadPageScrollAppliedY = 0.0;
    self.dpadPageScrollStartTime = 0.0;
    self.dpadPageScrollDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDpadPageScrollDisplayLink:)];
    [self.dpadPageScrollDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)handleDpadPageScrollDisplayLink:(CADisplayLink *)displayLink {
    if (![self canPerformCustomScroll]) {
        [self stopDpadPageScrollAnimation];
        return;
    }

    if (self.dpadPageScrollStartTime <= 0.0) {
        self.dpadPageScrollStartTime = displayLink.timestamp;
    }

    CFTimeInterval elapsed = displayLink.timestamp - self.dpadPageScrollStartTime;
    CGFloat progress = (self.dpadPageScrollDuration > 0.0) ? MIN(1.0, MAX(0.0, elapsed / self.dpadPageScrollDuration)) : 1.0;
    CGFloat inv = 1.0 - progress;
    CGFloat easeOutProgress = 1.0 - (inv * inv * inv);

    CGFloat desiredAppliedY = self.dpadPageScrollTargetTotalY * easeOutProgress;
    CGFloat stepY = desiredAppliedY - self.dpadPageScrollAppliedY;
    self.dpadPageScrollAppliedY = desiredAppliedY;

    if (fabs(stepY) >= 0.1) {
        BOOL moved = [self applyManualScrollDelta:CGPointMake(0.0, stepY)];
        if (!moved && progress > 0.15) {
            [self stopDpadPageScrollAnimation];
            [self.host browserRemoteInputControllerPersistSession];
            return;
        }
    }

    if (progress >= 1.0) {
        [self flushPendingJavaScriptScroll];
        [self stopDpadPageScrollAnimation];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)stopDpadHoldAndContinuousScroll {
    [self.dpadHoldTimer invalidate];
    self.dpadHoldTimer = nil;
    [self.dpadContinuousScrollDisplayLink invalidate];
    self.dpadContinuousScrollDisplayLink = nil;
    self.dpadContinuousLastTimestamp = 0.0;
    BOOL wasActive = self.dpadContinuousScrollActive;
    self.dpadContinuousScrollActive = NO;
    self.activeDpadDirection = 0;
    [self resetPendingJavaScriptScroll];
    if (wasActive) {
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)handleDpadHoldTimerFired:(__unused NSTimer *)timer {
    self.dpadHoldTimer = nil;
    if (self.activeDpadDirection == 0 || ![self canPerformCustomScroll]) {
        [self stopDpadHoldAndContinuousScroll];
        return;
    }

    [self stopManualScrollInertia];
    [self stopEdgeAutoScroll];
    [self stopDpadPageScrollAnimation];

    self.dpadContinuousScrollActive = YES;
    self.dpadContinuousLastTimestamp = 0.0;
    self.dpadContinuousScrollDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDpadContinuousScrollDisplayLink:)];
    [self.dpadContinuousScrollDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSLog(@"[InputTrace][Scroll] Dpad continuous scroll started direction=%ld", (long)self.activeDpadDirection);
}

- (void)handleDpadContinuousScrollDisplayLink:(CADisplayLink *)displayLink {
    if (self.activeDpadDirection == 0 || ![self canPerformCustomScroll]) {
        [self stopDpadHoldAndContinuousScroll];
        return;
    }

    if (self.dpadContinuousLastTimestamp <= 0.0) {
        self.dpadContinuousLastTimestamp = displayLink.timestamp;
        return;
    }

    CFTimeInterval dt = displayLink.timestamp - self.dpadContinuousLastTimestamp;
    self.dpadContinuousLastTimestamp = displayLink.timestamp;

    CGFloat stepY = (CGFloat)self.activeDpadDirection * 900.0 * dt;
    [self applyManualScrollDelta:CGPointMake(0.0, stepY)];
}

#pragma mark - Edge Auto Scroll

- (void)stopEdgeAutoScroll {
    [self.edgeAutoScrollDisplayLink invalidate];
    self.edgeAutoScrollDisplayLink = nil;
    self.edgeAutoScrollLastTimestamp = 0.0;
    self.edgeAutoScrollVelocityY = 0.0;
    [self resetPendingJavaScriptScroll];
}

- (void)updateEdgeAutoScrollForCursorPosition {
    if (!self.cursorModeEnabled ||
        ![self.host browserRemoteInputControllerEdgeAutoScrollEnabled] ||
        ![self canPerformCustomScroll]) {
        [self stopEdgeAutoScroll];
        return;
    }

    CGFloat screenHeight = [self viewportHeight];
    CGFloat edgeZoneHeight = screenHeight * 0.08;
    if (edgeZoneHeight <= 1.0) {
        [self stopEdgeAutoScroll];
        return;
    }

    CGFloat cursorY = self.cursorView.center.y;
    CGFloat velocityY = 0.0;

    if (cursorY < edgeZoneHeight) {
        CGFloat ratio = (edgeZoneHeight - MAX(0.0, cursorY)) / edgeZoneHeight;
        velocityY = -1200.0 * MIN(1.0, MAX(0.0, ratio));
    } else if (cursorY > (screenHeight - edgeZoneHeight)) {
        CGFloat ratio = (MIN(screenHeight, cursorY) - (screenHeight - edgeZoneHeight)) / edgeZoneHeight;
        velocityY = 1200.0 * MIN(1.0, MAX(0.0, ratio));
    }

    if (fabs(velocityY) < 1.0) {
        [self stopEdgeAutoScroll];
        return;
    }

    [self stopManualScrollInertia];
    self.edgeAutoScrollVelocityY = velocityY;
    if (self.edgeAutoScrollDisplayLink == nil) {
        self.edgeAutoScrollLastTimestamp = 0.0;
        self.edgeAutoScrollDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleEdgeAutoScrollDisplayLink:)];
        [self.edgeAutoScrollDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)handleEdgeAutoScrollDisplayLink:(CADisplayLink *)displayLink {
    if (!self.cursorModeEnabled ||
        ![self.host browserRemoteInputControllerEdgeAutoScrollEnabled] ||
        ![self canPerformCustomScroll] ||
        fabs(self.edgeAutoScrollVelocityY) < 1.0) {
        [self stopEdgeAutoScroll];
        return;
    }

    if (self.edgeAutoScrollLastTimestamp <= 0.0) {
        self.edgeAutoScrollLastTimestamp = displayLink.timestamp;
        return;
    }

    CFTimeInterval dt = displayLink.timestamp - self.edgeAutoScrollLastTimestamp;
    self.edgeAutoScrollLastTimestamp = displayLink.timestamp;

    CGFloat stepY = self.edgeAutoScrollVelocityY * dt;
    [self applyManualScrollDelta:CGPointMake(0.0, stepY)];
}

#pragma mark - Actions & Gestures

// A physical click also produces a touch sequence. The per-touch flag normally
// catches that, but UIKit delivers presses and touches on separate paths and
// does not guarantee their relative order, so a press reported before
// touchesBegan: would have its flag cleared and fire the tap action as well as
// the click. The timestamp closes that window.
static const CFTimeInterval kBrowserCursorIdleHideDelay = 3.0;

- (void)noteCursorActivity {
    self.lastCursorActivityTimestamp = CACurrentMediaTime();

    if (self.cursorView.alpha < 1.0) {
        [self.cursorView.layer removeAllAnimations];
        [UIView animateWithDuration:0.2 animations:^{
            self.cursorView.alpha = 1.0;
        }];
    }

    if (self.cursorIdleTimer == nil) {
        self.cursorIdleTimer = [NSTimer scheduledTimerWithTimeInterval:kBrowserCursorIdleHideDelay
                                                                target:self
                                                              selector:@selector(handleCursorIdleTimerFired:)
                                                              userInfo:nil
                                                               repeats:NO];
    }
}

- (void)handleCursorIdleTimerFired:(__unused NSTimer *)timer {
    self.cursorIdleTimer = nil;

    CFTimeInterval idle = CACurrentMediaTime() - self.lastCursorActivityTimestamp;
    if (idle < kBrowserCursorIdleHideDelay) {
        // Activity arrived while the timer was running; wait out the remainder.
        self.cursorIdleTimer = [NSTimer scheduledTimerWithTimeInterval:(kBrowserCursorIdleHideDelay - idle)
                                                                target:self
                                                              selector:@selector(handleCursorIdleTimerFired:)
                                                              userInfo:nil
                                                               repeats:NO];
        return;
    }

    if (!self.cursorModeEnabled ||
        self.cursorView.hidden ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerFocusNavigationActive]) {
        return;
    }

    [UIView animateWithDuration:0.4 animations:^{
        self.cursorView.alpha = 0.0;
    }];
}

- (void)noteSelectPressActivity {
    self.selectPressDuringCurrentTouch = YES;
    self.lastSelectPressActivityTimestamp = CACurrentMediaTime();
}

- (void)handleGlobalSelectPressEndedNotification {
    [self noteSelectPressActivity];
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
        return;
    }

    if ((CACurrentMediaTime() - self.lastDirectSelectPressTimestamp) < 0.15) {
        return;
    }

    [self handleSelectPressEnded];
}

- (void)handleDeferredSelectPressAction {
    if (!self.awaitingSecondSelectPress) {
        return;
    }

    self.awaitingSecondSelectPress = NO;
    self.lastTouchLocation = CGPointMake(-1, -1);

    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
        return;
    }

    [self.host browserRemoteInputControllerHandlePrimaryActionWithSource:BrowserPageActivationSourceClick];
}

- (void)handleSelectPressEnded {
    [self noteSelectPressActivity];
    CFTimeInterval now = CACurrentMediaTime();
    if (self.awaitingSecondSelectPress && (now - self.lastSelectPressTimestamp) < 0.35) {
        self.awaitingSecondSelectPress = NO;
        self.lastSelectPressTimestamp = now;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
        if (![self.host browserRemoteInputControllerTabOverviewVisible]) {
            [self setCursorModeEnabled:!self.cursorModeEnabled];
        }
        return;
    }

    self.awaitingSecondSelectPress = YES;
    self.lastSelectPressTimestamp = now;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
    [self performSelector:@selector(handleDeferredSelectPressAction) withObject:nil afterDelay:0.3];
}

- (void)handlePlayPauseDoubleTap:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerDismissTabOverview];
        return;
    }
    [self.host browserRemoteInputControllerHandleAdvancedMenuPress];
}

- (void)handleManualScrollPan:(UIPanGestureRecognizer *)gestureRecognizer {
    [self noteCursorActivity];
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerFocusNavigationActive]) {
        return;
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        [self stopManualScrollInertia];
    }

    CGPoint translation = [gestureRecognizer translationInView:self.rootView];
    if (!CGPointEqualToPoint(translation, CGPointZero)) {
        [self applyManualScrollDelta:CGPointMake(-translation.x, -translation.y)];
        [gestureRecognizer setTranslation:CGPointZero inView:self.rootView];
        self.manualScrollLastMovementTimestamp = CACurrentMediaTime();
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        CFTimeInterval timeSinceLastMovement = CACurrentMediaTime() - self.manualScrollLastMovementTimestamp;
        CGPoint velocity = [gestureRecognizer velocityInView:self.rootView];
        if (timeSinceLastMovement < 0.08) {
            [self startManualScrollInertiaWithVelocity:CGPointMake(-velocity.x, -velocity.y)];
        } else {
            [self stopManualScrollInertia];
        }
        [self.host browserRemoteInputControllerPersistSession];
    } else if (gestureRecognizer.state == UIGestureRecognizerStateCancelled ||
               gestureRecognizer.state == UIGestureRecognizerStateFailed) {
        [self stopManualScrollInertia];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    [self noteCursorActivity];
    for (UIPress *p in presses) {
        if (p.type == UIPressTypeSelect) {
            [self noteSelectPressActivity];
            self.selectPressStartTime = CACurrentMediaTime();
        }
    }

    UIPress *press = presses.anyObject;
    if (press == nil) {
        return;
    }

    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
        NSLog(@"[InputTrace][Root] pressesBegan type=%@ phase=%@ presented=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]));
    }

    if ((press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) &&
        press.phase == UIPressPhaseBegan) {
        if ([self.host browserRemoteInputControllerDpadScrollEnabled] && [self canPerformCustomScroll]) {
            if (press.type == UIPressTypeUpArrow &&
                [self isCursorInTopBarActivationZone] &&
                [self.host browserRemoteInputControllerCanActivateTopBarFocus]) {
                return;
            }
            [self stopDpadHoldAndContinuousScroll];
            self.activeDpadDirection = (press.type == UIPressTypeDownArrow) ? 1 : -1;
            self.dpadHoldTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                                  target:self
                                                                selector:@selector(handleDpadHoldTimerFired:)
                                                                userInfo:nil
                                                                 repeats:NO];
        }
    }
}

- (void)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    [self noteCursorActivity];
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect) {
            [self noteSelectPressActivity];
        }
        if (press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
            [self stopDpadHoldAndContinuousScroll];
        }
    }
}

- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    [self noteCursorActivity];
    for (UIPress *p in presses) {
        if (p.type == UIPressTypeSelect) {
            [self noteSelectPressActivity];
        }
    }

    UIPress *press = presses.anyObject;
    if (press == nil) {
        return NO;
    }

    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
        NSLog(@"[InputTrace][Root] pressesEnded type=%@ phase=%@ presented=%@ tabOverview=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]),
              [self.host browserRemoteInputControllerTabOverviewVisible] ? @"YES" : @"NO");
    }

    if (press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
        BOOL wasContinuousScrollActive = self.dpadContinuousScrollActive;
        [self stopDpadHoldAndContinuousScroll];
        if (wasContinuousScrollActive) {
            return YES;
        }
    }

    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypeDownArrow) {
            [self.host browserRemoteInputControllerDeactivateTopBarFocus];
            return YES;
        }
        if (press.type == UIPressTypePlayPause) {
            return YES;
        }
        if (press.type == UIPressTypeSelect ||
            press.type == UIPressTypeLeftArrow ||
            press.type == UIPressTypeRightArrow ||
            press.type == UIPressTypeUpArrow) {
            return NO;
        }
    }

    UIViewController *presentedViewController = [self.host browserRemoteInputControllerPresentedViewController];
    if (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]]) {
        if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
            if (press.type == UIPressTypeMenu) {
                [self.host browserRemoteInputControllerDismissTabOverview];
                return YES;
            }
            if (press.type == UIPressTypePlayPause) {
                [self.host browserRemoteInputControllerHandleTabOverviewAlternateAction];
                return YES;
            }
            return NO;
        }
        if (press.type == UIPressTypeMenu) {
            [presentedViewController dismissViewControllerAnimated:YES completion:nil];
            return YES;
        }
        return YES;
    }

    if (press.type == UIPressTypeSelect) {
        self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
        CFTimeInterval holdDuration = (self.selectPressStartTime > 0.0)
            ? (CACurrentMediaTime() - self.selectPressStartTime)
            : 0.0;
        self.selectPressStartTime = 0.0;
        if (holdDuration >= kBrowserSelectLongClickThreshold) {
            // Cancel any pending single-click action so the link does not also
            // open in the current tab after opening in a new one.
            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(handleDeferredSelectPressAction)
                                                       object:nil];
            self.awaitingSecondSelectPress = NO;
            if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
                [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
            } else {
                [self.host browserRemoteInputControllerHandlePrimaryActionWithSource:BrowserPageActivationSourceLongClick];
            }
            return YES;
        }
        [self handleSelectPressEnded];
        return YES;
    }

    if (press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
        if (![self canPerformCustomScroll]) {
            return NO;
        }

        if (press.type == UIPressTypeUpArrow) {
            BOOL dpadEnabled = [self.host browserRemoteInputControllerDpadScrollEnabled];
            if (!dpadEnabled || [self isCursorInTopBarActivationZone]) {
                if ([self.host browserRemoteInputControllerCanActivateTopBarFocus]) {
                    [self.host browserRemoteInputControllerActivateTopBarFocus];
                    return YES;
                }
                if (!dpadEnabled) {
                    return NO;
                }
            }
            if (dpadEnabled) {
                CGFloat pageDelta = -([self viewportHeight] * 0.85);
                [self startDpadPageScrollWithDeltaY:pageDelta];
                return YES;
            }
        } else if (press.type == UIPressTypeDownArrow) {
            if ([self.host browserRemoteInputControllerDpadScrollEnabled]) {
                CGFloat pageDelta = [self viewportHeight] * 0.85;
                [self startDpadPageScrollWithDeltaY:pageDelta];
                return YES;
            }
        }
        return NO;
    }

    if ((press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow) &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerFocusNavigationActive] &&
        [self.host browserRemoteInputControllerPresentedViewController] == nil) {
        if (press.type == UIPressTypeLeftArrow) {
            [self.host browserRemoteInputControllerGoBack];
        } else {
            [self.host browserRemoteInputControllerGoForward];
        }
        return YES;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
            [self.host browserRemoteInputControllerDismissTabOverview];
            return YES;
        }
        if (press.type == UIPressTypeSelect) {
            [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
            return YES;
        }
    }

    if (press.type == UIPressTypeMenu) {
        [self.host browserRemoteInputControllerHandleMenuPress];
        return YES;
    }
    if (press.type == UIPressTypePlayPause) {
        [self.host browserRemoteInputControllerHandlePlayPausePress];
        return YES;
    }
    return NO;
}

- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self noteCursorActivity];
    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }
    self.lastTouchLocation = CGPointMake(-1, -1);
    self.trackingTouchForTap = YES;
    self.currentTouchStartTime = CACurrentMediaTime();
    self.currentTouchStartCursorOrigin = self.cursorView.frame.origin;
    self.currentTouchMaxCursorDistance = 0.0;
    self.selectPressDuringCurrentTouch = NO;
    return YES;
}

- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self noteCursorActivity];
    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }

    for (UITouch *touch in touches) {
        UIScrollView *activeScrollView = [self.host browserRemoteInputControllerActiveScrollView];
        UIView *targetView = activeScrollView ?: self.rootView;
        CGPoint location = [touch locationInView:targetView];

        if (self.lastTouchLocation.x == -1 && self.lastTouchLocation.y == -1) {
            self.lastTouchLocation = location;
        } else {
            CGFloat xDiff = location.x - self.lastTouchLocation.x;
            CGFloat yDiff = location.y - self.lastTouchLocation.y;
            CGRect rect = self.cursorView.frame;

            CGFloat maxX = [self viewportWidth];
            CGFloat maxY = [self viewportHeight];
            if (rect.origin.x + xDiff >= 0 && rect.origin.x + xDiff <= maxX) {
                rect.origin.x += xDiff;
            }
            if (rect.origin.y + yDiff >= 0 && rect.origin.y + yDiff <= maxY) {
                rect.origin.y += yDiff;
            }
            self.cursorView.frame = rect;
            self.lastTouchLocation = location;

            if (self.trackingTouchForTap) {
                CGFloat dx = rect.origin.x - self.currentTouchStartCursorOrigin.x;
                CGFloat dy = rect.origin.y - self.currentTouchStartCursorOrigin.y;
                CGFloat distance = hypot(dx, dy);
                if (distance > self.currentTouchMaxCursorDistance) {
                    self.currentTouchMaxCursorDistance = distance;
                }
            }

            [self updateEdgeAutoScrollForCursorPosition];
        }

        self.cursorView.image = BrowserDefaultCursor();
        if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
            if ([self.host browserRemoteInputControllerTabOverviewContainsPoint:self.cursorView.frame.origin]) {
                self.cursorView.image = BrowserPointerCursor();
            }
            break;
        }
        if (self.cursorModeEnabled) {
            NSString *containsLink = [self.host browserRemoteInputControllerHoverStateAtCursorPoint:self.cursorView.frame.origin];
            if ([containsLink isEqualToString:@"true"]) {
                self.cursorView.image = BrowserPointerCursor();
            }
        }
        break;
    }

    return YES;
}

- (void)handleTouchesEnded {
    [self noteCursorActivity];
    self.lastTouchLocation = CGPointMake(-1, -1);
    // The cursor only moves while a finger is on the touch surface, so a cursor
    // parked inside the edge zone would otherwise auto-scroll to the end of the
    // page after the finger is lifted. Auto-scroll lasts as long as the touch.
    [self stopEdgeAutoScroll];

    BOOL wasTrackingTouch = self.trackingTouchForTap;
    self.trackingTouchForTap = NO;

    if (!wasTrackingTouch) {
        return;
    }

    CFTimeInterval touchDuration = CACurrentMediaTime() - self.currentTouchStartTime;
    CGFloat maxDistance = self.currentTouchMaxCursorDistance;
    BOOL selectOccurred = self.selectPressDuringCurrentTouch ||
        self.awaitingSecondSelectPress ||
        ((CACurrentMediaTime() - self.lastSelectPressActivityTimestamp) < 0.4);

    if (self.cursorModeEnabled &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerFocusNavigationActive] &&
        [self.host browserRemoteInputControllerPresentedViewController] == nil &&
        [self.host browserRemoteInputControllerTapToClickEnabled] &&
        touchDuration > 0.0 &&
        touchDuration < 0.25 &&
        maxDistance < 20.0 &&
        !selectOccurred) {
        NSLog(@"[InputTrace][TapToClick] Triggered tap action duration=%.3f maxDistance=%.1f", touchDuration, maxDistance);
        [self.host browserRemoteInputControllerHandlePrimaryActionWithSource:BrowserPageActivationSourceTap];
    }
}

- (void)handleTouchesCancelled {
    self.lastTouchLocation = CGPointMake(-1, -1);
    self.trackingTouchForTap = NO;
    self.selectPressDuringCurrentTouch = NO;
    [self stopEdgeAutoScroll];
}

@end
```

## `BrowserDOMInteractionService.h`  (44줄)

```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserDOMInteractionService : NSObject

- (CGPoint)DOMPointForCursorOrigin:(CGPoint)cursorOrigin
                            inView:(UIView *)containerView
                           webView:(BrowserWebView *)webView;
- (NSString *)evaluateResolvedElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body;
- (NSString *)evaluateEditableElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body;
- (NSString *)evaluateHoverStateJavaScriptAtPoint:(CGPoint)point
                                           webView:(BrowserWebView *)webView;
- (NSString *)javaScriptEscapedString:(NSString *)string;
- (BOOL)scrollActiveContainerByX:(CGFloat)dx
                               y:(CGFloat)dy
                         atPoint:(CGPoint)domPoint
                         webView:(BrowserWebView *)webView;
- (NSDictionary *)videoInfoAtDOMPoint:(CGPoint)point
                               webView:(BrowserWebView *)webView;
- (NSDictionary *)linkInfoAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView;
- (NSDictionary *)directVideoInfoAtDOMPoint:(CGPoint)point
                                     webView:(BrowserWebView *)webView;
- (BOOL)isVideoActivationTargetAtDOMPoint:(CGPoint)point
                                   webView:(BrowserWebView *)webView;
- (BOOL)isVideoDismissTargetAtDOMPoint:(CGPoint)point
                                webView:(BrowserWebView *)webView;
- (NSDictionary *)primedVideoInfoAtDOMPoint:(CGPoint)point
                                     webView:(BrowserWebView *)webView;
- (NSDictionary *)activateVideoTargetAtDOMPoint:(CGPoint)point
                                         webView:(BrowserWebView *)webView
                                         timeout:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserDOMInteractionService.m`  (818줄)

```objc
#import "BrowserDOMInteractionService.h"

#import "BrowserWebView.h"

static NSString * const kInteractiveElementSelector = @"a, button, input, textarea, select, option, label, summary, [role='button'], [onclick], [tabindex]";
static NSString * const kEditableElementSelector = @"input, textarea, select, [contenteditable='true'], [contenteditable=''], [contenteditable]";

@implementation BrowserDOMInteractionService

- (CGPoint)DOMPointForCursorOrigin:(CGPoint)cursorOrigin
                            inView:(UIView *)containerView
                           webView:(BrowserWebView *)webView {
    CGPoint point = [containerView convertPoint:cursorOrigin toView:webView];
    if (point.y < 0.0) {
        return point;
    }

    NSInteger displayWidth = [[webView stringByEvaluatingJavaScriptFromString:@"window.innerWidth"] integerValue];
    if (displayWidth <= 0) {
        return point;
    }

    CGFloat scale = CGRectGetWidth([webView frame]) / (CGFloat)displayWidth;
    if (scale <= 0.0) {
        return point;
    }

    point.x /= scale;
    point.y /= scale;
    return point;
}

- (NSString *)evaluateResolvedElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body {
    if (webView == nil) {
        return @"";
    }

    NSInteger pointX = (NSInteger)llround(point.x);
    NSInteger pointY = (NSInteger)llround(point.y);
    NSString *script = [NSString stringWithFormat:
                        @"(function(){"
                        "var x=%ld;"
                        "var y=%ld;"
                        "var interactiveSelector=\"%@\";"
                        "var editableSelector=\"%@\";"
                        "function resolveElement(root, px, py) {"
                            "if (!root || typeof root.elementFromPoint !== 'function') { return null; }"
                            "var element = root.elementFromPoint(px, py);"
                            "while (element) {"
                                "if (element.shadowRoot && typeof element.shadowRoot.elementFromPoint === 'function') {"
                                    "var shadowRect = element.getBoundingClientRect();"
                                    "var shadowElement = resolveElement(element.shadowRoot, px - shadowRect.left, py - shadowRect.top);"
                                    "if (shadowElement && shadowElement !== element) {"
                                        "element = shadowElement;"
                                        "continue;"
                                    "}"
                                "}"
                                "if (element.tagName === 'IFRAME') {"
                                    "try {"
                                        "var frameRect = element.getBoundingClientRect();"
                                        "var frameDocument = element.contentDocument;"
                                        "var frameElement = resolveElement(frameDocument, px - frameRect.left, py - frameRect.top);"
                                        "if (frameElement) {"
                                            "element = frameElement;"
                                            "continue;"
                                        "}"
                                    "} catch (error) {}"
                                "}"
                                "return element;"
                            "}"
                            "return null;"
                        "}"
                        "function closestMatch(element, selector) {"
                            "while (element) {"
                                "if (element.matches && element.matches(selector)) { return element; }"
                                "element = element.parentElement;"
                            "}"
                            "return null;"
                        "}"
                        "var resolvedElement = resolveElement(document, x, y);"
                        "var interactiveElement = closestMatch(resolvedElement, interactiveSelector);"
                        "var editableElement = closestMatch(resolvedElement, editableSelector);"
                        "%@"
                        "})()",
                        (long)pointX,
                        (long)pointY,
                        kInteractiveElementSelector,
                        kEditableElementSelector,
                        body];
    return [webView stringByEvaluatingJavaScriptFromString:script] ?: @"";
}

- (NSString *)evaluateEditableElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body {
    NSString *wrappedBody = [NSString stringWithFormat:
                             @"function browserIsEditableCandidate(element) {"
                                 "if (!element) { return false; }"
                                 "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                 "if (element.matches && element.matches(editableSelector)) { return true; }"
                                 "if (tagName === 'textarea' || tagName === 'select') { return true; }"
                                 "if (element.isContentEditable) { return true; }"
                                 "return false;"
                             "}"
                             "function browserEditableTarget() {"
                                 "var stored = window.__browserLastEditableElement;"
                                 "if (stored && stored.isConnected && browserIsEditableCandidate(stored)) { return stored; }"
                                 "var active = document.activeElement;"
                                 "if (active && browserIsEditableCandidate(active)) {"
                                     "window.__browserLastEditableElement = active;"
                                     "return active;"
                                 "}"
                                 "var candidate = editableElement || interactiveElement || resolvedElement;"
                                 "if (candidate && browserIsEditableCandidate(candidate)) {"
                                     "window.__browserLastEditableElement = candidate;"
                                     "return candidate;"
                                 "}"
                                 "if (candidate && candidate.closest) {"
                                     "var fallback = candidate.closest(editableSelector) || candidate.closest('textarea, select');"
                                     "if (fallback && browserIsEditableCandidate(fallback)) {"
                                         "window.__browserLastEditableElement = fallback;"
                                         "return fallback;"
                                     "}"
                                 "}"
                                 "return null;"
                             "}"
                             "%@",
                             body];
    return [self evaluateResolvedElementJavaScriptAtPoint:point webView:webView body:wrappedBody];
}

- (NSString *)evaluateHoverStateJavaScriptAtPoint:(CGPoint)point
                                           webView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"false";
    }

    return [self evaluateResolvedElementJavaScriptAtPoint:point
                                                  webView:webView
                                                     body:@"var candidate = interactiveElement || resolvedElement;"
                                                          "while (candidate) {"
                                                              "if (candidate.matches && candidate.matches(interactiveSelector)) { return 'true'; }"
                                                              "candidate = candidate.parentElement;"
                                                          "}"
                                                          "return 'false';"];
}

- (NSString *)javaScriptEscapedString:(NSString *)string {
    NSString *escapedString = string ?: @"";
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\\u2028"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\u2029" withString:@"\\u2029"];
    return escapedString;
}

- (BOOL)scrollActiveContainerByX:(CGFloat)dx
                               y:(CGFloat)dy
                         atPoint:(CGPoint)domPoint
                         webView:(BrowserWebView *)webView {
    if (webView == nil || (fabs(dx) < 0.01 && fabs(dy) < 0.01)) {
        return NO;
    }

    NSString *body = [NSString stringWithFormat:
                      @"var dx = %.4f;"
                       "var dy = %.4f;"
                       "function isOverflowScrollable(ov) {"
                           "return ov === 'auto' || ov === 'scroll' || ov === 'overlay';"
                       "}"
                       "function canScrollElement(el) {"
                           "if (!el || el === document.documentElement || el === document.body) { return false; }"
                           "if (!window.getComputedStyle) { return false; }"
                           "var style = window.getComputedStyle(el);"
                           "if (!style) { return false; }"
                           "var canY = (el.scrollHeight > el.clientHeight + 1) && isOverflowScrollable(style.overflowY || style.overflow);"
                           "var canX = (el.scrollWidth > el.clientWidth + 1) && isOverflowScrollable(style.overflowX || style.overflow);"
                           "return (Math.abs(dy) >= Math.abs(dx)) ? (canY || canX) : (canX || canY);"
                       "}"
                       "function nextParent(el) {"
                           "if (!el) { return null; }"
                           "if (el.parentElement) { return el.parentElement; }"
                           "var root = el.getRootNode ? el.getRootNode() : null;"
                           "if (root && root.host) { return root.host; }"
                           "return null;"
                       "}"
                       "var startEl = resolvedElement || (document.elementFromPoint ? document.elementFromPoint(x, y) : null);"
                       "var cur = startEl;"
                       "while (cur) {"
                           "if (canScrollElement(cur)) {"
                               "var beforeTop = cur.scrollTop;"
                               "var beforeLeft = cur.scrollLeft;"
                               "if (typeof cur.scrollBy === 'function') {"
                                   "cur.scrollBy(dx, dy);"
                               "} else {"
                                   "cur.scrollLeft += dx;"
                                   "cur.scrollTop += dy;"
                               "}"
                               "if (Math.abs(cur.scrollTop - beforeTop) > 0.5 || Math.abs(cur.scrollLeft - beforeLeft) > 0.5) {"
                                   "return 'true';"
                               "}"
                           "}"
                           "cur = nextParent(cur);"
                       "}"
                       "var docEl = document.scrollingElement || document.documentElement || document.body;"
                       "var winBeforeX = window.scrollX || window.pageXOffset || (docEl ? docEl.scrollLeft : 0) || 0;"
                       "var winBeforeY = window.scrollY || window.pageYOffset || (docEl ? docEl.scrollTop : 0) || 0;"
                       "window.scrollBy(dx, dy);"
                       "var winAfterX = window.scrollX || window.pageXOffset || (docEl ? docEl.scrollLeft : 0) || 0;"
                       "var winAfterY = window.scrollY || window.pageYOffset || (docEl ? docEl.scrollTop : 0) || 0;"
                       "if (Math.abs(winAfterX - winBeforeX) > 0.5 || Math.abs(winAfterY - winBeforeY) > 0.5) {"
                           "return 'true';"
                       "}"
                       "if (document.body) {"
                           "var bodyBeforeTop = document.body.scrollTop;"
                           "var bodyBeforeLeft = document.body.scrollLeft;"
                           "document.body.scrollLeft += dx;"
                           "document.body.scrollTop += dy;"
                           "if (Math.abs(document.body.scrollTop - bodyBeforeTop) > 0.5 || Math.abs(document.body.scrollLeft - bodyBeforeLeft) > 0.5) {"
                               "return 'true';"
                           "}"
                       "}"
                       "return 'false';",
                      dx, dy];

    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:domPoint
                                                              webView:webView
                                                                 body:body];
    return [result isEqualToString:@"true"];
}

- (NSDictionary *)videoInfoAtDOMPoint:(CGPoint)point
                               webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserAbsoluteURL(url) {"
                                                                       "if (!url) { return ''; }"
                                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                                       "}"
                                                                       "function browserVideoContainsPoint(video) {"
                                                                           "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                                           "var rect = video.getBoundingClientRect();"
                                                                           "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                                       "}"
                                                                       "function browserResolveVideoElement() {"
                                                                           "var candidate = resolvedElement;"
                                                                           "while (candidate) {"
                                                                               "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                                               "candidate = candidate.parentElement;"
                                                                           "}"
                                                                           "var videos = document.querySelectorAll('video');"
                                                                           "var bestVisibleVideo = null;"
                                                                           "var bestVisibleArea = 0;"
                                                                           "for (var i = 0; i < videos.length; i++) {"
                                                                               "var video = videos[i];"
                                                                               "if (browserVideoContainsPoint(video)) { return video; }"
                                                                               "if (!video || typeof video.getBoundingClientRect !== 'function') { continue; }"
                                                                               "var rect = video.getBoundingClientRect();"
                                                                               "var visibleWidth = Math.max(0, Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0));"
                                                                               "var visibleHeight = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));"
                                                                               "var visibleArea = visibleWidth * visibleHeight;"
                                                                               "if (visibleArea <= 0) { continue; }"
                                                                               "if (!video.paused && !video.ended && video.readyState >= 2) { return video; }"
                                                                               "if (visibleArea > bestVisibleArea) {"
                                                                                   "bestVisibleArea = visibleArea;"
                                                                                   "bestVisibleVideo = video;"
                                                                               "}"
                                                                           "}"
                                                                           "return bestVisibleVideo;"
                                                                       "}"
                                                                       "function browserResolvePrimarySource(video) {"
                                                                           "if (!video) { return ''; }"
                                                                           "if (video.currentSrc) { return browserAbsoluteURL(video.currentSrc); }"
                                                                           "if (video.src) { return browserAbsoluteURL(video.src); }"
                                                                           "var sources = video.querySelectorAll('source');"
                                                                           "for (var i = 0; i < sources.length; i++) {"
                                                                               "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                                               "if (sourceSrc) { return browserAbsoluteURL(sourceSrc); }"
                                                                           "}"
                                                                           "return '';"
                                                                       "}"
                                                                       "function browserResolveSourceList(video) {"
                                                                           "var values = [];"
                                                                           "if (!video) { return values; }"
                                                                           "if (video.currentSrc) { values.push(browserAbsoluteURL(video.currentSrc)); }"
                                                                           "if (video.src && values.indexOf(browserAbsoluteURL(video.src)) === -1) { values.push(browserAbsoluteURL(video.src)); }"
                                                                           "var sources = video.querySelectorAll('source');"
                                                                           "for (var i = 0; i < sources.length; i++) {"
                                                                               "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                                               "sourceSrc = browserAbsoluteURL(sourceSrc);"
                                                                               "if (sourceSrc && values.indexOf(sourceSrc) === -1) { values.push(sourceSrc); }"
                                                                           "}"
                                                                           "return values;"
                                                                       "}"
                                                                       "var video = browserResolveVideoElement();"
                                                                       "if (!video) { return ''; }"
                                                                       "return JSON.stringify({"
                                                                           "src: browserResolvePrimarySource(video),"
                                                                           "sources: browserResolveSourceList(video),"
                                                                           "poster: browserAbsoluteURL(video.poster || ''),"
                                                                           "title: video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '',"
                                                                           "tagName: video.tagName ? video.tagName.toLowerCase() : '',"
                                                                           "paused: !!video.paused"
                                                                       "});"];
    return [self JSONObjectFromJavaScriptString:result];
}

- (NSDictionary *)linkInfoAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserAbsoluteURL(url) {"
                                                                       "if (!url) { return ''; }"
                                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                                       "}"
                                                                       "var element = interactiveElement || resolvedElement;"
                                                                       "if (!element) { return ''; }"
                                                                       "var link = null;"
                                                                       "if (element.closest) {"
                                                                           "link = element.closest('a[href]');"
                                                                       "}"
                                                                       "if (!link && element.tagName && element.tagName.toLowerCase() === 'a') {"
                                                                           "link = element;"
                                                                       "}"
                                                                       "if (!link) { return ''; }"
                                                                       "var href = link.href || (link.getAttribute ? (link.getAttribute('href') || '') : '');"
                                                                       "if (!href) { return ''; }"
                                                                       "var target = link.getAttribute ? (link.getAttribute('target') || '') : '';"
                                                                       "return JSON.stringify({"
                                                                           "href: browserAbsoluteURL(href),"
                                                                           "target: String(target || '').toLowerCase()"
                                                                       "});"];
    return [self JSONObjectFromJavaScriptString:result];
}

- (NSDictionary *)directVideoInfoAtDOMPoint:(CGPoint)point
                                     webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserAbsoluteURL(url) {"
                                                                       "if (!url) { return ''; }"
                                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                                       "}"
                                                                       "function browserVideoContainsPoint(video) {"
                                                                           "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                                           "var rect = video.getBoundingClientRect();"
                                                                           "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                                       "}"
                                                                       "function browserResolveDirectVideoElement() {"
                                                                           "var candidate = resolvedElement;"
                                                                           "while (candidate) {"
                                                                               "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                                               "candidate = candidate.parentElement;"
                                                                           "}"
                                                                           "var videos = document.querySelectorAll('video');"
                                                                           "for (var i = 0; i < videos.length; i++) {"
                                                                               "if (browserVideoContainsPoint(videos[i])) { return videos[i]; }"
                                                                           "}"
                                                                           "return null;"
                                                                       "}"
                                                                       "function browserResolvePrimarySource(video) {"
                                                                           "if (!video) { return ''; }"
                                                                           "if (video.currentSrc) { return browserAbsoluteURL(video.currentSrc); }"
                                                                           "if (video.src) { return browserAbsoluteURL(video.src); }"
                                                                           "var sources = video.querySelectorAll('source');"
                                                                           "for (var i = 0; i < sources.length; i++) {"
                                                                               "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                                               "if (sourceSrc) { return browserAbsoluteURL(sourceSrc); }"
                                                                           "}"
                                                                           "return '';"
                                                                       "}"
                                                                       "function browserResolveSourceList(video) {"
                                                                           "var values = [];"
                                                                           "if (!video) { return values; }"
                                                                           "if (video.currentSrc) { values.push(browserAbsoluteURL(video.currentSrc)); }"
                                                                           "if (video.src && values.indexOf(browserAbsoluteURL(video.src)) === -1) { values.push(browserAbsoluteURL(video.src)); }"
                                                                           "var sources = video.querySelectorAll('source');"
                                                                           "for (var i = 0; i < sources.length; i++) {"
                                                                               "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                                               "sourceSrc = browserAbsoluteURL(sourceSrc);"
                                                                               "if (sourceSrc && values.indexOf(sourceSrc) === -1) { values.push(sourceSrc); }"
                                                                           "}"
                                                                           "return values;"
                                                                       "}"
                                                                       "var video = browserResolveDirectVideoElement();"
                                                                       "if (!video) { return ''; }"
                                                                       "return JSON.stringify({"
                                                                           "src: browserResolvePrimarySource(video),"
                                                                           "sources: browserResolveSourceList(video),"
                                                                           "poster: browserAbsoluteURL(video.poster || ''),"
                                                                           "title: video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '',"
                                                                           "tagName: video.tagName ? video.tagName.toLowerCase() : '',"
                                                                           "paused: !!video.paused"
                                                                       "});"];
    return [self JSONObjectFromJavaScriptString:result];
}

- (BOOL)isVideoActivationTargetAtDOMPoint:(CGPoint)point
                                   webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserVideoContainsPoint(video) {"
                                                                       "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                                       "var rect = video.getBoundingClientRect();"
                                                                       "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                                       "}"
                                                                       "function browserLooksLikeDismissControl(element) {"
                                                                           "if (!element) { return false; }"
                                                                           "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                                           "var role = element.getAttribute ? (element.getAttribute('role') || '').toLowerCase() : '';"
                                                                           "var isButtonLike = tagName === 'button' || tagName === 'a' || role === 'button' ||"
                                                                               "(typeof element.onclick === 'function') ||"
                                                                               "(typeof element.tabIndex === 'number' && element.tabIndex >= 0);"
                                                                           "if (!isButtonLike) { return false; }"
                                                                           "var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();"
                                                                           "var shortText = text.length <= 3 ? text : '';"
                                                                           "var label = ["
                                                                               "element.id || '',"
                                                                               "element.className || '',"
                                                                               "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('title') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('name') || '') : '',"
                                                                               "shortText"
                                                                           "].join(' ').toLowerCase();"
                                                                           "if (!label) { return false; }"
                                                                           "if ((/(^|[^a-z])(close|dismiss|cancel|collapse|minimi[sz]e|exit)([^a-z]|$)/).test(label) ||"
                                                                               "label.indexOf('modal-close') !== -1 ||"
                                                                               "label.indexOf('icon-close') !== -1) {"
                                                                               "return true;"
                                                                           "}"
                                                                           "if (shortText === '×' || shortText === '✕' || shortText === '✖' || shortText === 'x' || shortText === 'X') {"
                                                                               "return true;"
                                                                           "}"
                                                                           "return false;"
                                                                       "}"
                                                                       "function browserMatchesVideoIntent(element) {"
                                                                           "if (!element) { return false; }"
                                                                           "if (browserLooksLikeDismissControl(element)) { return false; }"
                                                                           "var value = ["
                                                                               "element.id || '',"
                                                                               "element.className || '',"
                                                                               "element.getAttribute ? (element.getAttribute('role') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('aria-description') || '') : '',"
                                                                               "element.getAttribute ? (element.getAttribute('title') || '') : ''"
                                                                           "].join(' ').toLowerCase();"
                                                                           "if (!value) { return false; }"
                                                                           "var hasPlayWord = (/(^|[^a-z])(play|watch|resume|trailer)([^a-z]|$)/).test(value);"
                                                                           "var hasControlWord = value.indexOf('ytp-') !== -1 || value.indexOf('video-play') !== -1 || value.indexOf('play-button') !== -1;"
                                                                           "return hasPlayWord || hasControlWord;"
                                                                       "}"
                                                                       "function browserContainsVideoAncestor(element) {"
                                                                           "var candidate = element;"
                                                                           "var depth = 0;"
                                                                           "while (candidate && depth < 10) {"
                                                                               "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return true; }"
                                                                               "candidate = candidate.parentElement;"
                                                                               "depth += 1;"
                                                                           "}"
                                                                           "return false;"
                                                                       "}"
                                                                       "function browserLooksLikeNavigationTarget(element) {"
                                                                           "if (!element) { return false; }"
                                                                           "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                                           "if (tagName !== 'a' && tagName !== 'button') { return false; }"
                                                                           "if (element.closest && element.closest('nav, header, [role=\"navigation\"], .ac-gn, .ac-gn-content, .ac-gn-list, .globalnav')) { return true; }"
                                                                           "if (tagName === 'a') {"
                                                                               "var href = (element.getAttribute ? (element.getAttribute('href') || '') : '').trim().toLowerCase();"
                                                                               "if (href && href !== '#' && href.indexOf('javascript:') !== 0 && href.indexOf('mailto:') !== 0 && href.indexOf('tel:') !== 0) {"
                                                                                   "return true;"
                                                                               "}"
                                                                           "}"
                                                                           "return false;"
                                                                       "}"
                                                                       "if (browserLooksLikeNavigationTarget(interactiveElement) &&"
                                                                           "!browserContainsVideoAncestor(interactiveElement) &&"
                                                                           "!browserMatchesVideoIntent(interactiveElement)) {"
                                                                           "return 'false';"
                                                                       "}"
                                                                       "var candidate = resolvedElement;"
                                                                       "var candidateDepth = 0;"
                                                                       "while (candidate && candidateDepth < 10) {"
                                                                           "if (browserLooksLikeDismissControl(candidate)) { return 'false'; }"
                                                                           "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return 'true'; }"
                                                                           "if (browserMatchesVideoIntent(candidate)) { return 'true'; }"
                                                                           "candidate = candidate.parentElement;"
                                                                           "candidateDepth += 1;"
                                                                       "}"
                                                                       "var videos = document.querySelectorAll('video');"
                                                                       "for (var i = 0; i < videos.length; i++) {"
                                                                           "if (browserVideoContainsPoint(videos[i])) {"
                                                                               "if (browserLooksLikeNavigationTarget(interactiveElement) && !browserContainsVideoAncestor(interactiveElement)) { return 'false'; }"
                                                                               "if (browserLooksLikeDismissControl(interactiveElement) || browserLooksLikeDismissControl(resolvedElement)) { return 'false'; }"
                                                                               "return 'true';"
                                                                           "}"
                                                                       "}"
                                                                       "return 'false';"];
    return [result isEqualToString:@"true"];
}

- (BOOL)isVideoDismissTargetAtDOMPoint:(CGPoint)point
                                webView:(BrowserWebView *)webView {
    NSString *result = [self evaluateResolvedElementJavaScriptAtPoint:point
                                                               webView:webView
                                                                  body:@"function browserLooksLikeDismissControl(element) {"
                                                                       "if (!element) { return false; }"
                                                                       "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                                       "var role = element.getAttribute ? (element.getAttribute('role') || '').toLowerCase() : '';"
                                                                       "var isButtonLike = tagName === 'button' || tagName === 'a' || role === 'button' ||"
                                                                           "(typeof element.onclick === 'function') ||"
                                                                           "(typeof element.tabIndex === 'number' && element.tabIndex >= 0);"
                                                                       "if (!isButtonLike) { return false; }"
                                                                       "var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();"
                                                                       "var shortText = text.length <= 3 ? text : '';"
                                                                       "var label = ["
                                                                           "element.id || '',"
                                                                           "element.className || '',"
                                                                           "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                                           "element.getAttribute ? (element.getAttribute('title') || '') : '',"
                                                                           "element.getAttribute ? (element.getAttribute('name') || '') : '',"
                                                                           "shortText"
                                                                       "].join(' ').toLowerCase();"
                                                                       "if (!label) { return false; }"
                                                                       "if ((/(^|[^a-z])(close|dismiss|cancel|collapse|minimi[sz]e|exit)([^a-z]|$)/).test(label) ||"
                                                                           "label.indexOf('modal-close') !== -1 ||"
                                                                           "label.indexOf('icon-close') !== -1) {"
                                                                           "return true;"
                                                                       "}"
                                                                       "if (shortText === '×' || shortText === '✕' || shortText === '✖' || shortText === 'x' || shortText === 'X') {"
                                                                           "return true;"
                                                                       "}"
                                                                       "return false;"
                                                                   "}"
                                                                   "var candidate = interactiveElement || resolvedElement;"
                                                                   "while (candidate) {"
                                                                       "if (browserLooksLikeDismissControl(candidate)) { return 'true'; }"
                                                                       "candidate = candidate.parentElement;"
                                                                   "}"
                                                                   "return 'false';"];
    return [result isEqualToString:@"true"];
}

- (NSDictionary *)primedVideoInfoAtDOMPoint:(CGPoint)point
                                     webView:(BrowserWebView *)webView {
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                           webView:webView
                                              body:@"window.__browserPrimedVideoInfo = '';"
                                                   "function browserAbsoluteURL(url) {"
                                                       "if (!url) { return ''; }"
                                                       "try { return String(new URL(url, document.baseURI).toString()); } catch (error) { return String(url); }"
                                                   "}"
                                                   "function browserVideoContainsPoint(video) {"
                                                       "if (!video || typeof video.getBoundingClientRect !== 'function') { return false; }"
                                                       "var rect = video.getBoundingClientRect();"
                                                       "return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;"
                                                   "}"
                                                   "function browserResolveVideoElement() {"
                                                       "var candidate = resolvedElement;"
                                                       "while (candidate) {"
                                                           "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                           "candidate = candidate.parentElement;"
                                                       "}"
                                                       "var videos = document.querySelectorAll('video');"
                                                       "var bestVisibleVideo = null;"
                                                       "var bestVisibleArea = 0;"
                                                       "for (var i = 0; i < videos.length; i++) {"
                                                           "var video = videos[i];"
                                                           "if (browserVideoContainsPoint(video)) { return video; }"
                                                           "if (!video || typeof video.getBoundingClientRect !== 'function') { continue; }"
                                                           "var rect = video.getBoundingClientRect();"
                                                           "var visibleWidth = Math.max(0, Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0));"
                                                           "var visibleHeight = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));"
                                                           "var visibleArea = visibleWidth * visibleHeight;"
                                                           "if (visibleArea <= 0) { continue; }"
                                                           "if (!video.paused && !video.ended && video.readyState >= 2) { return video; }"
                                                           "if (visibleArea > bestVisibleArea) {"
                                                               "bestVisibleArea = visibleArea;"
                                                               "bestVisibleVideo = video;"
                                                           "}"
                                                       "}"
                                                       "return bestVisibleVideo;"
                                                   "}"
                                                   "function browserResolvePrimarySource(video) {"
                                                       "if (!video) { return ''; }"
                                                       "if (video.currentSrc) { return browserAbsoluteURL(video.currentSrc); }"
                                                       "if (video.src) { return browserAbsoluteURL(video.src); }"
                                                       "var sources = video.querySelectorAll('source');"
                                                       "for (var i = 0; i < sources.length; i++) {"
                                                           "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                           "if (sourceSrc) { return browserAbsoluteURL(sourceSrc); }"
                                                       "}"
                                                       "return '';"
                                                   "}"
                                                   "function browserResolveSourceList(video) {"
                                                       "var values = [];"
                                                       "if (!video) { return values; }"
                                                       "if (video.currentSrc) { values.push(browserAbsoluteURL(video.currentSrc)); }"
                                                       "if (video.src && values.indexOf(browserAbsoluteURL(video.src)) === -1) { values.push(browserAbsoluteURL(video.src)); }"
                                                       "var sources = video.querySelectorAll('source');"
                                                       "for (var i = 0; i < sources.length; i++) {"
                                                           "var sourceSrc = sources[i].src || sources[i].getAttribute('src') || '';"
                                                           "sourceSrc = browserAbsoluteURL(sourceSrc);"
                                                           "if (sourceSrc && values.indexOf(sourceSrc) === -1) { values.push(sourceSrc); }"
                                                       "}"
                                                       "return values;"
                                                   "}"
                                                   "function browserStoreVideoInfo(video) {"
                                                       "if (!video) { return; }"
                                                       "window.__browserPrimedVideoInfo = JSON.stringify({"
                                                           "src: browserResolvePrimarySource(video),"
                                                           "sources: browserResolveSourceList(video),"
                                                           "poster: browserAbsoluteURL(video.poster || ''),"
                                                           "title: video.getAttribute('title') || video.getAttribute('aria-label') || document.title || '',"
                                                           "tagName: video.tagName ? video.tagName.toLowerCase() : '',"
                                                           "paused: !!video.paused"
                                                       "});"
                                                   "}"
                                                   "var video = browserResolveVideoElement();"
                                                   "if (!video) { return 'no-video'; }"
                                                   "try { if (video.focus) { video.focus(); } } catch (error) {}"
                                                   "var finish = function() {"
                                                       "try { if (video.pause) { video.pause(); } } catch (error) {}"
                                                       "browserStoreVideoInfo(video);"
                                                   "};"
                                                   "try {"
                                                       "var playResult = video.play ? video.play() : null;"
                                                       "if (playResult && typeof playResult.then === 'function') {"
                                                           "playResult.then(function() { setTimeout(finish, 0); }).catch(function() { setTimeout(finish, 0); });"
                                                       "} else {"
                                                           "setTimeout(finish, 0);"
                                                       "}"
                                                   "} catch (error) {"
                                                       "setTimeout(finish, 0);"
                                                   "}"
                                                   "return 'started';"];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSString *result = [webView stringByEvaluatingJavaScriptFromString:@"window.__browserPrimedVideoInfo || ''"];
        NSDictionary *videoInfo = [self JSONObjectFromJavaScriptString:result];
        if (videoInfo.count > 0) {
            return videoInfo;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    return nil;
}

- (NSDictionary *)activateVideoTargetAtDOMPoint:(CGPoint)point
                                         webView:(BrowserWebView *)webView
                                         timeout:(NSTimeInterval)timeout {
    if (webView == nil) {
        return nil;
    }

    NSTimeInterval effectiveTimeout = timeout > 0.0 ? timeout : 1.5;
    [self evaluateResolvedElementJavaScriptAtPoint:point
                                           webView:webView
                                              body:@"function browserMatchesVideoIntent(element) {"
                                                   "if (!element) { return false; }"
                                                   "if (browserLooksLikeDismissControl(element)) { return false; }"
                                                   "var value = ["
                                                       "element.id || '',"
                                                       "element.className || '',"
                                                       "element.getAttribute ? (element.getAttribute('role') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('aria-description') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('title') || '') : ''"
                                                   "].join(' ').toLowerCase();"
                                                   "if (!value) { return false; }"
                                                   "var hasPlayWord = (/(^|[^a-z])(play|watch|resume|trailer)([^a-z]|$)/).test(value);"
                                                   "var hasControlWord = value.indexOf('ytp-') !== -1 || value.indexOf('video-play') !== -1 || value.indexOf('play-button') !== -1;"
                                                   "return hasPlayWord || hasControlWord;"
                                               "}"
                                               "function browserLooksLikeDismissControl(element) {"
                                                   "if (!element) { return false; }"
                                                   "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                   "var role = element.getAttribute ? (element.getAttribute('role') || '').toLowerCase() : '';"
                                                   "var isButtonLike = tagName === 'button' || tagName === 'a' || role === 'button' ||"
                                                       "(typeof element.onclick === 'function') ||"
                                                       "(typeof element.tabIndex === 'number' && element.tabIndex >= 0);"
                                                   "if (!isButtonLike) { return false; }"
                                                   "var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();"
                                                   "var shortText = text.length <= 3 ? text : '';"
                                                   "var label = ["
                                                       "element.id || '',"
                                                       "element.className || '',"
                                                       "element.getAttribute ? (element.getAttribute('aria-label') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('title') || '') : '',"
                                                       "element.getAttribute ? (element.getAttribute('name') || '') : '',"
                                                       "shortText"
                                                   "].join(' ').toLowerCase();"
                                                   "if (!label) { return false; }"
                                                   "if ((/(^|[^a-z])(close|dismiss|cancel|collapse|minimi[sz]e|exit)([^a-z]|$)/).test(label) ||"
                                                       "label.indexOf('modal-close') !== -1 ||"
                                                       "label.indexOf('icon-close') !== -1) {"
                                                       "return true;"
                                                   "}"
                                                   "if (shortText === '×' || shortText === '✕' || shortText === '✖' || shortText === 'x' || shortText === 'X') {"
                                                       "return true;"
                                                   "}"
                                                   "return false;"
                                               "}"
                                               "function browserActivationTarget() {"
                                                   "function browserContainsVideoAncestor(element) {"
                                                       "var candidate = element;"
                                                       "var depth = 0;"
                                                       "while (candidate && depth < 10) {"
                                                           "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return true; }"
                                                           "candidate = candidate.parentElement;"
                                                           "depth += 1;"
                                                       "}"
                                                       "return false;"
                                                   "}"
                                                   "function browserLooksLikeNavigationTarget(element) {"
                                                       "if (!element) { return false; }"
                                                       "var tagName = element.tagName ? element.tagName.toLowerCase() : '';"
                                                       "if (tagName !== 'a' && tagName !== 'button') { return false; }"
                                                       "if (element.closest && element.closest('nav, header, [role=\"navigation\"], .ac-gn, .ac-gn-content, .ac-gn-list, .globalnav')) { return true; }"
                                                       "if (tagName === 'a') {"
                                                           "var href = (element.getAttribute ? (element.getAttribute('href') || '') : '').trim().toLowerCase();"
                                                           "if (href && href !== '#' && href.indexOf('javascript:') !== 0 && href.indexOf('mailto:') !== 0 && href.indexOf('tel:') !== 0) {"
                                                               "return true;"
                                                           "}"
                                                       "}"
                                                       "return false;"
                                                   "}"
                                                   "var candidate = interactiveElement || resolvedElement;"
                                                   "if (browserLooksLikeNavigationTarget(candidate) &&"
                                                       "!browserContainsVideoAncestor(candidate) &&"
                                                       "!browserMatchesVideoIntent(candidate)) {"
                                                       "return null;"
                                                   "}"
                                                   "var depth = 0;"
                                                   "while (candidate && depth < 10) {"
                                                       "if (browserLooksLikeDismissControl(candidate)) { return null; }"
                                                       "if (candidate.tagName && candidate.tagName.toLowerCase() === 'video') { return candidate; }"
                                                       "if (browserMatchesVideoIntent(candidate)) { return candidate; }"
                                                       "candidate = candidate.parentElement;"
                                                       "depth += 1;"
                                                   "}"
                                                   "return interactiveElement || resolvedElement || null;"
                                               "}"
                                               "function dispatchPointerLikeEvent(target, type, constructorName) {"
                                                   "if (!target) { return; }"
                                                   "try {"
                                                       "var Constructor = window[constructorName];"
                                                       "if (Constructor) {"
                                                           "var event = new Constructor(type, { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: 1, pointerType: 'mouse' });"
                                                           "target.dispatchEvent(event);"
                                                           "return;"
                                                       "}"
                                                   "} catch (error) {}"
                                                   "var mouseEvent = document.createEvent('MouseEvents');"
                                                   "mouseEvent.initMouseEvent(type, true, true, window, 1, x, y, x, y, false, false, false, false, 0, null);"
                                                   "target.dispatchEvent(mouseEvent);"
                                               "}"
                                               "var target = browserActivationTarget();"
                                               "if (!target) { return 'no-target'; }"
                                               "try { if (target.focus) { target.focus(); } } catch (error) {}"
                                               "dispatchPointerLikeEvent(target, 'pointerdown', 'PointerEvent');"
                                               "dispatchPointerLikeEvent(target, 'mousedown', 'MouseEvent');"
                                               "dispatchPointerLikeEvent(target, 'pointerup', 'PointerEvent');"
                                               "dispatchPointerLikeEvent(target, 'mouseup', 'MouseEvent');"
                                               "if (typeof target.click === 'function') { target.click(); }"
                                               "else { dispatchPointerLikeEvent(target, 'click', 'MouseEvent'); }"
                                               "return 'clicked';"];

    NSDictionary *lastVideoInfo = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:effectiveTimeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSDictionary *directVideoInfo = [self directVideoInfoAtDOMPoint:point webView:webView];
        NSString *directSrc = [directVideoInfo[@"src"] isKindOfClass:[NSString class]] ? directVideoInfo[@"src"] : @"";
        NSArray *directSources = [directVideoInfo[@"sources"] isKindOfClass:[NSArray class]] ? directVideoInfo[@"sources"] : @[];
        if (directSrc.length > 0 || directSources.count > 0) {
            return directVideoInfo;
        }

        NSDictionary *videoInfo = [self videoInfoAtDOMPoint:point webView:webView];
        if (videoInfo.count > 0) {
            lastVideoInfo = videoInfo;
            NSString *videoSrc = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
            NSArray *videoSources = [videoInfo[@"sources"] isKindOfClass:[NSArray class]] ? videoInfo[@"sources"] : @[];
            if (videoSrc.length > 0 || videoSources.count > 0) {
                return videoInfo;
            }
        }

        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    return lastVideoInfo;
}

- (NSDictionary *)JSONObjectFromJavaScriptString:(NSString *)string {
    if (string.length == 0) {
        return nil;
    }

    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    return object;
}

@end
```
