#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserLocalization.h"
#import "BrowserLog.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserWebView.h"
#import "BrowserYouTubeExtractor.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static BOOL const kBrowserYouTubeNativeExtractionEnabled = NO;

@interface BrowserVideoPlaybackCoordinator ()

@property (nonatomic, weak) id<BrowserVideoPlaybackCoordinatorHost> host;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserYouTubeExtractor *youTubeExtractor;
/// Set while the viewer explicitly asked for the Apple TV player (works even with the full-screen setting off).
@property (nonatomic) BOOL forceNativePlayback;
@property (nonatomic) NSTimeInterval pendingStartTime;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *pendingAlternatives;

@end

@implementation BrowserVideoPlaybackCoordinator

- (BOOL)isFullscreenVideoPlaybackEnabled {
    return self.host.browserFullscreenVideoPlaybackEnabled || self.forceNativePlayback;
}

#pragma mark - Streams the page loaded

- (BOOL)hasCapturedStream {
    return [self.host.browserWebView bestCapturedMediaStream] != nil;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)capturedStreamChoices {
    return [self.host.browserWebView playableCapturedMediaStreams] ?: @[];
}

- (NSString *)labelForCapturedStream:(NSDictionary<NSString *, NSString *> *)stream {
    NSURL *URL = [NSURL URLWithString:stream[@"url"] ?: @""];
    NSArray<NSString *> *hostParts = [URL.host componentsSeparatedByString:@"."];
    NSString *host = hostParts.count >= 2 ? [[hostParts subarrayWithRange:NSMakeRange(hostParts.count - 2, 2)] componentsJoinedByString:@"."] : (URL.host ?: @"?");
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"(2160|1440|1080|720|480|360|240)[pP]?" options:0 error:nil];
    NSInteger quality = 0;
    NSString *urlString = stream[@"url"] ?: @"";
    for (NSTextCheckingResult *match in [expression matchesInString:urlString options:0 range:NSMakeRange(0, urlString.length)]) {
        quality = MAX(quality, [[urlString substringWithRange:[match rangeAtIndex:1]] integerValue]);
    }
    NSString *kind = [stream[@"type"] isEqualToString:@"hls"] ? BrowserLocalized(@"Stream (all qualities)")
        : ([stream[@"type"] isEqualToString:@"dash"] ? BrowserLocalized(@"DASH stream (VLC)")
        : (URL.pathExtension.length > 0 ? URL.pathExtension.uppercaseString : BrowserLocalized(@"File")));
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:host];
    if (quality > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ldp", (long)quality]];
    }
    [parts addObject:kind];
    return [parts componentsJoinedByString:@" · "];
}

- (BOOL)playCapturedStreamAtTime:(NSTimeInterval)startTime {
    NSDictionary<NSString *, NSString *> *stream = [self.host.browserWebView bestCapturedMediaStream];
    return stream != nil && [self playCapturedStream:stream atTime:startTime];
}

- (BOOL)playCapturedStream:(NSDictionary<NSString *, NSString *> *)stream atTime:(NSTimeInterval)startTime {
    BrowserWebView *webView = self.host.browserWebView;
    NSURL *streamURL = stream[@"url"].length > 0 ? [NSURL URLWithString:stream[@"url"]] : nil;
    if (streamURL == nil) {
        return NO;
    }
    NSURL *pageURL = stream[@"page"].length > 0 ? [NSURL URLWithString:stream[@"page"]] : webView.request.URL;
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    if (webView.browserUserAgent.length > 0) {
        headers[@"User-Agent"] = webView.browserUserAgent;
    }
    if (pageURL.absoluteString.length > 0) {
        headers[@"Referer"] = pageURL.absoluteString;
        if (pageURL.host.length > 0) {
            headers[@"Origin"] = [NSString stringWithFormat:@"%@://%@", pageURL.scheme ?: @"https", pageURL.host];
        }
    }
    NSString *streamHost = streamURL.host.lowercaseString ?: @"";
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    for (NSHTTPCookie *cookie in [BrowserWebView allCookies]) {
        NSString *domain = cookie.domain.lowercaseString ?: @"";
        NSString *bare = [domain hasPrefix:@"."] ? [domain substringFromIndex:1] : domain;
        if (bare.length > 0 && ([streamHost isEqualToString:bare] || [streamHost hasSuffix:[@"." stringByAppendingString:bare]])) {
            [cookies addObject:cookie];
        }
    }
    BrowserLog(@"[MediaCapture] playing %@ (%@) at %.1fs", stream[@"url"], stream[@"type"], startTime);
    // Formats the Apple TV player can't play at all go straight to the VLC player.
    NSString *extension = streamURL.pathExtension.lowercaseString ?: @"";
    if ([stream[@"type"] isEqualToString:@"dash"] || [@[@"webm", @"mkv", @"flv", @"ogv", @"avi"] containsObject:extension]) {
        [self presentVLCPlayerForURL:streamURL title:self.host.browserCurrentPageTitle requestHeaders:headers startTime:startTime];
        return YES;
    }
    // Every other playable stream of the page, best first, so the player can offer "next video" if this one fails.
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *alternatives = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *candidate in [webView playableCapturedMediaStreams]) {
        if (![candidate[@"url"] isEqualToString:stream[@"url"]]) {
            [alternatives addObject:candidate];
        }
    }
    self.pendingAlternatives = alternatives;
    self.forceNativePlayback = YES;
    self.pendingStartTime = startTime;
    [self presentNativeVideoPlayerForURL:streamURL
                                   title:self.host.browserCurrentPageTitle
                          requestHeaders:headers
                                 cookies:cookies];
    self.forceNativePlayback = NO;
    self.pendingStartTime = 0.0;
    self.pendingAlternatives = nil;
    return YES;
}

/// The Apple TV player just finished a short clip (the advert). The page still sits in front of the real video,
/// so: skip its advert, let it load the real stream, and open that one in the player.
- (void)continueAfterAdvertStream:(NSURL *)advertURL {
    BrowserWebView *webView = self.host.browserWebView;
    if (webView == nil) {
        return;
    }
    [webView markCapturedStreamAsAdvert:advertURL.absoluteString];
    NSSet<NSString *> *knownBefore = [NSSet setWithArray:[[webView playableCapturedMediaStreams] valueForKey:@"url"] ?: @[]];
    [webView skipPageAdvertsAndPlayMainVideo];
    [self waitForRealStreamAttempt:0 knownBefore:knownBefore];
}

- (void)waitForRealStreamAttempt:(NSUInteger)attempt knownBefore:(NSSet<NSString *> *)knownBefore {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BrowserWebView *webView = weakSelf.host.browserWebView;
        if (weakSelf == nil || webView == nil || webView.window == nil) {
            return;
        }
        if (webView.window.rootViewController.presentedViewController != nil) {
            return; // something else opened meanwhile
        }
        NSArray<NSDictionary<NSString *, NSString *> *> *streams = [webView playableCapturedMediaStreams];
        NSDictionary<NSString *, NSString *> *fresh = nil;
        for (NSDictionary<NSString *, NSString *> *stream in streams) {
            if (![knownBefore containsObject:stream[@"url"]]) {
                fresh = stream;
                break;
            }
        }
        // A new stream appeared (the real video), or after a few seconds the best one that isn't the advert.
        if (fresh == nil && attempt >= 6) {
            fresh = streams.firstObject;
        }
        if (fresh != nil) {
            BrowserLog(@"[MediaCapture] after the advert: %@", fresh[@"url"]);
            [weakSelf playCapturedStream:fresh atTime:0.0];
            return;
        }
        if (attempt < 15) {
            if (attempt % 3 == 2) {
                [webView skipPageAdvertsAndPlayMainVideo];
            }
            [weakSelf waitForRealStreamAttempt:attempt + 1 knownBefore:knownBefore];
            return;
        }
        BrowserLog(@"[MediaCapture] no real stream after the advert; staying on the page");
    });
}

- (instancetype)initWithHost:(id<BrowserVideoPlaybackCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService {
    self = [super init];
    if (self) {
        _host = host;
        _domInteractionService = domInteractionService;
    }
    return self;
}

- (BrowserYouTubeExtractor *)youTubeExtractor {
    if (_youTubeExtractor == nil) {
        _youTubeExtractor = [BrowserYouTubeExtractor new];
    }
    return _youTubeExtractor;
}

- (void)playVideoUnderCursorIfAvailable {
    // "Play Active Video" is an explicit request, so it works even with the full-screen setting off.
    self.forceNativePlayback = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.forceNativePlayback = NO;
    });

    UIViewController *presentedViewController = self.host.browserPresentedViewController;
    if (!self.host.browserIsCursorModeEnabled ||
        (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]])) {
        return;
    }

    NSURL *pageURL = self.host.browserWebView.request.URL;
    CGPoint point = self.host.browserDOMCursorPoint;
    NSDictionary *videoInfo = [self.domInteractionService videoInfoAtDOMPoint:point
                                                                       webView:self.host.browserWebView];
    if (kBrowserYouTubeNativeExtractionEnabled && [[self youTubeExtractor] canExtractFromPageURL:pageURL]) {
        [self playYouTubeVideoAtPageURL:pageURL fallbackVideoInfo:videoInfo];
        return;
    }

    NSString *videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
    if (![self isNativePlayableVideoURLString:videoURLString] &&
        [self.domInteractionService isVideoActivationTargetAtDOMPoint:point webView:self.host.browserWebView]) {
        NSDictionary *activatedVideoInfo = [self.domInteractionService activateVideoTargetAtDOMPoint:point
                                                                                              webView:self.host.browserWebView
                                                                                              timeout:1.5];
        if (activatedVideoInfo.count > 0) {
            videoInfo = activatedVideoInfo;
            videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
        }
    }

    if (![self isNativePlayableVideoURLString:videoURLString]) {
        [self presentUnsupportedNativeVideoAlertForVideoInfo:videoInfo ?: @{}];
        return;
    }

    NSURL *videoURL = [NSURL URLWithString:videoURLString];
    NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : self.host.browserCurrentPageTitle;
    [self presentNativeVideoPlayerForURL:videoURL title:title];
}

- (BOOL)handleSelectPressForVideoAtCursor {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        return NO;
    }

    CGPoint point = self.host.browserDOMCursorPoint;
    if ([self.domInteractionService isVideoDismissTargetAtDOMPoint:point webView:self.host.browserWebView]) {
        return NO;
    }

    NSDictionary *directVideoInfo = [self.domInteractionService directVideoInfoAtDOMPoint:point
                                                                                   webView:self.host.browserWebView];
    NSString *directVideoURLString = [self nativePlayableURLStringFromVideoInfo:directVideoInfo];
    if ([self isNativePlayableVideoURLString:directVideoURLString]) {
        NSURL *videoURL = [NSURL URLWithString:directVideoURLString];
        NSString *title = [directVideoInfo[@"title"] isKindOfClass:[NSString class]] ? directVideoInfo[@"title"] : self.host.browserCurrentPageTitle;
        [self presentNativeVideoPlayerForURL:videoURL title:title];
        return YES;
    }

    if (![self.domInteractionService isVideoActivationTargetAtDOMPoint:point webView:self.host.browserWebView]) {
        return NO;
    }

    NSDictionary *videoInfo = [self.domInteractionService primedVideoInfoAtDOMPoint:point webView:self.host.browserWebView];
    if (videoInfo.count == 0) {
        videoInfo = [self.domInteractionService videoInfoAtDOMPoint:point webView:self.host.browserWebView];
    }

    NSString *videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
    if (![self isNativePlayableVideoURLString:videoURLString]) {
        NSDictionary *activatedVideoInfo = [self.domInteractionService activateVideoTargetAtDOMPoint:point
                                                                                              webView:self.host.browserWebView
                                                                                              timeout:1.5];
        if (activatedVideoInfo.count > 0) {
            videoInfo = activatedVideoInfo;
            videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
        }
    }

    if ([self isNativePlayableVideoURLString:videoURLString]) {
        NSURL *videoURL = [NSURL URLWithString:videoURLString];
        NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : self.host.browserCurrentPageTitle;
        [self presentNativeVideoPlayerForURL:videoURL title:title];
    } else {
        [self presentUnsupportedNativeVideoAlertForVideoInfo:videoInfo ?: @{}];
    }
    return YES;
}

- (NSString *)nativePlayableURLStringFromVideoInfo:(NSDictionary *)videoInfo {
    NSString *primarySource = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
    if ([self isNativePlayableVideoURLString:primarySource]) {
        return primarySource;
    }

    NSArray *sources = [videoInfo[@"sources"] isKindOfClass:[NSArray class]] ? videoInfo[@"sources"] : @[];
    for (id sourceValue in sources) {
        if (![sourceValue isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *source = (NSString *)sourceValue;
        if ([self isNativePlayableVideoURLString:source]) {
            return source;
        }
    }

    return primarySource;
}

- (BOOL)isNativePlayableVideoURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return NO;
    }

    NSString *lowercaseURLString = URLString.lowercaseString;
    if ([lowercaseURLString hasPrefix:@"blob:"] ||
        [lowercaseURLString hasPrefix:@"data:"] ||
        [lowercaseURLString hasPrefix:@"mediastream:"]) {
        return NO;
    }

    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return NO;
    }

    NSString *scheme = URL.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

- (void)presentNativeVideoPlayerForURL:(NSURL *)URL title:(NSString *)title {
    [self presentNativeVideoPlayerForURL:URL title:title requestHeaders:nil cookies:nil];
}

- (void)presentNativeVideoPlayerForURL:(NSURL *)URL
                                 title:(NSString *)title
                        requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders
                               cookies:(NSArray<NSHTTPCookie *> *)cookies {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        return;
    }

    if (URL == nil) {
        return;
    }

    [self.host.browserWebView pauseAllMediaPlayback];

    BrowserNativeVideoPlayerViewController *playerViewController = [[BrowserNativeVideoPlayerViewController alloc] initWithURL:URL
                                                                                                                          title:title
                                                                                                                  requestHeaders:requestHeaders
                                                                                                                         cookies:cookies];
    playerViewController.startTimeSeconds = self.pendingStartTime;
    // If the Apple TV player can't play it, the VLC player takes over automatically.
    __weak typeof(self) weakSelf = self;
    NSString *playerTitle = title;
    NSDictionary<NSString *, NSString *> *playerHeaders = requestHeaders;
    playerViewController.playWithVLCHandler = ^(NSURL *streamURL, NSTimeInterval currentTime) {
        [weakSelf presentVLCPlayerForURL:streamURL title:playerTitle requestHeaders:playerHeaders startTime:currentTime];
    };
    playerViewController.alternativeStreams = self.pendingAlternatives;
    if (self.pendingAlternatives != nil) {
        // Played one of the page's streams: if it was only the advert, fetch the real video afterwards.
        playerViewController.shortClipEndedHandler = ^(NSURL *streamURL) {
            [weakSelf continueAfterAdvertStream:streamURL];
        };
    }
    [self.host browserPresentViewController:playerViewController];
}

- (void)presentVLCPlayerForURL:(NSURL *)URL
                         title:(NSString *)title
                requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders
                     startTime:(NSTimeInterval)startTime {
    if (URL == nil) {
        return;
    }
    if (![BrowserVLCPlayerViewController isAvailable]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"VLC Player Missing")
                                                                       message:BrowserLocalized(@"The universal player is not included in this build.")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self.host browserPresentViewController:alert];
        return;
    }
    [self.host.browserWebView pauseAllMediaPlayback];
    BrowserVLCPlayerViewController *player = [[BrowserVLCPlayerViewController alloc] initWithURL:URL
                                                                                           title:title
                                                                                  requestHeaders:requestHeaders
                                                                                       startTime:startTime];
    [self.host browserPresentViewController:player];
}

- (NSDictionary<NSString *, NSString *> *)browserHeadersForYouTubePlaybackURL:(NSURL *)playbackURL
                                                                       pageURL:(NSURL *)pageURL {
    if (playbackURL == nil || pageURL == nil) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    NSString *userAgent = [[NSUserDefaults standardUserDefaults] stringForKey:kUserAgentDefaultsKey];
    if (userAgent.length > 0) {
        headers[@"User-Agent"] = userAgent;
    }

    headers[@"Referer"] = pageURL.absoluteString ?: @"https://www.youtube.com/";
    NSString *origin = [NSString stringWithFormat:@"%@://%@", pageURL.scheme ?: @"https", pageURL.host ?: @"www.youtube.com"];
    headers[@"Origin"] = origin;

    NSArray<NSHTTPCookie *> *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:pageURL];
    if (cookies.count > 0) {
        NSDictionary<NSString *, NSString *> *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
        NSString *cookieHeader = cookieHeaders[@"Cookie"];
        if (cookieHeader.length > 0) {
            headers[@"Cookie"] = cookieHeader;
        }
    }

    return headers.count > 0 ? headers : nil;
}

- (BOOL)cookie:(NSHTTPCookie *)cookie matchesHost:(NSString *)host {
    if (cookie == nil || host.length == 0) {
        return NO;
    }

    NSString *cookieDomain = cookie.domain.lowercaseString ?: @"";
    NSString *lowercaseHost = host.lowercaseString;
    if (cookieDomain.length == 0) {
        return NO;
    }

    if ([cookieDomain hasPrefix:@"."]) {
        cookieDomain = [cookieDomain substringFromIndex:1];
    }

    return [lowercaseHost isEqualToString:cookieDomain] || [lowercaseHost hasSuffix:[@"." stringByAppendingString:cookieDomain]];
}

- (NSArray<NSHTTPCookie *> *)browserCookiesForYouTubePlaybackURL:(NSURL *)playbackURL
                                                          pageURL:(NSURL *)pageURL {
    NSMutableArray<NSHTTPCookie *> *matchingCookies = [NSMutableArray array];
    NSMutableSet<NSString *> *seenCookieKeys = [NSMutableSet set];
    NSArray<NSHTTPCookie *> *allCookies = [BrowserWebView allCookies];
    NSString *pageHost = pageURL.host.lowercaseString ?: @"";
    NSString *playbackHost = playbackURL.host.lowercaseString ?: @"";

    for (NSHTTPCookie *cookie in allCookies) {
        BOOL matches = [self cookie:cookie matchesHost:pageHost] ||
            [self cookie:cookie matchesHost:playbackHost] ||
            [self cookie:cookie matchesHost:@"youtube.com"] ||
            [self cookie:cookie matchesHost:@"googlevideo.com"];
        if (!matches) {
            continue;
        }

        NSString *cookieKey = [NSString stringWithFormat:@"%@|%@|%@", cookie.domain ?: @"", cookie.path ?: @"", cookie.name ?: @""];
        if ([seenCookieKeys containsObject:cookieKey]) {
            continue;
        }
        [seenCookieKeys addObject:cookieKey];
        [matchingCookies addObject:cookie];
    }

    return matchingCookies;
}

- (void)presentUnsupportedNativeVideoAlertForVideoInfo:(NSDictionary *)videoInfo {
    // The video element only has a "blob:" address, but the page may have loaded a real stream in the background.
    if ([self playCapturedStreamAtTime:0.0]) {
        return;
    }
    // Many pages only load the real stream once the video starts: start it on the page and wait a few seconds for it.
    BrowserWebView *webView = self.host.browserWebView;
    [webView stringByEvaluatingJavaScriptFromString:
     @"(function(){ var best = null, area = 0; document.querySelectorAll('video').forEach(function(v){"
      "var r = v.getBoundingClientRect(); var a = r.width * r.height; if (a > area) { area = a; best = v; } });"
      "if (best && best.paused) { try { var p = best.play(); if (p && p.catch) { p.catch(function(){}); } } catch (e) {} }"
      "return 'ok'; })()"];
    [self waitForCapturedStreamWithVideoInfo:videoInfo ?: @{} attempt:0];
}

- (void)waitForCapturedStreamWithVideoInfo:(NSDictionary *)videoInfo attempt:(NSUInteger)attempt {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (strongSelf.host.browserPresentedViewController != nil) {
            return;
        }
        if ([strongSelf.host.browserWebView bestCapturedMediaStream] != nil) {
            NSString *time = [strongSelf.host.browserWebView stringByEvaluatingJavaScriptFromString:
                              @"(function(){ var t = 0; document.querySelectorAll('video').forEach(function(v){ if (v.currentTime > t) { t = v.currentTime; } }); return String(t); })()"];
            [strongSelf playCapturedStreamAtTime:time.doubleValue];
            return;
        }
        if (attempt < 16) {
            [strongSelf waitForCapturedStreamWithVideoInfo:videoInfo attempt:attempt + 1];
            return;
        }
        [strongSelf presentNoStreamFoundAlertForVideoInfo:videoInfo];
    });
}

- (void)presentNoStreamFoundAlertForVideoInfo:(NSDictionary *)videoInfo {
    (void)videoInfo;
    // What the page did load, so the reason is visible (e.g. only adverts, or only DASH).
    NSArray<NSDictionary<NSString *, NSString *> *> *all = self.host.browserWebView.capturedMediaStreams;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *stream in [all reverseObjectEnumerator]) {
        if (lines.count >= 5) {
            break;
        }
        NSURL *URL = [NSURL URLWithString:stream[@"url"] ?: @""];
        [lines addObject:[NSString stringWithFormat:@"• %@ · %@ (%@)", URL.host ?: @"?", stream[@"type"] ?: @"?", URL.lastPathComponent ?: @""]];
    }
    NSString *found = lines.count > 0
        ? [NSString stringWithFormat:BrowserLocalized(@"Found (%lu), but nothing playable:\n%@"), (unsigned long)all.count, [lines componentsJoinedByString:@"\n"]]
        : BrowserLocalized(@"The page didn't load a video address the app could see.");
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"No Video for the Apple TV Player")
                                                                             message:[NSString stringWithFormat:BrowserLocalized(@"Start the video on the page first and try again – or choose “Full Screen”.\n\n%@"), found]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentYouTubeExtractionError:(NSError *)error fallbackVideoInfo:(NSDictionary *)videoInfo {
    NSString *message = error.localizedDescription ?: BrowserLocalized(@"Could not extract a better YouTube playback URL.");
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"YouTube Extraction Failed")
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    NSString *fallbackURLString = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
    if ([self isNativePlayableVideoURLString:fallbackURLString]) {
        [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Play Current URL")
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURL *fallbackURL = [NSURL URLWithString:fallbackURLString];
            NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : weakSelf.host.browserCurrentPageTitle;
            [weakSelf presentNativeVideoPlayerForURL:fallbackURL title:title];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (void)playYouTubeVideoAtPageURL:(NSURL *)pageURL fallbackVideoInfo:(NSDictionary *)videoInfo {
    __weak typeof(self) weakSelf = self;
    [[self youTubeExtractor] extractPlaybackInfoFromPageURL:pageURL webView:self.host.browserWebView completion:^(BrowserYouTubeExtractionResult *result, NSError *error) {
        if (result.playbackURL != nil) {
            NSString *title = result.title.length > 0 ? result.title : weakSelf.host.browserCurrentPageTitle;
            NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionaryWithDictionary:result.requestHeaders ?: @{}];
            NSDictionary<NSString *, NSString *> *fallbackHeaders = [weakSelf browserHeadersForYouTubePlaybackURL:result.playbackURL pageURL:pageURL];
            [fallbackHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
                if (headers[key].length == 0 && value.length > 0) {
                    headers[key] = value;
                }
            }];

            NSArray<NSHTTPCookie *> *cookies = [weakSelf browserCookiesForYouTubePlaybackURL:result.playbackURL pageURL:pageURL];
            if (cookies.count > 0) {
                NSDictionary<NSString *, NSString *> *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
                NSString *cookieHeader = cookieHeaders[@"Cookie"];
                if (cookieHeader.length > 0) {
                    headers[@"Cookie"] = cookieHeader;
                }
            }

            [weakSelf presentNativeVideoPlayerForURL:result.playbackURL
                                               title:title
                                      requestHeaders:headers.count > 0 ? headers : nil
                                             cookies:cookies];
            return;
        }

        [weakSelf presentYouTubeExtractionError:error fallbackVideoInfo:videoInfo ?: @{}];
    }];
}

@end
