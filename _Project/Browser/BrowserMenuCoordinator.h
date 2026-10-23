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
- (void)browserShowTabOverview;
- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage;
- (void)browserHideTopNav;
- (void)browserShowTopNav;
- (void)browserUpdateTextFontSize;
- (void)browserApplyReadingZoom;
- (void)browserShowProbeWorkbench;
- (void)browserReloadActivePage;
- (NSString *)browserFitPageWidth;
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
