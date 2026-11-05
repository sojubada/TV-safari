#import <AVKit/AVKit.h>
#import "BrowserLog.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const BrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";
static BOOL sBrowserNativeScrubTracking = NO;
static CGFloat sBrowserNativePendingScrubPixels = 0.0;
static CGPoint sBrowserNativeLastTouchLocation = {0, 0};
static CFTimeInterval sBrowserNativeLastArrowPressTimestamp = 0.0;
static UIPressType sBrowserNativeLastArrowPressType = (UIPressType)-1;
static CGFloat const kBrowserNativeScrubPixelStep = 18.0;
static CFTimeInterval const kBrowserNativeArrowDoubleTapInterval = 0.35;

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

static UIViewController *BrowserFindViewControllerOfClass(UIViewController *viewController, Class targetClass) {
    if (viewController == nil || targetClass == Nil) {
        return nil;
    }

    if ([viewController isKindOfClass:targetClass]) {
        return viewController;
    }

    if (viewController.presentedViewController != nil) {
        UIViewController *match = BrowserFindViewControllerOfClass(viewController.presentedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    for (UIViewController *childViewController in viewController.childViewControllers) {
        UIViewController *match = BrowserFindViewControllerOfClass(childViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(navigationController.visibleViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabBarController = (UITabBarController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(tabBarController.selectedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

static NSArray<UIWindow *> *BrowserAllApplicationWindows(UIApplication *application) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    return windows;
}

static UIViewController *BrowserFindPresentedNativeVideoPlayerViewController(UIApplication *application, Class nativeVideoPlayerClass) {
    for (UIWindow *window in BrowserAllApplicationWindows(application)) {
        if (window.hidden || window.rootViewController == nil) {
            continue;
        }

        UIViewController *match = BrowserFindViewControllerOfClass(window.rootViewController, nativeVideoPlayerClass);
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

@interface UIApplication (BrowserSelectPressForwarding)

- (void)browser_sendEvent:(UIEvent *)event;

@end

@implementation UIApplication (BrowserSelectPressForwarding)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalMethod = class_getInstanceMethod(self, @selector(sendEvent:));
        Method replacementMethod = class_getInstanceMethod(self, @selector(browser_sendEvent:));
        if (originalMethod != NULL && replacementMethod != NULL) {
            method_exchangeImplementations(originalMethod, replacementMethod);
        }
    });
}

- (void)browser_sendEvent:(UIEvent *)event {
    Class nativeVideoPlayerClass = NSClassFromString(@"BrowserNativeVideoPlayerViewController");
    UIViewController *nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);

    // The Apple TV player (AVPlayerViewController) handles the Siri Remote itself – swiping to scrub, clicking to
    // play/pause, left/right to skip. Our own handling fought with it (after scrubbing, play no longer worked),
    // so while it is on screen every press goes straight to it; only Menu closes it.
    if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil &&
        [nativeVideoPlayerViewController isKindOfClass:[AVPlayerViewController class]]) {
        if (event.type == UIEventTypePresses) {
            SEL presses_ = NSSelectorFromString(@"allPresses");
            NSSet<UIPress *> *allPresses = [event respondsToSelector:presses_] ? ((id (*)(id, SEL))objc_msgSend)(event, presses_) : nil;
            for (UIPress *press in allPresses) {
                if (press.type == UIPressTypeMenu && press.phase == UIPressPhaseBegan) {
                    // Menu while the transport bar / scrubber is open just closes that; only a plain Menu leaves the player.
                    AVPlayerViewController *player = (AVPlayerViewController *)nativeVideoPlayerViewController;
                    if (player.presentedViewController == nil) {
                        BrowserLog(@"[InputTrace][App] Menu: close native player");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [player.player pause];
                            [player dismissViewControllerAnimated:YES completion:nil];
                        });
                        return;
                    }
                }
            }
        }
        [self browser_sendEvent:event];
        return;
    }

    if (event.type == UIEventTypeTouches) {
        SEL allTouchesSelector = NSSelectorFromString(@"allTouches");
        if ([event respondsToSelector:allTouchesSelector]) {
            NSSet<UITouch *> *touches = ((id (*)(id, SEL))objc_msgSend)(event, allTouchesSelector);
            for (UITouch *touch in touches) {
                if (touch.type != UITouchTypeIndirect) {
                    continue;
                }

                CGPoint location = [touch locationInView:nil];
                if (touch.phase == UITouchPhaseBegan) {
                    sBrowserNativeScrubTracking = (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil);
                    sBrowserNativePendingScrubPixels = 0.0;
                    sBrowserNativeLastTouchLocation = location;
                    continue;
                }

                if (!sBrowserNativeScrubTracking || nativeVideoPlayerViewController == nil) {
                    continue;
                }

                if (touch.phase == UITouchPhaseMoved) {
                    CGFloat deltaX = location.x - sBrowserNativeLastTouchLocation.x;
                    sBrowserNativeLastTouchLocation = location;
                    sBrowserNativePendingScrubPixels += deltaX;

                    SEL scrubSelector = NSSelectorFromString(@"scrubByHorizontalDelta:");
                    if ([nativeVideoPlayerViewController respondsToSelector:scrubSelector]) {
                        while (fabs(sBrowserNativePendingScrubPixels) >= kBrowserNativeScrubPixelStep) {
                            CGFloat step = sBrowserNativePendingScrubPixels > 0.0 ? kBrowserNativeScrubPixelStep : -kBrowserNativeScrubPixelStep;
                            ((void (*)(id, SEL, CGFloat))objc_msgSend)(nativeVideoPlayerViewController, scrubSelector, step);
                            sBrowserNativePendingScrubPixels -= step;
                            BrowserLog(@"[InputTrace][App] scrub step delta=%.2f", step);
                        }
                    }
                }

                if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                    sBrowserNativeScrubTracking = NO;
                    sBrowserNativePendingScrubPixels = 0.0;
                }
            }
        }

        [self browser_sendEvent:event];
        return;
    }

    if (event.type != UIEventTypePresses) {
        [self browser_sendEvent:event];
        return;
    }

    SEL allPressesSelector = NSSelectorFromString(@"allPresses");
    if (![event respondsToSelector:allPressesSelector]) {
        [self browser_sendEvent:event];
        return;
    }

    NSSet<UIPress *> *presses = ((id (*)(id, SEL))objc_msgSend)(event, allPressesSelector);
    for (UIPress *press in presses) {
        nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
            BrowserLog(@"[InputTrace][App] press=%@ phase=%@ top=%@",
                  BrowserPressTypeString(press.type),
                  BrowserPressPhaseString(press.phase),
                  nativeVideoPlayerViewController == nil ? @"(nil)" : NSStringFromClass([nativeVideoPlayerViewController class]));
        }

        if (press.type == UIPressTypeMenu && press.phase == UIPressPhaseBegan) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                BrowserLog(@"[InputTrace][App] swallow Menu for native player");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [nativeVideoPlayerViewController dismissViewControllerAnimated:YES completion:nil];
                });
                return;
            }
        }

        if (press.type == UIPressTypePlayPause && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL togglePlaybackSelector = NSSelectorFromString(@"togglePlayback");
                if ([nativeVideoPlayerViewController respondsToSelector:togglePlaybackSelector]) {
                    BrowserLog(@"[InputTrace][App] swallow PlayPause for native player");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(nativeVideoPlayerViewController, togglePlaybackSelector);
                    });
                    return;
                }
            }
        }

        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL togglePlaybackSelector = NSSelectorFromString(@"togglePlayback");
                if ([nativeVideoPlayerViewController respondsToSelector:togglePlaybackSelector]) {
                    BrowserLog(@"[InputTrace][App] swallow Select for native player");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(nativeVideoPlayerViewController, togglePlaybackSelector);
                    });
                    return;
                }
            }
        }

        if ((press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow) && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL skipSelector = NSSelectorFromString(@"skipByInterval:");
                if ([nativeVideoPlayerViewController respondsToSelector:skipSelector]) {
                    CFTimeInterval now = CACurrentMediaTime();
                    BOOL isDoubleTap = (sBrowserNativeLastArrowPressType == press.type) &&
                                       ((now - sBrowserNativeLastArrowPressTimestamp) <= kBrowserNativeArrowDoubleTapInterval);
                    sBrowserNativeLastArrowPressType = press.type;
                    sBrowserNativeLastArrowPressTimestamp = now;

                    if (isDoubleTap) {
                        NSTimeInterval delta = (press.type == UIPressTypeRightArrow) ? 5.0 : -5.0;
                        BrowserLog(@"[InputTrace][App] swallow %@ double tap for native player (delta=%0.1f)",
                              BrowserPressTypeString(press.type), delta);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(nativeVideoPlayerViewController, skipSelector, delta);
                        });
                        sBrowserNativeLastArrowPressType = (UIPressType)-1;
                        sBrowserNativeLastArrowPressTimestamp = 0.0;
                    } else {
                        BrowserLog(@"[InputTrace][App] swallow %@ single tap for native player (waiting for double tap)",
                              BrowserPressTypeString(press.type));
                    }
                    return;
                }
            }
        }
    }

    [self browser_sendEvent:event];

    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            BrowserLog(@"[InputTrace][App] post BrowserGlobalSelectPressEndedNotification");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalSelectPressEndedNotification object:nil];
            });
            break;
        }
    }
}

@end
