#import "BrowserDiagnosticLog.h"

static NSString * const kPreferredDirectory = @"/var/mobile/Media/TVSafari";
static NSString * const kLogFileName = @"tvsafari-diag.log";

// Generous enough to hold a long session, small enough that it can never
// matter to the device. When it is passed the oldest half is dropped.
static unsigned long long const kMaximumLogBytes = 512 * 1024;
static unsigned long long const kTrimToBytes = 192 * 1024;

@interface BrowserDiagnosticLog ()

@property (nonatomic, copy, readwrite) NSString *logPath;
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

- (void)resolveLogPath {
    NSFileManager *manager = NSFileManager.defaultManager;

    // isWritableFileAtPath: answered yes on a path the app could not actually
    // write to, so this tries the write instead of asking about it.
    [manager createDirectoryAtPath:kPreferredDirectory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:NULL];

    NSString *candidate = [kPreferredDirectory stringByAppendingPathComponent:kLogFileName];
    NSString *probe = [kPreferredDirectory stringByAppendingPathComponent:@".write-probe"];
    BOOL wrote = [@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (wrote) {
        // Removing only the probe this method just created.
        [manager removeItemAtPath:probe error:NULL];
        self.logPath = candidate;
        self.usingFallbackPath = NO;
        return;
    }

    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask,
                                                              YES).firstObject ?: NSTemporaryDirectory();
    self.logPath = [documents stringByAppendingPathComponent:kLogFileName];
    self.usingFallbackPath = YES;
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
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.logPath error:NULL];
    unsigned long long size = attributes.fileSize;
    NSString *where = self.usingFallbackPath ? @"앱 내부 (미디어 폴더에 못 씀)" : @"미디어 폴더";
    return [NSString stringWithFormat:@"%@\n%@\n%llu바이트", where, self.logPath, size];
}

// Reading it back so it can be shown on screen: moving a file off the device
// turned out to be the hard part, and a report view needs no file at all.
- (NSString *)contentsForDisplay {
    NSString *text = [NSString stringWithContentsOfFile:self.logPath
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text.length == 0) {
        return [NSString stringWithFormat:@"로그가 비어 있습니다.\n\n%@", [self statusDescription]];
    }
    // Newest last, so the tail is what matters when it is long.
    NSUInteger limit = 12000;
    if (text.length > limit) {
        text = [NSString stringWithFormat:@"(앞부분 생략)\n%@",
                [text substringFromIndex:text.length - limit]];
    }
    return text;
}

- (void)clear {
    NSString *path = self.logPath;
    dispatch_async(self.queue, ^{
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}

@end
