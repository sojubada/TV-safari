#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Append-only diagnostic log written to the user media partition, where a
/// file browser can pick it up. It never touches anything it did not create:
/// it makes one folder, appends to one file, and trims that file when it
/// grows past its cap. Nothing else on the device is read, moved or removed.
@interface BrowserDiagnosticLog : NSObject

+ (instancetype)sharedLog;

/// Where entries are actually going. The media partition when it is writable,
/// otherwise the app's own Documents directory.
@property (nonatomic, readonly, copy) NSString *logPath;
@property (nonatomic, readonly) BOOL usingFallbackPath;

- (void)logSection:(NSString *)title body:(nullable NSString *)body;
- (void)logLine:(NSString *)line;

/// A short human-readable statement of where the log is and how big it is.
- (NSString *)statusDescription;

/// The log as text, newest last, trimmed so it fits a report screen.
- (NSString *)contentsForDisplay;

- (void)clear;

@end

NS_ASSUME_NONNULL_END
