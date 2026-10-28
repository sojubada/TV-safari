#import "BrowserDiagnosticsLog.h"

#import <UIKit/UIKit.h>

static const unsigned long long kBrowserDiagnosticsMaxBytes = 512 * 1024;
static NSString *const kBrowserDiagnosticsFileName = @"tv-safari-diag.log";

@interface BrowserDiagnosticsLog ()
@property (nonatomic, readwrite, copy, nullable) NSString *logFilePath;
@property (nonatomic) dispatch_queue_t writeQueue;
@property (nonatomic) NSDateFormatter *timestampFormatter;
+ (NSString *)escapedHTML:(NSString *)text {
    NSMutableString *escaped = [text mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;"
                                options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;"
                                options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;"
                                options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

- (NSString *)logPageHTML {
    NSString *path = self.logFilePath;
    NSString *contents = path.length > 0
        ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]
        : nil;

    NSMutableString *rows = [NSMutableString string];
    if (contents.length > 0) {
        NSArray<NSString *> *lines = [contents componentsSeparatedByString:@"\n"];
        // Newest first: the thing that just went wrong is the thing being
        // looked for, and it should not be at the end of a long scroll.
        for (NSString *line in [[lines reverseObjectEnumerator] allObjects]) {
            if (line.length == 0) {
                continue;
            }
            NSString *className = @"row";
            if ([line rangeOfString:@"CRASH"].location != NSNotFound) {
                className = @"row crash";
            } else if ([line rangeOfString:@"load-fail"].location != NSNotFound) {
                className = @"row fail";
            } else if ([line rangeOfString:@"--- launch"].location != NSNotFound) {
                className = @"row launch";
            }
            [rows appendFormat:@"<div class=\"%@\">%@</div>", className,
                               [[self class] escapedHTML:line]];
        }
    } else {
        [rows appendString:@"<div class=\"row\">기록된 내용이 없습니다.</div>"];
    }

    return [NSString stringWithFormat:
            @"<!doctype html><html><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<style>"
            "body{background:#0d1117;color:#d7dde5;font:28px/1.5 -apple-system,monospace;"
            "margin:0;padding:48px 64px;}"
            "h1{font-size:40px;margin:0 0 8px;color:#fff;}"
            "p.path{color:#8a94a6;font-size:22px;word-break:break-all;margin:0 0 32px;}"
            ".row{padding:10px 14px;border-bottom:1px solid #1d2430;white-space:pre-wrap;"
            "word-break:break-all;}"
            ".crash{background:#3a1416;color:#ff9a9a;}"
            ".fail{background:#3a2d12;color:#ffd48a;}"
            ".launch{background:#10263a;color:#8fc8ff;}"
            "</style></head><body>"
            "<h1>진단 로그</h1><p class=\"path\">%@</p>%@</body></html>",
            [[self class] escapedHTML:path ?: @"(없음)"], rows];
}

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
