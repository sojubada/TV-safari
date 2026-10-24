# tvOS Browser v4.1.0 — 호스트·메뉴 (5-2, 5-4 검토 대상)

프린트 화면과 메뉴 구성이 들어 있습니다.

> 검토 지침은 `REVIEW_v4.1.0.md`를 먼저 읽어 주십시오.

## `ViewController.h`  (21줄)

```objc
//
//  ViewController.h
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import <UIKit/UIKit.h>
#import <GameKit/GameKit.h>

#import "BrowserWebView.h"
#import "BrowserTopBarView.h"

@interface ViewController : GCEventViewController <UIScrollViewDelegate, BrowserWebViewDelegate>

@property (nonatomic, retain) IBOutlet BrowserTopBarView *topMenuView;
@property (nonatomic, retain) IBOutlet UIView *browserContainerView;

@end
```

## `ViewController.m`  (1158줄)

```objc
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
#import "BrowserDOMInteractionService.h"
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

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate>

@property (nonatomic) BrowserContentBlockerController *contentBlockerController;
@property (nonatomic) BrowserDarkModeController *darkModeController;
@property (nonatomic) BrowserReaderModeController *readerModeController;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
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
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
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
// "print/" after "article/". It is the article text on a white page with no
// navigation, no ranking column and no advertising — the cleanest reading of
// a news page this browser can get, and it costs one string substitution.
- (BOOL)browserOpenPrintableArticle {
    NSURL *URL = self.webview.request.URL;
    NSString *path = URL.path ?: @"";
    if (![URL.host hasSuffix:@"news.naver.com"] || [path hasPrefix:@"/article/print/"]) {
        return NO;
    }

    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    // "", "article", oid, aid
    if (parts.count < 4 || ![parts[1] isEqualToString:@"article"]) {
        return NO;
    }
    NSString *oid = parts[2];
    NSString *aid = parts[3];
    if (oid.length == 0 || aid.length == 0) {
        return NO;
    }

    NSString *printString = [NSString stringWithFormat:@"https://n.news.naver.com/article/print/%@/%@", oid, aid];
    NSURL *printURL = [NSURL URLWithString:printString];
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
```

## `BrowserMenuCoordinator.h`  (46줄)

```objc
#import <UIKit/UIKit.h>
#import "BrowserWebView.h"

@class BrowserPreferencesStore;

@protocol BrowserMenuCoordinatorHost <NSObject>

@property (nonatomic, readonly) BrowserWebView *browserWebView;
@property (nonatomic, copy) NSString *browserPreviousURL;
@property (nonatomic) NSUInteger browserTextFontSize;
@property (nonatomic, readonly) BOOL browserTopMenuShowing;

- (void)browserPresentViewController:(UIViewController *)viewController;
- (void)browserLoadHomePage;
- (void)browserShowHints;
- (void)browserShowTabOverview;
- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage;
- (void)browserHideTopNav;
- (void)browserShowTopNav;
- (void)browserUpdateTextFontSize;
- (void)browserApplyReadingZoom;
- (void)browserApplyPageLayoutWidth;
- (BOOL)browserOpenPrintableArticle;
- (void)browserReloadActivePage;
- (void)browserUpdateForcedDarkMode;
- (void)browserCaptureSnapshotForCurrentTab;
- (void)browserRecreateActiveWebViewPreservingCurrentURL;
- (void)browserBringCursorToFront;
- (void)browserPlayVideoUnderCursorIfAvailable;
- (void)browserToggleReaderMode;
- (BOOL)browserIsReaderModeActive;

@end

@interface BrowserMenuCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore;
- (void)showAdvancedMenu;
- (void)showBookmarksMenuAnchoredAt:(CGFloat)anchorCenterX;
- (void)showReadingMenuAnchoredAt:(CGFloat)anchorCenterX;
- (void)showPrivacyMenuAnchoredAt:(CGFloat)anchorCenterX;
- (void)showSettingsMenuAnchoredAt:(CGFloat)anchorCenterX;

@end
```

## `BrowserMenuCoordinator.m`  (1580줄)

```objc
#import "BrowserMenuCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserContentBlockerController.h"
#import "BrowserWebView.h"
#import "BrowserFavoritesStore.h"

static UIColor *MenuTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

static NSString * const kBrowserWebKitMediaPrefsLogPrefix = @"[WebKitMediaPrefs]";

typedef void (^BrowserAdvancedMenuItemHandler)(void);

@interface BrowserAdvancedMenuItem : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic) UIAlertActionStyle style;
@property (nonatomic, copy) BrowserAdvancedMenuItemHandler handler;
// A setting changes in place and the menu stays up, so several can be
// changed without walking back to the icon in the bar for each one.
@property (nonatomic) BOOL keepsMenuOpen;

+ (instancetype)itemWithTitle:(NSString *)title
                        style:(UIAlertActionStyle)style
                      handler:(BrowserAdvancedMenuItemHandler)handler;

@end

@implementation BrowserAdvancedMenuItem

+ (instancetype)itemWithTitle:(NSString *)title
                        style:(UIAlertActionStyle)style
                      handler:(BrowserAdvancedMenuItemHandler)handler {
    BrowserAdvancedMenuItem *item = [BrowserAdvancedMenuItem new];
    item.title = title ?: @"";
    item.style = style;
    item.handler = handler;
    return item;
}

@end

@interface BrowserAdvancedMenuSection : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuItem *> *items;

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserAdvancedMenuItem *> *)items;

@end

@implementation BrowserAdvancedMenuSection

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserAdvancedMenuItem *> *)items {
    BrowserAdvancedMenuSection *section = [BrowserAdvancedMenuSection new];
    section.title = title ?: @"";
    section.items = [items copy] ?: @[];
    return section;
}

@end

@interface BrowserAdvancedMenuViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

- (instancetype)initWithTitle:(NSString *)title
                     sections:(NSArray<BrowserAdvancedMenuSection *> *)sections
                   footerText:(NSString *)footerText;

// Set to the screen x of the icon that opened the menu. The panel then drops
// down beneath that icon instead of sliding in from the right edge, so a menu
// reached from the bar reads as belonging to the icon that opened it.
@property (nonatomic) CGFloat anchorCenterX;

// Re-asked for after a setting changes, so row titles show the new state
// without the menu having to close.
@property (nonatomic, copy, nullable) NSArray<BrowserAdvancedMenuSection *> *(^sectionsProvider)(void);

@end

@interface BrowserAdvancedMenuViewController ()

@property (nonatomic, copy) NSString *menuTitle;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuSection *> *sections;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic) UIView *dimView;
@property (nonatomic) UIVisualEffectView *panelView;
@property (nonatomic) UITableView *tableView;
@property (nonatomic) NSLayoutConstraint *panelTrailingConstraint;
@property (nonatomic) NSLayoutConstraint *panelTopConstraint;
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) BOOL didAnimateIn;
@property (nonatomic) BOOL dismissalInProgress;
@property (nonatomic, nullable) NSIndexPath *focusIndexPathAfterReload;
@property (nonatomic) BOOL usingNativeGlassEffect;

@end

@implementation BrowserAdvancedMenuViewController

// Focus starts in the list, so a row is lit the moment the menu opens and
// the remote's direction pad moves between rows.
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    NSIndexPath *target = self.focusIndexPathAfterReload;
    if (target != nil) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:target];
        if (cell != nil) {
            return @[cell];
        }
    }
    if (self.tableView != nil) {
        return @[self.tableView];
    }
    return [super preferredFocusEnvironments];
}

- (BOOL)isAnchoredToBar {
    return self.anchorCenterX > 0.0;
}

- (CGFloat)anchoredPanelVisibleTopConstant {
    return 112.0;
}

// Sized from the rows it will show, clamped to what is left below the bar.
- (CGFloat)anchoredPanelHeight {
    CGFloat rowHeight = 68.0;
    CGFloat sectionHeaderHeight = 54.0;
    CGFloat chrome = 26.0 + 52.0 + 20.0 + 1.0 + 12.0 + 24.0;

    CGFloat content = 0.0;
    for (BrowserAdvancedMenuSection *section in self.sections) {
        if (section.title.length > 0) {
            content += sectionHeaderHeight;
        }
        content += rowHeight * (CGFloat)section.items.count;
    }

    CGFloat available = CGRectGetHeight(UIScreen.mainScreen.bounds)
        - [self anchoredPanelVisibleTopConstant] - 40.0;
    return MIN(MAX(content + chrome, 220.0), available);
}

- (CGFloat)anchoredPanelHiddenTopConstant {
    return -CGRectGetHeight(UIScreen.mainScreen.bounds);
}

- (UIVisualEffect *)panelEffect {
    Class glassEffectClass = NSClassFromString(@"UIGlassEffect");
    if (glassEffectClass != Nil) {
        id effect = [[glassEffectClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) {
            return (UIVisualEffect *)effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
}

- (instancetype)initWithTitle:(NSString *)title
                     sections:(NSArray<BrowserAdvancedMenuSection *> *)sections
                   footerText:(NSString *)footerText {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _menuTitle = [title copy] ?: @"Menu";
        _sections = [sections copy] ?: @[];
        _footerText = [footerText copy] ?: @"";
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    if ([self isAnchoredToBar]) {
        self.panelWidth = MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds) * 0.30, 460.0), 620.0);
    } else {
        self.panelWidth = MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds) * 0.38, 480.0), 700.0);
    }
    self.usingNativeGlassEffect = (NSClassFromString(@"UIGlassEffect") != Nil);

    UIView *dimView = [UIView new];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    dimView.backgroundColor = self.usingNativeGlassEffect ? UIColor.clearColor : [UIColor colorWithWhite:0.0 alpha:0.45];
    dimView.alpha = 0.0;
    [self.view addSubview:dimView];
    self.dimView = dimView;

    UIVisualEffectView *panelView = [[UIVisualEffectView alloc] initWithEffect:[self panelEffect]];
    panelView.translatesAutoresizingMaskIntoConstraints = NO;
    panelView.backgroundColor = UIColor.clearColor;
    panelView.layer.cornerRadius = 28.0;
    panelView.layer.masksToBounds = YES;
    panelView.layer.borderWidth = self.usingNativeGlassEffect ? 0.0 : 1.0;
    panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    [self.view addSubview:panelView];
    self.panelView = panelView;

    UIView *panelTint = nil;
    if (!self.usingNativeGlassEffect) {
        panelTint = [UIView new];
        panelTint.translatesAutoresizingMaskIntoConstraints = NO;
        panelTint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        [panelView.contentView addSubview:panelTint];
    }

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = self.menuTitle;
    titleLabel.font = [UIFont boldSystemFontOfSize:34.0];
    titleLabel.textAlignment = NSTextAlignmentLeft;
    if (@available(tvOS 13.0, *)) {
        titleLabel.textColor = UIColor.labelColor;
    } else {
        titleLabel.textColor = UIColor.whiteColor;
    }
    [panelView.contentView addSubview:titleLabel];

    UIView *separator = [UIView new];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(tvOS 13.0, *)) {
        separator.backgroundColor = UIColor.separatorColor;
    } else {
        separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    }
    [panelView.contentView addSubview:separator];

    UILabel *footerLabel = [UILabel new];
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    footerLabel.text = self.footerText;
    footerLabel.textAlignment = NSTextAlignmentCenter;
    footerLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightRegular];
    if (@available(tvOS 13.0, *)) {
        footerLabel.textColor = UIColor.secondaryLabelColor;
    } else {
        footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    }
    [panelView.contentView addSubview:footerLabel];

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.rowHeight = 68.0;
    tableView.backgroundColor = UIColor.clearColor;
    tableView.preservesSuperviewLayoutMargins = NO;
    tableView.layoutMargins = UIEdgeInsetsZero;
    if (@available(tvOS 11.0, *)) {
        tableView.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
        tableView.insetsLayoutMarginsFromSafeArea = NO;
    }
    tableView.cellLayoutMarginsFollowReadableWidth = NO;
    tableView.clipsToBounds = NO;
    tableView.layer.cornerRadius = 0.0;
    tableView.remembersLastFocusedIndexPath = YES;
    tableView.contentInset = UIEdgeInsetsZero;
    tableView.showsVerticalScrollIndicator = NO;
    if (@available(tvOS 11.0, *)) {
        tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        tableView.insetsContentViewsToSafeArea = NO;
    }
    [panelView.contentView addSubview:tableView];
    self.tableView = tableView;

    self.panelTrailingConstraint = [panelView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                                                             constant:self.panelWidth + 32.0];
    self.panelTopConstraint = [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor
                                                                  constant:[self anchoredPanelHiddenTopConstant]];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.widthAnchor constraintEqualToConstant:self.panelWidth],

        [titleLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:32.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-32.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panelView.topAnchor constant:26.0],

        [separator.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:20.0],
        [separator.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-20.0],
        [separator.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:20.0],
        [separator.heightAnchor constraintEqualToConstant:1.0],

        [tableView.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:12.0],
        [tableView.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:16.0],
        [tableView.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-16.0],
        [tableView.bottomAnchor constraintEqualToAnchor:footerLabel.topAnchor constant:-8.0],

        [footerLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:24.0],
        [footerLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-24.0],
        [footerLabel.bottomAnchor constraintEqualToAnchor:panelView.bottomAnchor constant:-12.0],
    ]];
    if ([self isAnchoredToBar]) {
        // Clamped so a panel hung off an icon near either end stays on screen.
        CGFloat screenWidth = CGRectGetWidth(UIScreen.mainScreen.bounds);
        CGFloat halfWidth = self.panelWidth / 2.0;
        CGFloat margin = 40.0;
        CGFloat centerX = MIN(MAX(self.anchorCenterX, halfWidth + margin), screenWidth - halfWidth - margin);
        [constraints addObject:[panelView.centerXAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                                                      constant:centerX]];
        [constraints addObject:self.panelTopConstraint];
        NSLayoutConstraint *heightConstraint =
            [panelView.heightAnchor constraintEqualToConstant:[self anchoredPanelHeight]];
        heightConstraint.priority = UILayoutPriorityDefaultHigh;
        [constraints addObject:heightConstraint];
        [constraints addObject:[panelView.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor
                                                                               constant:-40.0]];
    } else {
        [constraints addObject:[panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16.0]];
        [constraints addObject:[panelView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16.0]];
        [constraints addObject:self.panelTrailingConstraint];
    }
    if (panelTint != nil) {
        [constraints addObject:[panelTint.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor]];
        [constraints addObject:[panelTint.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor]];
        [constraints addObject:[panelTint.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor]];
        [constraints addObject:[panelTint.bottomAnchor constraintEqualToAnchor:panelView.contentView.bottomAnchor]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didAnimateIn) {
        return;
    }
    self.didAnimateIn = YES;
    if ([self isAnchoredToBar]) {
        self.panelTopConstraint.constant = [self anchoredPanelVisibleTopConstant];
    } else {
        self.panelTrailingConstraint.constant = -16.0;
    }
    [UIView animateWithDuration:0.28
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.dimView.alpha = 1.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (!self.isBeingDismissed || self.dismissalInProgress) {
        return;
    }

    if ([self isAnchoredToBar]) {
        self.panelTopConstraint.constant = [self anchoredPanelHiddenTopConstant];
    } else {
        self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
    }
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (coordinator != nil) {
        [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            self.dimView.alpha = 0.0;
            [self.view layoutIfNeeded];
        } completion:nil];
        return;
    }

    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.dimView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)dismissMenuWithCompletion:(void (^)(void))completion {
    if (self.dismissalInProgress) {
        return;
    }
    self.dismissalInProgress = YES;
    if ([self isAnchoredToBar]) {
        self.panelTopConstraint.constant = [self anchoredPanelHiddenTopConstant];
    } else {
        self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
    }
    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.dimView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:completion];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return 0;
    }
    return (NSInteger)self.sections[(NSUInteger)section].items.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return nil;
    }
    return self.sections[(NSUInteger)section].title;
}

- (CGFloat)tableView:(__unused UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count ||
        self.sections[(NSUInteger)section].title.length == 0) {
        return 0.0;
    }
    return 54.0;
}

// The system header style is small, grey and uppercase, which disappears at
// three metres. These are the only labels that say what part of the menu you
// are in, so they are drawn bright and large instead.
- (UIView *)tableView:(__unused UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return nil;
    }
    NSString *title = self.sections[(NSUInteger)section].title;
    if (title.length == 0) {
        return nil;
    }

    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.backgroundColor = UIColor.clearColor;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    label.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBold];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:label];

    UIView *rule = [[UIView alloc] initWithFrame:CGRectZero];
    rule.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    rule.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:rule];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:28.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-28.0],
        [label.bottomAnchor constraintEqualToAnchor:rule.topAnchor constant:-8.0],
        [rule.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:28.0],
        [rule.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-28.0],
        [rule.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6.0],
        [rule.heightAnchor constraintEqualToConstant:2.0],
    ]];
    return header;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const kCellIdentifier = @"BrowserAdvancedMenuCell";
    static NSInteger const kMenuTitleLabelTag = 9191;
    static NSInteger const kMenuFocusBackgroundTag = 9292;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kCellIdentifier];
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.clipsToBounds = NO;
        cell.contentView.clipsToBounds = NO;
        cell.preservesSuperviewLayoutMargins = NO;
        cell.layoutMargins = UIEdgeInsetsZero;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([cell respondsToSelector:@selector(setFocusStyle:)]) {
            [cell setValue:@(1) forKey:@"focusStyle"]; // UITableViewCellFocusStyleCustom
        }

        UIView *focusBackgroundView = [UIView new];
        focusBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
        focusBackgroundView.tag = kMenuFocusBackgroundTag;
        focusBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.95];
        focusBackgroundView.layer.cornerRadius = 14.0;
        focusBackgroundView.alpha = 0.0;
        [cell.contentView addSubview:focusBackgroundView];

        UILabel *titleLabel = [UILabel new];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.tag = kMenuTitleLabelTag;
        titleLabel.font = [UIFont systemFontOfSize:31.0 weight:UIFontWeightRegular];
        titleLabel.textAlignment = NSTextAlignmentLeft;
        titleLabel.numberOfLines = 1;
        [cell.contentView addSubview:titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [focusBackgroundView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:0.0],
            [focusBackgroundView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:0.0],
            [focusBackgroundView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:2.0],
            [focusBackgroundView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-2.0],

            [titleLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:24.0],
            [titleLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-24.0],
            [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    }

    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    UILabel *titleLabel = (UILabel *)[cell.contentView viewWithTag:kMenuTitleLabelTag];
    UIView *focusBackgroundView = [cell.contentView viewWithTag:kMenuFocusBackgroundTag];
    titleLabel.text = item.title;
    UIColor *titleColor = nil;
    if (item.style == UIAlertActionStyleDestructive) {
        titleColor = UIColor.redColor;
    } else if (@available(tvOS 13.0, *)) {
        titleColor = UIColor.labelColor;
    } else {
        titleColor = UIColor.whiteColor;
    }
    BOOL focused = cell.isFocused;
    if (focused && item.style != UIAlertActionStyleDestructive) {
        titleColor = [UIColor colorWithRed:0.07 green:0.09 blue:0.10 alpha:1.0];
    }
    titleLabel.textColor = titleColor;
    titleLabel.font = [UIFont systemFontOfSize:31.0
                                        weight:focused ? UIFontWeightSemibold : UIFontWeightRegular];
    focusBackgroundView.alpha = focused ? 1.0 : 0.0;
    return cell;
}

- (void)tableView:(UITableView *)tableView
didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context
withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    NSIndexPath *previousIndexPath = context.previouslyFocusedIndexPath;
    NSIndexPath *nextIndexPath = context.nextFocusedIndexPath;

    UITableViewCell *previousCell = previousIndexPath ? [tableView cellForRowAtIndexPath:previousIndexPath] : nil;
    UITableViewCell *nextCell = nextIndexPath ? [tableView cellForRowAtIndexPath:nextIndexPath] : nil;

    // The pill is solid now, so the label flips with it or the row becomes
    // white text on white.
    void (^applyFocus)(UITableViewCell *, BOOL) = ^(UITableViewCell *cell, BOOL isFocused) {
        if (cell == nil) {
            return;
        }
        [cell.contentView viewWithTag:9292].alpha = isFocused ? 1.0 : 0.0;

        UILabel *label = (UILabel *)[cell.contentView viewWithTag:9191];
        if (![label isKindOfClass:[UILabel class]]) {
            return;
        }
        label.font = [UIFont systemFontOfSize:31.0
                                       weight:isFocused ? UIFontWeightSemibold : UIFontWeightRegular];
        if ([label.textColor isEqual:UIColor.redColor]) {
            return;
        }
        if (isFocused) {
            label.textColor = [UIColor colorWithRed:0.07 green:0.09 blue:0.10 alpha:1.0];
        } else if (@available(tvOS 13.0, *)) {
            label.textColor = UIColor.labelColor;
        } else {
            label.textColor = UIColor.whiteColor;
        }
    };

    [coordinator addCoordinatedAnimations:^{
        applyFocus(previousCell, NO);
        applyFocus(nextCell, YES);
    } completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    BrowserAdvancedMenuItemHandler handler = item.handler;

    if (item.keepsMenuOpen && self.sectionsProvider != nil) {
        if (handler != nil) {
            handler();
        }
        NSArray<BrowserAdvancedMenuSection *> *refreshed = self.sectionsProvider();
        if (refreshed.count > 0) {
            self.sections = refreshed;
        }
        [self.tableView reloadData];
        self.focusIndexPathAfterReload = indexPath;
        [self setNeedsFocusUpdate];
        [self updateFocusIfNeeded];
        return;
    }

    [self dismissMenuWithCompletion:^{
        if (handler != nil) {
            handler();
        }
    }];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        [self dismissMenuWithCompletion:nil];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@interface BrowserMenuCoordinator ()

@property (nonatomic, weak) id<BrowserMenuCoordinatorHost> host;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserFavoritesStore *favoritesStore;

@end

@implementation BrowserMenuCoordinator

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _host = host;
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
        _favoritesStore = [BrowserFavoritesStore new];
    }
    return self;
}

- (void)showAdvancedMenu {
    __weak typeof(self) weakSelf = self;
    BrowserAdvancedMenuViewController *menuViewController = [[BrowserAdvancedMenuViewController alloc] initWithTitle:@"tvOS Browser"
                                                                                                            sections:[self advancedMenuSections]
                                                                                                          footerText:[self advancedMenuFooterText]];
    menuViewController.sectionsProvider = ^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf advancedMenuSections] ?: @[];
    };
    [self.host browserPresentViewController:menuViewController];
}

- (UIAlertController *)browserAlertControllerWithTitle:(NSString *)title message:(NSString *)message {
    return [UIAlertController alertControllerWithTitle:title
                                               message:message
                                        preferredStyle:UIAlertControllerStyleAlert];
}

- (UIAlertAction *)browserActionWithTitle:(NSString *)title
                                    style:(UIAlertActionStyle)style
                                  handler:(void (^ __nullable)(UIAlertAction *action))handler {
    return [UIAlertAction actionWithTitle:title style:style handler:handler];
}

- (BrowserAdvancedMenuItem *)advancedMenuItemWithTitle:(NSString *)title
                                                  style:(UIAlertActionStyle)style
                                                handler:(BrowserAdvancedMenuItemHandler)handler {
    return [BrowserAdvancedMenuItem itemWithTitle:title style:style handler:handler];
}

- (BrowserAdvancedMenuItem *)markKeepsMenuOpen:(BrowserAdvancedMenuItem *)item {
    item.keepsMenuOpen = YES;
    return item;
}

- (BrowserAdvancedMenuItem *)settingMenuItemWithTitle:(NSString *)title
                                              handler:(BrowserAdvancedMenuItemHandler)handler {
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:title
                                                              style:UIAlertActionStyleDefault
                                                            handler:handler];
    item.keepsMenuOpen = YES;
    return item;
}

- (UIAlertAction *)browserCancelAction {
    return [self browserActionWithTitle:nil style:UIAlertActionStyleCancel handler:nil];
}

- (BOOL)stringHasVisibleContent:(NSString *)string {
    NSString *trimmedString = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmedString.length > 0;
}

- (NSString *)displayTitleForStoredTitle:(NSString *)storedTitle
                               URLString:(NSString *)URLString
                              includeURL:(BOOL)includeURL {
    NSString *displayTitle = [self stringHasVisibleContent:storedTitle] ? storedTitle : URLString;
    if (includeURL && [self stringHasVisibleContent:storedTitle] && [self stringHasVisibleContent:URLString]) {
        return [NSString stringWithFormat:@"%@ - %@", storedTitle, URLString];
    }
    return displayTitle ?: @"";
}

- (void)loadStoredURLString:(NSString *)URLString {
    if (![self stringHasVisibleContent:URLString]) {
        return;
    }
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    NSString *userAgent = self.preferencesStore.userAgent;
    if (userAgent.length > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
    [[self.host browserWebView] loadRequest:request];
}

- (void)presentDeleteFavoriteMenu {
    NSArray<NSArray<NSString *> *> *favorites = [self.favoritesStore favorites];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Delete a Favorite"
                                                                       message:@"Select a Favorite to Delete"];
    __weak typeof(self) weakSelf = self;
    
    [favorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        if (![weakSelf stringHasVisibleContent:URLString]) {
            return;
        }
        
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:NO];
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            [weakSelf.favoritesStore removeFavoriteAtIndex:index];
        }]];
    }];
    
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentAddFavoritePrompt {
    NSString *pageTitle = [[self.host browserWebView] title];
    NSURLRequest *request = [[self.host browserWebView] request];
    NSString *currentURL = request.URL.absoluteString ?: @"";
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Name New Favorite"
                                                                       message:currentURL];
    __weak typeof(self) weakSelf = self;
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeDefault;
        textField.placeholder = @"Name New Favorite";
        textField.text = pageTitle;
        textField.textColor = MenuTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];
    
    [alertController addAction:[self browserActionWithTitle:@"Save"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
        UITextField *titleTextField = alertController.textFields.firstObject;
        NSString *savedTitle = titleTextField.text;
        if (![weakSelf stringHasVisibleContent:savedTitle]) {
            savedTitle = currentURL;
        }
        
        [weakSelf.favoritesStore addFavoriteWithURLString:currentURL title:savedTitle];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentFavoritesMenu {
    NSArray<NSArray<NSString *> *> *favorites = [self.favoritesStore favorites];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Favorites" message:@""];
    __weak typeof(self) weakSelf = self;
    
    [favorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:NO];
        if (![weakSelf stringHasVisibleContent:displayTitle]) {
            return;
        }
        
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }];
    
    if (favorites.count > 0) {
        [alertController addAction:[self browserActionWithTitle:@"Delete a Favorite"
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentDeleteFavoriteMenu];
        }]];
    }
    
    [alertController addAction:[self browserActionWithTitle:@"Add Current Page to Favorites"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf presentAddFavoritePrompt];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentHistoryMenu {
    NSArray *historyEntries = [[NSUserDefaults standardUserDefaults] arrayForKey:@"HISTORY"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"History" message:@""];
    __weak typeof(self) weakSelf = self;
    
    if (historyEntries.count > 0) {
        [alertController addAction:[self browserActionWithTitle:@"Clear History"
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"HISTORY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];
    }
    
    [historyEntries enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:YES];
        if (![weakSelf stringHasVisibleContent:displayTitle]) {
            return;
        }
        
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }];
    
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)applyUserAgent:(NSString *)userAgent mobileMode:(BOOL)mobileMode {
    self.preferencesStore.userAgent = userAgent;
    self.preferencesStore.mobileModeEnabled = mobileMode;
    
    NSURLRequest *request = [[self.host browserWebView] request];
    if (request != nil && [self stringHasVisibleContent:request.URL.absoluteString]) {
        [self.host browserCaptureSnapshotForCurrentTab];
    }
    
    __weak typeof(self) weakSelf = self;
    [BrowserWebView resetWebsiteDataWithCompletion:^{
        [weakSelf.host browserRecreateActiveWebViewPreservingCurrentURL];
        [weakSelf.host browserBringCursorToFront];
    }];
}

- (void)setPageScalingEnabled:(BOOL)enabled {
    self.preferencesStore.scalePagesToFit = enabled;
    [[self.host browserWebView] setScalesPageToFit:enabled];
    if (enabled) {
        [[self.host browserWebView] setContentMode:UIViewContentModeScaleAspectFit];
    }
    [[self.host browserWebView] reload];
}

- (void)clearCacheAndReload {
    __weak typeof(self) weakSelf = self;
    [BrowserWebView clearCachedDataWithCompletion:^{
        weakSelf.host.browserPreviousURL = @"";
        [[weakSelf.host browserWebView] reload];
    }];
}

- (void)clearCookiesAndReload {
    __weak typeof(self) weakSelf = self;
    [BrowserWebView clearCookiesWithCompletion:^{
        weakSelf.host.browserPreviousURL = @"";
        [[weakSelf.host browserWebView] reload];
    }];
}

- (BrowserAdvancedMenuItem *)contentBlockingToggleMenuItem {
    BOOL enabled = self.preferencesStore.contentBlockingEnabled;
    NSString *title = enabled ? @"Content Blocking: On" : @"Content Blocking: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.contentBlockingEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)forcedDarkModeToggleMenuItem {
    BOOL enabled = self.preferencesStore.forcedDarkModeEnabled;
    NSString *title = enabled ? @"Force Dark Mode: On" : @"Force Dark Mode: Off";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        weakSelf.preferencesStore.forcedDarkModeEnabled = !enabled;
        [weakSelf.host browserUpdateForcedDarkMode];
    }];
}

- (BrowserAdvancedMenuItem *)readerModeToggleMenuItem {
    BOOL isActive = [self.host browserIsReaderModeActive];
    NSString *title = isActive ? @"Exit Reader Mode" : @"Reader Mode";
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [weakSelf.host browserToggleReaderMode];
    }];
}

- (BrowserAdvancedMenuItem *)tapToClickToggleMenuItem {
    BOOL enabled = self.preferencesStore.tapToClickEnabled;
    NSString *title = enabled ? @"Tap to Click: On" : @"Tap to Click: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.tapToClickEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)openLinksInNewTabToggleMenuItem {
    BOOL enabled = self.preferencesStore.openLinksInNewTabOnClick;
    NSString *title = enabled ? @"Open Links in New Tab: On" : @"Open Links in New Tab: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.openLinksInNewTabOnClick = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)jsScrollFallbackToggleMenuItem {
    BOOL enabled = self.preferencesStore.jsScrollFallbackEnabled;
    NSString *title = enabled ? @"JS Scroll Fallback: On" : @"JS Scroll Fallback: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.jsScrollFallbackEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)dpadScrollToggleMenuItem {
    BOOL enabled = self.preferencesStore.dpadScrollEnabled;
    NSString *title = enabled ? @"D-Pad Page Scroll: On" : @"D-Pad Page Scroll: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.dpadScrollEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)edgeAutoScrollToggleMenuItem {
    BOOL enabled = self.preferencesStore.edgeAutoScrollEnabled;
    NSString *title = enabled ? @"Edge Auto-Scroll: On" : @"Edge Auto-Scroll: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.edgeAutoScrollEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)topNavigationVisibilityMenuItem {
    NSString *title = self.host.browserTopMenuShowing ? @"Hide Top Navigation bar" : @"Show Top Navigation bar";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        if (self.host.browserTopMenuShowing) {
            UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Hide Top Navigation bar?"
                                                                               message:@"You can still open the side menu by double-tapping the Play/Pause button."];
            [alertController addAction:[self browserActionWithTitle:@"Cancel"
                                                              style:UIAlertActionStyleCancel
                                                            handler:nil]];
            [alertController addAction:[self browserActionWithTitle:@"Hide Bar"
                                                              style:UIAlertActionStyleDestructive
                                                            handler:^(__unused UIAlertAction *action) {
                [self.host browserHideTopNav];
            }]];
            [self.host browserPresentViewController:alertController];
        } else {
            [self.host browserShowTopNav];
        }
    }];
}

- (BrowserAdvancedMenuItem *)homePageMenuItem {
    return [self advancedMenuItemWithTitle:@"Go To Home Page"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserLoadHomePage];
    }];
}

- (BrowserAdvancedMenuItem *)setCurrentPageAsHomePageMenuItem {
    return [self advancedMenuItemWithTitle:@"Set Current Page As Home Page"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        NSURLRequest *request = [[self.host browserWebView] request];
        if (request != nil && [self stringHasVisibleContent:request.URL.absoluteString]) {
            self.preferencesStore.homePageURLString = request.URL.absoluteString;
        }
    }];
}

- (BrowserAdvancedMenuItem *)usageGuideMenuItem {
    return [self advancedMenuItemWithTitle:@"Usage Guide"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowHints];
    }];
}

- (BrowserAdvancedMenuItem *)showTabsMenuItem {
    return [self advancedMenuItemWithTitle:@"Show Tabs"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowTabOverview];
    }];
}

- (BrowserAdvancedMenuItem *)newTabMenuItem {
    return [self advancedMenuItemWithTitle:@"Open New Tab"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserCreateNewTabLoadingHomePage:YES];
    }];
}

- (BrowserAdvancedMenuItem *)favoritesMenuItem {
    return [self advancedMenuItemWithTitle:@"Favorites"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentFavoritesMenu];
    }];
}

- (BrowserAdvancedMenuItem *)historyMenuItem {
    return [self advancedMenuItemWithTitle:@"History"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentHistoryMenu];
    }];
}

- (BrowserAdvancedMenuItem *)userAgentModeMenuItem {
    BOOL mobileModeEnabled = self.preferencesStore.mobileModeEnabled;
    NSString *title = mobileModeEnabled ? @"Switch To Desktop User Agent" : @"Switch To Mobile User Agent";
    NSString *userAgent = mobileModeEnabled ? BrowserPreferencesStore.desktopUserAgent : BrowserPreferencesStore.mobileUserAgent;
    BOOL mobileMode = !mobileModeEnabled;
    
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        [self applyUserAgent:userAgent mobileMode:mobileMode];
    }];
}

- (BrowserAdvancedMenuItem *)pageScalingMenuItem {
    BOOL scalesPageToFit = [[self.host browserWebView] scalesPageToFit];
    NSString *title = scalesPageToFit ? @"Stop Scaling Pages to Fit" : @"Scale Pages to Fit";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        [self setPageScalingEnabled:!scalesPageToFit];
    }];
}

- (BrowserAdvancedMenuItem *)toggleFavoriteMenuItem {
    NSURLRequest *request = [[self.host browserWebView] request];
    NSString *currentURLString = request.URL.absoluteString;
    
    if (currentURLString.length == 0) {
        return nil;
    }
    
    BOOL isFavorite = [self.favoritesStore isFavoriteURLString:currentURLString];
    NSString *title = isFavorite ? @"Remove from Favorites" : @"Add to Favorites";
    
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        if (isFavorite) {
            [weakSelf.favoritesStore removeFavoriteWithURLString:currentURLString];
        } else {
            NSString *pageTitle = [[weakSelf.host browserWebView] title];
            [weakSelf.favoritesStore addFavoriteWithURLString:currentURLString title:pageTitle];
        }
    }];
}

- (BrowserAdvancedMenuItem *)increaseFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self markKeepsMenuOpen:[self advancedMenuItemWithTitle:@"Increase Font Size"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        weakSelf.host.browserTextFontSize += 5;
        [weakSelf.host browserUpdateTextFontSize];
    }]];
}

- (BrowserAdvancedMenuItem *)decreaseFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self markKeepsMenuOpen:[self advancedMenuItemWithTitle:@"Decrease Font Size"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        weakSelf.host.browserTextFontSize -= 5;
        [weakSelf.host browserUpdateTextFontSize];
    }]];
}

- (BrowserAdvancedMenuItem *)resetFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self markKeepsMenuOpen:[self advancedMenuItemWithTitle:@"Reset Font Size"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        weakSelf.host.browserTextFontSize = 100;
        [weakSelf.host browserUpdateTextFontSize];
    }]];
}

// The two icons beside the menu open a slice of it. Same items, same titles,
// reached in one click instead of scrolling the whole list from the sofa.
- (void)presentAnchoredMenuWithTitle:(NSString *)title
                            provider:(NSArray<BrowserAdvancedMenuSection *> *(^)(void))provider
                            anchorAt:(CGFloat)anchorCenterX {
    BrowserAdvancedMenuViewController *menuViewController =
        [[BrowserAdvancedMenuViewController alloc] initWithTitle:title
                                                        sections:provider()
                                                      footerText:@""];
    menuViewController.anchorCenterX = anchorCenterX;
    menuViewController.sectionsProvider = provider;
    [self.host browserPresentViewController:menuViewController];
}

// The star holds four things and nothing else: add or remove this page,
// delete one from the list, the folders, and the list itself.
- (NSArray<BrowserAdvancedMenuSection *> *)bookmarksMenuSections {
    NSMutableArray<BrowserAdvancedMenuItem *> *items = [NSMutableArray array];
    BrowserAdvancedMenuItem *toggleFavoriteItem = [self toggleFavoriteMenuItem];
    if (toggleFavoriteItem != nil) {
        [items addObject:toggleFavoriteItem];
    }
    [items addObject:[self deleteFavoriteMenuItem]];
    [items addObject:[self favoriteFoldersMenuItem]];
    [items addObject:[self favoritesMenuItem]];

    return @[[BrowserAdvancedMenuSection sectionWithTitle:@"즐겨찾기" items:items]];
}

- (BrowserAdvancedMenuItem *)deleteFavoriteMenuItem {
    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"즐겨찾기 삭제  (%lu개)",
                       (unsigned long)[self.favoritesStore count]];
    return [self advancedMenuItemWithTitle:title style:UIAlertActionStyleDestructive handler:^{
        [weakSelf presentDeleteFavoriteMenu];
    }];
}

- (BrowserAdvancedMenuItem *)favoriteFoldersMenuItem {
    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"폴더  (%lu개)",
                       (unsigned long)[self.favoritesStore folderNames].count];
    return [self advancedMenuItemWithTitle:title style:UIAlertActionStyleDefault handler:^{
        [weakSelf presentFavoriteFoldersMenu];
    }];
}

- (void)presentFavoriteFoldersMenu {
    __weak typeof(self) weakSelf = self;
    NSArray<NSString *> *folders = [self.favoritesStore folderNames];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"즐겨찾기 폴더" message:@""];

    for (NSString *folder in folders) {
        NSUInteger count = [self.favoritesStore favoritesInFolder:folder].count;
        NSString *title = [NSString stringWithFormat:@"%@  (%lu)", folder, (unsigned long)count];
        [alertController addAction:[self browserActionWithTitle:title
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentFavoritesInFolder:folder];
        }]];
    }

    NSString *currentURL = [self.host browserWebView].request.URL.absoluteString;
    if ([self.favoritesStore isFavoriteURLString:currentURL]) {
        [alertController addAction:[self browserActionWithTitle:@"이 페이지를 폴더에 넣기"
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentMoveCurrentFavoriteToFolderMenu];
        }]];
    }

    [alertController addAction:[self browserActionWithTitle:@"새 폴더 만들기"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf presentCreateFolderPrompt];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentFavoritesInFolder:(NSString *)folderName {
    __weak typeof(self) weakSelf = self;
    NSArray<NSArray<NSString *> *> *entries = [self.favoritesStore favoritesInFolder:folderName];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:folderName message:@""];

    for (NSArray<NSString *> *entry in entries) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *stored = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [self displayTitleForStoredTitle:stored URLString:URLString includeURL:NO];
        if (![self stringHasVisibleContent:displayTitle]) {
            continue;
        }
        [alertController addAction:[self browserActionWithTitle:displayTitle
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }

    // Removing a folder keeps its favorites; they go back to the top level.
    [alertController addAction:[self browserActionWithTitle:@"이 폴더 없애기 (즐겨찾기는 유지)"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf.favoritesStore removeFolderNamed:folderName];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentMoveCurrentFavoriteToFolderMenu {
    __weak typeof(self) weakSelf = self;
    NSString *currentURL = [self.host browserWebView].request.URL.absoluteString;
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"어느 폴더에 넣을까요" message:@""];

    for (NSString *folder in [self.favoritesStore folderNames]) {
        [alertController addAction:[self browserActionWithTitle:folder
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf.favoritesStore setFolder:folder forURLString:currentURL];
        }]];
    }
    [alertController addAction:[self browserActionWithTitle:@"폴더에서 꺼내기"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf.favoritesStore setFolder:nil forURLString:currentURL];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentCreateFolderPrompt {
    __weak typeof(self) weakSelf = self;
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"새 폴더" message:@"폴더 이름"];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"폴더 이름";
    }];
    [alertController addAction:[self browserActionWithTitle:@"만들기"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        NSString *name = alertController.textFields.firstObject.text;
        name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length > 0) {
            [weakSelf.favoritesStore createFolderNamed:name];
        }
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (NSArray<BrowserAdvancedMenuSection *> *)readingMenuSections {
    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Reading" items:@[
            [self readerModeToggleMenuItem],
            [self forcedDarkModeToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Reader Text Size" items:@[
            [self increaseReaderFontSizeMenuItem],
            [self decreaseReaderFontSizeMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"화면 채우기" items:@[
            [self narrowerLayoutMenuItem],
            [self widerLayoutMenuItem],
            [self printableArticleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Page Text Size" items:@[
            [self increasePageZoomMenuItem],
            [self decreasePageZoomMenuItem],
            [self resetPageZoomMenuItem],
            [self boldTextToggleMenuItem],
            [self increaseMinimumFontSizeMenuItem],
            [self decreaseMinimumFontSizeMenuItem],
            [self increaseFontSizeMenuItem],
            [self decreaseFontSizeMenuItem],
            [self resetFontSizeMenuItem],
            [self pageScalingMenuItem],
        ]],
    ];
}

// Fitting the screen to the page: the page is laid out at this width and
// scaled up to fill the display, so a desktop layout that caps itself near
// 1275 fills a 1920 screen instead of sitting in the middle of it.
- (BrowserAdvancedMenuItem *)narrowerLayoutMenuItem {
    NSUInteger width = self.preferencesStore.pageLayoutWidth;
    NSString *title = width > 0
        ? [NSString stringWithFormat:@"화면 더 크게  (레이아웃 %lupx)", (unsigned long)width]
        : @"화면 더 크게  (끔)";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        NSUInteger current = weakSelf.preferencesStore.pageLayoutWidth;
        weakSelf.preferencesStore.pageLayoutWidth = current == 0 ? 1280
            : (current > 900 ? current - 80 : current);
        [weakSelf.host browserApplyPageLayoutWidth];
    }];
}

- (BrowserAdvancedMenuItem *)widerLayoutMenuItem {
    NSUInteger width = self.preferencesStore.pageLayoutWidth;
    NSString *title = width > 0
        ? [NSString stringWithFormat:@"화면 작게  (레이아웃 %lupx)", (unsigned long)width]
        : @"화면 작게  (끔)";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        NSUInteger current = weakSelf.preferencesStore.pageLayoutWidth;
        weakSelf.preferencesStore.pageLayoutWidth = (current == 0 || current >= 1840) ? 0 : current + 80;
        [weakSelf.host browserApplyPageLayoutWidth];
    }];
}

- (BrowserAdvancedMenuItem *)printableArticleMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:@"기사만 깔끔하게 보기" style:UIAlertActionStyleDefault handler:^{
        if (![weakSelf.host browserOpenPrintableArticle]) {
            UIAlertController *alert =
                [weakSelf browserAlertControllerWithTitle:@"기사만 깔끔하게 보기"
                                                  message:@"네이버 뉴스 기사 페이지에서만 쓸 수 있습니다."];
            [alert addAction:[weakSelf browserCancelAction]];
            [weakSelf.host browserPresentViewController:alert];
        }
    }];
}

- (BrowserAdvancedMenuItem *)boldTextToggleMenuItem {
    BOOL enabled = self.preferencesStore.boldTextEnabled;
    NSString *title = enabled ? @"Bolder Text: On" : @"Bolder Text: Off";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        weakSelf.preferencesStore.boldTextEnabled = !enabled;
        [weakSelf.host browserUpdateTextFontSize];
    }];
}

- (BrowserAdvancedMenuItem *)increaseMinimumFontSizeMenuItem {
    NSUInteger size = self.preferencesStore.minimumFontSize;
    NSString *title = size > 0
        ? [NSString stringWithFormat:@"Minimum Text Bigger  (%lupt)", (unsigned long)size]
        : @"Minimum Text Bigger  (off)";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        weakSelf.preferencesStore.minimumFontSize = weakSelf.preferencesStore.minimumFontSize + 2;
        [weakSelf.host browserApplyReadingZoom];
        [weakSelf.host browserReloadActivePage];
    }];
}

- (BrowserAdvancedMenuItem *)decreaseMinimumFontSizeMenuItem {
    NSUInteger size = self.preferencesStore.minimumFontSize;
    NSString *title = size > 0
        ? [NSString stringWithFormat:@"Minimum Text Smaller  (%lupt)", (unsigned long)size]
        : @"Minimum Text Smaller  (off)";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        NSUInteger current = weakSelf.preferencesStore.minimumFontSize;
        weakSelf.preferencesStore.minimumFontSize = current >= 2 ? current - 2 : 0;
        [weakSelf.host browserApplyReadingZoom];
        [weakSelf.host browserReloadActivePage];
    }];
}

- (BrowserAdvancedMenuItem *)increasePageZoomMenuItem {
    NSString *title = [NSString stringWithFormat:@"Zoom In  (%lu%%)",
                       (unsigned long)self.preferencesStore.pageZoomPercent];
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        weakSelf.preferencesStore.pageZoomPercent = weakSelf.preferencesStore.pageZoomPercent + 10;
        [weakSelf.host browserApplyReadingZoom];
    }];
}

- (BrowserAdvancedMenuItem *)decreasePageZoomMenuItem {
    NSString *title = [NSString stringWithFormat:@"Zoom Out  (%lu%%)",
                       (unsigned long)self.preferencesStore.pageZoomPercent];
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        NSUInteger current = weakSelf.preferencesStore.pageZoomPercent;
        weakSelf.preferencesStore.pageZoomPercent = current > 10 ? current - 10 : current;
        [weakSelf.host browserApplyReadingZoom];
    }];
}

- (BrowserAdvancedMenuItem *)resetPageZoomMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:@"Reset Zoom to 100%" handler:^{
        weakSelf.preferencesStore.pageZoomPercent = 100;
        [weakSelf.host browserApplyReadingZoom];
    }];
}

- (BrowserAdvancedMenuItem *)increaseReaderFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"Larger Reader Text (%lu)",
                       (unsigned long)self.preferencesStore.readerFontSize];
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        weakSelf.preferencesStore.readerFontSize = weakSelf.preferencesStore.readerFontSize + 6;
        [weakSelf reapplyReaderModeIfActive];
    }];
}

- (BrowserAdvancedMenuItem *)decreaseReaderFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"Smaller Reader Text (%lu)",
                       (unsigned long)self.preferencesStore.readerFontSize];
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        NSUInteger current = weakSelf.preferencesStore.readerFontSize;
        weakSelf.preferencesStore.readerFontSize = current > 6 ? current - 6 : current;
        [weakSelf reapplyReaderModeIfActive];
    }];
}

// A size change only shows once the page is rebuilt, so reader mode is turned
// off and on again when it is already showing.
- (void)reapplyReaderModeIfActive {
    if (![self.host browserIsReaderModeActive]) {
        return;
    }
    [self.host browserToggleReaderMode];
    [self.host browserToggleReaderMode];
}

- (NSArray<BrowserAdvancedMenuSection *> *)privacyMenuSections {
    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Blocking" items:@[
            [self contentBlockingToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Stored Data" items:@[
            [self clearCacheMenuItem],
            [self clearCookiesMenuItem],
        ]],
    ];
}

- (NSArray<BrowserAdvancedMenuSection *> *)settingsMenuSections {
    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Remote" items:@[
            [self tapToClickToggleMenuItem],
            [self openLinksInNewTabToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Scrolling" items:@[
            [self dpadScrollToggleMenuItem],
            [self edgeAutoScrollToggleMenuItem],
            [self jsScrollFallbackToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Reading" items:@[
            [self increasePageZoomMenuItem],
            [self decreasePageZoomMenuItem],
            [self resetPageZoomMenuItem],
            [self boldTextToggleMenuItem],
            [self increaseMinimumFontSizeMenuItem],
            [self decreaseMinimumFontSizeMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Page" items:@[
            [self lightenHeavySitesToggleMenuItem],
            [self userAgentModeMenuItem],
            [self topNavigationVisibilityMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Help" items:@[
            [self usageGuideMenuItem],
        ]],
    ];
}

- (void)showBookmarksMenuAnchoredAt:(CGFloat)anchorCenterX {
    __weak typeof(self) weakSelf = self;
    [self presentAnchoredMenuWithTitle:@"Bookmarks"
                              provider:^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf bookmarksMenuSections] ?: @[];
    }
                              anchorAt:anchorCenterX];
}

- (void)showReadingMenuAnchoredAt:(CGFloat)anchorCenterX {
    __weak typeof(self) weakSelf = self;
    [self presentAnchoredMenuWithTitle:@"Reading"
                              provider:^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf readingMenuSections] ?: @[];
    }
                              anchorAt:anchorCenterX];
}

- (void)showPrivacyMenuAnchoredAt:(CGFloat)anchorCenterX {
    __weak typeof(self) weakSelf = self;
    [self presentAnchoredMenuWithTitle:@"Privacy"
                              provider:^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf privacyMenuSections] ?: @[];
    }
                              anchorAt:anchorCenterX];
}

- (void)showSettingsMenuAnchoredAt:(CGFloat)anchorCenterX {
    __weak typeof(self) weakSelf = self;
    [self presentAnchoredMenuWithTitle:@"Settings"
                              provider:^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf settingsMenuSections] ?: @[];
    }
                              anchorAt:anchorCenterX];
}


- (BrowserAdvancedMenuItem *)lightenHeavySitesToggleMenuItem {
    BOOL enabled = self.preferencesStore.lightenHeavySitesEnabled;
    NSString *title = enabled ? @"Lighten Heavy Sites: On" : @"Lighten Heavy Sites: Off";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title
                                  handler:^{
        weakSelf.preferencesStore.lightenHeavySitesEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)clearCacheMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:@"Clear Cache"
                                     style:UIAlertActionStyleDestructive
                                   handler:^{
        [weakSelf clearCacheAndReload];
    }];
}

- (BrowserAdvancedMenuItem *)clearCookiesMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:@"Clear Cookies"
                                     style:UIAlertActionStyleDestructive
                                   handler:^{
        [weakSelf clearCookiesAndReload];
    }];
}

- (NSArray<BrowserAdvancedMenuSection *> *)advancedMenuSections {
    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Tabs" items:@[
            [self showTabsMenuItem],
            [self newTabMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Page" items:@[
            [self historyMenuItem],
            [self homePageMenuItem],
            [self setCurrentPageAsHomePageMenuItem],
            [self userAgentModeMenuItem],
            [self topNavigationVisibilityMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Maintenance" items:@[
            [self clearCacheMenuItem],
            [self clearCookiesMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Help" items:@[
            [self usageGuideMenuItem],
        ]],
    ];
}

- (NSString *)advancedMenuFooterText {
    NSDictionary *infoDictionary = NSBundle.mainBundle.infoDictionary;
    NSString *version = infoDictionary[@"CFBundleShortVersionString"];
    BOOL hasVersion = [self stringHasVisibleContent:version];

    if (hasVersion) {
        return [NSString stringWithFormat:@"Version %@", version];
    }
    return @"";
}

@end
```

## `BrowserPageActionCoordinator.h`  (36줄)

```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "BrowserRemoteInputController.h"

@class BrowserDOMInteractionService;
@class BrowserNavigationService;
@class BrowserPreferencesStore;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserPageActionCoordinatorHost <NSObject>

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController;
- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request;

@end

@interface BrowserPageActionCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
            preferencesStore:(BrowserPreferencesStore *)preferencesStore NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (NSString *)hoverStateAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;
- (BOOL)handlePageSelectionAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView
                               source:(BrowserPageActivationSource)source;

@end

NS_ASSUME_NONNULL_END
```

## `BrowserPageActionCoordinator.m`  (318줄)

```objc
#import "BrowserPageActionCoordinator.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"

static UIColor *BrowserPageActionTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

@interface BrowserPageActionCoordinator ()

@property (nonatomic, weak) id<BrowserPageActionCoordinatorHost> host;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;

@end

@implementation BrowserPageActionCoordinator

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
            preferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _host = host;
        _domInteractionService = domInteractionService;
        _navigationService = navigationService;
        _preferencesStore = preferencesStore;
    }
    return self;
}

- (NSString *)hoverStateAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    return [self.domInteractionService evaluateHoverStateJavaScriptAtPoint:point webView:webView];
}

- (BOOL)handleTargetBlankLinkAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    NSDictionary *linkInfo = [self.domInteractionService linkInfoAtDOMPoint:point webView:webView];
    NSString *href = [linkInfo[@"href"] isKindOfClass:[NSString class]] ? linkInfo[@"href"] : @"";
    NSString *target = [linkInfo[@"target"] isKindOfClass:[NSString class]] ? linkInfo[@"target"] : @"";

    if (href.length == 0 || ![target isEqualToString:@"_blank"]) {
        return NO;
    }

    NSURLRequest *request = [self.navigationService requestForURLString:href];
    if (request == nil) {
        return NO;
    }

    return [self.host browserPageActionCoordinatorCreateNewTabWithRequest:request];
}

- (NSString *)URLStringByRemovingFragment:(NSString *)URLString {
    if (URLString.length == 0) {
        return @"";
    }
    NSRange hashRange = [URLString rangeOfString:@"#"];
    if (hashRange.location == NSNotFound) {
        return URLString;
    }
    return [URLString substringToIndex:hashRange.location];
}

- (BOOL)isSamePageFragmentLinkForHref:(NSString *)href webView:(BrowserWebView *)webView {
    if ([href hasPrefix:@"#"]) {
        return YES;
    }
    NSRange hashRange = [href rangeOfString:@"#"];
    if (hashRange.location == NSNotFound) {
        return NO;
    }
    NSString *currentURLString = webView.request.URL.absoluteString ?: @"";
    if (currentURLString.length == 0) {
        currentURLString = [webView stringByEvaluatingJavaScriptFromString:@"window.location.href"] ?: @"";
    }
    if (currentURLString.length == 0) {
        return NO;
    }
    NSString *baseHref = [self URLStringByRemovingFragment:href];
    NSString *baseCurrent = [self URLStringByRemovingFragment:currentURLString];
    return baseHref.length > 0 && [baseHref isEqualToString:baseCurrent];
}

- (BOOL)handleNewTabLinkOnClickAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    NSDictionary *linkInfo = [self.domInteractionService linkInfoAtDOMPoint:point webView:webView];
    NSString *rawHref = [linkInfo[@"href"] isKindOfClass:[NSString class]] ? linkInfo[@"href"] : @"";
    NSString *href = [rawHref stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (href.length == 0) {
        return NO;
    }

    NSString *lowercaseHref = href.lowercaseString;
    if ([lowercaseHref hasPrefix:@"javascript:"] ||
        [lowercaseHref hasPrefix:@"mailto:"] ||
        [lowercaseHref hasPrefix:@"tel:"] ||
        [lowercaseHref hasPrefix:@"#"]) {
        return NO;
    }

    if ([self isSamePageFragmentLinkForHref:href webView:webView]) {
        return NO;
    }

    NSURLRequest *request = [self.navigationService requestForURLString:href];
    if (request == nil) {
        return NO;
    }

    NSLog(@"[InputTrace][NewTabLink] Opening link in new tab on physical click href=%@", href);
    // If the tab limit (5 tabs) is reached, createNewTabWithRequest: presents the
    // "Maximum Tabs Reached" alert and returns NO. We still return YES so the
    // page does not navigate underneath the alert.
    [self.host browserPageActionCoordinatorCreateNewTabWithRequest:request];
    return YES;
}

- (void)presentEditableFieldPromptForFieldType:(NSString *)fieldType
                                         point:(CGPoint)point
                                       webView:(BrowserWebView *)webView {
    NSString *fieldTitle = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                         webView:webView
                                                                                            body:@"var target = browserEditableTarget();"
                                                                                                 "if (!target) { return ''; }"
                                                                                                 "return target.title || target.getAttribute('aria-label') || target.name || target.placeholder || '';"];
    if ([fieldTitle isEqualToString:@""]) {
        fieldTitle = fieldType;
    }
    NSString *placeholder = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                          webView:webView
                                                                                             body:@"var target = browserEditableTarget();"
                                                                                                  "if (!target) { return ''; }"
                                                                                                  "return target.placeholder || target.getAttribute('aria-label') || '';"];
    if ([placeholder isEqualToString:@""]) {
        placeholder = [fieldTitle isEqualToString:fieldType] ? @"Text Input" : [NSString stringWithFormat:@"%@ Input", fieldTitle];
    }
    NSString *testedFormResponse = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                                 webView:webView
                                                                                                    body:@"var target = browserEditableTarget();"
                                                                                                         "return (target && target.form && target.form.hasAttribute('onsubmit')) ? 'true' : 'false';"];
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Input Text"
                                                                             message:[fieldTitle capitalizedString]
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        if ([fieldType isEqualToString:@"url"]) {
            textField.keyboardType = UIKeyboardTypeURL;
        } else if ([fieldType isEqualToString:@"email"]) {
            textField.keyboardType = UIKeyboardTypeEmailAddress;
        } else if ([fieldType isEqualToString:@"tel"] ||
                   [fieldType isEqualToString:@"number"] ||
                   [fieldType isEqualToString:@"date"] ||
                   [fieldType isEqualToString:@"datetime"] ||
                   [fieldType isEqualToString:@"datetime-local"]) {
            textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        } else {
            textField.keyboardType = UIKeyboardTypeDefault;
        }
        textField.placeholder = [placeholder capitalizedString];
        if ([fieldType isEqualToString:@"password"]) {
            textField.secureTextEntry = YES;
        }
        textField.text = [weakSelf.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                           webView:webView
                                                                                              body:@"var target = browserEditableTarget();"
                                                                                                   "if (!target) { return ''; }"
                                                                                                   "if (typeof target.value !== 'undefined') { return target.value; }"
                                                                                                   "return target.textContent || '';"];
        textField.textColor = BrowserPageActionTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];

    UIAlertAction *submitAction = [UIAlertAction actionWithTitle:@"Submit"
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(__unused UIAlertAction *action) {
        UITextField *inputTextField = alertController.textFields.firstObject;
        NSString *escapedText = [weakSelf.domInteractionService javaScriptEscapedString:inputTextField.text];
        [weakSelf.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                         webView:webView
                                                                            body:[NSString stringWithFormat:@"var target = browserEditableTarget();"
                                                                                  "if (!target) { return 'false'; }"
                                                                                  "if (typeof target.value !== 'undefined') { target.value = '%@'; }"
                                                                                  "else { target.textContent = '%@'; }"
                                                                                  "if (target.dispatchEvent) {"
                                                                                      "target.dispatchEvent(new Event('input', { bubbles: true }));"
                                                                                      "target.dispatchEvent(new Event('change', { bubbles: true }));"
                                                                                  "}"
                                                                                  "if (target.form) { target.form.submit(); }"
                                                                                  "return 'true';", escapedText, escapedText]];
    }];
    UIAlertAction *doneAction = [UIAlertAction actionWithTitle:@"Done"
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *action) {
        UITextField *inputTextField = alertController.textFields.firstObject;
        NSString *escapedText = [weakSelf.domInteractionService javaScriptEscapedString:inputTextField.text];
        [weakSelf.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                         webView:webView
                                                                            body:[NSString stringWithFormat:@"var target = browserEditableTarget();"
                                                                                  "if (!target) { return 'false'; }"
                                                                                  "if (typeof target.value !== 'undefined') { target.value = '%@'; }"
                                                                                  "else { target.textContent = '%@'; }"
                                                                                  "if (target.dispatchEvent) {"
                                                                                      "target.dispatchEvent(new Event('input', { bubbles: true }));"
                                                                                      "target.dispatchEvent(new Event('change', { bubbles: true }));"
                                                                                  "}"
                                                                                  "return 'true';", escapedText, escapedText]];
    }];
    [alertController addAction:doneAction];
    if ([testedFormResponse isEqualToString:@"true"]) {
        [alertController addAction:submitAction];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPageActionCoordinatorPresentViewController:alertController];

    UITextField *inputTextField = alertController.textFields.firstObject;
    if ([[inputTextField.text stringByReplacingOccurrencesOfString:@" " withString:@""] isEqualToString:@""]) {
        [inputTextField becomeFirstResponder];
    }
}

- (BOOL)handlePageSelectionAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView
                               source:(BrowserPageActivationSource)source {
    if ([self handleTargetBlankLinkAtDOMPoint:point webView:webView]) {
        return YES;
    }
    // A click opens the link in a new tab; a light tap opens it in this one.
    // Holding the click counts as a click, so the hold length does not matter.
    //
    // Video players are the exception. A thumbnail is usually wrapped in a
    // link, so the new-tab rule grabbed the click before the player's own
    // handler ran and the video opened as a blank new tab instead of playing.
    // The click falls through to the page when the cursor is over a player,
    // whether or not the external player is switched on.
    BOOL overVideo = [self.domInteractionService isVideoActivationTargetAtDOMPoint:point
                                                                           webView:webView];
    if (!overVideo &&
        (source == BrowserPageActivationSourceClick ||
         source == BrowserPageActivationSourceLongClick) &&
        self.preferencesStore.openLinksInNewTabOnClick) {
        if ([self handleNewTabLinkOnClickAtDOMPoint:point webView:webView]) {
            return YES;
        }
    }

    NSString *fieldType = [self.domInteractionService evaluateResolvedElementJavaScriptAtPoint:point
                                                                                        webView:webView
                                                                                           body:@"function browserEditableTargetAtPoint() {"
                                                                                                "var candidate = editableElement;"
                                                                                                "if (!candidate && resolvedElement && resolvedElement.matches) {"
                                                                                                    "if (resolvedElement.matches(editableSelector) || resolvedElement.matches('textarea, select')) {"
                                                                                                        "candidate = resolvedElement;"
                                                                                                    "}"
                                                                                                "}"
                                                                                                "if (!candidate) { return null; }"
                                                                                                "window.__browserLastEditableElement = candidate;"
                                                                                                "return candidate;"
                                                                                                "}"
                                                                                                "var target = browserEditableTargetAtPoint();"
                                                                                                "if (!target) { return ''; }"
                                                                                                "var tagName = target.tagName ? target.tagName.toLowerCase() : '';"
                                                                                                "var type = (target.type || '').toLowerCase();"
                                                                                                "if (tagName === 'textarea' || target.isContentEditable) { return 'text'; }"
                                                                                                "if (tagName === 'input' && !type) { return 'text'; }"
                                                                                                "return type;"];
    [self.domInteractionService evaluateResolvedElementJavaScriptAtPoint:point
                                                                 webView:webView
                                                                    body:@"var target = editableElement || interactiveElement || resolvedElement;"
                                                                         "if (!target) { return 'false'; }"
                                                                         "try { if (target.focus) { target.focus(); } } catch (error) {}"
                                                                         "function dispatchPointerLikeEvent(type, constructorName) {"
                                                                             "try {"
                                                                                 "var Constructor = window[constructorName];"
                                                                                 "if (Constructor) {"
                                                                                     "var event = new Constructor(type, { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: 1, pointerType: 'mouse' });"
                                                                                     "return target.dispatchEvent(event);"
                                                                                 "}"
                                                                             "} catch (error) {}"
                                                                             "var mouseEvent = document.createEvent('MouseEvents');"
                                                                             "mouseEvent.initMouseEvent(type, true, true, window, 1, x, y, x, y, false, false, false, false, 0, null);"
                                                                             "return target.dispatchEvent(mouseEvent);"
                                                                         "}"
                                                                         "dispatchPointerLikeEvent('pointerdown', 'PointerEvent');"
                                                                         "dispatchPointerLikeEvent('mousedown', 'MouseEvent');"
                                                                         "dispatchPointerLikeEvent('pointerup', 'PointerEvent');"
                                                                         "dispatchPointerLikeEvent('mouseup', 'MouseEvent');"
                                                                         "if (typeof target.click === 'function') { target.click(); }"
                                                                         "else { dispatchPointerLikeEvent('click', 'MouseEvent'); }"
                                                                         "return 'true';"];
    fieldType = fieldType.lowercaseString;
    if ([fieldType isEqualToString:@"date"] ||
        [fieldType isEqualToString:@"datetime"] ||
        [fieldType isEqualToString:@"datetime-local"] ||
        [fieldType isEqualToString:@"email"] ||
        [fieldType isEqualToString:@"month"] ||
        [fieldType isEqualToString:@"number"] ||
        [fieldType isEqualToString:@"password"] ||
        [fieldType isEqualToString:@"search"] ||
        [fieldType isEqualToString:@"tel"] ||
        [fieldType isEqualToString:@"text"] ||
        [fieldType isEqualToString:@"time"] ||
        [fieldType isEqualToString:@"url"] ||
        [fieldType isEqualToString:@"week"]) {
        [self presentEditableFieldPromptForFieldType:fieldType point:point webView:webView];
    }
    return YES;
}

@end
```
