#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserNativeVideoPlayerViewController : AVPlayerViewController

- (instancetype)initWithURL:(NSURL *)URL title:(nullable NSString *)title;
- (instancetype)initWithURL:(NSURL *)URL
                      title:(nullable NSString *)title
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                    cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;

/// Where to start (seconds), e.g. where the video on the page was. 0 = from the start.
@property (nonatomic) NSTimeInterval startTimeSeconds;
/// Other streams the page loaded: if one can't be played, the viewer can try the next one.
@property (nonatomic, copy, nullable) NSArray<NSDictionary<NSString *, NSString *> *> *alternativeStreams;
/// Called when the Apple TV player can't play the stream: hands it to the VLC player (stream address, position).
@property (nonatomic, copy, nullable) void (^playWithVLCHandler)(NSURL *streamURL, NSTimeInterval currentTime);
/// Called (after the player closed) when a short clip – usually a pre-roll advert – played to its end.
@property (nonatomic, copy, nullable) void (^shortClipEndedHandler)(NSURL *streamURL);

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

/// Universal player (VLC): plays nearly every format – HLS, DASH, MP4, WebM/VP9, MKV, AV1 … – where the Apple TV player gives up.
@interface BrowserVLCPlayerViewController : UIViewController

/// NO when the VLC library isn't in the build (then nothing can be played with it).
+ (BOOL)isAvailable;
- (instancetype)initWithURL:(NSURL *)URL
                      title:(nullable NSString *)title
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                  startTime:(NSTimeInterval)startTime NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
