#import <UIKit/UIKit.h>
#import "BrowserWebView.h"

@class BrowserPreferencesStore;

@protocol BrowserMenuCoordinatorHost <NSObject>

@property (nonatomic, readonly) BrowserWebView *browserWebView;
@property (nonatomic, copy) NSString *browserPreviousURL;
@property (nonatomic) NSUInteger browserTextFontSize;
@property (nonatomic) BOOL browserFullscreenVideoPlaybackEnabled;
@property (nonatomic, readonly) BOOL browserTopMenuShowing;

- (void)browserPresentViewController:(UIViewController *)viewController;
- (void)browserLoadHomePage;
- (void)browserShowHints;
- (void)browserShowWhatsNew;
- (void)browserShowReader;
- (void)browserShowFeeds;
- (void)browserSubscribeToPageFeed;
- (void)browserSetSettingsTitleShown:(BOOL)shown;
- (void)browserShowTabOverview;
- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage;
- (void)browserHideTopNav;
- (void)browserShowTopNav;
- (void)browserUpdateTextFontSize;
- (void)browserCaptureSnapshotForCurrentTab;
- (void)browserRecreateActiveWebViewPreservingCurrentURL;
- (void)browserBringCursorToFront;
/// Shows the diagnostic log as a page.
- (void)browserShowDiagnosticLog;
/// The favorites changed (the top bar's star follows the current page).
- (void)browserFavoritesDidChange;

@end

@interface BrowserMenuCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore;
- (void)showAdvancedMenu;
/// The star in the top bar: add or remove this page, and the list.
- (void)presentFavoritesPanel;
/// YES when this address is saved as a favorite (scheme and host case, a
/// trailing slash and the #fragment are ignored).
- (BOOL)isFavoriteURLString:(nullable NSString *)URLString;

@end
