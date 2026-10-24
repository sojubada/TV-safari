#import "BrowserRemoteInputController.h"

// The JavaScript scroll fallback runs synchronously (it pumps the run loop until
// WebKit answers), so it must never be driven at display-link rate. Deltas are
// accumulated and flushed at most this often.
static const CFTimeInterval kBrowserJSScrollMinimumInterval = 0.05;
static const CFTimeInterval kBrowserSelectLongClickThreshold = 0.5;

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

@property (nonatomic) BOOL trackingTouchForTap;
@property (nonatomic) CFTimeInterval currentTouchStartTime;
@property (nonatomic) CGPoint currentTouchStartCursorOrigin;
@property (nonatomic) CGFloat currentTouchMaxCursorDistance;
@property (nonatomic) BOOL selectPressDuringCurrentTouch;
@property (nonatomic) CFTimeInterval lastSelectPressActivityTimestamp;
@property (nonatomic) CFTimeInterval selectPressStartTime;
@property (nonatomic, nullable) NSTimer *cursorIdleTimer;
@property (nonatomic) CFTimeInterval lastCursorActivityTimestamp;

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

        [self noteCursorActivity];
    }
    return self;
}

- (void)dealloc {
    [self.cursorIdleTimer invalidate];
    self.cursorIdleTimer = nil;
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
        ![self.host browserRemoteInputControllerFocusNavigationActive];
}

- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled {
    BOOL wasCursorModeEnabled = self.cursorModeEnabled;
    _cursorModeEnabled = cursorModeEnabled;
    self.lastTouchLocation = CGPointMake(-1, -1);
    self.trackingTouchForTap = NO;
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
    BOOL topBarFocusActive = [self.host browserRemoteInputControllerFocusNavigationActive];
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
        topBarFocusActive ||
        presentedActive;
    if (!self.cursorView.hidden) {
        [self noteCursorActivity];
    }
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
        [self.host browserRemoteInputControllerFocusNavigationActive]) {
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

// A physical click also produces a touch sequence. The per-touch flag normally
// catches that, but UIKit delivers presses and touches on separate paths and
// does not guarantee their relative order, so a press reported before
// touchesBegan: would have its flag cleared and fire the tap action as well as
// the click. The timestamp closes that window.
static const CFTimeInterval kBrowserCursorIdleHideDelay = 3.0;

- (void)noteCursorActivity {
    self.lastCursorActivityTimestamp = CACurrentMediaTime();

    if (self.cursorView.alpha < 1.0) {
        [self.cursorView.layer removeAllAnimations];
        [UIView animateWithDuration:0.2 animations:^{
            self.cursorView.alpha = 1.0;
        }];
    }

    if (self.cursorIdleTimer == nil) {
        self.cursorIdleTimer = [NSTimer scheduledTimerWithTimeInterval:kBrowserCursorIdleHideDelay
                                                                target:self
                                                              selector:@selector(handleCursorIdleTimerFired:)
                                                              userInfo:nil
                                                               repeats:NO];
    }
}

- (void)handleCursorIdleTimerFired:(__unused NSTimer *)timer {
    self.cursorIdleTimer = nil;

    CFTimeInterval idle = CACurrentMediaTime() - self.lastCursorActivityTimestamp;
    if (idle < kBrowserCursorIdleHideDelay) {
        // Activity arrived while the timer was running; wait out the remainder.
        self.cursorIdleTimer = [NSTimer scheduledTimerWithTimeInterval:(kBrowserCursorIdleHideDelay - idle)
                                                                target:self
                                                              selector:@selector(handleCursorIdleTimerFired:)
                                                              userInfo:nil
                                                               repeats:NO];
        return;
    }

    if (!self.cursorModeEnabled ||
        self.cursorView.hidden ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerFocusNavigationActive]) {
        return;
    }

    [UIView animateWithDuration:0.4 animations:^{
        self.cursorView.alpha = 0.0;
    }];
}

- (void)noteSelectPressActivity {
    self.selectPressDuringCurrentTouch = YES;
    self.lastSelectPressActivityTimestamp = CACurrentMediaTime();
}

- (void)handleGlobalSelectPressEndedNotification {
    [self noteSelectPressActivity];
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
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

    [self.host browserRemoteInputControllerHandlePrimaryActionWithSource:BrowserPageActivationSourceClick];
}

- (void)handleSelectPressEnded {
    [self noteSelectPressActivity];
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
    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerDismissTabOverview];
        return;
    }
    [self.host browserRemoteInputControllerHandleAdvancedMenuPress];
}

- (void)handleManualScrollPan:(UIPanGestureRecognizer *)gestureRecognizer {
    [self noteCursorActivity];
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerFocusNavigationActive]) {
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
    [self noteCursorActivity];
    for (UIPress *p in presses) {
        if (p.type == UIPressTypeSelect) {
            [self noteSelectPressActivity];
            self.selectPressStartTime = CACurrentMediaTime();
        }
    }

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
    [self noteCursorActivity];
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect) {
            [self noteSelectPressActivity];
        }
        if (press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
            [self stopDpadHoldAndContinuousScroll];
        }
    }
}

- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    [self noteCursorActivity];
    for (UIPress *p in presses) {
        if (p.type == UIPressTypeSelect) {
            [self noteSelectPressActivity];
        }
    }

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

    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
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
        CFTimeInterval holdDuration = (self.selectPressStartTime > 0.0)
            ? (CACurrentMediaTime() - self.selectPressStartTime)
            : 0.0;
        self.selectPressStartTime = 0.0;
        if (holdDuration >= kBrowserSelectLongClickThreshold) {
            // Cancel any pending single-click action so the link does not also
            // open in the current tab after opening in a new one.
            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(handleDeferredSelectPressAction)
                                                       object:nil];
            self.awaitingSecondSelectPress = NO;
            if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
                [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
            } else {
                [self.host browserRemoteInputControllerHandlePrimaryActionWithSource:BrowserPageActivationSourceLongClick];
            }
            return YES;
        }
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

    if ((press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow) &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerFocusNavigationActive] &&
        [self.host browserRemoteInputControllerPresentedViewController] == nil) {
        if (press.type == UIPressTypeLeftArrow) {
            [self.host browserRemoteInputControllerGoBack];
        } else {
            [self.host browserRemoteInputControllerGoForward];
        }
        return YES;
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
    [self noteCursorActivity];
    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }
    self.lastTouchLocation = CGPointMake(-1, -1);
    self.trackingTouchForTap = YES;
    self.currentTouchStartTime = CACurrentMediaTime();
    self.currentTouchStartCursorOrigin = self.cursorView.frame.origin;
    self.currentTouchMaxCursorDistance = 0.0;
    self.selectPressDuringCurrentTouch = NO;
    return YES;
}

- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self noteCursorActivity];
    if ([self.host browserRemoteInputControllerFocusNavigationActive]) {
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

            if (self.trackingTouchForTap) {
                CGFloat dx = rect.origin.x - self.currentTouchStartCursorOrigin.x;
                CGFloat dy = rect.origin.y - self.currentTouchStartCursorOrigin.y;
                CGFloat distance = hypot(dx, dy);
                if (distance > self.currentTouchMaxCursorDistance) {
                    self.currentTouchMaxCursorDistance = distance;
                }
            }

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
    [self noteCursorActivity];
    self.lastTouchLocation = CGPointMake(-1, -1);
    // The cursor only moves while a finger is on the touch surface, so a cursor
    // parked inside the edge zone would otherwise auto-scroll to the end of the
    // page after the finger is lifted. Auto-scroll lasts as long as the touch.
    [self stopEdgeAutoScroll];

    BOOL wasTrackingTouch = self.trackingTouchForTap;
    self.trackingTouchForTap = NO;

    if (!wasTrackingTouch) {
        return;
    }

    CFTimeInterval touchDuration = CACurrentMediaTime() - self.currentTouchStartTime;
    CGFloat maxDistance = self.currentTouchMaxCursorDistance;
    BOOL selectOccurred = self.selectPressDuringCurrentTouch ||
        self.awaitingSecondSelectPress ||
        ((CACurrentMediaTime() - self.lastSelectPressActivityTimestamp) < 0.4);

    if (self.cursorModeEnabled &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerFocusNavigationActive] &&
        [self.host browserRemoteInputControllerPresentedViewController] == nil &&
        [self.host browserRemoteInputControllerTapToClickEnabled] &&
        touchDuration > 0.0 &&
        touchDuration < 0.25 &&
        maxDistance < 20.0 &&
        !selectOccurred) {
        NSLog(@"[InputTrace][TapToClick] Triggered tap action duration=%.3f maxDistance=%.1f", touchDuration, maxDistance);
        [self.host browserRemoteInputControllerHandlePrimaryActionWithSource:BrowserPageActivationSourceTap];
    }
}

- (void)handleTouchesCancelled {
    self.lastTouchLocation = CGPointMake(-1, -1);
    self.trackingTouchForTap = NO;
    self.selectPressDuringCurrentTouch = NO;
    [self stopEdgeAutoScroll];
}

@end