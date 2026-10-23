#import "BrowserDiagnosticLog.h"

static NSString * const kPreferredDirectory = @"/var/mobile/Media/TVSafari";
static NSString * const kLogFileName = @"tvsafari-diag.log";

// Generous enough to hold a long session, small enough that it can never
// matter to the device. When it is passed the oldest half is dropped.
static unsigned long long const kMaximumLogBytes = 512 * 1024;
static unsigned long long const kTrimToBytes = 192 * 1024;

@interface BrowserDiagnosticLog ()

@property (nonatomic, copy, readwrite) NSString *logPath;
@property (nonatomic, copy, readwrite) NSString *resolvedDirectoryLabel;
@property (nonatomic, readwrite) BOOL usingFallbackPath;
@property (nonatomic, strong) dispatch_queue_t queue;

@end

@implementation BrowserDiagnosticLog

+ (instancetype)sharedLog {
    static BrowserDiagnosticLog *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [BrowserDiagnosticLog new];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("browser.diagnostic.log", DISPATCH_QUEUE_SERIAL);
        [self resolveLogPath];
    }
    return self;
}

// tvOS has no writable Documents directory. NSSearchPathForDirectoriesInDomains
// still returns a path for it, the write silently fails, and the log stays at
// zero bytes — which is exactly what happened. Caches is the directory tvOS
// actually gives an app, so every candidate is tried by writing to it.
- (void)resolveLogPath {
    NSFileManager *manager = NSFileManager.defaultManager;

    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                           NSUserDomainMask,
                                                           YES).firstObject;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    [candidates addObject:kPreferredDirectory];
    if (caches.length > 0) {
        [candidates addObject:caches];
    }
    [candidates addObject:NSTemporaryDirectory()];

    for (NSString *directory in candidates) {
        if (directory.length == 0) {
            continue;
        }
        if (![manager fileExistsAtPath:directory]) {
            [manager createDirectoryAtPath:directory
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:NULL];
        }

        NSString *probe = [directory stringByAppendingPathComponent:@".tvsafari-write-probe"];
        BOOL wrote = [@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if (!wrote) {
            continue;
        }
        // Removing only the probe the line above just created.
        [manager removeItemAtPath:probe error:NULL];

        self.logPath = [directory stringByAppendingPathComponent:kLogFileName];
        self.usingFallbackPath = ![directory isEqualToString:kPreferredDirectory];
        self.resolvedDirectoryLabel = [directory isEqualToString:kPreferredDirectory]
            ? @"미디어 폴더"
            : ([directory isEqualToString:caches] ? @"앱 캐시 폴더" : @"임시 폴더");
        return;
    }

    self.logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:kLogFileName];
    self.usingFallbackPath = YES;
    self.resolvedDirectoryLabel = @"쓸 수 있는 폴더를 찾지 못함";
}

- (NSString *)timestamp {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [formatter stringFromDate:[NSDate date]];
}

- (void)logLine:(NSString *)line {
    [self appendText:[NSString stringWithFormat:@"[%@] %@\n", [self timestamp], line ?: @""]];
}

- (void)logSection:(NSString *)title body:(NSString *)body {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"\n===== %@ — %@ =====\n", [self timestamp], title ?: @""];
    if (body.length > 0) {
        [text appendString:body];
        if (![body hasSuffix:@"\n"]) {
            [text appendString:@"\n"];
        }
    }
    [self appendText:text];
}

- (void)appendText:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }
    NSString *path = self.logPath;
    dispatch_async(self.queue, ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        if (![manager fileExistsAtPath:path]) {
            [manager createFileAtPath:path contents:data attributes:nil];
            return;
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:path];
        if (handle == nil) {
            return;
        }
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (__unused NSException *exception) {
            return;
        }

        [self trimIfNeededAtPath:path];
    });
}

- (void)trimIfNeededAtPath:(NSString *)path {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    unsigned long long size = attributes.fileSize;
    if (size <= kMaximumLogBytes) {
        return;
    }

    NSData *existing = [NSData dataWithContentsOfFile:path];
    if (existing.length <= kTrimToBytes) {
        return;
    }
    NSData *tail = [existing subdataWithRange:NSMakeRange(existing.length - (NSUInteger)kTrimToBytes,
                                                          (NSUInteger)kTrimToBytes)];
    NSMutableData *trimmed = [[@"(이전 기록은 크기 제한으로 잘렸습니다)\n"
                               dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [trimmed appendData:tail];
    [trimmed writeToFile:path atomically:YES];
}

- (NSString *)statusDescription {
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL exists = [manager fileExistsAtPath:self.logPath];
    NSDictionary *attributes = [manager attributesOfItemAtPath:self.logPath error:NULL];
    unsigned long long size = attributes.fileSize;
    return [NSString stringWithFormat:@"%@\n%@\n파일 %@ · %llu바이트",
            self.resolvedDirectoryLabel ?: @"-",
            self.logPath,
            exists ? @"있음" : @"없음",
            size];
}

- (void)clear {
    NSString *path = self.logPath;
    dispatch_async(self.queue, ^{
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}

@end
