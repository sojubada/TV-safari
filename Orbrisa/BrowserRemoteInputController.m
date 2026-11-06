#import "BrowserRemoteInputController.h"
#import "BrowserLog.h"

// The JavaScript scroll fallback runs synchronously (it pumps the run loop until
// WebKit answers), so it must never be driven at display-link rate. Deltas are
// accumulated and flushed at most this often.
static const CFTimeInterval kBrowserJSScrollMinimumInterval = 0.05;
// Holding the center of the clickpad this long turns link navigation on or off.
static const CFTimeInterval kBrowserLinkNavigationHoldDuration = 0.8;
// Holding up/down on the ring this long turns a page step into continuous scrolling.
static const CFTimeInterval kBrowserDpadHoldDuration = 0.4;
static const CFTimeInterval kBrowserCursorIdleHideDelay = 3.0;

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
@property (nonatomic, readwrite, getter=isLinkNavigationActive) BOOL linkNavigationActive;
/// The center was held long enough to toggle link navigation; the release
/// that follows is not a click.
@property (nonatomic) BOOL selectHoldFired;

// Tap to click.
@property (nonatomic) BOOL trackingTouchForTap;
@property (nonatomic) CFTimeInterval currentTouchStartTime;
@property (nonatomic) CGPoint currentTouchStartCursorOrigin;
@property (nonatomic) CGFloat currentTouchMaxCursorDistance;
@property (nonatomic) BOOL selectPressDuringCurrentTouch;
@property (nonatomic) CFTimeInterval lastSelectPressActivityTimestamp;

// Pointer fades out when idle.
@property (nonatomic, nullable) NSTimer *cursorIdleTimer;
@property (nonatomic) CFTimeInterval lastCursorActivityTimestamp;

// Set when the bar hands focus back. Without it the pointer, parked inside the
// bar, would slide straight back in on the next flick of the finger.
@property (nonatomic) CFTimeInterval topBarSnapSuppressedUntil;
@property (nonatomic) CGFloat topBarExitSwipeDistance;

// Ring up/down: one page per click, continuous while held.
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

// Pointer resting at the top or bottom edge scrolls the page.
@property (nonatomic, nullable) CADisplayLink *edgeAutoScrollDisplayLink;
@property (nonatomic) CFTimeInterval edgeAutoScrollLastTimestamp;
@property (nonatomic) CGFloat edgeAutoScrollVelocityY;

// Scrolling a box inside the page when the page itself doesn't move.
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
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self stopManualScrollInertia];
    [self stopDpadPageScrollAnimation];
    [self stopDpadHoldAndContinuousScroll];
    [self stopEdgeAutoScroll];
}

#pragma mark - Geometry

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

// The bar's own rectangle is the zone, so the pointer activates it by touching
// it rather than by being somewhere near the top of the screen.
- (CGFloat)topBarBottomEdge {
    CGFloat edge = [self.host browserRemoteInputControllerTopBarBottomEdge];
    if (edge <= 1.0) {
        return 0.0;
    }
    return MIN(edge, [self viewportHeight] * 0.25);
}

- (BOOL)isCursorInTopBarActivationZone {
    CGFloat barBottom = [self topBarBottomEdge];
    if (barBottom > 0.0) {
        return self.cursorView.center.y < barBottom;
    }
    return self.cursorView.center.y < ([self viewportHeight] * 0.12);
}

- (BOOL)hardwareTypingActive {
    return [self.host respondsToSelector:@selector(browserRemoteInputControllerHardwareTypingActive)] &&
        [self.host browserRemoteInputControllerHardwareTypingActive];
}

#pragma mark - Top bar

// While the bar has focus the pointer is not being moved, so the finger is
// free to say "give it back": a firm downward drag across the touch surface
// does it, without waiting for the focus engine to run out of things to focus.
- (void)accumulateDownwardSwipeToLeaveTopBar:(NSSet<UITouch *> *)touches {
    UITouch *touch = touches.anyObject;
    if (touch == nil) {
        return;
    }
    CGPoint location = [touch locationInView:self.rootView];
    if (self.lastTouchLocation.x == -1 && self.lastTouchLocation.y == -1) {
        self.lastTouchLocation = location;
        self.topBarExitSwipeDistance = 0.0;
        return;
    }

    CGFloat yDiff = location.y - self.lastTouchLocation.y;
    self.lastTouchLocation = location;
    if (yDiff > 0.0) {
        self.topBarExitSwipeDistance += yDiff;
    } else if (yDiff < -4.0) {
        // Changed direction, so this was not one firm downward drag.
        self.topBarExitSwipeDistance = 0.0;
    }

    if (self.topBarExitSwipeDistance > 220.0) {
        self.topBarExitSwipeDistance = 0.0;
        [self.host browserRemoteInputControllerDeactivateTopBarFocus];
    }
}

- (void)noteTopBarFocusDeactivated {
    CGFloat barBottom = [self topBarBottomEdge];
    if (barBottom > 0.0) {
        CGRect rect = self.cursorView.frame;
        if (rect.origin.y < barBottom) {
            rect.origin.y = barBottom + 40.0;
            self.cursorView.frame = rect;
        }
    }
    self.topBarSnapSuppressedUntil = CACurrentMediaTime() + 0.6;
    self.lastTouchLocation = CGPointMake(-1, -1);
    [self noteCursorActivity];
}

- (BOOL)shouldSnapToTopBarMovingUpward:(BOOL)movingUpward {
    if (!movingUpward || !self.cursorModeEnabled || self.linkNavigationActive) {
        return NO;
    }
    if (CACurrentMediaTime() < self.topBarSnapSuppressedUntil) {
        return NO;
    }
    if ([self topBarBottomEdge] <= 0.0) {
        return NO;
    }
    if (![self isCursorInTopBarActivationZone]) {
        return NO;
    }
    return [self.host browserRemoteInputControllerCanActivateTopBarFocus];
}

// Reaching the very top of the screen brings a scrolled-away bar back. The
// slide into it waits for the next movement, so the bar appearing is never the
// same gesture as being pulled into it.
- (BOOL)revealTopBarIfCursorAtScreenTop:(BOOL)movingUpward {
    if (!movingUpward || !self.cursorModeEnabled) {
        return NO;
    }
    if (self.cursorView.center.y > ([self viewportHeight] * 0.07)) {
        return NO;
    }
    return [self.host browserRemoteInputControllerRevealTopBarIfHidden];
}

- (BOOL)canPerformCustomScroll {
    return [self.host browserRemoteInputControllerPresentedViewController] == nil &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerTopBarFocusActive] &&
        !self.linkNavigationActive &&
        ![self hardwareTypingActive];
}

#pragma mark - Modes

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
    BOOL topBarFocusActive = [self.host browserRemoteInputControllerTopBarFocusActive];
    BOOL tabOverviewVisible = [self.host browserRemoteInputControllerTabOverviewVisible];

    if (topBarFocusActive || tabOverviewVisible) {
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
    if (!self.cursorView.hidden) {
        [self noteCursorActivity];
    }
}

#pragma mark - Scrolling

- (BOOL)applyManualScrollDelta:(CGPoint)delta {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    if (scrollView != nil) {
        CGPoint contentOffset = scrollView.contentOffset;
        CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
        // The top inset keeps the start of the page below the floating top bar.
        CGFloat minOffsetY = -scrollView.contentInset.top;
        CGFloat maxOffsetY = MAX(minOffsetY, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds) + scrollView.contentInset.bottom);
        CGFloat nextOffsetX = MIN(MAX(contentOffset.x + delta.x, 0.0), maxOffsetX);
        CGFloat nextOffsetY = MIN(MAX(contentOffset.y + delta.y, minOffsetY), maxOffsetY);
        CGPoint nextOffset = CGPointMake(nextOffsetX, nextOffsetY);
        if (!CGPointEqualToPoint(contentOffset, nextOffset)) {
            [scrollView setContentOffset:nextOffset animated:NO];
            return YES;
        }
    }

    // The page itself didn't move. Many sites scroll inside a box instead of
    // the page (web apps, chat windows, some news sites), so try the box under
    // the pointer.
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

#pragma mark - Ring up/down: page step and hold scroll

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
    BrowserLog(@"[InputTrace][Scroll] ring hold scroll started direction=%ld", (long)self.activeDpadDirection);
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

#pragma mark - Edge auto scroll

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

    // With the bar on screen its rectangle belongs to the bar, so the upward
    // scroll zone begins underneath it instead of overlapping it.
    CGFloat topZoneStart = [self topBarBottomEdge];
    CGFloat topZoneEnd = topZoneStart + edgeZoneHeight;

    if (cursorY < topZoneEnd && cursorY >= topZoneStart) {
        CGFloat ratio = (topZoneEnd - cursorY) / edgeZoneHeight;
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

#pragma mark - Pointer fades when idle

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
        self.linkNavigationActive ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }

    [UIView animateWithDuration:0.4 animations:^{
        self.cursorView.alpha = 0.0;
    }];
}

#pragma mark - Select (click)

// A physical click also produces a touch sequence. The per-touch flag normally
// catches that, but UIKit delivers presses and touches on separate paths and
// does not guarantee their relative order, so a press reported before
// touchesBegan: would have its flag cleared and fire the tap action as well as
// the click. The timestamp closes that window.
- (void)noteSelectPressActivity {
    self.selectPressDuringCurrentTouch = YES;
    self.lastSelectPressActivityTimestamp = CACurrentMediaTime();
}

- (void)handleGlobalSelectPressEndedNotification {
    [self noteSelectPressActivity];
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    // Return on a Bluetooth keyboard arrives as a Select press too; while
    // typing it sends the field, and must not also click the page.
    if ([self hardwareTypingActive]) {
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
    [self noteSelectPressActivity];
    // The hold already toggled link navigation; its release is not a click.
    if (self.selectHoldFired) {
        self.selectHoldFired = NO;
        return;
    }
    if (self.linkNavigationActive) {
        [self.host browserRemoteInputControllerLinkNavigationActivate];
        return;
    }
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

#pragma mark - Link navigation

- (void)setLinkNavigationActive:(BOOL)linkNavigationActive {
    if (_linkNavigationActive == linkNavigationActive) {
        return;
    }
    _linkNavigationActive = linkNavigationActive;
    self.awaitingSecondSelectPress = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
    if (linkNavigationActive) {
        [self stopManualScrollInertia];
        [self stopEdgeAutoScroll];
        [self stopDpadPageScrollAnimation];
        [self stopDpadHoldAndContinuousScroll];
    }
    [self noteCursorActivity];
    [self.host browserRemoteInputControllerLinkNavigationDidChangeActive:linkNavigationActive];
}

- (BOOL)handleLinkNavigationPress:(UIPress *)press {
    switch (press.type) {
        case UIPressTypeUpArrow: {
            NSString *result = [self.host browserRemoteInputControllerLinkNavigationMove:@"up"];
            if ([result isEqualToString:@"top"]) {
                if ([self.host browserRemoteInputControllerCanActivateTopBarFocus]) {
                    // Already at the top of the page: carry on up into the top bar.
                    [self setLinkNavigationActive:NO];
                    [self.host browserRemoteInputControllerActivateTopBarFocus];
                } else {
                    // Bar hidden: the red button is the next stop up.
                    [self.host browserRemoteInputControllerLinkNavigationSelectShowBarButton];
                }
            }
            return YES;
        }
        case UIPressTypeDownArrow:
            [self.host browserRemoteInputControllerLinkNavigationMove:@"down"];
            return YES;
        case UIPressTypeLeftArrow:
            [self.host browserRemoteInputControllerLinkNavigationMove:@"left"];
            return YES;
        case UIPressTypeRightArrow:
            [self.host browserRemoteInputControllerLinkNavigationMove:@"right"];
            return YES;
        case UIPressTypeSelect:
            self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
            [self handleSelectPressEnded];
            return YES;
        case UIPressTypeMenu:
            [self setLinkNavigationActive:NO];
            return YES;
        default:
            return NO;
    }
}

// Holding the center of the clickpad toggles link navigation (on: arrows jump
// between links; off: back to the cursor). The ring's own holds scroll the page.
- (void)handleSelectLongPress {
    if (![self canToggleLinkNavigationWithHold]) {
        return;
    }
    self.selectHoldFired = YES;
    self.awaitingSecondSelectPress = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
    if (self.linkNavigationActive) {
        [self setLinkNavigationActive:NO];
        [self setCursorModeEnabled:YES];
    } else {
        [self setLinkNavigationActive:YES];
    }
}

- (BOOL)canToggleLinkNavigationWithHold {
    return [self.host browserRemoteInputControllerPresentedViewController] == nil &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerTopBarFocusActive] &&
        ![self hardwareTypingActive];
}

#pragma mark - Play/Pause

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

#pragma mark - Scroll mode pan

- (void)handleManualScrollPan:(UIPanGestureRecognizer *)gestureRecognizer {
    [self noteCursorActivity];
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

#pragma mark - Presses

- (void)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    [self noteCursorActivity];
    // Keys while typing are the keyboard's, not holds or page steps.
    if ([self hardwareTypingActive]) {
        return;
    }

    UIPress *press = presses.anyObject;
    if (press == nil || press.key != nil) {
        return;
    }

    if (press.type == UIPressTypeSelect) {
        [self noteSelectPressActivity];
        self.selectHoldFired = NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleSelectLongPress) object:nil];
        if ([self canToggleLinkNavigationWithHold]) {
            [self performSelector:@selector(handleSelectLongPress) withObject:nil afterDelay:kBrowserLinkNavigationHoldDuration];
        }
    }

    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
        BrowserLog(@"[InputTrace][Root] pressesBegan type=%@ phase=%@ presented=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]));
    }

    // Ring up/down held: after a moment the page scrolls continuously.
    if ((press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) &&
        press.phase == UIPressPhaseBegan &&
        [self.host browserRemoteInputControllerDpadScrollEnabled] &&
        [self canPerformCustomScroll]) {
        if (press.type == UIPressTypeUpArrow && [self shouldUpGoToTopBar]) {
            return;
        }
        [self stopDpadHoldAndContinuousScroll];
        self.activeDpadDirection = (press.type == UIPressTypeDownArrow) ? 1 : -1;
        self.dpadHoldTimer = [NSTimer scheduledTimerWithTimeInterval:kBrowserDpadHoldDuration
                                                              target:self
                                                            selector:@selector(handleDpadHoldTimerFired:)
                                                            userInfo:nil
                                                             repeats:NO];
    }
}

- (void)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    [self noteCursorActivity];
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect) {
            [self noteSelectPressActivity];
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleSelectLongPress) object:nil];
        }
        if (press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
            [self stopDpadHoldAndContinuousScroll];
        }
    }
}

// Up goes into the top bar when the pointer is already up by the bar, or when
// the page is at its top and there's nowhere further up to scroll.
- (BOOL)shouldUpGoToTopBar {
    if (![self.host browserRemoteInputControllerCanActivateTopBarFocus]) {
        return NO;
    }
    return [self isCursorInTopBarActivationZone] || [self.host browserRemoteInputControllerPageAtTop];
}

- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    [self noteCursorActivity];
    UIPress *press = presses.anyObject;
    if (press == nil) {
        return NO;
    }

    // A field is being typed into from a Bluetooth keyboard, so a key goes to
    // it before the handling below can read it as a direction or a button.
    if ([self.host respondsToSelector:@selector(browserRemoteInputControllerHandleHardwareKeyPress:)] &&
        [self.host browserRemoteInputControllerHandleHardwareKeyPress:press]) {
        self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
        return YES;
    }

    if (press.type == UIPressTypeSelect) {
        [self noteSelectPressActivity];
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleSelectLongPress) object:nil];
    }

    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
        BrowserLog(@"[InputTrace][Root] pressesEnded type=%@ phase=%@ presented=%@ tabOverview=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]),
              [self.host browserRemoteInputControllerTabOverviewVisible] ? @"YES" : @"NO");
    }

    // The end of a hold-to-scroll is not also a page step.
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

    if (self.linkNavigationActive) {
        if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
            [self setLinkNavigationActive:NO];
        } else if ([self handleLinkNavigationPress:press]) {
            return YES;
        }
    }

    if (press.type == UIPressTypeSelect) {
        self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
        [self handleSelectPressEnded];
        return YES;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
            [self.host browserRemoteInputControllerDismissTabOverview];
            return YES;
        }
        return NO;
    }

    // Ring up/down: a page at a time. Up goes into the top bar instead when
    // the pointer is by the bar or the page is already at its top.
    if (press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
        BOOL dpadEnabled = [self.host browserRemoteInputControllerDpadScrollEnabled];
        if (press.type == UIPressTypeUpArrow) {
            if (!dpadEnabled || [self shouldUpGoToTopBar]) {
                if ([self.host browserRemoteInputControllerCanActivateTopBarFocus]) {
                    [self.host browserRemoteInputControllerActivateTopBarFocus];
                    return YES;
                }
            }
        }
        if (!dpadEnabled || ![self canPerformCustomScroll]) {
            return NO;
        }
        CGFloat pageDelta = [self viewportHeight] * 0.85;
        [self startDpadPageScrollWithDeltaY:(press.type == UIPressTypeUpArrow) ? -pageDelta : pageDelta];
        return YES;
    }

    // Ring left/right: page history.
    if (press.type == UIPressTypeLeftArrow) {
        [self.host browserRemoteInputControllerGoBack];
        return YES;
    }
    if (press.type == UIPressTypeRightArrow) {
        [self.host browserRemoteInputControllerGoForward];
        return YES;
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

#pragma mark - Touches (pointer)

- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self noteCursorActivity];
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        self.lastTouchLocation = CGPointMake(-1, -1);
        self.topBarExitSwipeDistance = 0.0;
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }
    self.lastTouchLocation = CGPointMake(-1, -1);
    self.trackingTouchForTap = !self.linkNavigationActive;
    self.currentTouchStartTime = CACurrentMediaTime();
    self.currentTouchStartCursorOrigin = self.cursorView.frame.origin;
    self.currentTouchMaxCursorDistance = 0.0;
    self.selectPressDuringCurrentTouch = NO;
    return YES;
}

- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self noteCursorActivity];
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        [self accumulateDownwardSwipeToLeaveTopBar:touches];
        return NO;
    }
    self.topBarExitSwipeDistance = 0.0;
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }
    if (self.linkNavigationActive) {
        return YES;
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

            // Reaching the very top brings back a bar hidden by scrolling.
            if ([self revealTopBarIfCursorAtScreenTop:(yDiff < 0.0)]) {
                return YES;
            }

            // Magnetic bar: sliding the pointer up into the bar hands the
            // remote to the focus engine, so the buttons are reached by moving
            // to them rather than by clicking first.
            if ([self shouldSnapToTopBarMovingUpward:(yDiff < 0.0)]) {
                self.trackingTouchForTap = NO;
                [self stopEdgeAutoScroll];
                [self stopManualScrollInertia];
                [self.host browserRemoteInputControllerActivateTopBarFocus];
                return YES;
            }

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

    // Tap to click: a light, short touch that barely moved the pointer, with
    // no physical click anywhere near it.
    CFTimeInterval touchDuration = CACurrentMediaTime() - self.currentTouchStartTime;
    CGFloat maxDistance = self.currentTouchMaxCursorDistance;
    BOOL selectOccurred = self.selectPressDuringCurrentTouch ||
        self.awaitingSecondSelectPress ||
        ((CACurrentMediaTime() - self.lastSelectPressActivityTimestamp) < 0.4);

    if (self.cursorModeEnabled &&
        !self.linkNavigationActive &&
        ![self hardwareTypingActive] &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerTopBarFocusActive] &&
        [self.host browserRemoteInputControllerPresentedViewController] == nil &&
        [self.host browserRemoteInputControllerTapToClickEnabled] &&
        touchDuration > 0.0 &&
        touchDuration < 0.25 &&
        maxDistance < 20.0 &&
        !selectOccurred) {
        BrowserLog(@"[InputTrace][TapToClick] tap duration=%.3f maxDistance=%.1f", touchDuration, maxDistance);
        [self.host browserRemoteInputControllerHandlePrimaryAction];
    }
}

- (void)handleTouchesCancelled {
    self.lastTouchLocation = CGPointMake(-1, -1);
    self.trackingTouchForTap = NO;
    self.selectPressDuringCurrentTouch = NO;
    [self stopEdgeAutoScroll];
}

@end
