# tvOS Browser — 원본 소스 묶음 (작업 6용, v2.1.0 기준)

`docs/GEMINI_TASK_2.md` 작업에 필요한 파일들의 **현재 전체 원본**입니다.
앞부분은 수정 대상, 뒷부분은 호출할 API를 확인하기 위한 참조용 헤더입니다.

각 파일은 `FILE: <경로>` 줄 다음 코드 블록에 들어 있습니다. 경로는 저장소 루트 기준입니다.

## 수정 대상

---

FILE: _Project/Browser/BrowserRemoteInputController.h

```objc
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
- (BOOL)browserRemoteInputControllerScrollActiveContainerByDelta:(CGPoint)delta atCursorPoint:(CGPoint)cursorPoint;
- (BOOL)browserRemoteInputControllerJSScrollFallbackEnabled;
- (BOOL)browserRemoteInputControllerDpadScrollEnabled;
- (BOOL)browserRemoteInputControllerEdgeAutoScrollEnabled;

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
- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled;
- (void)refreshInteractionState;

@end

NS_ASSUME_NONNULL_END```

---

FILE: _Project/Browser/BrowserRemoteInputController.m

```objc
#import "BrowserRemoteInputController.h"

// The JavaScript scroll fallback runs synchronously (it pumps the run loop until
// WebKit answers), so it must never be driven at display-link rate. Deltas are
// accumulated and flushed at most this often.
static const CFTimeInterval kBrowserJSScrollMinimumInterval = 0.05;

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
    }
    return self;
}

- (void)dealloc {
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
        ![self.host browserRemoteInputControllerTopBarFocusActive];
}

- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled {
    BOOL wasCursorModeEnabled = self.cursorModeEnabled;
    _cursorModeEnabled = cursorModeEnabled;
    self.lastTouchLocation = CGPointMake(-1, -1);
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
    BOOL topBarFocusActive = [self.host browserRemoteInputControllerTopBarFocusActive];
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
        topBarFocusActive;
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
        [self.host browserRemoteInputControllerTopBarFocusActive]) {
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

- (void)handleGlobalSelectPressEndedNotification {
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
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

    [self.host browserRemoteInputControllerHandlePrimaryAction];
}

- (void)handleSelectPressEnded {
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
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerDismissTabOverview];
        return;
    }
    [self.host browserRemoteInputControllerHandleAdvancedMenuPress];
}

- (void)handleManualScrollPan:(UIPanGestureRecognizer *)gestureRecognizer {
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerTopBarFocusActive]) {
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
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
            [self stopDpadHoldAndContinuousScroll];
        }
    }
}

- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
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

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
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
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }
    self.lastTouchLocation = CGPointMake(-1, -1);
    return YES;
}

- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
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
    self.lastTouchLocation = CGPointMake(-1, -1);
    // The cursor only moves while a finger is on the touch surface, so a cursor
    // parked inside the edge zone would otherwise auto-scroll to the end of the
    // page after the finger is lifted. Auto-scroll lasts as long as the touch.
    [self stopEdgeAutoScroll];
}

@end```

---

FILE: _Project/Browser/ViewController.h

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

---

FILE: _Project/Browser/ViewController.m

```objc
//
//  ViewController.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

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
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";

static UIColor *kTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;

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
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator];

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

- (void)performTopBarAction:(BrowserTopBarAction)action {
    [self deactivateTopBarFocusMode];

    switch (action) {
        case BrowserTopBarActionBack:
            if (self.webview.canGoBack) {
                [self.webview goBack];
            }
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
    }
}

- (void)updateTextFontSize {
    if (self.webview == nil) {
        return;
    }

    NSString *jsString = [[NSString alloc] initWithFormat:
                          @"(function(){"
                           "var value='%lu%%';"
                           "var multiplier=%lu/100;"
                           "if (document.documentElement && document.documentElement.style) {"
                               "document.documentElement.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.documentElement.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (document.body && document.body.style) {"
                               "document.body.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.body.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (!document.body || !window.getComputedStyle) { return value; }"
                           "var elements = document.querySelectorAll('body, body *');"
                           "for (var i = 0; i < elements.length; i++) {"
                               "var element = elements[i];"
                               "if (!element || !element.tagName) { continue; }"
                               "var tagName = element.tagName.toLowerCase();"
                               "if (tagName === 'script' || tagName === 'style' || tagName === 'noscript') { continue; }"
                               "var originalSize = element.getAttribute('data-browser-original-font-size');"
                               "if (!originalSize) {"
                                   "var computedSize = window.getComputedStyle(element).fontSize || '';"
                                   "if (computedSize.indexOf('px') == -1) { continue; }"
                                   "var parsedSize = parseFloat(computedSize);"
                                   "if (!isFinite(parsedSize) || parsedSize <= 0) { continue; }"
                                   "originalSize = String(parsedSize);"
                                   "element.setAttribute('data-browser-original-font-size', originalSize);"
                               "}"
                               "var baseSize = parseFloat(originalSize);"
                               "if (!isFinite(baseSize) || baseSize <= 0) { continue; }"
                               "element.style.setProperty('font-size', (baseSize * multiplier) + 'px', 'important');"
                           "}"
                           "return value;"
                          "})()",
                          (unsigned long)self.viewModel.textFontSize,
                          (unsigned long)self.viewModel.textFontSize];
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
                                                                             message:@"Double press the touch area to switch between cursor & scroll mode.\nPress the touch area while in cursor mode to click.\nSingle tap to Menu button to Go Back, or Exit on root page.\nSingle tap the Play/Pause button to: Go Forward, Enter URL or Reload Page.\nDouble tap the Play/Pause to show the Advanced Menu with more options.\nUse the tabs icon in the top bar to open the tab overview."
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

- (void)browserHandlePrimaryAction {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        return;
    }

    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    if (point.y < 0) {
        [self activateTopBarFocusMode];
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
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

#pragma mark - BrowserTabCoordinatorHost

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (void)browserTabCoordinatorUpdateTextFontSize {
    [self updateTextFontSize];
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

- (void)browserRemoteInputControllerHandlePrimaryAction {
    [self browserHandlePrimaryAction];
}

- (void)browserRemoteInputControllerHandleMenuPress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.webview.canGoBack) {
        [self.webview goBack];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Exit App?"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Exit"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            exit(EXIT_SUCCESS);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
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

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    return [self.tabCoordinator createNewTabWithRequest:request];
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)navigationType;
    [self.tabCoordinator prepareTabForRequest:request webView:webView];
    return YES;
}

- (void)webViewDidStartLoad:(id)webView {
    [self.tabCoordinator webViewDidStartLoad:webView];
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
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
    [self.remoteInputController handleTouchesEnded];
    [super touchesCancelled:touches withEvent:event];
}

@end```

---

FILE: _Project/Browser/BrowserPageActionCoordinator.h

```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserDOMInteractionService;
@class BrowserNavigationService;
@class BrowserVideoPlaybackCoordinator;
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
    videoPlaybackCoordinator:(BrowserVideoPlaybackCoordinator *)videoPlaybackCoordinator NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (NSString *)hoverStateAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;
- (BOOL)handlePageSelectionAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;

@end

NS_ASSUME_NONNULL_END
```

---

FILE: _Project/Browser/BrowserPageActionCoordinator.m

```objc
#import "BrowserPageActionCoordinator.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserVideoPlaybackCoordinator.h"
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
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;

@end

@implementation BrowserPageActionCoordinator

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
    videoPlaybackCoordinator:(BrowserVideoPlaybackCoordinator *)videoPlaybackCoordinator {
    self = [super init];
    if (self) {
        _host = host;
        _domInteractionService = domInteractionService;
        _navigationService = navigationService;
        _videoPlaybackCoordinator = videoPlaybackCoordinator;
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

- (BOOL)handlePageSelectionAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    if ([self.videoPlaybackCoordinator handleSelectPressForVideoAtCursor]) {
        return YES;
    }
    if ([self handleTargetBlankLinkAtDOMPoint:point webView:webView]) {
        return YES;
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

---

FILE: _Project/Browser/BrowserPreferencesStore.h

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPreferencesStore : NSObject

+ (NSString *)desktopUserAgent;
+ (NSString *)mobileUserAgent;

@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL mobileModeEnabled;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) NSUInteger textFontSize;
@property (nonatomic) BOOL fullscreenVideoPlaybackEnabled;
@property (nonatomic) BOOL scalePagesToFit;
@property (nonatomic) BOOL dontShowHintsOnLaunch;
@property (nonatomic, copy) NSString *homePageURLString;
@property (nonatomic) BOOL jsScrollFallbackEnabled;
@property (nonatomic) BOOL dpadScrollEnabled;
@property (nonatomic) BOOL edgeAutoScrollEnabled;

- (void)ensureUserAgentConsistency;

@end

NS_ASSUME_NONNULL_END```

---

FILE: _Project/Browser/BrowserPreferencesStore.m

```objc
#import "BrowserPreferencesStore.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static NSString * const kMobileModeDefaultsKey = @"MobileMode";
static NSString * const kShowTopNavigationBarDefaultsKey = @"ShowTopNavigationBar";
static NSString * const kTextFontSizeDefaultsKey = @"TextFontSize";
static NSString * const kEnableFullscreenVideoPlaybackDefaultsKey = @"EnableFullscreenVideoPlayback";
static NSString * const kScalePagesToFitDefaultsKey = @"ScalePagesToFit";
static NSString * const kDontShowHintsOnLaunchDefaultsKey = @"DontShowHintsOnLaunch";
static NSString * const kHomepageDefaultsKey = @"homepage";
static NSString * const kJSScrollFallbackEnabledDefaultsKey = @"JSScrollFallbackEnabled";
static NSString * const kDpadScrollEnabledDefaultsKey = @"DpadScrollEnabled";
static NSString * const kEdgeAutoScrollEnabledDefaultsKey = @"EdgeAutoScrollEnabled";

static NSUInteger const kDefaultTextFontSize = 100;
static NSUInteger const kMinimumTextFontSize = 50;
static NSUInteger const kMaximumTextFontSize = 200;

@implementation BrowserPreferencesStore

+ (NSString *)desktopUserAgent {
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
}

+ (NSString *)mobileUserAgent {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
}

- (NSUserDefaults *)defaults {
    return [NSUserDefaults standardUserDefaults];
}

- (void)ensureUserAgentConsistency {
    if (self.userAgent.length > 0) {
        return;
    }
    self.userAgent = self.mobileModeEnabled ? BrowserPreferencesStore.mobileUserAgent : BrowserPreferencesStore.desktopUserAgent;
}

- (NSString *)userAgent {
    NSString *userAgent = [[self defaults] stringForKey:kUserAgentDefaultsKey];
    if (userAgent.length > 0) {
        return userAgent;
    }
    return self.mobileModeEnabled ? BrowserPreferencesStore.mobileUserAgent : BrowserPreferencesStore.desktopUserAgent;
}

- (void)setUserAgent:(NSString *)userAgent {
    [[self defaults] setObject:userAgent ?: @"" forKey:kUserAgentDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)mobileModeEnabled {
    return [[self defaults] boolForKey:kMobileModeDefaultsKey];
}

- (void)setMobileModeEnabled:(BOOL)mobileModeEnabled {
    [[self defaults] setBool:mobileModeEnabled forKey:kMobileModeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)topNavigationBarVisible {
    NSNumber *showTopNavBar = [[self defaults] objectForKey:kShowTopNavigationBarDefaultsKey];
    return showTopNavBar ? showTopNavBar.boolValue : YES;
}

- (void)setTopNavigationBarVisible:(BOOL)topNavigationBarVisible {
    [[self defaults] setObject:@(topNavigationBarVisible) forKey:kShowTopNavigationBarDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)textFontSize {
    NSNumber *textFontSizeValue = [[self defaults] objectForKey:kTextFontSizeDefaultsKey];
    if (textFontSizeValue == nil) {
        return kDefaultTextFontSize;
    }
    NSUInteger textFontSize = textFontSizeValue.unsignedIntegerValue;
    return MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
}

- (void)setTextFontSize:(NSUInteger)textFontSize {
    textFontSize = MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
    [[self defaults] setObject:@(textFontSize) forKey:kTextFontSizeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)fullscreenVideoPlaybackEnabled {
    return [[self defaults] boolForKey:kEnableFullscreenVideoPlaybackDefaultsKey];
}

- (void)setFullscreenVideoPlaybackEnabled:(BOOL)fullscreenVideoPlaybackEnabled {
    [[self defaults] setBool:fullscreenVideoPlaybackEnabled forKey:kEnableFullscreenVideoPlaybackDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)scalePagesToFit {
    return [[self defaults] boolForKey:kScalePagesToFitDefaultsKey];
}

- (void)setScalePagesToFit:(BOOL)scalePagesToFit {
    [[self defaults] setBool:scalePagesToFit forKey:kScalePagesToFitDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)dontShowHintsOnLaunch {
    return [[self defaults] boolForKey:kDontShowHintsOnLaunchDefaultsKey];
}

- (void)setDontShowHintsOnLaunch:(BOOL)dontShowHintsOnLaunch {
    [[self defaults] setBool:dontShowHintsOnLaunch forKey:kDontShowHintsOnLaunchDefaultsKey];
    [[self defaults] synchronize];
}

- (NSString *)homePageURLString {
    NSString *value = [[self defaults] stringForKey:kHomepageDefaultsKey];
    return value ?: @"";
}

- (void)setHomePageURLString:(NSString *)homePageURLString {
    [[self defaults] setObject:homePageURLString ?: @"" forKey:kHomepageDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)jsScrollFallbackEnabled {
    NSNumber *value = [[self defaults] objectForKey:kJSScrollFallbackEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setJsScrollFallbackEnabled:(BOOL)jsScrollFallbackEnabled {
    [[self defaults] setObject:@(jsScrollFallbackEnabled) forKey:kJSScrollFallbackEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)dpadScrollEnabled {
    NSNumber *value = [[self defaults] objectForKey:kDpadScrollEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setDpadScrollEnabled:(BOOL)dpadScrollEnabled {
    [[self defaults] setObject:@(dpadScrollEnabled) forKey:kDpadScrollEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)edgeAutoScrollEnabled {
    NSNumber *value = [[self defaults] objectForKey:kEdgeAutoScrollEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setEdgeAutoScrollEnabled:(BOOL)edgeAutoScrollEnabled {
    [[self defaults] setObject:@(edgeAutoScrollEnabled) forKey:kEdgeAutoScrollEnabledDefaultsKey];
    [[self defaults] synchronize];
}

@end```

---

FILE: _Project/Browser/BrowserMenuCoordinator.m

```objc
#import "BrowserMenuCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"

static UIColor *MenuTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

static NSString * const kBrowserMediaDiagnosticsLogPrefix = @"[MediaDiagnostics]";
static NSString * const kBrowserWebKitMediaPrefsLogPrefix = @"[WebKitMediaPrefs]";
static NSString * const kBrowserScrollDiagnosticsLogPrefix = @"[ScrollDiagnostics]";

typedef void (^BrowserAdvancedMenuItemHandler)(void);

@interface BrowserAdvancedMenuItem : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic) UIAlertActionStyle style;
@property (nonatomic, copy) BrowserAdvancedMenuItemHandler handler;

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

@end

@interface BrowserAdvancedMenuViewController ()

@property (nonatomic, copy) NSString *menuTitle;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuSection *> *sections;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic) UIView *dimView;
@property (nonatomic) UIVisualEffectView *panelView;
@property (nonatomic) UITableView *tableView;
@property (nonatomic) NSLayoutConstraint *panelTrailingConstraint;
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) BOOL didAnimateIn;
@property (nonatomic) BOOL dismissalInProgress;
@property (nonatomic) BOOL usingNativeGlassEffect;

@end

@implementation BrowserAdvancedMenuViewController

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

    self.panelWidth = MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds) * 0.38, 480.0), 700.0);
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

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.widthAnchor constraintEqualToConstant:self.panelWidth],
        [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16.0],
        [panelView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16.0],
        self.panelTrailingConstraint,

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
    self.panelTrailingConstraint.constant = -16.0;
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

    self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
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
    self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
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
        focusBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        focusBackgroundView.layer.cornerRadius = 12.0;
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
    titleLabel.textColor = titleColor;
    focusBackgroundView.alpha = cell.isFocused ? 1.0 : 0.0;
    return cell;
}

- (void)tableView:(UITableView *)tableView
didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context
withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    NSIndexPath *previousIndexPath = context.previouslyFocusedIndexPath;
    NSIndexPath *nextIndexPath = context.nextFocusedIndexPath;

    UITableViewCell *previousCell = previousIndexPath ? [tableView cellForRowAtIndexPath:previousIndexPath] : nil;
    UITableViewCell *nextCell = nextIndexPath ? [tableView cellForRowAtIndexPath:nextIndexPath] : nil;

    [coordinator addCoordinatedAnimations:^{
        UIView *previousFocusBackground = [previousCell.contentView viewWithTag:9292];
        previousFocusBackground.alpha = 0.0;

        UIView *nextFocusBackground = [nextCell.contentView viewWithTag:9292];
        nextFocusBackground.alpha = 1.0;
    } completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    BrowserAdvancedMenuItemHandler handler = item.handler;
    [self dismissMenuWithCompletion:^{
        if (handler != nil) {
            handler();
        }
    }];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.tableView];
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

@end

@implementation BrowserMenuCoordinator

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _host = host;
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
    }
    return self;
}

- (void)showAdvancedMenu {
    BrowserAdvancedMenuViewController *menuViewController = [[BrowserAdvancedMenuViewController alloc] initWithTitle:@"tvOS Browser"
                                                                                                            sections:[self advancedMenuSections]
                                                                                                          footerText:[self advancedMenuFooterText]];
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

- (void)saveFavoritesArray:(NSArray *)favorites {
    [[NSUserDefaults standardUserDefaults] setObject:favorites forKey:@"FAVORITES"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)presentDeleteFavoriteMenu {
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"];
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
            NSMutableArray *updatedFavorites = [favorites mutableCopy];
            [updatedFavorites removeObjectAtIndex:index];
            [weakSelf saveFavoritesArray:updatedFavorites];
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
        
        NSArray *favoriteEntry = @[currentURL, savedTitle ?: @""];
        NSMutableArray *favorites = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"] mutableCopy];
        if (favorites == nil) {
            favorites = [NSMutableArray array];
        }
        [favorites addObject:favoriteEntry];
        [weakSelf saveFavoritesArray:favorites];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentFavoritesMenu {
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"];
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

- (NSString *)mediaDiagnosticsJavaScript {
    return @"(function(){"
            "function canPlay(type){"
                "try {"
                    "var video=document.createElement('video');"
                    "if (!video || typeof video.canPlayType!=='function') { return 'n/a'; }"
                    "var value=video.canPlayType(type);"
                    "return value ? String(value) : '';"
                "} catch (error) { return 'error'; }"
            "}"
            "function mse(type){"
                "try {"
                    "if (typeof MediaSource==='undefined' || typeof MediaSource.isTypeSupported!=='function') { return 'n/a'; }"
                    "return MediaSource.isTypeSupported(type) ? 'yes' : 'no';"
                "} catch (error) { return 'error'; }"
            "}"
            "function probeGlobal(name){"
                "try {"
                    "var value=window[name];"
                    "if (typeof value==='undefined') { return 'undefined'; }"
                    "if (value === null) { return 'null'; }"
                    "return typeof value;"
                "} catch (error) { return 'error'; }"
            "}"
            "var video=document.querySelector('video');"
            "var result={"
                "href:(window.location && window.location.href) ? String(window.location.href) : '',"
                "title:(document && document.title) ? String(document.title) : '',"
                "userAgent:(navigator && navigator.userAgent) ? String(navigator.userAgent) : '',"
                "platform:(navigator && navigator.platform) ? String(navigator.platform) : '',"
                "mediaSource:(typeof MediaSource!=='undefined') ? 'yes' : 'no',"
                "managedMediaSource:(typeof ManagedMediaSource!=='undefined') ? 'yes' : 'no',"
                "mediaCapabilities:(typeof navigator.mediaCapabilities!=='undefined') ? 'yes' : 'no',"
                "videoElement:video ? 'yes' : 'no',"
                "videoSrc:video ? String(video.currentSrc||video.src||'') : '',"
                "globalMediaSource:probeGlobal('MediaSource'),"
                "globalManagedMediaSource:probeGlobal('ManagedMediaSource'),"
                "globalWebKitMediaSource:probeGlobal('WebKitMediaSource'),"
                "globalSourceBuffer:probeGlobal('SourceBuffer'),"
                "globalManagedSourceBuffer:probeGlobal('ManagedSourceBuffer'),"
                "globalWebKitSourceBuffer:probeGlobal('WebKitSourceBuffer'),"
                "hls:canPlay('application/vnd.apple.mpegurl'),"
                "mp4H264:canPlay('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"'),"
                "mp4Hevc:canPlay('video/mp4; codecs=\"hvc1.1.6.L93.B0, mp4a.40.2\"'),"
                "webmVp9:canPlay('video/webm; codecs=\"vp9\"'),"
                "mp4Av1:canPlay('video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"'),"
                "webmAv1:canPlay('video/webm; codecs=\"av01.0.05M.08\"'),"
                "mseMp4H264:mse('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"'),"
                "mseWebmVp9:mse('video/webm; codecs=\"vp9\"'),"
                "mseMp4Av1:mse('video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"'),"
                "mseWebmAv1:mse('video/webm; codecs=\"av01.0.05M.08\"')"
            "};"
            "return JSON.stringify(result);"
           "})()";
}

- (NSDictionary *)mediaDiagnosticsDictionary {
    NSString *resultString = [[self.host browserWebView] stringByEvaluatingJavaScriptFromString:[self mediaDiagnosticsJavaScript]];
    if (![self stringHasVisibleContent:resultString]) {
        return nil;
    }

    NSData *resultData = [resultString dataUsingEncoding:NSUTF8StringEncoding];
    if (resultData == nil) {
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:resultData options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return object;
}

- (NSString *)stringValueForDiagnosticsKey:(NSString *)key dictionary:(NSDictionary *)dictionary fallback:(NSString *)fallback {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSString class]] && [self stringHasVisibleContent:value]) {
        return value;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *stringValue = [value stringValue];
        if ([self stringHasVisibleContent:stringValue]) {
            return stringValue;
        }
    }
    return fallback;
}

- (void)presentMediaDiagnostics {
    NSDictionary *diagnostics = [self mediaDiagnosticsDictionary];
    if (diagnostics == nil) {
        UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Media Diagnostics"
                                                                           message:@"The page did not return diagnostics data."];
        [alertController addAction:[self browserCancelAction]];
        [self.host browserPresentViewController:alertController];
        return;
    }

    BOOL mobileModeEnabled = self.preferencesStore.mobileModeEnabled;
    NSString *message = [NSString stringWithFormat:
                         @"Mode: %@\n"
                          "URL: %@\n"
                          "UA: %@\n\n"
                          "MediaSource: %@\n"
                          "ManagedMediaSource: %@\n"
                          "MediaCapabilities: %@\n"
                          "Video Element: %@\n"
                          "Video Src: %@\n\n"
                          "Global MediaSource: %@\n"
                          "Global ManagedMediaSource: %@\n"
                          "Global WebKitMediaSource: %@\n"
                          "Global SourceBuffer: %@\n"
                          "Global ManagedSourceBuffer: %@\n"
                          "Global WebKitSourceBuffer: %@\n\n"
                          "canPlay HLS: %@\n"
                          "canPlay MP4 H.264: %@\n"
                          "canPlay MP4 HEVC: %@\n"
                          "canPlay WebM VP9: %@\n"
                          "canPlay MP4 AV1: %@\n"
                          "canPlay WebM AV1: %@\n\n"
                          "MSE MP4 H.264: %@\n"
                          "MSE WebM VP9: %@\n"
                          "MSE MP4 AV1: %@\n"
                          "MSE WebM AV1: %@",
                         mobileModeEnabled ? @"Mobile" : @"Desktop",
                         [self stringValueForDiagnosticsKey:@"href" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"userAgent" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"mediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"managedMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mediaCapabilities" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"videoElement" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"videoSrc" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"globalMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalManagedMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalWebKitMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalManagedSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalWebKitSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"hls" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4H264" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4Hevc" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"webmVp9" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4Av1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"webmAv1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseMp4H264" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseWebmVp9" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseMp4Av1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseWebmAv1" dictionary:diagnostics fallback:@"n/a"]];

    NSLog(@"%@ %@", kBrowserMediaDiagnosticsLogPrefix, message);

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Media Diagnostics"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentWebKitRuntimeMediaPreferences {
    NSString *report = [[self.host browserWebView] runtimeMediaPreferenceReport];
    if (![self stringHasVisibleContent:report]) {
        report = @"No runtime WebKit media preference information was returned.";
    }

    NSLog(@"%@ %@", kBrowserWebKitMediaPrefsLogPrefix, report);

    NSString *message = report;
    if (message.length > 1800) {
        message = [[message substringToIndex:1800] stringByAppendingString:@"\n\nFull report logged to console."];
    }

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"WebKit Media Prefs"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (NSString *)pageScrollDiagnosticsJavaScript {
    return @"(function(){"
            "var docEl = document.documentElement;"
            "var body = document.body;"
            "var docScrollHeight = docEl ? (docEl.scrollHeight || 0) : 0;"
            "var bodyScrollHeight = body ? (body.scrollHeight || 0) : 0;"
            "var winInnerHeight = window.innerHeight || 0;"
            "var winInnerWidth = window.innerWidth || 0;"
            "var count = 0;"
            "var maxScrollHeight = 0;"
            "var maxContainerDesc = 'none';"
            "if (document.querySelectorAll && window.getComputedStyle) {"
                "var all = document.querySelectorAll('*');"
                "for (var i = 0; i < all.length; i++) {"
                    "var el = all[i];"
                    "if (el === docEl || el === body) { continue; }"
                    "var sh = el.scrollHeight || 0;"
                    "var ch = el.clientHeight || 0;"
                    "if (sh > ch + 1) {"
                        "var st = window.getComputedStyle(el);"
                        "var oy = st ? (st.overflowY || st.overflow || '') : '';"
                        "if (oy === 'auto' || oy === 'scroll' || oy === 'overlay') {"
                            "count++;"
                            "if (sh > maxScrollHeight) {"
                                "maxScrollHeight = sh;"
                                "var tag = el.tagName ? el.tagName.toLowerCase() : 'el';"
                                "var idStr = el.id ? ('#' + el.id) : '';"
                                "maxContainerDesc = tag + idStr;"
                            "}"
                        "}"
                    "}"
                "}"
            "}"
            "return JSON.stringify({"
                "docScrollHeight: docScrollHeight,"
                "bodyScrollHeight: bodyScrollHeight,"
                "innerHeight: winInnerHeight,"
                "innerWidth: winInnerWidth,"
                "scrollableCount: count,"
                "maxContainerScrollHeight: maxScrollHeight,"
                "maxContainerDesc: maxContainerDesc"
            "});"
           "})()";
}

- (void)presentPageScrollDiagnostics {
    BrowserWebView *webView = [self.host browserWebView];
    UIScrollView *scrollView = webView.scrollView;
    CGFloat contentSizeHeight = scrollView ? scrollView.contentSize.height : 0.0;
    CGFloat boundsHeight = scrollView ? CGRectGetHeight(scrollView.bounds) : 0.0;
    CGFloat offsetY = scrollView ? scrollView.contentOffset.y : 0.0;

    NSString *jsResult = [webView stringByEvaluatingJavaScriptFromString:[self pageScrollDiagnosticsJavaScript]];
    NSDictionary *dict = nil;
    if ([self stringHasVisibleContent:jsResult]) {
        NSData *data = [jsResult dataUsingEncoding:NSUTF8StringEncoding];
        if (data != nil) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                dict = obj;
            }
        }
    }

    CGFloat pageZoom = 1.0;
    @try {
        id zoomVal = [webView valueForKey:@"pageZoom"];
        if ([zoomVal respondsToSelector:@selector(doubleValue)]) {
            pageZoom = (CGFloat)[zoomVal doubleValue];
        }
    } @catch (__unused NSException *exception) {
        NSInteger innerWidth = [dict[@"innerWidth"] respondsToSelector:@selector(integerValue)] ? [dict[@"innerWidth"] integerValue] : 0;
        if (innerWidth > 0 && CGRectGetWidth(webView.frame) > 0.0) {
            pageZoom = CGRectGetWidth(webView.frame) / (CGFloat)innerWidth;
        }
    }

    NSString *message = [NSString stringWithFormat:
                         @"documentElement.scrollHeight: %@\n"
                          "body.scrollHeight: %@\n"
                          "window.innerHeight: %@\n\n"
                          "scrollView.contentSize.height: %.1f\n"
                          "scrollView.bounds.size.height: %.1f\n"
                          "scrollView.contentOffset.y: %.1f\n\n"
                          "Scrollable Containers: %@\n"
                          "Largest Container scrollHeight: %@ (%@)\n\n"
                          "pageZoom: %.2f (scalesPageToFit: %@)",
                         [self stringValueForDiagnosticsKey:@"docScrollHeight" dictionary:dict fallback:@"0"],
                         [self stringValueForDiagnosticsKey:@"bodyScrollHeight" dictionary:dict fallback:@"0"],
                         [self stringValueForDiagnosticsKey:@"innerHeight" dictionary:dict fallback:@"0"],
                         contentSizeHeight,
                         boundsHeight,
                         offsetY,
                         [self stringValueForDiagnosticsKey:@"scrollableCount" dictionary:dict fallback:@"0"],
                         [self stringValueForDiagnosticsKey:@"maxContainerScrollHeight" dictionary:dict fallback:@"0"],
                         [self stringValueForDiagnosticsKey:@"maxContainerDesc" dictionary:dict fallback:@"none"],
                         pageZoom,
                         webView.scalesPageToFit ? @"YES" : @"NO"];

    NSLog(@"%@ %@", kBrowserScrollDiagnosticsLogPrefix, message);

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Page Scroll Diagnostics"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (BrowserAdvancedMenuItem *)jsScrollFallbackToggleMenuItem {
    BOOL enabled = self.preferencesStore.jsScrollFallbackEnabled;
    NSString *title = enabled ? @"JS Scroll Fallback: On" : @"JS Scroll Fallback: Off";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.preferencesStore.jsScrollFallbackEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)dpadScrollToggleMenuItem {
    BOOL enabled = self.preferencesStore.dpadScrollEnabled;
    NSString *title = enabled ? @"D-Pad Page Scroll: On" : @"D-Pad Page Scroll: Off";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.preferencesStore.dpadScrollEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)edgeAutoScrollToggleMenuItem {
    BOOL enabled = self.preferencesStore.edgeAutoScrollEnabled;
    NSString *title = enabled ? @"Edge Auto-Scroll: On" : @"Edge Auto-Scroll: Off";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.preferencesStore.edgeAutoScrollEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)topNavigationVisibilityMenuItem {
    NSString *title = self.host.browserTopMenuShowing ? @"Hide Top Navigation bar" : @"Show Top Navigation bar";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
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

- (UIAlertAction *)wkWebViewProofOfConceptAction {
    return [self browserActionWithTitle:@"Open WKWebView PoC"
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction *action) {
        Class proofOfConceptControllerClass = NSClassFromString(@"BrowserWKWebViewProofOfConceptViewController");
        UIViewController *viewController = nil;
        if (proofOfConceptControllerClass != Nil) {
            viewController = [proofOfConceptControllerClass new];
            viewController.modalPresentationStyle = UIModalPresentationFullScreen;
        } else {
            viewController = [UIAlertController alertControllerWithTitle:@"WKWebView PoC Missing"
                                                                 message:@"The proof-of-concept controller was not compiled into this build."
                                                          preferredStyle:UIAlertControllerStyleAlert];
            [(UIAlertController *)viewController addAction:[self browserCancelAction]];
        }
        [self.host browserPresentViewController:viewController];
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
    
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self applyUserAgent:userAgent mobileMode:mobileMode];
    }];
}

- (BrowserAdvancedMenuItem *)pageScalingMenuItem {
    BOOL scalesPageToFit = [[self.host browserWebView] scalesPageToFit];
    NSString *title = scalesPageToFit ? @"Stop Scaling Pages to Fit" : @"Scale Pages to Fit";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self setPageScalingEnabled:!scalesPageToFit];
    }];
}

- (UIAlertAction *)playVideoUnderCursorAction {
    return [self browserActionWithTitle:@"Play Active Video"
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.host browserPlayVideoUnderCursorIfAvailable];
        });
    }];
}

- (BrowserAdvancedMenuItem *)fullscreenVideoPlaybackToggleMenuItem {
    BOOL enabled = self.host.browserFullscreenVideoPlaybackEnabled;
    NSString *title = enabled ? @"Disable Full Screen player" : @"Enable Full Screen player";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.host.browserFullscreenVideoPlaybackEnabled = !enabled;
    }];
}

- (NSArray<BrowserAdvancedMenuSection *> *)advancedMenuSections {
    BrowserAdvancedMenuItem *increaseFontSizeItem = [self advancedMenuItemWithTitle:@"Increase Font Size"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        self.host.browserTextFontSize += 5;
        [self.host browserUpdateTextFontSize];
    }];
    BrowserAdvancedMenuItem *decreaseFontSizeItem = [self advancedMenuItemWithTitle:@"Decrease Font Size"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        self.host.browserTextFontSize -= 5;
        [self.host browserUpdateTextFontSize];
    }];
    BrowserAdvancedMenuItem *resetFontSizeItem = [self advancedMenuItemWithTitle:@"Reset Font Size"
                                                                            style:UIAlertActionStyleDefault
                                                                          handler:^{
        self.host.browserTextFontSize = 100;
        [self.host browserUpdateTextFontSize];
    }];
    BrowserAdvancedMenuItem *pageScrollDiagnosticsItem = [self advancedMenuItemWithTitle:@"Page Scroll Diagnostics"
                                                                                   style:UIAlertActionStyleDefault
                                                                                 handler:^{
        [self presentPageScrollDiagnostics];
    }];
    BrowserAdvancedMenuItem *mediaDiagnosticsItem = [self advancedMenuItemWithTitle:@"Media Diagnostics"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        [self presentMediaDiagnostics];
    }];
    BrowserAdvancedMenuItem *webkitMediaPrefsItem = [self advancedMenuItemWithTitle:@"Inspect WebKit Media Prefs"
                                                                                style:UIAlertActionStyleDefault
                                                                              handler:^{
        [self presentWebKitRuntimeMediaPreferences];
    }];
    BrowserAdvancedMenuItem *clearCacheItem = [self advancedMenuItemWithTitle:@"Clear Cache"
                                                                         style:UIAlertActionStyleDestructive
                                                                       handler:^{
        [self clearCacheAndReload];
    }];
    BrowserAdvancedMenuItem *clearCookiesItem = [self advancedMenuItemWithTitle:@"Clear Cookies"
                                                                           style:UIAlertActionStyleDestructive
                                                                         handler:^{
        [self clearCookiesAndReload];
    }];

    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Navigation"
                                               items:@[
            [self homePageMenuItem],
            [self setCurrentPageAsHomePageMenuItem],
            [self favoritesMenuItem],
            [self historyMenuItem],
            [self showTabsMenuItem],
            [self newTabMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Scrolling & Input"
                                               items:@[
            [self dpadScrollToggleMenuItem],
            [self edgeAutoScrollToggleMenuItem],
            [self jsScrollFallbackToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Appearance"
                                               items:@[
            [self topNavigationVisibilityMenuItem],
            [self pageScalingMenuItem],
            increaseFontSizeItem,
            decreaseFontSizeItem,
            resetFontSizeItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Video Playback"
                                               items:@[
            [self fullscreenVideoPlaybackToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Compatibility"
                                               items:@[
            [self userAgentModeMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Diagnostics"
                                               items:@[
            pageScrollDiagnosticsItem,
            mediaDiagnosticsItem,
            webkitMediaPrefsItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Maintenance"
                                               items:@[
            clearCacheItem,
            clearCookiesItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Help"
                                               items:@[
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

@end```

## 참조용 — 호출할 API (수정하지 말 것)

---

FILE: _Project/Browser/BrowserTabCoordinator.h

_새 탭 생성 API_

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
- (void)setTopNavigationVisible:(BOOL)visible;
- (BrowserTabViewModel *)tabForWebView:(id)webView;
- (BOOL)isPrimaryDocumentRequest:(NSURLRequest *)request;

@end

NS_ASSUME_NONNULL_END
```

---

FILE: _Project/Browser/BrowserViewModel.h

_탭 모델_

```objc
#import <Foundation/Foundation.h>

@class BrowserTabViewModel;

@interface BrowserViewModel : NSObject

@property (nonatomic, strong, readonly) NSMutableArray *tabs;
@property (nonatomic) NSInteger activeTabIndex;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) BOOL tabOverviewVisible;
@property (nonatomic) NSUInteger textFontSize;
@property (nonatomic) BOOL fullscreenVideoPlaybackEnabled;

- (BrowserTabViewModel *)activeTab;
- (BrowserTabViewModel *)addTab;
- (BrowserTabViewModel *)ensureActiveTab;
- (BrowserTabViewModel *)removeTabAtIndex:(NSInteger)tabIndex;
- (void)restoreTabs:(NSArray<BrowserTabViewModel *> *)tabs activeTabIndex:(NSInteger)activeTabIndex;
- (void)switchToTabAtIndex:(NSInteger)tabIndex;

@end
```

---

FILE: _Project/Browser/BrowserViewModel.m

_최대 탭 수 kMaximumTabCount_

```objc
#import "BrowserViewModel.h"

#import "BrowserTabViewModel.h"

static NSUInteger const kDefaultTextFontSize = 100;
static NSUInteger const kMinimumTextFontSize = 50;
static NSUInteger const kMaximumTextFontSize = 200;
static NSUInteger const kMaximumTabCount = 5;
@implementation BrowserViewModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _tabs = [NSMutableArray array];
        _activeTabIndex = NSNotFound;
        _topNavigationBarVisible = YES;
        _textFontSize = kDefaultTextFontSize;
        _fullscreenVideoPlaybackEnabled = NO;
    }
    return self;
}

- (BrowserTabViewModel *)activeTab {
    if (self.activeTabIndex == NSNotFound || self.activeTabIndex < 0 || self.activeTabIndex >= self.tabs.count) {
        return nil;
    }
    return self.tabs[self.activeTabIndex];
}

- (BrowserTabViewModel *)addTab {
    if (self.tabs.count >= kMaximumTabCount) {
        return nil;
    }
    
    BrowserTabViewModel *tab = [BrowserTabViewModel new];
    [self.tabs addObject:tab];
    self.activeTabIndex = self.tabs.count - 1;
    return tab;
}

- (BrowserTabViewModel *)ensureActiveTab {
    BrowserTabViewModel *tab = [self activeTab];
    if (tab != nil) {
        return tab;
    }
    return [self addTab];
}

- (BrowserTabViewModel *)removeTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.tabs.count) {
        return nil;
    }
    
    BrowserTabViewModel *removedTab = self.tabs[tabIndex];
    [self.tabs removeObjectAtIndex:tabIndex];
    
    if (self.tabs.count == 0) {
        self.activeTabIndex = NSNotFound;
    } else if (tabIndex == self.activeTabIndex) {
        self.activeTabIndex = MIN(tabIndex, self.tabs.count - 1);
    } else if (tabIndex < self.activeTabIndex) {
        self.activeTabIndex -= 1;
    }
    
    return removedTab;
}

- (void)restoreTabs:(NSArray<BrowserTabViewModel *> *)tabs activeTabIndex:(NSInteger)activeTabIndex {
    [self.tabs removeAllObjects];
    if (tabs.count > 0) {
        [self.tabs addObjectsFromArray:tabs];
    }
    
    if (self.tabs.count == 0) {
        self.activeTabIndex = NSNotFound;
        return;
    }
    
    if (activeTabIndex < 0 || activeTabIndex >= self.tabs.count) {
        self.activeTabIndex = 0;
        return;
    }
    
    self.activeTabIndex = activeTabIndex;
}

- (void)switchToTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.tabs.count) {
        return;
    }
    self.activeTabIndex = tabIndex;
}

- (void)setTopNavigationBarVisible:(BOOL)topNavigationBarVisible {
    _topNavigationBarVisible = topNavigationBarVisible;
}

- (void)setTextFontSize:(NSUInteger)textFontSize {
    textFontSize = MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
    _textFontSize = textFontSize;
}

- (void)setFullscreenVideoPlaybackEnabled:(BOOL)fullscreenVideoPlaybackEnabled {
    _fullscreenVideoPlaybackEnabled = fullscreenVideoPlaybackEnabled;
}

@end
```

---

FILE: _Project/Browser/BrowserDOMInteractionService.h

_linkInfoAtDOMPoint:_

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

NS_ASSUME_NONNULL_END```

---

FILE: _Project/Browser/BrowserNavigationService.h

_requestForURLString:_

```objc
#import <Foundation/Foundation.h>

@class BrowserTabViewModel;
@class BrowserPreferencesStore;

@interface BrowserNavigationService : NSObject

- (instancetype)initWithPreferencesStore:(BrowserPreferencesStore *)preferencesStore;
- (NSURLRequest *)homePageRequest;
- (NSURLRequest *)requestForURLString:(NSString *)URLString;
- (NSURLRequest *)requestForEnteredAddressString:(NSString *)addressString;
- (NSURLRequest *)googleSearchRequestForQuery:(NSString *)query;
- (NSURLRequest *)googleSearchRequestForFailedRequestURLString:(NSString *)requestURLString;
- (void)updateTab:(BrowserTabViewModel *)tab
    withPageTitle:(NSString *)pageTitle
  currentURLString:(NSString *)currentURLString;
- (BOOL)shouldIgnoreLoadError:(NSError *)error;

@end
```

---

FILE: _Project/Browser/BrowserWebView.h

_웹뷰 시그니처_

```objc
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserWebViewDelegate <NSObject>

@optional
- (BOOL)webView:(id _Nonnull)webView shouldStartLoadWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (BOOL)webView:(id _Nonnull)webView shouldCreateNewTabWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (void)webViewDidStartLoad:(id _Nonnull)webView;
- (void)webViewDidFinishLoad:(id _Nonnull)webView;
- (void)webView:(id _Nonnull)webView didFailLoadWithError:(NSError * _Nonnull)error;

@end

@interface BrowserWebView : UIView

@property (nullable, nonatomic, weak) id<BrowserWebViewDelegate> delegate;
@property (nullable, nonatomic, readonly, strong) NSURLRequest *request;
@property (nullable, nonatomic, readonly, strong) UIScrollView *scrollView;
@property (nullable, nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, getter=canGoBack) BOOL canGoBack;
@property (nonatomic, readonly, getter=canGoForward) BOOL canGoForward;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic) BOOL scalesPageToFit;

- (instancetype)initWithUserAgent:(NSString * _Nullable)userAgent
      allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback NS_DESIGNATED_INITIALIZER;

- (void)loadRequest:(NSURLRequest * _Nullable)request;
- (void)reload;
- (void)goBack;
- (void)goForward;
- (nullable NSString *)stringByEvaluatingJavaScriptFromString:(NSString * _Nonnull)script;
- (NSString * _Nonnull)runtimeMediaPreferenceReport;
- (void)setUserAgent:(NSString * _Nullable)userAgent;
- (void)pauseAllMediaPlayback;

+ (nullable NSData *)cookieDataRepresentation;
+ (NSArray<NSHTTPCookie *> * _Nonnull)allCookies;
+ (void)restoreCookiesFromData:(NSData * _Nullable)cookieData;
+ (void)clearCachedDataWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)clearCookiesWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)resetWebsiteDataWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
```

