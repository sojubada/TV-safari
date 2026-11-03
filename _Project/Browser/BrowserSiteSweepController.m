#import "BrowserSiteSweepController.h"

#import <QuartzCore/QuartzCore.h>

#import "BrowserDiagnosticsLog.h"

static NSString * const kSweepIndexDefaultsKey = @"SiteSweepIndex";
static NSString * const kSweepRunningDefaultsKey = @"SiteSweepRunning";
// Long enough for a slow portal on a slow connection, short enough that a
// hung site does not stall the whole sweep.
static const NSTimeInterval kSweepPerSiteTimeout = 25.0;
// A moment between sites, so the one just finished can be torn down before
// the next is built. Back to back, the memory of both overlaps.
static const NSTimeInterval kSweepSettleDelay = 1.5;

@interface BrowserSiteSweepController ()
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, readwrite) NSUInteger currentIndex;
@property (nonatomic, copy) NSArray<NSString *> *sites;
@property (nonatomic, nullable) NSTimer *timeoutTimer;
@property (nonatomic) CFTimeInterval currentStartTime;
@property (nonatomic) BOOL currentSettled;
@end

@implementation BrowserSiteSweepController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _sites = [[self class] loadSites];
        // A sweep that was running when the app went down is resumed rather
        // than restarted: the site that killed it is exactly the one worth
        // getting past, not repeating.
        if ([[NSUserDefaults standardUserDefaults] boolForKey:kSweepRunningDefaultsKey]) {
            _currentIndex = (NSUInteger)[[NSUserDefaults standardUserDefaults]
                                         integerForKey:kSweepIndexDefaultsKey];
        }
    }
    return self;
}

+ (NSArray<NSString *> *)loadSites {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"sweep-sites" ofType:@"txt"];
    NSString *text = path.length > 0
        ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]
        : nil;
    if (text.length == 0) {
        return @[];
    }
    NSMutableArray<NSString *> *sites = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"http"]) {
            [sites addObject:trimmed];
        }
    }
    return sites;
}

- (NSUInteger)siteCount {
    return self.sites.count;
}

- (void)startFromBeginning:(BOOL)fromBeginning {
    if (self.sites.count == 0) {
        [[BrowserDiagnosticsLog sharedLog] logEvent:@"sweep" detail:@"no site list in the bundle"];
        return;
    }
    if (fromBeginning) {
        self.currentIndex = 0;
    }
    if (self.currentIndex >= self.sites.count) {
        self.currentIndex = 0;
    }
    self.running = YES;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kSweepRunningDefaultsKey];
    [[BrowserDiagnosticsLog sharedLog]
        logEvent:@"sweep"
          detail:[NSString stringWithFormat:@"=== start at %lu of %lu ===",
                  (unsigned long)self.currentIndex + 1, (unsigned long)self.sites.count]];
    [self loadCurrentSite];
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    [self.timeoutTimer invalidate];
    self.timeoutTimer = nil;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kSweepRunningDefaultsKey];
    [[BrowserDiagnosticsLog sharedLog]
        logEvent:@"sweep"
          detail:[NSString stringWithFormat:@"=== stopped at %lu ===",
                  (unsigned long)self.currentIndex + 1]];
}

- (void)loadCurrentSite {
    if (!self.running || self.currentIndex >= self.sites.count) {
        return;
    }

    // Written down before the load, not after: if this site takes the app
    // with it, this line is the last one in the file and names the culprit.
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)self.currentIndex
                                               forKey:kSweepIndexDefaultsKey];

    NSString *urlString = self.sites[self.currentIndex];
    NSURL *URL = [NSURL URLWithString:urlString];
    if (URL == nil) {
        [self recordOutcome:@"bad-url" extra:nil];
        return;
    }

    self.currentSettled = NO;
    self.currentStartTime = CACurrentMediaTime();
    [[BrowserDiagnosticsLog sharedLog]
        logEvent:@"sweep-open"
          detail:[NSString stringWithFormat:@"%lu/%lu  %@",
                  (unsigned long)self.currentIndex + 1,
                  (unsigned long)self.sites.count, urlString]];

    [self.timeoutTimer invalidate];
    self.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:kSweepPerSiteTimeout
                                                         target:self
                                                       selector:@selector(handleTimeout)
                                                       userInfo:nil
                                                        repeats:NO];
    [self.delegate siteSweepController:self wantsLoadOfURL:URL];
}

- (void)handleTimeout {
    [self recordOutcome:@"TIMEOUT" extra:nil];
}

- (void)noteLoadFinished {
    [self recordOutcome:@"ok" extra:nil];
}

- (void)noteLoadFailedWithError:(NSError *)error {
    // -999 is this browser cancelling the previous load to start the next
    // one, which is the sweep's own doing and not the site's.
    if (error.code == NSURLErrorCancelled) {
        return;
    }
    [self recordOutcome:@"FAIL"
                  extra:[NSString stringWithFormat:@"%ld %@",
                         (long)error.code, error.localizedDescription ?: @""]];
}

- (void)noteWebContentProcessDidTerminate {
    [self recordOutcome:@"CRASHED" extra:nil];
}

- (void)recordOutcome:(NSString *)outcome extra:(NSString *)extra {
    if (!self.running || self.currentSettled) {
        return;
    }
    self.currentSettled = YES;
    [self.timeoutTimer invalidate];
    self.timeoutTimer = nil;

    NSUInteger elapsedMilliseconds =
        (NSUInteger)((CACurrentMediaTime() - self.currentStartTime) * 1000.0);
    NSString *urlString = (self.currentIndex < self.sites.count)
        ? self.sites[self.currentIndex] : @"";
    [[BrowserDiagnosticsLog sharedLog]
        logEvent:@"sweep-result"
          detail:[NSString stringWithFormat:@"%@  %lums  %@%@%@",
                  outcome, (unsigned long)elapsedMilliseconds, urlString,
                  extra.length > 0 ? @"  " : @"", extra ?: @""]];

    self.currentIndex += 1;
    if (self.currentIndex >= self.sites.count) {
        [[BrowserDiagnosticsLog sharedLog]
            logEvent:@"sweep" detail:@"=== finished the whole list ==="];
        [self stop];
        [self.delegate siteSweepControllerDidFinish:self];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSweepSettleDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf loadCurrentSite];
    });
}

@end
