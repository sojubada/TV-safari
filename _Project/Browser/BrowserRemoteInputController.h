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
/// Offers a press to the hardware keyboard path before anything else sees
/// it. YES when it was a key that got typed into the page.
- (BOOL)browserRemoteInputControllerHandleHardwareKeyPress:(UIPress *)press;
- (BOOL)browserRemoteInputControllerFocusNavigationActive;
- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus;
/// Bottom edge of the top bar in root coordinates, or 0 when the bar is
/// hidden. The pointer snaps into the bar at this line, and page edge
/// auto-scroll starts below it.
- (CGFloat)browserRemoteInputControllerTopBarBottomEdge;
/// Restores bar focus after a menu closed, if the bar had it when the menu
/// opened. Returns YES when it took the press.
- (BOOL)browserRemoteInputControllerRestoreTopBarFocusIfPending;
- (void)browserRemoteInputControllerCancelPendingTopBarFocusRestore;
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
/// Called when the bar gives focus back, so the pointer reappears below the
/// bar instead of inside it, where it would snap straight back in.
- (void)noteTopBarFocusDeactivated;

@end

NS_ASSUME_NONNULL_END