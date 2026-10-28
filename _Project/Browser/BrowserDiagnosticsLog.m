#import "BrowserDiagnosticsLog.h"

#import <UIKit/UIKit.h>

static const unsigned long long kBrowserDiagnosticsMaxBytes = 512 * 1024;
static NSString *const kBrowserDiagnosticsFileName = @"tv-safari-diag.log";

@interface BrowserDiagnosticsLog ()
@property (nonatomic, readwrite, copy, nullable) NSString *logFilePath;
@property (nonatomic) dispatch_queue_t writeQueue;
@property (nonatomic) NSDateFormatter *timestampFormatter;
@end

@implementation BrowserDiagnosticsLog

+ (instancetype)sharedLog {
    static BrowserDiagnosticsLog *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[BrowserDiagnosticsLog alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _writeQueue = dispatch_queue_create("browser.diagnostics", DISPATCH_QUEUE_SERIAL);
        _timestampFormatter = [[NSDateFormatter alloc] init];
        _timestampFormatter.dateFormat = @"MM-dd HH:mm:ss";
        _timestampFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _logFilePath = [[self class] resolveWritableLogPath];
    }
    return self;
}

// Asking the file system whether a directory is writable is not enough on
// this system — a path can look fine and swallow the write. So each candidate
// is tried with a real file, and the first one that holds it wins.
+ (nullable NSString *)resolveWritableLogPath {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    [candidates addObject:@"/private/var/mobile/Media/TVSafari"];
    [candidates addObject:@"/var/mobile/Media/TVSafari"];
    [candidates addObject:@"/private/var/mobile/Media"];

    NSArray<NSString *> *caches =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (caches.firstObject != nil) {
        [candidates addObject:[caches.firstObject stringByAppendingPathComponent:@"TVSafari"]];
    }
    [candidates addObject:NSTemporaryDirectory()];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *directory in candidates) {
        if (directory.length == 0) {
            continue;
        }
        if (![fileManager fileExistsAtPath:directory]) {
            [fileManager createDirectoryAtPath:directory
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:NULL];
        }
        NSString *path = [directory stringByAppendingPathComponent:kBrowserDiagnosticsFileName];
        NSString *probe = @"";
        if (![fileManager fileExistsAtPath:path]) {
            if (![probe writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
                continue;
            }
        }
        // Existing or just created, it still has to accept an append.
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            continue;
        }
        [handle closeFile];
        return path;
    }
    return nil;
}

- (void)logSessionStart {
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"?";
    [self logEvent:@"session"
            detail:[NSString stringWithFormat:@"--- launch v%@ (%@) tvOS %@ ---",
                    version, build, [UIDevice currentDevice].systemVersion]];
}

- (void)logEvent:(NSString *)event detail:(NSString *)detail {
    NSString *path = self.logFilePath;
    if (path.length == 0 || event.length == 0) {
        return;
    }
    NSString *stamp = [self.timestampFormatter stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"%@  %@  %@\n",
                      stamp, event, detail.length > 0 ? detail : @""];

    dispatch_async(self.writeQueue, ^{
        [[self class] appendLine:line toPath:path];
    });
}

+ (void)appendLine:(NSString *)line toPath:(NSString *)path {
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    // Kept to a size that can be read in one sitting: past the cap the older
    // half goes, which keeps the recent history that a problem lives in.
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [fileManager attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (size > kBrowserDiagnosticsMaxBytes) {
        NSData *existing = [NSData dataWithContentsOfFile:path];
        if (existing.length > (NSUInteger)(kBrowserDiagnosticsMaxBytes / 2)) {
            NSData *tail = [existing subdataWithRange:
                            NSMakeRange(existing.length - (NSUInteger)(kBrowserDiagnosticsMaxBytes / 2),
                                        (NSUInteger)(kBrowserDiagnosticsMaxBytes / 2))];
            [tail writeToFile:path atomically:YES];
        }
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle == nil) {
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (NSException *exception) {
        // A full or vanished volume is not worth taking the app down for.
    }
    [handle closeFile];
}

@end
