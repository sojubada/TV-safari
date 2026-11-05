#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when the Liquid Glass amount changes (Settings slider).
FOUNDATION_EXPORT NSNotificationName const BrowserGlassAmountDidChangeNotification;
/// 0 = no glass (solid surfaces) … 1 = full Liquid Glass (default).
FOUNDATION_EXPORT CGFloat BrowserGlassAmount(void);
FOUNDATION_EXPORT void BrowserSetGlassAmount(CGFloat amount);
/// Lays a solid colour over a glass view's background, as opaque as the glass is turned down.
FOUNDATION_EXPORT void BrowserApplyGlassAmount(UIVisualEffectView *effectView, UIColor *solidColor);

typedef NS_ENUM(NSInteger, BrowserTopBarAction) {
    BrowserTopBarActionBack = 0,
    BrowserTopBarActionRefresh,
    BrowserTopBarActionForward,
    BrowserTopBarActionHome,
    BrowserTopBarActionTabs,
    BrowserTopBarActionURL,
    BrowserTopBarActionFullscreen,
    BrowserTopBarActionMenu,
    BrowserTopBarActionReader,
    BrowserTopBarActionFeed
};

@class BrowserTopBarView;

@protocol BrowserTopBarViewDelegate <NSObject>

- (void)browserTopBarView:(BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action;

@end

/// Top navigation bar in three glass islands:
/// left (back, forward, reload) · center (page title, address, progress) · right (home, tabs, fullscreen, menu).
@interface BrowserTopBarView : UIVisualEffectView

@property (nonatomic, weak, nullable) id<BrowserTopBarViewDelegate> delegate;
@property (nonatomic, readonly) UIImageView *backImageView;
@property (nonatomic, readonly) UIImageView *refreshImageView;
@property (nonatomic, readonly) UIImageView *forwardImageView;
@property (nonatomic, readonly) UIImageView *homeImageView;
@property (nonatomic, readonly) UIImageView *tabsImageView;
@property (nonatomic, readonly) UIImageView *fullscreenImageView;
@property (nonatomic, readonly) UIImageView *menuImageView;
/// The large first line of the center pill (page title, or the host when there is no title).
@property (nonatomic, readonly) UILabel *URLLabel;
/// Start/stop it as before: the bar shows a progress line in the center pill while it animates.
@property (nonatomic, readonly) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, readonly, getter=isFocusModeActive) BOOL focusModeActive;

- (CGRect)interactiveFrameForView:(UIView *)view;
- (void)setFocusModeActive:(BOOL)focusModeActive;
- (nullable UIView *)preferredFocusItem;

/// Shows the page title on the first line and the address (with a lock for https) on the second.
- (void)setPageTitle:(nullable NSString *)title URLString:(nullable NSString *)URLString;
/// Shows a fixed title (e.g. "Einstellungen") in the address field until it is cleared with nil; page updates are kept for later.
- (void)setOverrideTitle:(nullable NSString *)title subtitle:(nullable NSString *)subtitle;
/// Same, with a small orange symbol in front of the title (e.g. the RSS symbol for the feeds).
- (void)setOverrideTitle:(nullable NSString *)title subtitle:(nullable NSString *)subtitle symbolName:(nullable NSString *)symbolName;
/// Number shown on the tabs button; 0 hides it.
- (void)setTabCount:(NSUInteger)tabCount;
/// Shows the "Reader" button in the address pill and the RSS button next to it (only when the page has an article / a feed).
- (void)setReaderAvailable:(BOOL)readerAvailable feedAvailable:(BOOL)feedAvailable;
/// Dims the back/forward buttons when there is nowhere to go.
- (void)setCanGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
/// YES for a bright page (grey glass, white symbols), NO for a dark page (light glass, dark symbols).
- (void)setPageIsLight:(BOOL)pageIsLight animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
