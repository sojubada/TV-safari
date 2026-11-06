#import "BrowserDiagnosticsLog.h"

#import <UIKit/UIKit.h>

#import <mach/mach.h>
#import <os/proc.h>

#import <objc/runtime.h>

#import <execinfo.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <string.h>
#import <signal.h>
#import <unistd.h>

static const unsigned long long kBrowserDiagnosticsMaxBytes = 512 * 1024;
static NSString *const kBrowserDiagnosticsFileName = @"orbrisa-diag.log";

@interface BrowserDiagnosticsLog ()
@property (nonatomic, readwrite, copy, nullable) NSString *logFilePath;
@property (nonatomic) dispatch_queue_t writeQueue;
@property (nonatomic) NSDateFormatter *timestampFormatter;
@end


// Written from a signal handler, where almost nothing is allowed: no
// Objective-C, no malloc, no NSString. Only the path, held as plain bytes
// from before the crash, and write().
static char gBrowserLogPathBytes[1024] = {0};

static void BrowserWriteRaw(const char *text) {
    if (gBrowserLogPathBytes[0] == 0 || text == NULL) {
        return;
    }
    int fd = open(gBrowserLogPathBytes, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) {
        return;
    }
    size_t length = strlen(text);
    ssize_t ignored = write(fd, text, length);
    (void)ignored;
    close(fd);
}

static void BrowserHandleFatalSignal(int signalNumber) {
    switch (signalNumber) {
        case SIGSEGV: BrowserWriteRaw("SIGNAL  SIGSEGV (bad memory access)\n"); break;
        case SIGBUS:  BrowserWriteRaw("SIGNAL  SIGBUS\n"); break;
        case SIGABRT: BrowserWriteRaw("SIGNAL  SIGABRT\n"); break;
        case SIGILL:  BrowserWriteRaw("SIGNAL  SIGILL\n"); break;
        case SIGFPE:  BrowserWriteRaw("SIGNAL  SIGFPE\n"); break;
        case SIGTRAP: BrowserWriteRaw("SIGNAL  SIGTRAP\n"); break;
        default:      BrowserWriteRaw("SIGNAL  other\n"); break;
    }
    // Where it came from. No symbol names in a release build, but the image
    // each frame belongs to — this app, WebKit, libsystem — and its offset is
    // already the difference between a bug here and a bug underneath.
    // backtrace_symbols_fd writes straight to the descriptor without
    // allocating, which is what makes it usable here.
    static void *frames[48];
    int frameCount = backtrace(frames, 48);
    if (frameCount > 0 && gBrowserLogPathBytes[0] != 0) {
        int fd = open(gBrowserLogPathBytes, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) {
            backtrace_symbols_fd(frames, frameCount, fd);
            close(fd);
        }
    }
    // Hand it back to the system so the crash still happens as it would have.
    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

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
    // Only the app's own folders. Nothing outside the app's container is ever
    // written, so the log cannot touch anything else on the box.
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSArray<NSString *> *caches =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (caches.firstObject != nil) {
        [candidates addObject:[caches.firstObject stringByAppendingPathComponent:@"Diagnostics"]];
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

- (void)installCrashAndStallWatch {
    NSString *path = self.logFilePath;
    if (path.length == 0) {
        return;
    }
    strncpy(gBrowserLogPathBytes, path.fileSystemRepresentation, sizeof(gBrowserLogPathBytes) - 1);

    [self captureStandardErrorFromPreviousLaunch];

    signal(SIGSEGV, BrowserHandleFatalSignal);
    signal(SIGBUS, BrowserHandleFatalSignal);
    signal(SIGABRT, BrowserHandleFatalSignal);
    signal(SIGILL, BrowserHandleFatalSignal);
    signal(SIGFPE, BrowserHandleFatalSignal);
    signal(SIGTRAP, BrowserHandleFatalSignal);

    [self startMainThreadStallWatch];
}

// A frozen app is killed with no warning and no exception, so the only way to
// know it froze is to have asked the main thread a question it failed to
// answer. A ping every second; if three in a row go unanswered the main
// thread has been stuck for about that long, and that is written down.
- (void)startMainThreadStallWatch {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __block NSInteger outstanding = 0;
        dispatch_queue_t watchQueue =
            dispatch_queue_create("browser.diagnostics.watch", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watchQueue);
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                  (uint64_t)(1.0 * NSEC_PER_SEC),
                                  (uint64_t)(0.2 * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            outstanding += 1;
            if (outstanding == 4) {
                // Raw write: the serial queue behind logEvent: is fine, but a
                // stall this long often ends with the process gone before a
                // queued write reaches the disk.
                BrowserWriteRaw("STALL  main thread has not answered for ~4s\n");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                dispatch_async(watchQueue, ^{
                    if (outstanding >= 4) {
                        [weakSelf logEvent:@"STALL-END"
                                    detail:[NSString stringWithFormat:@"main thread answered after ~%lds",
                                            (long)outstanding]];
                    }
                    outstanding = 0;
                });
            });
        });
        dispatch_resume(timer);
        // Held for the life of the app.
        objc_setAssociatedObject(self, @selector(startMainThreadStallWatch), timer,
                                 OBJC_ASSOCIATION_RETAIN);
    });
}

// phys_footprint is what the system measures an app against when it decides
// who to kill, and os_proc_available_memory is what is left of the
// allowance. A page that dies is a page that ran the second number to zero.
+ (long long)freeDiskMegabytes {
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:NULL];
    NSNumber *freeBytes = attributes[NSFileSystemFreeSize];
    if (freeBytes == nil) {
        return -1;
    }
    return freeBytes.longLongValue / (1024 * 1024);
}

- (NSString *)memoryFootprintSummary {
    double usedMB = 0.0;
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        usedMB = (double)info.phys_footprint / (1024.0 * 1024.0);
    }

    double freeMB = -1.0;
    if (@available(tvOS 13.0, *)) {
        freeMB = (double)os_proc_available_memory() / (1024.0 * 1024.0);
    }

    if (freeMB >= 0.0) {
        return [NSString stringWithFormat:@"mem %.0fMB used, %.0fMB left", usedMB, freeMB];
    }
    return [NSString stringWithFormat:@"mem %.0fMB used", usedMB];
}

+ (void)trimStandardErrorIfLarge {
    struct stat info;
    int fd = fileno(stderr);
    if (fd >= 0 && fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 1024 * 1024) {
        ftruncate(fd, 0);
    }
}

- (void)captureStandardErrorFromPreviousLaunch {
    NSString *directory = [self.logFilePath stringByDeletingLastPathComponent];
    if (directory.length == 0) {
        return;
    }
    NSString *current = [directory stringByAppendingPathComponent:@"orbrisa-stderr.log"];
    NSString *previous = [directory stringByAppendingPathComponent:@"orbrisa-stderr.prev.log"];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // What the last launch said on its way out.
    [fileManager removeItemAtPath:previous error:NULL];
    if ([fileManager fileExistsAtPath:current]) {
        [fileManager moveItemAtPath:current toPath:previous error:NULL];
        NSString *text = [NSString stringWithContentsOfFile:previous encoding:NSUTF8StringEncoding error:NULL];
        NSMutableArray<NSString *> *kept = [NSMutableArray array];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if (line.length == 0 || [line containsString:@"[InputTrace]"]) {
                continue;
            }
            [kept addObject:line.length > 300 ? [line substringToIndex:300] : line];
        }
        NSUInteger start = kept.count > 20 ? kept.count - 20 : 0;
        for (NSUInteger i = start; i < kept.count; i++) {
            [self logEventSynchronously:@"prev-stderr" detail:kept[i]];
        }
    }

    // From here on, this launch's own.
    FILE *redirected = freopen(current.fileSystemRepresentation, "a", stderr);
    if (redirected != NULL) {
        setvbuf(stderr, NULL, _IONBF, 0);
    }
}

- (void)logSessionStart {
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"?";
    [self logEvent:@"session"
            detail:[NSString stringWithFormat:@"--- launch v%@ (%@) tvOS %@  %@  disk %lldMB free ---",
                    version, build, [UIDevice currentDevice].systemVersion,
                    [self memoryFootprintSummary], [[self class] freeDiskMegabytes]]];
}

- (void)logEventSynchronously:(NSString *)event detail:(NSString *)detail {
    NSString *path = self.logFilePath;
    if (path.length == 0 || event.length == 0) {
        return;
    }
    NSString *stamp = [self.timestampFormatter stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"%@  %@  %@\n",
                      stamp, event, detail.length > 0 ? detail : @""];
    [[self class] appendLine:line toPath:path];
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
