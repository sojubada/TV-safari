#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserNativeVideoPlayerViewController : AVPlayerViewController

- (instancetype)initWithURL:(NSURL *)URL title:(nullable NSString *)title;
- (instancetype)initWithURL:(NSURL *)URL
                      title:(nullable NSString *)title
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                    cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;

// Called once if the stream never produces a picture, so the caller can say
// so instead of leaving a black screen on screen. The player dismisses itself
// first, so the handler runs with nothing presented.
@property (nonatomic, copy, nullable) void (^playbackFailureHandler)(NSString *reason);

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
