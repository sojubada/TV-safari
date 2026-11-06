#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A running account of what the browser did and where it broke, kept in a
/// plain text file so a problem can be read afterwards instead of described
/// from memory.
///
/// The file lives in the app's own Caches folder and nowhere else; it is read
/// from Settings › Diagnostic Log inside the browser.
@interface BrowserDiagnosticsLog : NSObject

+ (instancetype)sharedLog;

/// The file being written, or nil when nowhere could be written at all.
@property (nonatomic, readonly, copy, nullable) NSString *logFilePath;

/// One line: a timestamp, the event, and whatever detail belongs with it.
/// Safe to call from anywhere; writing is serialised and never blocks on the
/// web view.
- (void)logEvent:(NSString *)event detail:(nullable NSString *)detail;

/// Starts a new session's section, naming the app version.
- (void)logSessionStart;

/// Written before returning, on the calling thread. For the moments when the
/// process is about to end and a queued write would be lost with it — which
/// is exactly what happened to the two aborts in the last log: the signal
/// line made it, the exception that caused it did not.
- (void)logEventSynchronously:(NSString *)event detail:(nullable NSString *)detail;

/// Arms the two things an ordinary log cannot catch: a crash below
/// Objective-C, which kills the process before any normal code runs, and a
/// main thread that stops answering, which ends with the system taking the
/// app and no record of why.
- (void)installCrashAndStallWatch;

/// How much memory the app is using and how much it has left before the
/// system takes it, as a short string for the log. This is the number the
/// whole stability question turns on, and until now it was never measured.
- (NSString *)memoryFootprintSummary;

/// Free space on the device in megabytes, -1 if it cannot be read. Twice now
/// the device has run out mid-sweep and loads failed with "No space left on
/// device"; this is how that is seen coming instead of after.
+ (long long)freeDiskMegabytes;
+ (void)trimStandardErrorIfLarge;

/// The whole log as a page the browser can show, newest first. The file sits
/// in the app's own container, which nothing else on the box can navigate to,
/// so the browser reads it to itself.
- (NSString *)logPageHTML;

@end

NS_ASSUME_NONNULL_END
