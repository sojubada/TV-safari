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
#import "BrowserDiagnosticsLog.h"
#import "BrowserDOMInteractionService.h"
#import "BrowserHardwareKeyboardController.h"
#import "BrowserNavigationService.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserRemoteInputController.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
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

/// A view that exists only to be focused. It sits just under the bar, so a
/// downward swipe while the bar has focus has somewhere to go — the focus
/// engine owns the touch surface at that moment, and a plain touch handler
/// never sees the gesture at all.
@interface BrowserFocusEscapeView : UIView
@property (nonatomic) BOOL focusAllowed;
@end

@implementation BrowserFocusEscapeView
- (BOOL)canBecomeFocused {
    return self.focusAllowed;
}
@end

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate,
    BrowserHardwareKeyboardControllerDelegate>

@property (nonatomic) BrowserContentBlockerController *contentBlockerController;
@property (nonatomic) BrowserDarkModeController *darkModeController;
@property (nonatomic) BrowserReaderModeController *readerModeController;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserHardwareKeyboardController *hardwareKeyboardController;
/// Where the field being typed into lives, so each keystroke lands in the
/// same element.
@property (nonatomic) CGPoint hardwareTypingDOMPoint;
@property (nonatomic, weak) BrowserWebView *hardwareTypingWebView;
@property (nonatomic, nullable) UILabel *inputModeLabel;
/// Shows what is being typed, with the syllable still being built underlined.
/// The page's own field cannot carry that mark, and without it there is no
/// way to tell a finished 가 from a 가 that is still waiting for a 받침.
@property (nonatomic, nullable) UIView *typingBarView;
@property (nonatomic, nullable) UILabel *typingLanguageLabel;
@property (nonatomic, nullable) UILabel *typingTextLabel;
/// Gives a keyboard that has never answered a moment to do so before the
/// remote dialog takes over.
@property (nonatomic, nullable) NSTimer *typingProofTimer;
/// Writing into the page is held back a moment between keystrokes. Each write
/// runs JavaScript synchronously, which pumps the run loop, and doing that on
/// every letter of a heavy page is enough to take its web process down.
@property (nonatomic, nullable) NSTimer *typingFlushTimer;
@property (nonatomic, copy, nullable) NSString *pendingTypingText;
/// The address the field being typed into belongs to. A page that has moved
/// on since is a different page, and text left over from the old one must not
/// be written into whatever now sits at that spot.
@property (nonatomic, copy, nullable) NSString *typingPageURLString;
@property (nonatomic, nullable) BrowserFocusEscapeView *focusEscapeView;
/// Hidden by scrolling down, which is separate from the person switching the
/// bar off for good.
@property (nonatomic) BOOL topBarHiddenByScrolling;
@property (nonatomic) CGFloat topBarScrollAccumulator;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;
@property (nonatomic) BOOL topBarFocusPendingRestore;
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


    self.contentBlockerController = [BrowserContentBlockerController sharedController];
    [self.contentBlockerController prepareRuleListIfNeeded];

    self.darkModeController = [BrowserDarkModeController new];
    self.readerModeController = [BrowserReaderModeController new];
    self.domInteractionService = [BrowserDOMInteractionService new];
    [[BrowserDiagnosticsLog sharedLog] logSessionStart];
    self.hardwareKeyboardController = [BrowserHardwareKeyboardController new];
    self.hardwareKeyboardController.delegate = self;
    [self.hardwareKeyboardController prepareForKeyboardDetection];
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
    BrowserFocusEscapeView *escapeView = [[BrowserFocusEscapeView alloc] initWithFrame:CGRectZero];
    escapeView.backgroundColor = UIColor.clearColor;
    escapeView.focusAllowed = NO;
    [self.view addSubview:escapeView];
    self.focusEscapeView = escapeView;
    [self.view addSubview:self.remoteInputController.cursorView];
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
                                                                    preferencesStore:self.preferencesStore];

    self.tabCoordinator.pageLayoutWidth = (CGFloat)self.preferencesStore.pageLayoutWidth;
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
    [[BrowserDiagnosticsLog sharedLog] logEvent:@"app" detail:@"resign-active"];
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    // A launch line with one of these before it is the person leaving. A
    // launch line with nothing before it is the app being taken.
    [[BrowserDiagnosticsLog sharedLog] logEvent:@"app" detail:@"background"];
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
    self.focusEscapeView.focusAllowed = YES;
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
    self.focusEscapeView.focusAllowed = NO;
    [self.remoteInputController noteTopBarFocusDeactivated];
    [self.topMenuView setFocusModeActive:NO];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

// The exit button is its own button at the far left of the bar, so pressing
// it is already the decision. A confirmation would only add a second press.
- (void)promptExitApp {
    [self.tabCoordinator persistSession];
    exit(EXIT_SUCCESS);
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

    // One stylesheet carries every reading adjustment. This used to walk each
    // element in the document calling getComputedStyle, which is what killed
    // heavy pages; selector matching is WebKit's own work and costs nothing.
    //
    // Weight matters as much as size. News sites set body text in thin faces
    // that hold up on a phone at arm's length and wash out at three metres,
    // where a television's pixels are too coarse to carry the stroke.
    // Enlarging thin text only makes it large and faint.
    NSMutableString *css = [NSMutableString string];
    [css appendFormat:@"html,body{-webkit-text-size-adjust:%lu%%!important;"
                       "text-size-adjust:%lu%%!important;}",
                      (unsigned long)self.viewModel.textFontSize,
                      (unsigned long)self.viewModel.textFontSize];

    if (self.preferencesStore.boldTextEnabled) {
        [css appendString:
            @"html body,html body p,html body li,html body td,html body dd,"
             "html body span,html body div,html body a,html body figcaption"
             "{font-weight:600!important;}"
             "html body h1,html body h2,html body h3,html body h4,"
             "html body b,html body strong{font-weight:800!important;}"
             "html body p,html body li{line-height:1.65!important;}"];
    }

    // The rules carry no quotes, backslashes or newlines, so they drop into a
    // JavaScript string literal as they are.
    NSString *jsString = [NSString stringWithFormat:
                          @"(function(){"
                           "var el=document.getElementById('browser-text-scale');"
                           "if(!el){"
                               "if(!document.head){return 'no-head';}"
                               "el=document.createElement('style');"
                               "el.id='browser-text-scale';"
                               "document.head.appendChild(el);"
                           "}"
                           "el.textContent='%@';"
                           "return 'ok';"
                          "})()", css];
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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Directly under the bar and the full width of it, so "down" out of any
    // icon lands here.
    CGFloat top = CGRectGetMaxY(self.topMenuView.frame);
    self.focusEscapeView.frame = CGRectMake(0.0,
                                            top,
                                            CGRectGetWidth(self.view.bounds),
                                            MAX(120.0, CGRectGetHeight(self.view.bounds) - top));
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context
       withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    if (context.nextFocusedView != self.focusEscapeView || self.focusEscapeView == nil) {
        return;
    }
    // Focus arrived at the patch below the bar, which only happens on a swipe
    // down out of the bar. Leaving focus mode runs a focus update of its own,
    // so it waits until this one has finished.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf deactivateTopBarFocusMode];
    });
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

- (void)browserRemoteInputControllerDidScrollVertically:(CGFloat)deltaY {
    if (!self.viewModel.topNavigationBarVisible || self.topBarFocusActive) {
        return;
    }
    // Direction changes reset the run, so the bar reacts to a deliberate
    // scroll rather than to the wobble of a finger on the touch surface.
    if ((deltaY > 0.0) != (self.topBarScrollAccumulator > 0.0)) {
        self.topBarScrollAccumulator = 0.0;
    }
    self.topBarScrollAccumulator += deltaY;

    if (!self.topBarHiddenByScrolling && self.topBarScrollAccumulator > 160.0) {
        [self setTopBarHiddenByScrolling:YES];
    } else if (self.topBarHiddenByScrolling && self.topBarScrollAccumulator < -80.0) {
        [self setTopBarHiddenByScrolling:NO];
    }
}

- (BOOL)browserRemoteInputControllerRevealTopBarIfHidden {
    if (!self.topBarHiddenByScrolling) {
        return NO;
    }
    [self setTopBarHiddenByScrolling:NO];
    return YES;
}

- (void)setTopBarHiddenByScrolling:(BOOL)hidden {
    if (_topBarHiddenByScrolling == hidden) {
        return;
    }
    _topBarHiddenByScrolling = hidden;
    self.topBarScrollAccumulator = 0.0;

    CGFloat offset = CGRectGetHeight(self.topMenuView.frame) + 12.0;
    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.topMenuView.transform = hidden ? CGAffineTransformMakeTranslation(0.0, -offset)
                                            : CGAffineTransformIdentity;
        self.topMenuView.alpha = hidden ? 0.0 : 1.0;
    } completion:nil];
}

- (CGFloat)browserRemoteInputControllerTopBarBottomEdge {
    if (!self.viewModel.topNavigationBarVisible || self.topMenuView.hidden ||
        self.topBarHiddenByScrolling) {
        return 0.0;
    }
    return CGRectGetMaxY(self.topMenuView.frame);
}

- (BOOL)browserRemoteInputControllerRestoreTopBarFocusIfPending {
    if (!self.topBarFocusPendingRestore) {
        return NO;
    }
    self.topBarFocusPendingRestore = NO;
    if (![self canActivateTopBarFocusMode]) {
        return NO;
    }
    [self activateTopBarFocusMode];
    return YES;
}

- (void)browserRemoteInputControllerCancelPendingTopBarFocusRestore {
    self.topBarFocusPendingRestore = NO;
}

- (void)browserPresentViewController:(UIViewController *)viewController {
    // A menu opened from the bar has to take focus, so the bar gives it up.
    // Remember that it had it, or closing the menu leaves the remote owning
    // nothing: arrow presses fall through to page history instead of moving
    // between the icons the person was just using.
    self.topBarFocusPendingRestore = self.topBarFocusActive;
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

- (void)browserUpdateForcedDarkMode {
    BOOL enabled = self.preferencesStore.forcedDarkModeEnabled;
    // Applying this only to the visible tab left the others as they were
    // until you switched to one, which looked like the setting had not taken.
    for (BrowserWebView *webView in [self.tabCoordinator allLoadedWebViews]) {
        [self.darkModeController syncDarkModeState:enabled forWebView:webView];
    }
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
    [webView setMinimumFontSize:(CGFloat)self.preferencesStore.minimumFontSize];
    [webView applyPageScalingIfNeeded];
}

- (void)browserReloadActivePage {
    [self.webview reload];
}

- (void)browserApplyPageLayoutWidth {
    self.tabCoordinator.pageLayoutWidth = (CGFloat)self.preferencesStore.pageLayoutWidth;
}

// Naver's print view is not a popup, it is a URL: the same article with
// "print/" inserted before the publisher and article numbers. It is the text
// on a white page with no navigation, no ranking column and no advertising.
//
// The path comes in more than one shape — /article/214/0001531015 and
// /mnews/article/214/0001531015 both occur, and both take the print form —
// so the "article" segment is located wherever it sits rather than assumed
// to be first, and whatever precedes it is carried over.
- (BOOL)browserOpenPrintableArticle {
    NSURL *URL = self.webview.request.URL;
    NSString *host = URL.host.lowercaseString ?: @"";
    // Matching a bare suffix would also accept evilnews.naver.com.
    BOOL isNaverNews = [host isEqualToString:@"news.naver.com"] ||
                       [host hasSuffix:@".news.naver.com"];
    if (!isNaverNews) {
        return NO;
    }

    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *segment in [(URL.path ?: @"") componentsSeparatedByString:@"/"]) {
        if (segment.length > 0) {
            [segments addObject:segment];
        }
    }

    NSUInteger articleIndex = [segments indexOfObject:@"article"];
    if (articleIndex == NSNotFound || segments.count < articleIndex + 3) {
        return NO;
    }

    NSString *oid = segments[articleIndex + 1];
    NSString *aid = segments[articleIndex + 2];
    if ([oid isEqualToString:@"print"]) {
        return NO;   // already the print view
    }

    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    if (oid.length == 0 || aid.length == 0 ||
        [oid rangeOfCharacterFromSet:nonDigits].location != NSNotFound ||
        [aid rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        return NO;
    }

    NSMutableArray<NSString *> *printSegments =
        [[segments subarrayWithRange:NSMakeRange(0, articleIndex + 1)] mutableCopy];
    [printSegments addObjectsFromArray:@[@"print", oid, aid]];

    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    components.host = URL.host;
    components.path = [@"/" stringByAppendingString:[printSegments componentsJoinedByString:@"/"]];

    NSURL *printURL = components.URL;
    if (printURL == nil) {
        return NO;
    }
    [self.webview loadRequest:[NSURLRequest requestWithURL:printURL]];
    return YES;
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

#pragma mark - Hardware keyboard

- (NSString *)browserPageActionCoordinatorKeyboardDetectionSummary {
    return [self.hardwareKeyboardController detectionSummary];
}

- (BOOL)browserPageActionCoordinatorBeginHardwareTypingAtDOMPoint:(CGPoint)point
                                                          webView:(BrowserWebView *)webView
                                                     existingText:(NSString *)existingText {
    if (webView == nil) {
        return NO;
    }
    if (![self.hardwareKeyboardController beginCaptureWithExistingText:existingText]) {
        return NO;
    }

    self.hardwareTypingDOMPoint = point;
    self.hardwareTypingWebView = webView;
    self.typingPageURLString = webView.request.URL.absoluteString ?: @"";

    // The element has to hold the caret itself, or the page will not show what
    // is being typed and will not react to it.
    [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                 webView:webView
                                                                    body:@"var target = browserEditableTarget();"
                                                                         "if (!target) { return 'false'; }"
                                                                         "if (target.focus) { target.focus(); }"
                                                                         "return 'true';"];
    [self showTypingBarWithText:existingText];

    // A keyboard that has already answered once needs no proving.
    if (!self.hardwareKeyboardController.isKeyboardProven) {
        self.typingProofTimer = [NSTimer scheduledTimerWithTimeInterval:2.5
                                                                 target:self
                                                               selector:@selector(handleTypingProofTimeout)
                                                               userInfo:nil
                                                                repeats:NO];
    }
    return YES;
}

#pragma mark - Typing bar

- (void)showTypingBarWithText:(NSString *)text {
    if (self.typingBarView == nil) {
        UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.94];
        bar.layer.cornerRadius = 22.0;
        bar.userInteractionEnabled = NO;

        UILabel *language = [[UILabel alloc] initWithFrame:CGRectZero];
        language.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBold];
        language.textColor = [UIColor colorWithRed:0.45 green:0.76 blue:1.0 alpha:1.0];
        language.textAlignment = NSTextAlignmentCenter;
        [bar addSubview:language];

        UILabel *body = [[UILabel alloc] initWithFrame:CGRectZero];
        body.font = [UIFont systemFontOfSize:36.0 weight:UIFontWeightRegular];
        body.textColor = UIColor.whiteColor;
        [bar addSubview:body];

        [self.view addSubview:bar];
        self.typingBarView = bar;
        self.typingLanguageLabel = language;
        self.typingTextLabel = body;
    }

    CGFloat width = MIN(1400.0, CGRectGetWidth(self.view.bounds) - 160.0);
    CGFloat height = 96.0;
    self.typingBarView.frame = CGRectMake(floor((CGRectGetWidth(self.view.bounds) - width) / 2.0),
                                          CGRectGetHeight(self.view.bounds) - height - 80.0,
                                          width,
                                          height);
    self.typingLanguageLabel.frame = CGRectMake(24.0, 0.0, 110.0, height);
    self.typingTextLabel.frame = CGRectMake(146.0, 0.0, width - 170.0, height);
    [self.view bringSubviewToFront:self.typingBarView];
    self.typingBarView.hidden = NO;
    self.typingBarView.alpha = 1.0;
    [self updateTypingBarWithText:text ?: @""];
}

- (void)hideTypingBar {
    self.typingBarView.hidden = YES;
}

- (void)updateTypingBarWithText:(NSString *)text {
    self.typingLanguageLabel.text = self.hardwareKeyboardController.isKoreanInputActive ? @"한" : @"EN";

    NSString *composing = self.hardwareKeyboardController.composingText ?: @"";
    NSMutableAttributedString *attributed =
        [[NSMutableAttributedString alloc] initWithString:text.length > 0 ? text : @" "];
    // The composing syllable is the tail of the text, so it is marked from the
    // end rather than tracked as a separate position.
    if (composing.length > 0 && text.length >= composing.length) {
        NSRange range = NSMakeRange(text.length - composing.length, composing.length);
        [attributed addAttribute:NSUnderlineStyleAttributeName
                           value:@(NSUnderlineStyleSingle)
                           range:range];
        [attributed addAttribute:NSForegroundColorAttributeName
                           value:[UIColor colorWithRed:1.0 green:0.86 blue:0.45 alpha:1.0]
                           range:range];
    }
    self.typingTextLabel.attributedText = attributed;
}

- (void)endHardwareTypingSession {
    [self.typingProofTimer invalidate];
    self.typingProofTimer = nil;
    [self flushPendingTypingText];
    self.typingPageURLString = nil;
    [self.hardwareKeyboardController endCapture];
    self.hardwareTypingWebView = nil;
    [self hideTypingBar];
}

// Nothing was typed, so there is no keyboard listening and the remote dialog
// is the only way into this field.
- (void)handleTypingProofTimeout {
    self.typingProofTimer = nil;
    if (!self.hardwareKeyboardController.isCapturing) {
        return;
    }
    CGPoint point = self.hardwareTypingDOMPoint;
    BrowserWebView *webView = self.hardwareTypingWebView;
    [self endHardwareTypingSession];
    if (webView != nil) {
        [self.pageActionCoordinator presentEditableFieldPromptAtDOMPoint:point webView:webView];
    }
}

- (void)hardwareKeyboardController:(BrowserHardwareKeyboardController *)controller
                     didChangeText:(NSString *)text {
    (void)controller;
    // A keystroke arrived, so the keyboard has proved itself and the dialog
    // is not needed.
    [self.typingProofTimer invalidate];
    self.typingProofTimer = nil;
    [self updateTypingBarWithText:text];

    if (self.hardwareTypingWebView == nil) {
        return;
    }
    self.pendingTypingText = text;
    [self.typingFlushTimer invalidate];
    self.typingFlushTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                             target:self
                                                           selector:@selector(flushPendingTypingText)
                                                           userInfo:nil
                                                            repeats:NO];
}

- (void)flushPendingTypingText {
    [self.typingFlushTimer invalidate];
    self.typingFlushTimer = nil;

    NSString *text = self.pendingTypingText;
    self.pendingTypingText = nil;
    BrowserWebView *webView = self.hardwareTypingWebView;
    if (text == nil || webView == nil) {
        return;
    }
    // Submitting a search navigates, and the next click would otherwise flush
    // the old query into whatever field now sits at the same spot — which on a
    // results page is the search box, so the address itself got searched for.
    NSString *currentURLString = webView.request.URL.absoluteString ?: @"";
    if (self.typingPageURLString != nil &&
        ![currentURLString isEqualToString:self.typingPageURLString]) {
        [[BrowserDiagnosticsLog sharedLog] logEvent:@"typing-drop"
                                             detail:@"page changed under the field"];
        return;
    }
    NSString *escaped = [self.domInteractionService javaScriptEscapedString:text];
    [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:self.hardwareTypingDOMPoint
                                                                 webView:webView
                                                                    body:[NSString stringWithFormat:
                                                                          @"var target = browserEditableTarget();"
                                                                          "if (!target) { return 'false'; }"
                                                                          "if (typeof target.value !== 'undefined') {"
                                                                              "target.value = '%@';"
                                                                              "if (target.setSelectionRange) {"
                                                                                  "try { target.setSelectionRange(target.value.length, target.value.length); } catch (error) {}"
                                                                              "}"
                                                                          "} else {"
                                                                              "target.textContent = '%@';"
                                                                          "}"
                                                                          "if (target.dispatchEvent) {"
                                                                              "target.dispatchEvent(new Event('input', { bubbles: true }));"
                                                                          "}"
                                                                          "return 'true';", escaped, escaped]];
}

- (void)hardwareKeyboardControllerDidSubmit:(BrowserHardwareKeyboardController *)controller {
    (void)controller;
    [self flushPendingTypingText];
    BrowserWebView *webView = self.hardwareTypingWebView;
    if (webView == nil) {
        return;
    }
    [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:self.hardwareTypingDOMPoint
                                                                 webView:webView
                                                                    body:@"var target = browserEditableTarget();"
                                                                         "if (!target) { return 'false'; }"
                                                                         "if (target.dispatchEvent) {"
                                                                             "target.dispatchEvent(new Event('change', { bubbles: true }));"
                                                                         "}"
                                                                         "var form = target.form;"
                                                                         "try {"
                                                                             "var options = { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true };"
                                                                             "var accepted = !target.dispatchEvent(new KeyboardEvent('keydown', options));"
                                                                             "target.dispatchEvent(new KeyboardEvent('keypress', options));"
                                                                             "target.dispatchEvent(new KeyboardEvent('keyup', options));"
                                                                             "if (accepted) { return 'true'; }"
                                                                         "} catch (error) {}"
                                                                         "if (form) {"
                                                                             "var submitter = form.querySelector('button[type=\"submit\"], input[type=\"submit\"], button:not([type])');"
                                                                             "if (submitter) { submitter.click(); return 'true'; }"
                                                                             "if (form.requestSubmit) { form.requestSubmit(); return 'true'; }"
                                                                             "form.submit();"
                                                                         "}"
                                                                         "return 'true';"];
    [self endHardwareTypingSession];
}

- (void)hardwareKeyboardControllerDidCancel:(BrowserHardwareKeyboardController *)controller {
    (void)controller;
    [self endHardwareTypingSession];
}

- (void)hardwareKeyboardController:(BrowserHardwareKeyboardController *)controller
              didChangeKoreanInput:(BOOL)koreanInput {
    (void)controller;
    [self.typingProofTimer invalidate];
    self.typingProofTimer = nil;
    self.typingLanguageLabel.text = koreanInput ? @"한" : @"EN";
    [self showInputModeNotice:koreanInput ? @"한글" : @"English"];
}

// A keyboard carries no sign of which language it is typing, so the app says
// so for a moment when it changes.
- (void)showInputModeNotice:(NSString *)text {
    if (self.inputModeLabel == nil) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:34.0 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
        label.layer.cornerRadius = 18.0;
        label.layer.masksToBounds = YES;
        label.userInteractionEnabled = NO;
        [self.view addSubview:label];
        self.inputModeLabel = label;
    }

    UILabel *label = self.inputModeLabel;
    label.text = text;
    CGFloat width = 240.0;
    CGFloat height = 72.0;
    label.frame = CGRectMake(floor((CGRectGetWidth(self.view.bounds) - width) / 2.0),
                             CGRectGetHeight(self.view.bounds) - height - 90.0,
                             width,
                             height);
    [self.view bringSubviewToFront:label];
    label.alpha = 1.0;
    [UIView animateWithDuration:0.3
                          delay:1.1
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        label.alpha = 0.0;
    } completion:nil];
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

- (BOOL)browserRemoteInputControllerHandleHardwareKeyPress:(UIPress *)press {
    return [self.hardwareKeyboardController handleKeyPress:press];
}

- (BOOL)browserRemoteInputControllerFocusNavigationActive {
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
    // A click lands somewhere new, so whatever field was being typed into is
    // finished with. If the click is on another field, typing starts again a
    // moment later with that one.
    [self endHardwareTypingSession];
    [self browserHandlePrimaryActionWithSource:source];
}

- (void)browserRemoteInputControllerHandleMenuPress {
    if (self.hardwareKeyboardController.isCapturing) {
        [self endHardwareTypingSession];
        return;
    }
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

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // The log simply stops when the system takes the app for memory, so the
    // warnings leading up to it are the only sign of what happened.
    [[BrowserDiagnosticsLog sharedLog]
        logEvent:@"MEMORY-WARNING"
          detail:[NSString stringWithFormat:@"tabs=%lu  %@",
                  (unsigned long)self.viewModel.tabs.count,
                  self.webview.request.URL.absoluteString ?: @""]];
}

- (void)webViewDidStartLoad:(id)webView {
    // Anything typed belonged to the page being left.
    self.pendingTypingText = nil;
    [[BrowserDiagnosticsLog sharedLog] logEvent:@"load"
                                         detail:[(BrowserWebView *)webView request].URL.absoluteString];
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
    [[BrowserDiagnosticsLog sharedLog]
        logEvent:@"CRASH"
          detail:[NSString stringWithFormat:@"deaths=%lu  consecutive=%lu  %@",
                  (unsigned long)webView.webContentTerminationCount,
                  (unsigned long)(self.consecutiveWebContentCrashes + 1),
                  urlString]];

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
    [[BrowserDiagnosticsLog sharedLog]
        logEvent:@"load-fail"
          detail:[NSString stringWithFormat:@"%ld %@  %@",
                  (long)error.code, error.localizedDescription ?: @"",
                  [(BrowserWebView *)webView request].URL.absoluteString ?: @""]];
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
