//
//  ViewController.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "BrowserContentBlockerController.h"
#import "BrowserDarkModeController.h"
#import "BrowserReaderModeController.h"
#import "BrowserMenuCoordinator.h"
#import "BrowserProbeWorkbenchViewController.h"
#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserRemoteInputController.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";

// Checks and leaves fullscreen in a single evaluation: each one of these
// pumps the run loop, and Menu is the most used button on the remote.
// tvOS WebKit may only carry the webkit-prefixed form, so both are tried.
static NSString * const kBrowserExitFullscreenScript =
    @"(function(){"
        "var element = document.fullscreenElement ||"
                      "document.webkitFullscreenElement ||"
                      "document.webkitCurrentFullScreenElement;"
        "if (!element) { return 'none'; }"
        "try {"
            "if (document.exitFullscreen) { document.exitFullscreen(); }"
            "else if (document.webkitExitFullscreen) { document.webkitExitFullscreen(); }"
            "else if (document.webkitCancelFullScreen) { document.webkitCancelFullScreen(); }"
            "else if (element.webkitExitFullscreen) { element.webkitExitFullscreen(); }"
            "else { return 'none'; }"
        "} catch (error) { return 'none'; }"
        "return 'exited';"
    "})()";

static UIColor *kTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserProbeWorkbenchDelegate, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserContentBlockerController *contentBlockerController;
@property (nonatomic) BrowserDarkModeController *darkModeController;
@property (nonatomic) BrowserReaderModeController *readerModeController;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic, nullable) BrowserProbeWorkbenchViewController *probeWorkbench;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;
@property (nonatomic, copy, nullable) NSString *lastWebContentCrashURLString;
@property (nonatomic) NSUInteger consecutiveWebContentCrashes;

@end

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.definesPresentationContext = YES;
    self.scrollViewAllowBounces = YES;

    self.preferencesStore = [BrowserPreferencesStore new];
    [self.preferencesStore ensureUserAgentConsistency];

    self.viewModel = [BrowserViewModel new];
    self.viewModel.topNavigationBarVisible = self.preferencesStore.topNavigationBarVisible;
    self.viewModel.textFontSize = self.preferencesStore.textFontSize;
    self.viewModel.fullscreenVideoPlaybackEnabled = self.preferencesStore.fullscreenVideoPlaybackEnabled;


    self.contentBlockerController = [BrowserContentBlockerController sharedController];
    [self.contentBlockerController prepareRuleListIfNeeded];

    self.darkModeController = [BrowserDarkModeController new];
    self.readerModeController = [BrowserReaderModeController new];
    self.domInteractionService = [BrowserDOMInteractionService new];
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
    [self.view addSubview:self.remoteInputController.cursorView];
    self.videoPlaybackCoordinator = [[BrowserVideoPlaybackCoordinator alloc] initWithHost:self
                                                                      domInteractionService:self.domInteractionService];
    self.tabCoordinator = [[BrowserTabCoordinator alloc] initWithHost:self
                                                             viewModel:self.viewModel
                                                      preferencesStore:self.preferencesStore
                                                     navigationService:self.navigationService
                                                          sessionStore:self.sessionStore
                                                    browserContainerView:self.browserContainerView
                                                              rootView:self.view
                                                            topMenuView:self.topMenuView
                                                            cursorView:self.remoteInputController.cursorView
                                               manualScrollPanRecognizer:self.remoteInputController.manualScrollPanRecognizer
                                                           webViewDelegate:self
                                                       scrollViewAllowBounces:self.scrollViewAllowBounces];
    self.tabOverviewController = [[BrowserTabOverviewController alloc] initWithHost:self
                                                                            viewModel:self.viewModel
                                                                             rootView:self.view
                                                                           topMenuView:self.topMenuView
                                                                           cursorView:self.remoteInputController.cursorView];
    self.pageActionCoordinator = [[BrowserPageActionCoordinator alloc] initWithHost:self
                                                               domInteractionService:self.domInteractionService
                                                                   navigationService:self.navigationService
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator
                                                                    preferencesStore:self.preferencesStore];

    self.topMenuView.delegate = self;
    self.topMenuView.loadingSpinner.hidesWhenStopped = YES;
    self.remoteInputController.cursorView.hidden = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalSelectPressEndedNotification:)
                                                 name:kBrowserGlobalSelectPressEndedNotification
                                               object:nil];

    [self.tabCoordinator restoreInitialStateOrCreateFirstTab];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tabCoordinator webViewDidAppear];
    if (!self.preferencesStore.dontShowHintsOnLaunch && !self.displayedHintsOnLaunch) {
        [self showHintsAlert];
    }
    self.displayedHintsOnLaunch = YES;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleGlobalSelectPressEndedNotification:(NSNotification *)notification {
    (void)notification;
    [self.remoteInputController handleGlobalSelectPressEndedNotification];
}

#pragma mark - Helpers

- (BrowserWebView *)webview {
    return self.tabCoordinator.activeWebView;
}

- (CGPoint)browserDOMPointForCursor {
    return [self.domInteractionService DOMPointForCursorOrigin:self.remoteInputController.cursorView.frame.origin
                                                        inView:self.view
                                                       webView:self.webview];
}

- (void)loadHomePage {
    [self.tabCoordinator loadHomePage];
}

- (void)showAdvancedMenu {
    [self deactivateTopBarFocusMode];
    [self.menuCoordinator showAdvancedMenu];
}

- (BOOL)canActivateTopBarFocusMode {
    return self.presentedViewController == nil &&
        !self.tabOverviewController.visible &&
        self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden;
}

- (void)activateTopBarFocusMode {
    if (![self canActivateTopBarFocusMode]) {
        return;
    }
    if (self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = YES;
    [self.topMenuView setFocusModeActive:YES];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)deactivateTopBarFocusMode {
    if (!self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = NO;
    [self.topMenuView setFocusModeActive:NO];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)promptExitApp {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Exit App?"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Exit"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self.tabCoordinator persistSession];
        exit(EXIT_SUCCESS);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil]];
    [self browserPresentViewController:alert];
}

- (BOOL)exitWebFullscreenIfActive {
    NSString *result = [self.webview stringByEvaluatingJavaScriptFromString:kBrowserExitFullscreenScript];
    return [result isEqualToString:@"exited"];
}

// Back acts on the tab that is showing. With no history left, the tab itself
// is what Back leaves, so it closes. On the last tab nothing happens: the
// Apple TV home button is the way out, and quitting has its own button now.
- (void)performBackNavigationOrCloseTab {
    if (self.webview.canGoBack) {
        [self.webview goBack];
        return;
    }
    if (self.viewModel.tabs.count > 1) {
        [self.tabCoordinator closeTabAtIndex:self.viewModel.activeTabIndex];
    }
}

// The anchor is read before the bar loses focus, because deactivating focus
// can change the bar's layout.
- (void)presentBarMenuForAction:(BrowserTopBarAction)action {
    CGFloat anchorCenterX = [self.topMenuView screenCenterXForAction:action];
    [self deactivateTopBarFocusMode];
    switch (action) {
        case BrowserTopBarActionBookmarks:
            [self.menuCoordinator showBookmarksMenuAnchoredAt:anchorCenterX];
            break;
        case BrowserTopBarActionReading:
            [self.menuCoordinator showReadingMenuAnchoredAt:anchorCenterX];
            break;
        case BrowserTopBarActionPrivacy:
            [self.menuCoordinator showPrivacyMenuAnchoredAt:anchorCenterX];
            break;
        case BrowserTopBarActionSettings:
            [self.menuCoordinator showSettingsMenuAnchoredAt:anchorCenterX];
            break;
        default:
            break;
    }
}

- (void)performTopBarAction:(BrowserTopBarAction)action {
    [self deactivateTopBarFocusMode];

    switch (action) {
        case BrowserTopBarActionBack:
            if ([self exitWebFullscreenIfActive]) {
                break;
            }
            [self performBackNavigationOrCloseTab];
            break;
        case BrowserTopBarActionExit:
            [self promptExitApp];
            break;
        case BrowserTopBarActionRefresh:
            [self.webview reload];
            break;
        case BrowserTopBarActionForward:
            if (self.webview.canGoForward) {
                [self.webview goForward];
            }
            break;
        case BrowserTopBarActionHome:
            [self loadHomePage];
            break;
        case BrowserTopBarActionTabs:
            [self browserShowTabOverview];
            break;
        case BrowserTopBarActionURL:
            [self showInputURLorSearchGoogle];
            break;
        case BrowserTopBarActionFullscreen:
            if (self.viewModel.topNavigationBarVisible) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Hide Top Navigation bar?"
                                                                                         message:@"You can still open the side menu by double-tapping the Play/Pause button."
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Hide Bar"
                                                                    style:UIAlertActionStyleDestructive
                                                                  handler:^(__unused UIAlertAction *action) {
                    [self browserHideTopNav];
                }]];
                [self browserPresentViewController:alertController];
            } else {
                [self browserShowTopNav];
            }
            break;
        case BrowserTopBarActionMenu:
            [self showAdvancedMenu];
            break;
        case BrowserTopBarActionBookmarks:
        case BrowserTopBarActionReading:
        case BrowserTopBarActionPrivacy:
        case BrowserTopBarActionSettings:
            [self presentBarMenuForAction:action];
            break;
    }
}

- (void)updateTextFontSize {
    if (self.webview == nil) {
        return;
    }

    // This used to walk every element in the document, calling
    // getComputedStyle on each and writing an inline font-size. On a heavy
    // page that is tens of thousands of forced layout passes inside a
    // synchronous evaluation, and it ran on every load even at 100%. It is
    // one stylesheet now: WebKit's own text-size-adjust does the scaling.
    NSUInteger size = self.viewModel.textFontSize;
    NSString *jsString = [[NSString alloc] initWithFormat:
                          @"(function(){"
                           "var value='%lu%%';"
                           "var el = document.getElementById('browser-text-scale');"
                           "if (!el) {"
                               "if (!document.head) { return 'no-head'; }"
                               "el = document.createElement('style');"
                               "el.id = 'browser-text-scale';"
                               "document.head.appendChild(el);"
                           "}"
                           "el.textContent = 'html,body{-webkit-text-size-adjust:' + value + ' !important;"
                           "text-size-adjust:' + value + ' !important;}';"
                           "return value;"
                          "})()",
                          (unsigned long)size];
    [self.webview stringByEvaluatingJavaScriptFromString:jsString];
}

- (void)showInputURLorSearchGoogle {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Enter URL or Search Terms"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeURL;
        textField.placeholder = @"Enter URL or Search Terms";
        textField.textColor = kTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];

    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Search Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForQuery:textField.text];
        if (searchRequest != nil) {
            [weakSelf.webview loadRequest:searchRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Go To Website"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        if (textField.text.length == 0) {
            [weakSelf requestURLorSearchInput];
            return;
        }
        NSURLRequest *navigationRequest = [weakSelf.navigationService requestForEnteredAddressString:textField.text];
        if (navigationRequest != nil) {
            [weakSelf.webview loadRequest:navigationRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];

    UITextField *textField = alertController.textFields.firstObject;
    if (self.webview.request == nil || self.webview.request.URL.absoluteString.length > 0) {
        [textField becomeFirstResponder];
    }
}

- (void)requestURLorSearchInput {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Quick Menu"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    if (self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Go Forward"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self.webview goForward];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"Input URL or Search with Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showInputURLorSearchGoogle];
    }]];

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            self.tabCoordinator.previousURL = @"";
            [self.webview reload];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)showHintsAlert {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Usage Guide"
                                                                             message:@"Double press the touch area to switch between cursor & scroll mode.\nLightly tap the touch area while in cursor mode to click or open links in the current tab.\nPress and hold the click for half a second on a link to open it in a new tab.\nSingle tap the Menu button to Go Back, or to close the tab at the start of its history.\nUse the power icon at the left of the top bar to quit.\nSingle tap the Play/Pause button to: Go Forward, Enter URL or Reload Page.\nDouble tap the Play/Pause to show the Advanced Menu with more options.\nUse the tabs icon in the top bar to open the tab overview."
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    if (self.preferencesStore.dontShowHintsOnLaunch) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Always Show On Launch"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = NO;
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Don't Show This Again"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = YES;
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"Dismiss"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)browserHandlePrimaryActionWithSource:(BrowserPageActivationSource)source {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        return;
    }

    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    if (point.y < 0) {
        [self activateTopBarFocusMode];
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview source:source];
}

// Presenting or dismissing changes whether the cursor should be on screen
// and whether the web view should take input, so both ends refresh.
- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    [super presentViewController:viewControllerToPresent animated:animated completion:^{
        [self.remoteInputController refreshInteractionState];
        if (completion != nil) {
            completion();
        }
    }];
    [self.remoteInputController refreshInteractionState];
}

- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    [super dismissViewControllerAnimated:animated completion:^{
        [self.remoteInputController refreshInteractionState];
        if (completion != nil) {
            completion();
        }
    }];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.topBarFocusActive) {
        UIView *preferredFocusItem = [self.topMenuView preferredFocusItem];
        if (preferredFocusItem != nil) {
            return @[preferredFocusItem];
        }
    }
    return [super preferredFocusEnvironments];
}

#pragma mark - BrowserTopBarViewDelegate

- (void)browserTopBarView:(__unused BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action {
    [self performTopBarAction:action];
}

#pragma mark - BrowserMenuCoordinatorHost

- (BrowserWebView *)browserWebView {
    return self.webview;
}

- (NSString *)browserPreviousURL {
    return self.tabCoordinator.previousURL;
}

- (void)setBrowserPreviousURL:(NSString *)browserPreviousURL {
    self.tabCoordinator.previousURL = browserPreviousURL ?: @"";
}

- (NSUInteger)browserTextFontSize {
    return self.viewModel.textFontSize;
}

- (void)setBrowserTextFontSize:(NSUInteger)browserTextFontSize {
    self.viewModel.textFontSize = browserTextFontSize;
    self.preferencesStore.textFontSize = self.viewModel.textFontSize;
}

- (BOOL)browserTopMenuShowing {
    return self.viewModel.topNavigationBarVisible;
}

- (BOOL)browserFullscreenVideoPlaybackEnabled {
    return self.viewModel.fullscreenVideoPlaybackEnabled;
}

- (void)setBrowserFullscreenVideoPlaybackEnabled:(BOOL)browserFullscreenVideoPlaybackEnabled {
    self.viewModel.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
    self.preferencesStore.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
}

- (void)browserPresentViewController:(UIViewController *)viewController {
    [self deactivateTopBarFocusMode];
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserLoadHomePage {
    [self loadHomePage];
}

- (void)browserShowHints {
    [self showHintsAlert];
}

- (void)browserShowTabOverview {
    [self deactivateTopBarFocusMode];
    [self.tabCoordinator prepareTabOverviewThumbnails];
    [self.tabOverviewController show];
}

- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserHideTopNav {
    [self deactivateTopBarFocusMode];
    self.viewModel.topNavigationBarVisible = NO;
    self.preferencesStore.topNavigationBarVisible = NO;
    [self.tabCoordinator setTopNavigationVisible:NO];
}

- (void)browserShowTopNav {
    self.viewModel.topNavigationBarVisible = YES;
    self.preferencesStore.topNavigationBarVisible = YES;
    [self.tabCoordinator setTopNavigationVisible:YES];
}

- (void)browserUpdateTextFontSize {
    [self updateTextFontSize];
}

#pragma mark - Probe Workbench

// A report that fills the screen hides the page it describes. The workbench
// narrows the page instead and keeps the controls beside it, so a setting is
// seen taking effect on the real thing. Anything that proves itself here earns
// a place in the ordinary menus.
- (void)browserShowProbeWorkbench {
    if (self.probeWorkbench != nil) {
        return;
    }

    BrowserProbeWorkbenchViewController *workbench =
        [[BrowserProbeWorkbenchViewController alloc] initWithSections:[self workbenchSections]];
    workbench.workbenchDelegate = self;
    self.probeWorkbench = workbench;

    [self addChildViewController:workbench];
    workbench.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:workbench.view];
    [NSLayoutConstraint activateConstraints:@[
        [workbench.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [workbench.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [workbench.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [workbench.view.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.34],
    ]];
    [workbench didMoveToParentViewController:self];

    [self.view layoutIfNeeded];
    self.tabCoordinator.webViewLeadingInset = CGRectGetWidth(self.view.bounds) * 0.34;
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)probeWorkbenchDidRequestClose:(BrowserProbeWorkbenchViewController *)workbench {
    if (workbench != self.probeWorkbench) {
        return;
    }
    [workbench willMoveToParentViewController:nil];
    [workbench.view removeFromSuperview];
    [workbench removeFromParentViewController];
    self.probeWorkbench = nil;
    self.tabCoordinator.webViewLeadingInset = 0.0;
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)refreshWorkbenchRows {
    [self.probeWorkbench setSections:[self workbenchSections]];
}

- (NSString *)workbenchEvaluate:(NSString *)script fallback:(NSString *)fallback {
    NSString *value = [self.webview stringByEvaluatingJavaScriptFromString:script];
    return value.length > 0 ? value : fallback;
}

- (NSArray<BrowserWorkbenchSection *> *)workbenchSections {
    __weak typeof(self) weakSelf = self;

    BrowserWorkbenchSection *measure = [BrowserWorkbenchSection sectionWithTitle:@"측정" items:@[
        [BrowserWorkbenchItem itemWithTitle:@"페이지 프로세스 상태" action:^NSString *{
            BrowserWebView *webView = weakSelf.webview;
            NSString *alive = [weakSelf workbenchEvaluate:@"'alive'" fallback:@""];
            return [NSString stringWithFormat:@"프로세스: %@\n누적 사망: %lu회",
                    alive.length > 0 ? @"살아있음" : @"응답 없음",
                    (unsigned long)webView.webContentTerminationCount];
        }],
        [BrowserWorkbenchItem itemWithTitle:@"엔진 재생 능력" action:^NSString *{
            NSString *script =
                @"(function(){var v=document.createElement('video');"
                 "function c(t){try{return v.canPlayType(t)||'no';}catch(e){return 'err';}}"
                 "return 'MSE: '+((typeof MediaSource!=='undefined')?'yes':'no')"
                 "+'\\nHLS: '+c('application/vnd.apple.mpegurl')"
                 "+'\\nMP4: '+c('video/mp4');})()";
            return [weakSelf workbenchEvaluate:script fallback:@"읽을 수 없음 (프로세스 없음)"];
        }],
        [BrowserWorkbenchItem itemWithTitle:@"페이지 크기 (무게)" action:^NSString *{
            NSString *script =
                @"(function(){try{var n=document.getElementsByTagName('*').length;"
                 "var f=document.getElementsByTagName('iframe').length;"
                 "var i=document.images.length;"
                 "return '요소 '+n+'개\\n프레임 '+f+'개 · 이미지 '+i+'개'"
                 "+((n>12000)?'\\n※ 매우 무거움':'');}catch(e){return 'err';}})()";
            return [weakSelf workbenchEvaluate:script fallback:@"읽을 수 없음 (프로세스 없음)"];
        }],
        [BrowserWorkbenchItem itemWithTitle:@"현재 User Agent" action:^NSString *{
            NSString *agent = [weakSelf.webview currentUserAgent] ?: @"(없음)";
            NSString *mode = weakSelf.preferencesStore.mobileModeEnabled ? @"모바일" : @"데스크톱";
            NSUInteger tail = MIN((NSUInteger)60, agent.length);
            return [NSString stringWithFormat:@"%@\n…%@", mode,
                    [agent substringFromIndex:agent.length - tail]];
        }],
    ]];

    NSUInteger zoom = self.preferencesStore.pageZoomPercent;
    BOOL reader = [self browserIsReaderModeActive];
    BOOL dark = self.preferencesStore.forcedDarkModeEnabled;
    BOOL blocking = self.preferencesStore.contentBlockingEnabled;
    BOOL mobile = self.preferencesStore.mobileModeEnabled;

    BrowserWorkbenchSection *apply = [BrowserWorkbenchSection sectionWithTitle:@"이 페이지에 적용" items:@[
        [BrowserWorkbenchItem itemWithTitle:[NSString stringWithFormat:@"확대 키우기  (지금 %lu%%)", (unsigned long)zoom]
                                     action:^NSString *{
            weakSelf.preferencesStore.pageZoomPercent = weakSelf.preferencesStore.pageZoomPercent + 10;
            [weakSelf applyReadingZoom];
            [weakSelf refreshWorkbenchRows];
            return [NSString stringWithFormat:@"확대 %lu%%", (unsigned long)weakSelf.preferencesStore.pageZoomPercent];
        }],
        [BrowserWorkbenchItem itemWithTitle:[NSString stringWithFormat:@"확대 줄이기  (지금 %lu%%)", (unsigned long)zoom]
                                     action:^NSString *{
            NSUInteger current = weakSelf.preferencesStore.pageZoomPercent;
            weakSelf.preferencesStore.pageZoomPercent = current > 10 ? current - 10 : current;
            [weakSelf applyReadingZoom];
            [weakSelf refreshWorkbenchRows];
            return [NSString stringWithFormat:@"확대 %lu%%", (unsigned long)weakSelf.preferencesStore.pageZoomPercent];
        }],
        [BrowserWorkbenchItem itemWithTitle:@"확대 100%로 되돌리기" action:^NSString *{
            weakSelf.preferencesStore.pageZoomPercent = 100;
            [weakSelf applyReadingZoom];
            [weakSelf refreshWorkbenchRows];
            return @"확대 100%";
        }],
        [BrowserWorkbenchItem itemWithTitle:reader ? @"읽기 모드 끄기" : @"읽기 모드 켜기"
                                     action:^NSString *{
            [weakSelf browserToggleReaderMode];
            [weakSelf refreshWorkbenchRows];
            return [weakSelf browserIsReaderModeActive] ? @"읽기 모드 켜짐" : @"읽기 모드 꺼짐";
        }],
        [BrowserWorkbenchItem itemWithTitle:blocking ? @"광고 차단 끄기" : @"광고 차단 켜기"
                                     action:^NSString *{
            BOOL next = !weakSelf.preferencesStore.contentBlockingEnabled;
            weakSelf.preferencesStore.contentBlockingEnabled = next;
            [[BrowserContentBlockerController sharedController] applyContentBlockingToWebView:weakSelf.webview
                                                                                      enabled:next];
            [weakSelf refreshWorkbenchRows];
            return next ? @"광고 차단 켜짐\n(새로고침하면 완전히 적용)" : @"광고 차단 꺼짐\n(새로고침하면 완전히 적용)";
        }],
        [BrowserWorkbenchItem itemWithTitle:dark ? @"다크 모드 끄기" : @"다크 모드 켜기"
                                     action:^NSString *{
            BOOL next = !weakSelf.preferencesStore.forcedDarkModeEnabled;
            weakSelf.preferencesStore.forcedDarkModeEnabled = next;
            [weakSelf browserUpdateForcedDarkMode];
            [weakSelf refreshWorkbenchRows];
            return next ? @"다크 모드 켜짐" : @"다크 모드 꺼짐";
        }],
        [BrowserWorkbenchItem itemWithTitle:mobile ? @"데스크톱 화면으로 전환" : @"모바일 화면으로 전환"
                                     action:^NSString *{
            BOOL nextMobile = !weakSelf.preferencesStore.mobileModeEnabled;
            weakSelf.preferencesStore.mobileModeEnabled = nextMobile;
            weakSelf.preferencesStore.userAgent = nextMobile ? BrowserPreferencesStore.mobileUserAgent
                                                             : BrowserPreferencesStore.desktopUserAgent;
            [weakSelf.webview setUserAgent:weakSelf.preferencesStore.userAgent];
            [weakSelf.webview reload];
            [weakSelf refreshWorkbenchRows];
            return nextMobile ? @"모바일로 다시 불러오는 중" : @"데스크톱으로 다시 불러오는 중";
        }],
    ]];

    BrowserWorkbenchSection *recover = [BrowserWorkbenchSection sectionWithTitle:@"복구" items:@[
        [BrowserWorkbenchItem itemWithTitle:@"새로고침" action:^NSString *{
            [weakSelf.webview reload];
            return @"다시 불러오는 중";
        }],
        [BrowserWorkbenchItem itemWithTitle:@"페이지 프로세스 재시작" action:^NSString *{
            BOOL ok = [weakSelf.webview restartWebContentProcess];
            return ok ? @"프로세스를 내렸습니다.\n새로고침하십시오." : @"재시작을 지원하지 않습니다.";
        }],
    ]];

    return @[measure, apply, recover];
}

- (void)browserUpdateForcedDarkMode {
    BOOL enabled = self.preferencesStore.forcedDarkModeEnabled;
    [self.darkModeController syncDarkModeState:enabled forWebView:self.webview];
}

- (void)browserCaptureSnapshotForCurrentTab {
    [self.tabCoordinator captureSnapshotForCurrentTab];
}

- (void)browserRecreateActiveWebViewPreservingCurrentURL {
    [self.tabCoordinator recreateActiveWebViewPreservingCurrentURL];
}

- (void)browserBringCursorToFront {
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];
}

- (void)browserPlayVideoUnderCursorIfAvailable {
    [self.videoPlaybackCoordinator playVideoUnderCursorIfAvailable];
}

- (BOOL)browserIsReaderModeActive {
    return [self.readerModeController isReaderModeActiveForWebView:self.webview];
}

- (void)browserToggleReaderMode {
    if ([self.readerModeController isReaderModeActiveForWebView:self.webview]) {
        [self.readerModeController disableReaderModeForWebView:self.webview];
    } else {
        NSString *result = [self.readerModeController enableReaderModeForWebView:self.webview
                                                                      fontSize:self.preferencesStore.readerFontSize];
        if (![result hasPrefix:@"success"]) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reader Mode"
                                                                           message:@"Could not find enough readable content on this page."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }
}

#pragma mark - BrowserVideoPlaybackCoordinatorHost

- (BOOL)browserIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (CGPoint)browserDOMCursorPoint {
    return [self browserDOMPointForCursor];
}

- (UIViewController *)browserPresentedViewController {
    return self.presentedViewController;
}

- (NSString *)browserCurrentPageTitle {
    return self.webview.title;
}

- (void)browserSetFullscreenVideoPlaybackEnabled:(BOOL)enabled {
    [self setBrowserFullscreenVideoPlaybackEnabled:enabled];
}

#pragma mark - BrowserTabCoordinatorHost

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (void)browserTabCoordinatorUpdateTextFontSize {
    [self applyReadingZoom];
    [self updateTextFontSize];
}

- (void)applyReadingZoom {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return;
    }
    webView.userPageZoom = (CGFloat)self.preferencesStore.pageZoomPercent / 100.0;
    [webView applyPageScalingIfNeeded];
}

- (void)browserApplyReadingZoom {
    [self applyReadingZoom];
}

- (BOOL)browserTabCoordinatorIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (BOOL)browserTabCoordinatorIsTabOverviewVisible {
    return self.tabOverviewController.visible;
}

#pragma mark - BrowserTabOverviewControllerHost

- (BOOL)browserTabOverviewControllerCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (void)browserTabOverviewControllerSetCursorModeEnabled:(BOOL)enabled {
    [self.remoteInputController setCursorModeEnabled:enabled];
}

- (void)browserTabOverviewControllerPresentViewController:(UIViewController *)viewController {
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserTabOverviewControllerCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserTabOverviewControllerSwitchToTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator switchToTabAtIndex:tabIndex];
    [self.darkModeController syncDarkModeState:self.preferencesStore.forcedDarkModeEnabled
                                    forWebView:self.webview];
}

- (void)browserTabOverviewControllerCloseTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator closeTabAtIndex:tabIndex];
}

#pragma mark - BrowserPageActionCoordinatorHost

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request {
    return [self.tabCoordinator createNewTabWithRequest:request];
}

#pragma mark - BrowserRemoteInputControllerHost

- (UIScrollView *)browserRemoteInputControllerActiveScrollView {
    return self.webview.scrollView;
}

- (UIViewController *)browserRemoteInputControllerPresentedViewController {
    return self.presentedViewController;
}

- (BOOL)browserRemoteInputControllerTopBarFocusActive {
    return self.topBarFocusActive;
}

- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus {
    return [self canActivateTopBarFocusMode];
}

- (void)browserRemoteInputControllerActivateTopBarFocus {
    [self activateTopBarFocusMode];
}

- (void)browserRemoteInputControllerDeactivateTopBarFocus {
    [self deactivateTopBarFocusMode];
}

- (BOOL)browserRemoteInputControllerTabOverviewVisible {
    return self.tabOverviewController.visible;
}

- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point {
    return [self.tabOverviewController containsPoint:point];
}

- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point {
    return [self.tabOverviewController handleSelectionAtPoint:point];
}

- (void)browserRemoteInputControllerDismissTabOverview {
    [self.tabOverviewController dismiss];
}

- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction {
    [self.tabOverviewController handleAlternateAction];
}

- (void)browserRemoteInputControllerHandlePrimaryActionWithSource:(BrowserPageActivationSource)source {
    [self browserHandlePrimaryActionWithSource:source];
}

- (void)browserRemoteInputControllerHandleMenuPress {
    if (self.presentedViewController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if ([self exitWebFullscreenIfActive]) {
        return;
    }
    [self performBackNavigationOrCloseTab];
}

- (void)browserRemoteInputControllerHandlePlayPausePress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self requestURLorSearchInput];
    }
}

- (void)browserRemoteInputControllerHandleAdvancedMenuPress {
    [self showAdvancedMenu];
}

- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point {
    if (self.webview.request == nil) {
        return @"false";
    }
    CGPoint webPoint = [self.view convertPoint:point toView:self.webview];
    if (webPoint.y < 0) {
        return @"false";
    }
    CGPoint domPoint = [self browserDOMPointForCursor];
    return [self.pageActionCoordinator hoverStateAtDOMPoint:domPoint webView:self.webview];
}

- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled {
    self.webview.userInteractionEnabled = enabled;
}

- (void)browserRemoteInputControllerPersistSession {
    [self.tabCoordinator persistSession];
}

- (BOOL)browserRemoteInputControllerScrollActiveContainerByDelta:(CGPoint)delta atCursorPoint:(CGPoint)cursorPoint {
    if (self.webview == nil) {
        return NO;
    }
    CGPoint domPoint = [self.domInteractionService DOMPointForCursorOrigin:cursorPoint
                                                                    inView:self.view
                                                                   webView:self.webview];
    CGPoint clampedDOMPoint = CGPointMake(MAX(0.0, domPoint.x), MAX(0.0, domPoint.y));
    return [self.domInteractionService scrollActiveContainerByX:delta.x
                                                              y:delta.y
                                                        atPoint:clampedDOMPoint
                                                        webView:self.webview];
}

- (BOOL)browserRemoteInputControllerJSScrollFallbackEnabled {
    return self.preferencesStore.jsScrollFallbackEnabled;
}

- (BOOL)browserRemoteInputControllerDpadScrollEnabled {
    return self.preferencesStore.dpadScrollEnabled;
}

- (BOOL)browserRemoteInputControllerEdgeAutoScrollEnabled {
    return self.preferencesStore.edgeAutoScrollEnabled;
}

- (BOOL)browserRemoteInputControllerTapToClickEnabled {
    return self.preferencesStore.tapToClickEnabled;
}

- (void)browserRemoteInputControllerGoBack {
    if ([self exitWebFullscreenIfActive]) {
        return;
    }
    [self performBackNavigationOrCloseTab];
}

- (void)browserRemoteInputControllerGoForward {
    if (self.webview.canGoForward) {
        [self.webview goForward];
    }
}

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    return [self.tabCoordinator createNewTabWithRequest:request];
}

// Hosts whose desktop build is heavy enough to take the web content process
// down on this hardware. The phone agent gets a far lighter page.
- (BOOL)isHeavyHost:(NSString *)host {
    NSString *lowercaseHost = host.lowercaseString ?: @"";
    for (NSString *heavy in @[@"youtube.com", @"youtu.be"]) {
        if ([lowercaseHost isEqualToString:heavy] ||
            [lowercaseHost hasSuffix:[@"." stringByAppendingString:heavy]]) {
            return YES;
        }
    }
    return NO;
}

// The agent applies to the next load, not the one being decided, so this
// cancels and re-issues once. The agent check keeps that from repeating.
- (BOOL)lightenRequestIfNeeded:(NSURLRequest *)request webView:(id)webView {
    if (!self.preferencesStore.lightenHeavySitesEnabled ||
        ![webView isKindOfClass:[BrowserWebView class]] ||
        ![self isHeavyHost:request.URL.host]) {
        return NO;
    }

    BrowserWebView *browserWebView = (BrowserWebView *)webView;
    NSString *mobileAgent = BrowserPreferencesStore.mobileUserAgent;
    if ([browserWebView.currentUserAgent isEqualToString:mobileAgent]) {
        return NO;
    }

    [browserWebView setUserAgent:mobileAgent];
    NSURLRequest *retry = [request copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [browserWebView loadRequest:retry];
    });
    return YES;
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)navigationType;
    if ([self lightenRequestIfNeeded:request webView:webView]) {
        return NO;
    }
    [self.tabCoordinator prepareTabForRequest:request webView:webView];
    return YES;
}

- (void)webViewDidStartLoad:(id)webView {
    [self.tabCoordinator webViewDidStartLoad:webView];
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    if ([webView isKindOfClass:[BrowserWebView class]]) {
        if (self.preferencesStore.forcedDarkModeEnabled) {
            [self.darkModeController syncDarkModeState:YES forWebView:(BrowserWebView *)webView];
        }
        if (self.preferencesStore.contentBlockingEnabled) {
            BrowserWebView *targetWebView = (BrowserWebView *)webView;
            [[BrowserContentBlockerController sharedController] applyContentBlockingToWebView:targetWebView enabled:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[BrowserContentBlockerController sharedController] applyContentBlockingToWebView:targetWebView enabled:YES];
            });
        }
    }
    if (self.tabOverviewController.visible) {
        BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
        NSInteger tabIndex = tab != nil ? [self.viewModel.tabs indexOfObject:tab] : NSNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.tabOverviewController.visible) {
                return;
            }
            if (tabIndex != NSNotFound) {
                [self.tabOverviewController updateCardAtIndex:tabIndex];
            } else {
                [self.tabOverviewController reload];
            }
        });
    }
}

// A dead content process shows as a blank page with no script running, which
// is what the probe caught on YouTube: evaluation returned nothing at all.
// One reload covers a transient death; a second on the same page means the
// page is too heavy for this device, and the mobile site is the way out.
- (void)browserWebViewWebContentProcessDidTerminate:(BrowserWebView *)webView {
    NSString *urlString = webView.request.URL.absoluteString ?: @"";

    if ([urlString isEqualToString:self.lastWebContentCrashURLString]) {
        self.consecutiveWebContentCrashes += 1;
    } else {
        self.lastWebContentCrashURLString = urlString;
        self.consecutiveWebContentCrashes = 1;
    }

    if (webView != self.webview) {
        return;
    }

    if (self.consecutiveWebContentCrashes <= 1) {
        [webView reload];
        return;
    }

    NSString *host = webView.request.URL.host ?: urlString;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"This Page Keeps Crashing"
                         message:[NSString stringWithFormat:
                                  @"%@ stopped its web process twice in a row, which leaves the "
                                  @"page blank. Deaths so far: %lu.\n\n"
                                  @"Reader mode strips the page down to its text and is the "
                                  @"most reliable way to read a site that keeps crashing.",
                                  host, (unsigned long)webView.webContentTerminationCount]
                  preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    if (!self.preferencesStore.mobileModeEnabled) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Switch to Mobile and Reload"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.mobileModeEnabled = YES;
            weakSelf.preferencesStore.userAgent = BrowserPreferencesStore.mobileUserAgent;
            weakSelf.consecutiveWebContentCrashes = 0;
            [weakSelf.tabCoordinator recreateActiveWebViewPreservingCurrentURL];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Reload"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        weakSelf.consecutiveWebContentCrashes = 0;
        [weakSelf.webview reload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Leave It" style:UIAlertActionStyleCancel handler:nil]];
    [self browserPresentViewController:alert];
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
    BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSURL *failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    NSURLRequest *currentRequest = [webView request];
    NSString *currentRequestURLString = currentRequest.URL.absoluteString ?: @"";
    if (failingURL != nil &&
        currentRequestURLString.length > 0 &&
        ![failingURL.absoluteString isEqualToString:currentRequestURLString]) {
        return;
    }

    if (tab == self.tabCoordinator.activeTab) {
        [self.topMenuView.loadingSpinner stopAnimating];
    }
    if (tab != self.tabCoordinator.activeTab) {
        return;
    }
    if ([self.navigationService shouldIgnoreLoadError:error]) {
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Could Not Load Webpage"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Google This Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            if (searchRequest != nil) {
                [weakSelf.webview loadRequest:searchRequest];
            }
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Enter a URL or Search"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf requestURLorSearchInput];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Presses / Touches

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesBegan:presses withEvent:event];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if ([self.remoteInputController handlePressesEnded:presses withEvent:event]) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesCancelled:presses withEvent:event];
    [super pressesCancelled:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesBegan:touches withEvent:event]) {
        return;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesMoved:touches withEvent:event]) {
        return;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesCancelled];
    [super touchesCancelled:touches withEvent:event];
}

@end
