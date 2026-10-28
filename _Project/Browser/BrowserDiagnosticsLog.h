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

@end

NS_ASSUME_NONNULL_END
