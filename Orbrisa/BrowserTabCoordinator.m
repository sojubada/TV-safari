#import "BrowserTabCoordinator.h"
#import "BrowserLocalization.h"
#import "BrowserLog.h"

#import "BrowserNavigationService.h"
#import "BrowserPreferencesStore.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTopBarView.h"
#import "BrowserViewModel.h"
#import "BrowserWebView.h"

#import <TVServices/TVServices.h>

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
        // No black screen at start: paint the area behind the page in the last page's colour right away.
        browserContainerView.backgroundColor = [self lastPageEdgeColor];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleForceDarkPagesDidChange:)
                                                     name:BrowserForceDarkPagesDidChangeNotification
                                                   object:nil];
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

- (void)updateTopNavAndWebView {
    if (self.activeWebView == nil) {
        return;
    }
    // The web view always fills the screen and the glass bar floats on top of the page.
    // A top content inset keeps the start of the page clear of the bar; scrolled content passes underneath it.
    self.activeWebView.frame = self.rootView.bounds;

    UIScrollView *scrollView = self.activeWebView.scrollView;
    if (scrollView == nil) {
        return;
    }
    if (scrollView.backgroundColor == nil || CGColorGetAlpha(scrollView.backgroundColor.CGColor) < 0.01) {
        scrollView.backgroundColor = self.browserContainerView.backgroundColor;
    }
    CGFloat topInset = self.topNavigationVisible ? self.topMenuBrowserOffset : 0.0;
    if (scrollView.contentInset.top == topInset) {
        return;
    }
    BOOL wasAtTop = scrollView.contentOffset.y <= 0.0;
    UIEdgeInsets insets = UIEdgeInsetsMake(topInset, 0.0, 0.0, 0.0);
    scrollView.contentInset = insets;
    scrollView.verticalScrollIndicatorInsets = insets;
    if (wasAtTop) {
        scrollView.contentOffset = CGPointMake(scrollView.contentOffset.x, -topInset);
    }
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
    webView.backgroundColor = UIColor.clearColor;

    UIScrollView *scrollView = webView.scrollView;
    scrollView.layoutMargins = UIEdgeInsetsZero;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scrollView.contentOffset = CGPointZero;
    scrollView.contentInset = UIEdgeInsetsZero;
    scrollView.clipsToBounds = NO;
    scrollView.backgroundColor = UIColor.clearColor;
    scrollView.bounces = self.scrollViewAllowBounces;
    [scrollView.panGestureRecognizer addTarget:self action:@selector(handleWebViewPanGesture:)];
    scrollView.scrollEnabled = NO;

    BOOL shouldScalePagesToFit = self.preferencesStore.scalePagesToFit;
    webView.scalesPageToFit = shouldScalePagesToFit;
    webView.contentMode = shouldScalePagesToFit ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleToFill;
    webView.userInteractionEnabled = NO;

    // Start with the colour of the last page seen, so there is no black band while the first page loads.
    UIColor *edgeColor = [self lastPageEdgeColor];
    [webView setPageEdgeColor:edgeColor];
    self.browserContainerView.backgroundColor = edgeColor;
    [self.topMenuView setPageIsLight:[self colorIsLight:edgeColor] animated:NO];
    return webView;
}

- (void)handleForceDarkPagesDidChange:(NSNotification *)notification {
    (void)notification;
    // Let the page restyle first, then match the bar and the strip above the page to it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateChromeBackgroundFromActiveWebView];
    });
}

#pragma mark - Remembered page colour

static NSString * const kBrowserLastPageEdgeColorKey = @"BrowserLastPageEdgeColor";

- (UIColor *)lastPageEdgeColor {
    NSArray<NSNumber *> *components = [[NSUserDefaults standardUserDefaults] arrayForKey:kBrowserLastPageEdgeColorKey];
    if (components.count != 3) {
        return UIColor.whiteColor; // most pages are light
    }
    return [UIColor colorWithRed:components[0].doubleValue
                           green:components[1].doubleValue
                            blue:components[2].doubleValue
                           alpha:1.0];
}

- (void)rememberPageEdgeColor:(UIColor *)color {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:@[@(red), @(green), @(blue)] forKey:kBrowserLastPageEdgeColorKey];
}

- (BOOL)colorIsLight:(UIColor *)color {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return YES;
    }
    return ((0.2126 * red) + (0.7152 * green) + (0.0722 * blue)) > 0.5;
}

- (void)refreshActiveTabUI {
    BrowserTabViewModel *tab = self.activeTab;
    [self.topMenuView setTabCount:self.viewModel.tabs.count];
    if (tab == nil) {
        [self.topMenuView setPageTitle:nil URLString:nil];
        [self.topMenuView setCanGoBack:NO canGoForward:NO];
        return;
    }

    NSURLRequest *request = self.activeWebView.request;
    NSString *currentURL = tab.URLString.length > 0 ? tab.URLString : request.URL.absoluteString;
    [self.topMenuView setPageTitle:tab.title URLString:currentURL];
    [self.topMenuView setCanGoBack:self.activeWebView.canGoBack canGoForward:self.activeWebView.canGoForward];

    if (request != nil) {
        [self.host browserTabCoordinatorUpdateTextFontSize];
        [self updateChromeBackgroundFromActiveWebView];
    }
}

#pragma mark - Strip behind the top bar

// The web view starts below the top bar, so the strip behind the glass islands shows the container view.
// Give that strip the page's own background colour so the bar floats on the page instead of on a black band.
- (void)updateChromeBackgroundFromActiveWebView {
    BrowserWebView *webView = self.activeWebView;
    if (webView == nil) {
        return;
    }

    // Read the colour actually visible at the top of the page: the first element there (or one of its
    // parents) with a background. Pages like Google in dark mode paint nothing themselves and rely on the
    // browser's dark default, so a page that asks for dark colours counts as dark.
    NSString *script = @"(function(){"
        "if(document.getElementById('__tvForceDarkStyle')){return 'rgb(26, 26, 26)';}"
        "function bg(e){while(e&&e.nodeType===1){var v=getComputedStyle(e).backgroundColor;"
        "if(v&&v!=='transparent'&&v!=='rgba(0, 0, 0, 0)'){return v;}e=e.parentElement;}return '';}"
        "var probe=document.elementFromPoint(Math.max(1,innerWidth/2),Math.max(1,Math.min(innerHeight-1,40)));"
        "var c=bg(probe)||bg(document.body)||bg(document.documentElement);"
        "if(c){return c;}"
        "var meta=document.querySelector('meta[name=\"color-scheme\"]');"
        "var scheme=(getComputedStyle(document.documentElement).colorScheme||'')+' '+(meta?meta.content:'');"
        "if(scheme.indexOf('dark')>=0&&window.matchMedia&&matchMedia('(prefers-color-scheme: dark)').matches){return 'rgb(31, 31, 31)';}"
        "return 'rgb(255, 255, 255)';"
        "})()";
    NSString *value = [webView stringByEvaluatingJavaScriptFromString:script];
    UIColor *color = [self colorFromCSSColorString:value];
    if (color != nil) {
        self.browserContainerView.backgroundColor = color;
        // The space above the page (under the floating bar) belongs to the web view's scroll view.
        [webView setPageEdgeColor:color];

        [self.topMenuView setPageIsLight:[self colorIsLight:color] animated:YES];
        [self rememberPageEdgeColor:color];
    }
}

- (UIColor *)colorFromCSSColorString:(NSString *)string {
    NSString *trimmed = [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trimmed.lowercaseString hasPrefix:@"rgb"]) {
        return nil;
    }

    NSRegularExpression *numberPattern = [NSRegularExpression regularExpressionWithPattern:@"[0-9]*\\.?[0-9]+" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [numberPattern matchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    if (matches.count < 3) {
        return nil;
    }

    CGFloat components[4] = {0.0, 0.0, 0.0, 1.0};
    for (NSUInteger index = 0; index < MIN(matches.count, (NSUInteger)4); index++) {
        components[index] = [[trimmed substringWithRange:matches[index].range] doubleValue];
    }
    if (components[3] < 0.05) {
        return nil;
    }

    return [UIColor colorWithRed:MIN(components[0], 255.0) / 255.0
                           green:MIN(components[1], 255.0) / 255.0
                            blue:MIN(components[2], 255.0) / 255.0
                           alpha:1.0];
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
        CGFloat minOffsetY = -scrollView.contentInset.top;
        CGFloat maxOffsetY = MAX(minOffsetY, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds) + scrollView.contentInset.bottom);
        // A saved offset of 0 (or less) means "top of the page", which sits below the bar.
        CGFloat targetOffsetY = savedScrollOffset.y <= 0.0 ? minOffsetY : savedScrollOffset.y;
        CGPoint clampedScrollOffset = CGPointMake(MIN(MAX(savedScrollOffset.x, 0.0), maxOffsetX),
                                                  MIN(MAX(targetOffsetY, minOffsetY), maxOffsetY));
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
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Maximum Tabs Reached")
                                                                             message:BrowserLocalized(@"Orbrisa keeps up to five tabs open at once.")
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Dismiss")
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
    // The site's logo for the tab strip: the largest PNG/ICO icon the page names, else /favicon.ico.
    NSString *iconURL = [webView stringByEvaluatingJavaScriptFromString:
                         @"(function(){ var best = '', size = -1;"
                          "document.querySelectorAll('link[rel~=\"icon\"], link[rel=\"apple-touch-icon\"], link[rel=\"apple-touch-icon-precomposed\"]').forEach(function(l){"
                          "  var href = l.href || ''; if (!href || /\\.svg(\\?|#|$)/i.test(href) || /^data:image\\/svg/i.test(href)) { return; }"
                          "  var m = /(\\d+)x(\\d+)/.exec(l.getAttribute('sizes') || ''); var s = m ? +m[1] : (/apple-touch/.test(l.rel) ? 180 : 32);"
                          "  if (s > 512) { s = 100; }"
                          "  if (s > size) { size = s; best = href; }"
                          "});"
                          "return best || (location.protocol.indexOf('http') === 0 ? location.origin + '/favicon.ico' : ''); })()"];
    if (iconURL.length > 0) {
        tab.iconURLString = iconURL;
    }

    if (tab == self.activeTab) {
        [self refreshActiveTabUI];
    } else if ([self isWebViewStaged:webView]) {
        [webView pauseAllMediaPlayback];
    }
    BOOL restoringScrollPosition = tab.needsScrollRestore && tab.hasSavedScrollOffset;
    [self restoreSavedScrollOffsetForTab:tab webView:webView];
    if (!restoringScrollPosition && tab == self.activeTab) {
        [self alignPageTopBelowBarInWebView:webView];
    }
    if (!tab.needsScrollRestore) {
        [self captureSnapshotForTab:tab];
        [self persistSession];
    }
}

- (void)webViewDidCommitNavigation:(id)webView {
    if ([self tabForWebView:webView] == self.activeTab) {
        [self alignPageTopBelowBarInWebView:webView];
    }
}

// A freshly loaded page is scrolled to 0 by WebKit, which puts its first lines under the floating bar.
// Move it down so it starts just below the bar.
- (void)alignPageTopBelowBarInWebView:(BrowserWebView *)webView {
    UIScrollView *scrollView = webView.scrollView;
    if (scrollView == nil) {
        return;
    }
    CGFloat topInset = scrollView.contentInset.top;
    if (topInset <= 0.0) {
        return;
    }
    if (scrollView.contentOffset.y > -topInset + 0.5 && scrollView.contentOffset.y <= 2.0) {
        [scrollView setContentOffset:CGPointMake(scrollView.contentOffset.x, -topInset) animated:NO];
    }
}


#pragma mark - Top Shelf

/// The shared App Group (group.<bundle id>), written into Info.plist at build time.
#define kBrowserAppGroup ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"OrbrisaAppGroup"] ?: @"")
static NSString * const kBrowserTopShelfKey = @"TopShelf";

static NSData *BrowserTopShelfJPEG(UIImage *image) {
    if (image == nil || image.size.width < 1.0 || image.size.height < 1.0) {
        return nil;
    }
    // 16:9 crop from the top of the page, 960 × 540 – what the Top Shelf shows.
    CGSize target = CGSizeMake(960.0, 540.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIImage *scaled = [[[UIGraphicsImageRenderer alloc] initWithSize:target format:format] imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        CGFloat scale = MAX(target.width / image.size.width, target.height / image.size.height);
        CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
        [image drawInRect:CGRectMake((target.width - drawn.width) / 2.0, 0.0, drawn.width, drawn.height)];
    }];
    return UIImageJPEGRepresentation(scaled, 0.8);
}

/// A tile for a favorite without a picture: the site's first letter and name on the Orbrisa blue.
static NSData *BrowserTopShelfTile(NSString *title, NSString *host) {
    CGSize size = CGSizeMake(960.0, 540.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIImage *tile = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(__bridge id)[UIColor colorWithRed:0.10 green:0.36 blue:0.85 alpha:1.0].CGColor,
                            (__bridge id)[UIColor colorWithRed:0.03 green:0.10 blue:0.30 alpha:1.0].CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero, CGPointMake(size.width, size.height), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);

        NSString *name = host.length > 0 ? host : title;
        if ([name hasPrefix:@"www."]) {
            name = [name substringFromIndex:4];
        }
        NSString *letter = name.length > 0 ? [[name substringToIndex:1] uppercaseString] : @"•";
        NSDictionary *letterAttributes = @{NSFontAttributeName: [UIFont systemFontOfSize:220.0 weight:UIFontWeightBold],
                                           NSForegroundColorAttributeName: UIColor.whiteColor};
        CGSize letterSize = [letter sizeWithAttributes:letterAttributes];
        [letter drawAtPoint:CGPointMake((size.width - letterSize.width) / 2.0, 90.0) withAttributes:letterAttributes];

        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.alignment = NSTextAlignmentCenter;
        paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary *nameAttributes = @{NSFontAttributeName: [UIFont systemFontOfSize:44.0 weight:UIFontWeightSemibold],
                                         NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.85],
                                         NSParagraphStyleAttributeName: paragraph};
        [name drawInRect:CGRectMake(40.0, 400.0, size.width - 80.0, 60.0) withAttributes:nameAttributes];
    }];
    return UIImageJPEGRepresentation(tile, 0.85);
}

- (void)updateTopShelf {
    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:kBrowserAppGroup];
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:kBrowserAppGroup];
    if (container == nil || shared == nil) {
        BrowserLog(@"[TopShelf] app group %@ not available", kBrowserAppGroup);
        return;
    }
    [self captureSnapshotForTab:self.activeTab];

    NSURL *folder = [container URLByAppendingPathComponent:@"TopShelf" isDirectory:YES];
    NSFileManager *files = [NSFileManager defaultManager];
    [files removeItemAtURL:folder error:nil];
    [files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *stamp = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970];

    // Open tabs, the active one first.
    NSMutableArray<BrowserTabViewModel *> *orderedTabs = [self.viewModel.tabs mutableCopy];
    BrowserTabViewModel *active = self.activeTab;
    if (active != nil && [orderedTabs containsObject:active]) {
        [orderedTabs removeObject:active];
        [orderedTabs insertObject:active atIndex:0];
    }
    NSMutableDictionary<NSString *, NSString *> *imageByHost = [NSMutableDictionary dictionary];
    NSMutableArray *tabEntries = [NSMutableArray array];
    for (BrowserTabViewModel *tab in orderedTabs) {
        NSString *URLString = tab.URLString.length > 0 ? tab.URLString : tab.requestURL;
        if (URLString.length == 0 || [URLString hasPrefix:@"about:"]) {
            continue;
        }
        NSUInteger index = [self.viewModel.tabs indexOfObject:tab];
        NSMutableDictionary *entry = [@{@"url": URLString, @"title": tab.title ?: @"", @"index": @(index)} mutableCopy];
        NSData *jpeg = BrowserTopShelfJPEG(tab.snapshotImage);
        NSString *host = [NSURL URLWithString:URLString].host ?: @"";
        if (jpeg == nil) {
            jpeg = BrowserTopShelfTile(tab.title, host);
        }
        NSString *name = [NSString stringWithFormat:@"tab-%lu-%@.jpg", (unsigned long)tabEntries.count, stamp];
        if ([jpeg writeToURL:[folder URLByAppendingPathComponent:name] atomically:YES]) {
            entry[@"image"] = name;
            if (host.length > 0 && tab.snapshotImage != nil && imageByHost[host] == nil) {
                imageByHost[host] = name;
            }
        }
        [tabEntries addObject:entry];
    }

    // Favorites: stored by the menu as [URL, name] pairs.
    NSMutableArray *favoriteEntries = [NSMutableArray array];
    for (id favorite in [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"]) {
        if (![favorite isKindOfClass:[NSArray class]] || [favorite count] < 1 || ![favorite[0] isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *URLString = favorite[0];
        NSString *title = ([favorite count] > 1 && [favorite[1] isKindOfClass:[NSString class]]) ? favorite[1] : @"";
        NSString *host = [NSURL URLWithString:URLString].host ?: @"";
        NSMutableDictionary *entry = [@{@"url": URLString, @"title": title} mutableCopy];
        NSString *name = imageByHost[host];
        if (name == nil) {
            name = [NSString stringWithFormat:@"fav-%lu-%@.jpg", (unsigned long)favoriteEntries.count, stamp];
            if (![BrowserTopShelfTile(title, host) writeToURL:[folder URLByAppendingPathComponent:name] atomically:YES]) {
                name = nil;
            }
        }
        if (name != nil) {
            entry[@"image"] = name;
        }
        [favoriteEntries addObject:entry];
    }

    [shared setObject:@{@"tabs": tabEntries, @"favorites": favoriteEntries} forKey:kBrowserTopShelfKey];
    [shared synchronize];
    [TVTopShelfContentProvider topShelfContentDidChange];
    BrowserLog(@"[TopShelf] updated: %lu tabs, %lu favorites", (unsigned long)tabEntries.count, (unsigned long)favoriteEntries.count);
}

- (void)openAppURL:(NSURL *)URL {
    if (URL == nil || ![URL.scheme.lowercaseString isEqualToString:@"orbrisa"]) {
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    NSString *target = nil;
    NSInteger index = -1;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"url"]) {
            target = item.value;
        } else if ([item.name isEqualToString:@"index"]) {
            index = item.value.integerValue;
        }
    }
    if (target.length == 0) {
        return;
    }
    BrowserLog(@"[TopShelf] open %@ %@", URL.host, target);

    // A tab from the shelf: the same tab if it is still there, else any tab showing that page.
    if ([URL.host isEqualToString:@"tab"] || [URL.host isEqualToString:@"favorite"]) {
        if ([URL.host isEqualToString:@"tab"] && index >= 0 && index < (NSInteger)self.viewModel.tabs.count) {
            BrowserTabViewModel *tab = self.viewModel.tabs[index];
            NSString *URLString = tab.URLString.length > 0 ? tab.URLString : tab.requestURL;
            if ([URLString isEqualToString:target]) {
                [self switchToTabAtIndex:index];
                return;
            }
        }
        NSUInteger position = 0;
        for (BrowserTabViewModel *tab in self.viewModel.tabs) {
            NSString *URLString = tab.URLString.length > 0 ? tab.URLString : tab.requestURL;
            if ([URLString isEqualToString:target]) {
                [self switchToTabAtIndex:(NSInteger)position];
                return;
            }
            position += 1;
        }
    }
    NSURLRequest *request = [self.navigationService requestForURLString:target];
    if (request != nil) {
        [self createNewTabWithRequest:request];
    }
}

@end
