#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserLocalization.h"
#import "BrowserLog.h"
#import "BrowserNativeVideoAssetLoader.h"

#import <AVFoundation/AVFoundation.h>

#if __has_include(<VLCKit/VLCKit.h>)
#import <VLCKit/VLCKit.h>
#define BROWSER_HAS_VLC 1
#else
#define BROWSER_HAS_VLC 0
#endif

static NSString * const kBrowserNativeVideoPlayerLogPrefix = @"[NativeVideoPlayer]";
static NSString * const kBrowserNativePlayerInputLogPrefix = @"[InputTrace][NativePlayer]";

static NSString *BrowserNativePlayerPressTypeString(UIPressType type) {
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

static NSString *BrowserNativePlayerPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

@interface BrowserNativeVideoPlayerViewController ()

@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *requestCookies;
@property (nonatomic, strong) BrowserNativeVideoAssetLoader *assetLoader;
@property (nonatomic) NSUInteger alternativeIndex;
@property (nonatomic) BOOL showingFailure;

@end

@implementation BrowserNativeVideoPlayerViewController

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    BrowserLog(@"%@ %@", kBrowserNativeVideoPlayerLogPrefix, message);
}

- (instancetype)initWithURL:(NSURL *)URL title:(NSString *)title {
    return [self initWithURL:URL title:title requestHeaders:nil cookies:nil];
}

- (instancetype)initWithURL:(NSURL *)URL
                      title:(NSString *)title
             requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                    cookies:(NSArray<NSHTTPCookie *> *)cookies {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoURL = URL;
        _videoTitle = [title copy] ?: @"";
        _requestHeaders = [requestHeaders copy] ?: @{};
        _requestCookies = [cookies copy] ?: @[];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    self.showsPlaybackControls = YES;
    AVPlayerItem *playerItem = [self playerItemForURL:self.videoURL];
    self.player = [AVPlayer playerWithPlayerItem:playerItem];
    [self log:@"created player url=%@", self.videoURL.absoluteString ?: @""];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemFailedToPlayToEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:self.player.currentItem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemDidPlayToEndTime:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemNewErrorLogEntry:)
                                                 name:AVPlayerItemNewErrorLogEntryNotification
                                               object:self.player.currentItem];

    [self.player.currentItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    if (@available(tvOS 10.0, *)) {
        [self.player addObserver:self
                      forKeyPath:@"timeControlStatus"
                         options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                         context:NULL];
    }
}

- (AVPlayerItem *)playerItemForURL:(NSURL *)URL {
    if (self.requestHeaders.count == 0 && self.requestCookies.count == 0) {
        return [AVPlayerItem playerItemWithURL:URL];
    }
    NSMutableDictionary *assetOptions = [NSMutableDictionary dictionary];
    NSMutableDictionary *directHeaders = [self.requestHeaders mutableCopy];
    [directHeaders removeObjectForKey:@"Cookie"];
    NSString *lowerURL = URL.absoluteString.lowercaseString ?: @"";
    BOOL isPlaylist = [lowerURL containsString:@".m3u8"] || [lowerURL containsString:@"m3u8"];
    if (!isPlaylist) {
        // A plain video file: the player loads it itself (with the page's headers and cookies),
        // which handles seeking and large files far better than going through the app.
        if (directHeaders.count > 0) {
            assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = directHeaders;
        }
        if (self.requestCookies.count > 0) {
            assetOptions[@"AVURLAssetHTTPCookiesKey"] = self.requestCookies;
        }
        [self log:@"direct file url=%@ headers=%@ cookies=%lu", URL.absoluteString ?: @"", directHeaders, (unsigned long)self.requestCookies.count];
        return [AVPlayerItem playerItemWithAsset:[AVURLAsset URLAssetWithURL:URL options:assetOptions]];
    }
    if (self.requestHeaders.count > 0) {
        assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = self.requestHeaders;
        NSString *userAgent = self.requestHeaders[@"User-Agent"];
        if (userAgent.length > 0) {
            assetOptions[@"AVURLAssetHTTPUserAgentKey"] = userAgent;
        }
    }
    if (self.requestCookies.count > 0) {
        assetOptions[@"AVURLAssetHTTPCookiesKey"] = self.requestCookies;
    }
    self.assetLoader = [[BrowserNativeVideoAssetLoader alloc] initWithRequestHeaders:self.requestHeaders cookies:self.requestCookies];
    NSURL *assetURL = [self.assetLoader assetURLForPlaybackURL:URL];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:assetOptions];
    [self.assetLoader attachToAsset:asset];
    [self log:@"using request headers %@ cookies=%lu url=%@", self.requestHeaders, (unsigned long)self.requestCookies.count, URL.absoluteString ?: @""];
    return [AVPlayerItem playerItemWithAsset:asset];
}

#pragma mark - When a stream can't be played

- (NSString *)describeError:(NSError *)error {
    if (error == nil) {
        AVPlayerItemErrorLogEvent *event = self.player.currentItem.errorLog.events.lastObject;
        if (event != nil) {
            return [NSString stringWithFormat:@"%@ %ld: %@", event.errorDomain ?: @"", (long)event.errorStatusCode, event.errorComment ?: @""];
        }
        return BrowserLocalized(@"Unknown error");
    }
    NSMutableString *text = [NSMutableString stringWithFormat:@"%@ (%@ %ld)", error.localizedDescription ?: @"", error.domain, (long)error.code];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (underlying != nil) {
        [text appendFormat:@"\n→ %@ (%@ %ld)", underlying.localizedDescription ?: @"", underlying.domain, (long)underlying.code];
    }
    AVPlayerItemErrorLogEvent *event = self.player.currentItem.errorLog.events.lastObject;
    if (event != nil) {
        [text appendFormat:@"\nLog: %ld %@ %@", (long)event.errorStatusCode, event.errorComment ?: @"", event.URI ?: @""];
    }
    return text;
}

- (NSURL *)currentStreamURL {
    if (self.alternativeIndex > 0 && self.alternativeIndex - 1 < self.alternativeStreams.count) {
        return [NSURL URLWithString:self.alternativeStreams[self.alternativeIndex - 1][@"url"] ?: @""];
    }
    return self.videoURL;
}

- (void)showPlaybackFailure:(NSError *)error {
    if (self.showingFailure || self.presentedViewController != nil) {
        return;
    }
    // The Apple TV player can't do it: hand the same stream straight to the VLC player (no question needed).
    if (self.playWithVLCHandler != nil && [BrowserVLCPlayerViewController isAvailable]) {
        void (^handler)(NSURL *, NSTimeInterval) = self.playWithVLCHandler;
        self.playWithVLCHandler = nil;
        NSURL *streamURL = [self currentStreamURL];
        NSTimeInterval time = CMTimeGetSeconds(self.player.currentTime);
        [self log:@"handing over to VLC: %@ (%@)", streamURL.absoluteString ?: @"", error];
        [self.player pause];
        [self dismissViewControllerAnimated:NO completion:^{
            handler(streamURL, isfinite(time) ? MAX(time, self.startTimeSeconds) : self.startTimeSeconds);
        }];
        return;
    }
    self.showingFailure = YES;
    NSURL *streamURL = [self currentStreamURL];
    NSUInteger remaining = 0;
    for (NSUInteger i = self.alternativeIndex; i < self.alternativeStreams.count; i++) {
        if (![self.alternativeStreams[i][@"url"] isEqualToString:streamURL.absoluteString]) {
            remaining += 1;
        }
    }
    NSString *message = [NSString stringWithFormat:@"%@\n\nStream: %@ · %@\n%@",
                         [self describeError:error],
                         streamURL.pathExtension.length > 0 ? streamURL.pathExtension : @"?",
                         streamURL.host ?: @"",
                         remaining > 0 ? [NSString stringWithFormat:BrowserLocalized(@"%lu more videos found."), (unsigned long)remaining] : BrowserLocalized(@"No other videos found.")];
    [self log:@"playback failure shown: %@", message];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Video Can't Be Played")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (remaining > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Next Found Video")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            weakSelf.showingFailure = NO;
            [weakSelf playNextAlternative];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Close")
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        weakSelf.showingFailure = NO;
        [weakSelf closePlayer];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)playNextAlternative {
    NSString *current = [self currentStreamURL].absoluteString ?: @"";
    while (self.alternativeIndex < self.alternativeStreams.count) {
        NSDictionary *stream = self.alternativeStreams[self.alternativeIndex];
        self.alternativeIndex += 1;
        NSURL *URL = [NSURL URLWithString:stream[@"url"] ?: @""];
        if (URL == nil || [URL.absoluteString isEqualToString:current]) {
            continue;
        }
        [self log:@"trying alternative %lu/%lu %@", (unsigned long)self.alternativeIndex, (unsigned long)self.alternativeStreams.count, URL.absoluteString];
        AVPlayerItem *oldItem = self.player.currentItem;
        @try {
            [oldItem removeObserver:self forKeyPath:@"status"];
        } @catch (__unused NSException *exception) {}
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:oldItem];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemNewErrorLogEntryNotification object:oldItem];

        AVPlayerItem *item = [self playerItemForURL:URL];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handlePlayerItemFailedToPlayToEndTime:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handlePlayerItemNewErrorLogEntry:) name:AVPlayerItemNewErrorLogEntryNotification object:item];
        [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];
        [self.player replaceCurrentItemWithPlayerItem:item];
        [self.player play];
        return;
    }
    [self closePlayer];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    BrowserLog(@"%@ viewDidAppear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewDidAppear play"];
    [self.player play];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    BrowserLog(@"%@ viewWillDisappear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewWillDisappear pause"];
    [self.player pause];
}

- (void)dealloc {
    @try {
        [self.player.currentItem removeObserver:self forKeyPath:@"status"];
    } @catch (__unused NSException *exception) {}
    @try {
        [self.player removeObserver:self forKeyPath:@"timeControlStatus"];
    } @catch (__unused NSException *exception) {}
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)togglePlayback {
    if (self.player.rate > 0.0) {
        [self log:@"toggle pause"];
        [self.player pause];
    } else {
        [self log:@"toggle play"];
        [self.player play];
    }
}

- (void)skipByInterval:(NSTimeInterval)delta {
    if (self.player.currentItem == nil) {
        return;
    }

    NSTimeInterval currentTime = CMTimeGetSeconds(self.player.currentTime);
    if (!isfinite(currentTime)) {
        currentTime = 0.0;
    }

    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval targetTime = currentTime + delta;
    if (isfinite(duration) && duration > 0.0) {
        targetTime = MIN(MAX(targetTime, 0.0), MAX(duration - 0.05, 0.0));
    } else {
        targetTime = MAX(targetTime, 0.0);
    }

    [self log:@"seek delta=%0.3f from=%0.3f to=%0.3f", delta, currentTime, targetTime];
    CMTime seekTime = CMTimeMakeWithSeconds(targetTime, NSEC_PER_SEC);
    [self.player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)scrubByHorizontalDelta:(CGFloat)delta {
    // Approximate touch-surface horizontal movement to timeline seek.
    NSTimeInterval secondsDelta = (NSTimeInterval)delta / 4.0;
    if (fabs(secondsDelta) < 0.01) {
        return;
    }
    [self skipByInterval:secondsDelta];
}

- (void)closePlayer {
    [self log:@"close player"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handlePlayerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self log:@"failedToPlayToEnd error=%@", error];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showPlaybackFailure:error];
    });
}

/// A short clip that ends is almost always the advert in front of the real video:
/// go back to the page, skip the advert there and open the real video instead.
- (void)handlePlayerItemDidPlayToEndTime:(NSNotification *)notification {
    if (notification.object != self.player.currentItem) {
        return;
    }
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    [self log:@"played to end, duration=%.1f", duration];
    if (!isfinite(duration) || duration > 120.0) {
        return;
    }
    NSURL *streamURL = [self currentStreamURL];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.shortClipEndedHandler != nil) {
            void (^handler)(NSURL *) = self.shortClipEndedHandler;
            self.shortClipEndedHandler = nil;
            [self log:@"short clip ended (advert?), back to the page for the real video"];
            [self dismissViewControllerAnimated:NO completion:^{
                handler(streamURL);
            }];
            return;
        }
        [self playNextAlternative];
    });
}

- (void)handlePlayerItemNewErrorLogEntry:(NSNotification *)notification {
    AVPlayerItemErrorLog *errorLog = self.player.currentItem.errorLog;
    AVPlayerItemErrorLogEvent *lastEvent = errorLog.events.lastObject;
    [self log:@"errorLog domain=%@ status=%ld comment=%@ serverAddress=%@ playbackSessionID=%@",
     lastEvent.errorDomain ?: @"",
     (long)lastEvent.errorStatusCode,
     lastEvent.errorComment ?: @"",
     lastEvent.serverAddress ?: @"",
     lastEvent.playbackSessionID ?: @""];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == self.player.currentItem && [keyPath isEqualToString:@"status"]) {
        switch (self.player.currentItem.status) {
            case AVPlayerItemStatusUnknown:
                [self log:@"item status=unknown error=%@", self.player.currentItem.error];
                break;
            case AVPlayerItemStatusReadyToPlay:
                if (self.startTimeSeconds > 1.0) {
                    NSTimeInterval start = self.startTimeSeconds;
                    self.startTimeSeconds = 0.0;
                    [self.player seekToTime:CMTimeMakeWithSeconds(start, NSEC_PER_SEC)];
                }
                [self log:@"item status=ready duration=%f likelyToKeepUp=%d bufferEmpty=%d",
                 CMTimeGetSeconds(self.player.currentItem.duration),
                 self.player.currentItem.isPlaybackLikelyToKeepUp,
                 self.player.currentItem.isPlaybackBufferEmpty];
                break;
            case AVPlayerItemStatusFailed: {
                NSError *itemError = self.player.currentItem.error;
                [self log:@"item status=failed error=%@", itemError];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showPlaybackFailure:itemError];
                });
                break;
            }
        }
        return;
    }

    if (object == self.player && [keyPath isEqualToString:@"timeControlStatus"]) {
        if (@available(tvOS 10.0, *)) {
            NSString *status = @"unknown";
            switch (self.player.timeControlStatus) {
                case AVPlayerTimeControlStatusPaused:
                    status = @"paused";
                    break;
                case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                    status = @"waiting";
                    break;
                case AVPlayerTimeControlStatusPlaying:
                    status = @"playing";
                    break;
            }
            [self log:@"timeControlStatus=%@ reason=%@", status, self.player.reasonForWaitingToPlay ?: @""];
            return;
        }
    }

    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        BrowserLog(@"%@ pressesBegan type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        BrowserLog(@"%@ pressesEnded type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesEnded:presses withEvent:event];
}

@end


#pragma mark - VLC player

@interface BrowserVLCPlayerViewController ()
@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic) NSTimeInterval startTime;
@property (nonatomic, strong) UIView *videoView;
@property (nonatomic, strong) UIView *controlsView;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSTimer *updateTimer;
@property (nonatomic) CFTimeInterval controlsShownAt;
@property (nonatomic) BOOL showedError;
@property (nonatomic) CGFloat panRemainder;
#if BROWSER_HAS_VLC
@property (nonatomic, strong) VLCMediaPlayer *mediaPlayer;
#endif
@end

@implementation BrowserVLCPlayerViewController

+ (BOOL)isAvailable {
    return BROWSER_HAS_VLC ? YES : NO;
}

- (instancetype)initWithURL:(NSURL *)URL title:(NSString *)title requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders startTime:(NSTimeInterval)startTime {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoURL = URL;
        _videoTitle = [title copy] ?: @"";
        _requestHeaders = [requestHeaders copy] ?: @{};
        _startTime = startTime;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight alpha:(CGFloat)alpha {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:alpha];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.videoView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.videoView.backgroundColor = UIColor.blackColor;
    [self.view addSubview:self.videoView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.color = UIColor.whiteColor;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];

    self.statusLabel = [self labelWithSize:26 weight:UIFontWeightMedium alpha:0.8];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    // Bottom bar: title, progress, time (fades out after a few seconds like the Apple TV player).
    self.controlsView = [UIView new];
    self.controlsView.translatesAutoresizingMaskIntoConstraints = NO;
    CAGradientLayer *shade = [CAGradientLayer layer];
    shade.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.75].CGColor];
    shade.frame = CGRectMake(0, 0, 4000, 260);
    [self.controlsView.layer addSublayer:shade];
    [self.view addSubview:self.controlsView];

    self.titleLabel = [self labelWithSize:30 weight:UIFontWeightSemibold alpha:1.0];
    self.titleLabel.text = self.videoTitle.length > 0 ? self.videoTitle : self.videoURL.host;
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progressTintColor = UIColor.whiteColor;
    self.progressView.trackTintColor = [UIColor colorWithWhite:1 alpha:0.25];
    self.timeLabel = [self labelWithSize:24 weight:UIFontWeightMedium alpha:0.85];
    UILabel *hint = [self labelWithSize:20 weight:UIFontWeightRegular alpha:0.55];
    hint.text = BrowserLocalized(@"VLC · Center: Play/Pause · ◀︎ ▶︎ 10 s · Swipe: scrub · Back: close");
    for (UIView *subview in @[self.titleLabel, self.progressView, self.timeLabel, hint]) {
        [self.controlsView addSubview:subview];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:30],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToConstant:1400],
        [self.controlsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.controlsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.controlsView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.controlsView.heightAnchor constraintEqualToConstant:260],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.controlsView.leadingAnchor constant:90],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.controlsView.trailingAnchor constant:-90],
        [self.titleLabel.bottomAnchor constraintEqualToAnchor:self.progressView.topAnchor constant:-22],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.controlsView.leadingAnchor constant:90],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.timeLabel.leadingAnchor constant:-30],
        [self.progressView.bottomAnchor constraintEqualToAnchor:hint.topAnchor constant:-26],
        [self.timeLabel.centerYAnchor constraintEqualToAnchor:self.progressView.centerYAnchor],
        [self.timeLabel.trailingAnchor constraintEqualToAnchor:self.controlsView.trailingAnchor constant:-90],
        [hint.leadingAnchor constraintEqualToAnchor:self.controlsView.leadingAnchor constant:90],
        [hint.bottomAnchor constraintEqualToAnchor:self.controlsView.bottomAnchor constant:-50],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.allowedTouchTypes = @[@(UITouchTypeIndirect)];
    [self.view addGestureRecognizer:pan];

    [self.spinner startAnimating];
    [self startPlayback];
    [self showControls];
}

- (void)startPlayback {
#if BROWSER_HAS_VLC
    VLCMedia *media = [VLCMedia mediaWithURL:self.videoURL];
    if (media == nil) {
        [self showError:BrowserLocalized(@"The video address is invalid.")];
        return;
    }
    NSString *referer = self.requestHeaders[@"Referer"];
    NSString *userAgent = self.requestHeaders[@"User-Agent"];
    if (referer.length > 0) {
        [media addOption:[NSString stringWithFormat:@":http-referrer=%@", referer]];
    }
    if (userAgent.length > 0) {
        [media addOption:[NSString stringWithFormat:@":http-user-agent=%@", userAgent]];
    }
    if (self.startTime > 1.0) {
        [media addOption:[NSString stringWithFormat:@":start-time=%.1f", self.startTime]];
    }
    [media addOption:@":network-caching=1500"];
    self.mediaPlayer = [[VLCMediaPlayer alloc] init];
    self.mediaPlayer.drawable = self.videoView;
    self.mediaPlayer.media = media;
    [self.mediaPlayer play];
    BrowserLog(@"[VLCPlayer] play %@", self.videoURL.absoluteString);
    __weak typeof(self) weakSelf = self;
    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf updateFromPlayer];
    }];
#else
    [self showError:BrowserLocalized(@"The VLC player is not included in this build.")];
#endif
}

- (NSString *)formatTime:(NSInteger)milliseconds {
    NSInteger seconds = MAX(0, milliseconds / 1000);
    if (seconds >= 3600) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(seconds / 3600), (long)((seconds / 60) % 60), (long)(seconds % 60)];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

- (void)updateFromPlayer {
#if BROWSER_HAS_VLC
    VLCMediaPlayerState state = self.mediaPlayer.state;
    if (state == VLCMediaPlayerStateError) {
        [self showError:BrowserLocalized(@"VLC couldn't play this video. The site probably only allows it in its own player.")];
        return;
    }
    if (self.mediaPlayer.isPlaying) {
        [self.spinner stopAnimating];
        self.statusLabel.text = nil;
    }
    NSInteger now = self.mediaPlayer.time.intValue;
    NSInteger length = self.mediaPlayer.media.length.intValue;
    self.progressView.progress = length > 0 ? (float)now / (float)length : 0.0f;
    self.timeLabel.text = length > 0 ? [NSString stringWithFormat:@"%@ / %@", [self formatTime:now], [self formatTime:length]] : [self formatTime:now];
    if (state == VLCMediaPlayerStateStopped && length > 0 && now >= length - 1500) {
        [self close];
        return;
    }
    if (self.mediaPlayer.isPlaying && CACurrentMediaTime() - self.controlsShownAt > 4.0 && self.controlsView.alpha > 0.0) {
        [UIView animateWithDuration:0.4 animations:^{ self.controlsView.alpha = 0.0; }];
    }
#endif
}

- (void)showControls {
    self.controlsShownAt = CACurrentMediaTime();
    [UIView animateWithDuration:0.2 animations:^{ self.controlsView.alpha = 1.0; }];
}

- (void)showError:(NSString *)message {
    if (self.showedError) {
        return;
    }
    self.showedError = YES;
    [self.spinner stopAnimating];
    BrowserLog(@"[VLCPlayer] error %@", message);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Video Can't Be Played")
                                                                   message:[NSString stringWithFormat:@"%@\n\n%@", message, self.videoURL.host ?: @""]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Close") style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        [weakSelf close];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)jumpBy:(double)seconds {
#if BROWSER_HAS_VLC
    if (seconds > 0) {
        [self.mediaPlayer jumpForward:seconds];
    } else {
        [self.mediaPlayer jumpBackward:-seconds];
    }
#endif
    [self showControls];
}

- (void)togglePlayback {
#if BROWSER_HAS_VLC
    if (self.mediaPlayer.isPlaying) {
        [self.mediaPlayer pause];
    } else {
        [self.mediaPlayer play];
    }
#endif
    [self showControls];
}

- (void)close {
    [self.updateTimer invalidate];
    self.updateTimer = nil;
#if BROWSER_HAS_VLC
    [self.mediaPlayer stop];
#endif
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.panRemainder = 0;
        [self showControls];
    }
    CGPoint translation = [pan translationInView:self.view];
    [pan setTranslation:CGPointZero inView:self.view];
    // About 1 second per 25 points of swipe; jumps in whole 5-second steps.
    self.panRemainder += translation.x / 25.0;
    if (fabs(self.panRemainder) >= 5.0) {
        double step = self.panRemainder > 0 ? 5.0 : -5.0;
        self.panRemainder -= step;
        [self jumpBy:step];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    switch (press.type) {
        case UIPressTypeMenu:
            [self close];
            return;
        case UIPressTypeSelect:
        case UIPressTypePlayPause:
            [self togglePlayback];
            return;
        case UIPressTypeLeftArrow:
            [self jumpBy:-10];
            return;
        case UIPressTypeRightArrow:
            [self jumpBy:10];
            return;
        case UIPressTypeUpArrow:
        case UIPressTypeDownArrow:
            [self showControls];
            return;
        default:
            [super pressesEnded:presses withEvent:event];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press.type == UIPressTypeMenu || press.type == UIPressTypeSelect || press.type == UIPressTypePlayPause ||
        press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow ||
        press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
        return; // handled on release
    }
    [super pressesBegan:presses withEvent:event];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
}

- (void)dealloc {
    [_updateTimer invalidate];
#if BROWSER_HAS_VLC
    [_mediaPlayer stop];
#endif
}

@end
