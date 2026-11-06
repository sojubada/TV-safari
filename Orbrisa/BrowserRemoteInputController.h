#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserRemoteInputControllerHost <NSObject>

- (nullable UIScrollView *)browserRemoteInputControllerActiveScrollView;
- (nullable UIViewController *)browserRemoteInputControllerPresentedViewController;
- (BOOL)browserRemoteInputControllerTopBarFocusActive;
- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus;
- (void)browserRemoteInputControllerActivateTopBarFocus;
- (void)browserRemoteInputControllerDeactivateTopBarFocus;
- (BOOL)browserRemoteInputControllerTabOverviewVisible;
- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point;
- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point;
- (void)browserRemoteInputControllerDismissTabOverview;
- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction;
- (void)browserRemoteInputControllerHandlePrimaryAction;
- (void)browserRemoteInputControllerHandleMenuPress;
- (void)browserRemoteInputControllerHandlePlayPausePress;
- (void)browserRemoteInputControllerHandleAdvancedMenuPress;
- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point;
- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled;
- (void)browserRemoteInputControllerPersistSession;
/// Link navigation: jump between the links and buttons of a page with the remote's arrow clicks.
- (void)browserRemoteInputControllerLinkNavigationDidChangeActive:(BOOL)active;
/// direction is "up", "down", "left" or "right". Returns "ok", "scrolled", "edge", "top" or "none".
- (NSString *)browserRemoteInputControllerLinkNavigationMove:(NSString *)direction;
- (void)browserRemoteInputControllerLinkNavigationActivate;
/// Up at the top of the page while the bar is hidden: select the red show-bar button. NO if it isn't shown.
- (BOOL)browserRemoteInputControllerLinkNavigationSelectShowBarButton;

// Carried over from TV-safari.
/// Bottom edge of the top bar in root coordinates, or 0 when the bar is not
/// on screen. The pointer slides into the bar at this line, and edge
/// auto-scroll starts below it.
- (CGFloat)browserRemoteInputControllerTopBarBottomEdge;
/// Brings a bar hidden by scrolling back. YES when it had to.
- (BOOL)browserRemoteInputControllerRevealTopBarIfHidden;
/// YES when the page is scrolled all the way to the top.
- (BOOL)browserRemoteInputControllerPageAtTop;
/// Scrolls the box under the cursor when the page itself doesn't move.
- (BOOL)browserRemoteInputControllerScrollActiveContainerByDelta:(CGPoint)delta atCursorPoint:(CGPoint)cursorPoint;
- (BOOL)browserRemoteInputControllerJSScrollFallbackEnabled;
- (BOOL)browserRemoteInputControllerDpadScrollEnabled;
- (BOOL)browserRemoteInputControllerEdgeAutoScrollEnabled;
- (BOOL)browserRemoteInputControllerTapToClickEnabled;
- (void)browserRemoteInputControllerGoBack;
- (void)browserRemoteInputControllerGoForward;

@optional
/// YES while a Bluetooth keyboard is typing into a field.
- (BOOL)browserRemoteInputControllerHardwareTypingActive;
/// A key from a Bluetooth keyboard, offered to the typing session first.
/// YES when it was used, so it isn't also read as a remote press.
- (BOOL)browserRemoteInputControllerHandleHardwareKeyPress:(UIPress *)press;

@end

@interface BrowserRemoteInputController : NSObject

@property (nonatomic, readonly) UIImageView *cursorView;
@property (nonatomic, readonly) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readonly) UITapGestureRecognizer *playPauseDoubleTapRecognizer;
@property (nonatomic, readonly, getter=isCursorModeEnabled) BOOL cursorModeEnabled;
/// Turned on and off by holding the center of the clickpad; Menu also turns it off.
@property (nonatomic, readonly, getter=isLinkNavigationActive) BOOL linkNavigationActive;

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)handleGlobalSelectPressEndedNotification;
- (void)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (void)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)handleTouchesEnded;
- (void)handleTouchesCancelled;
/// The bar gave focus back: park the pointer below it so it doesn't slide
/// straight back in.
- (void)noteTopBarFocusDeactivated;
- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled;
- (void)setLinkNavigationActive:(BOOL)linkNavigationActive;
- (void)refreshInteractionState;

@end

NS_ASSUME_NONNULL_END
