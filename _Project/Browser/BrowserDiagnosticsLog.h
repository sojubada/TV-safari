#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A running account of what the browser did and where it broke, kept in a
/// plain text file so a problem can be read afterwards instead of described
/// from memory.
///
/// The file is written outside the app wherever that is allowed, so the file
/// browser can open it; where it is not, it falls back to a directory the app
/// certainly owns, and says which one it used.
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

/// Arms the two things an ordinary log cannot catch: a crash below
/// Objective-C, which kills the process before any normal code runs, and a
/// main thread that stops answering, which ends with the system taking the
/// app and no record of why.
- (void)installCrashAndStallWatch;

/// The whole log as a page the browser can show, newest first. The file sits
/// in the app's own container, which nothing else on the box can navigate to,
/// so the browser reads it to itself.
- (NSString *)logPageHTML;

@end

NS_ASSUME_NONNULL_END
