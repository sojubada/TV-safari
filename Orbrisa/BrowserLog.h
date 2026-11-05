//
//  BrowserLog.h
//  Orbrisa
//

#import <Foundation/Foundation.h>

/// Console logging for development. Debug builds print to the Xcode console;
/// Release builds stay silent (the arguments are still type-checked, so nothing goes stale).
#if DEBUG
#define BrowserLog(...) NSLog(__VA_ARGS__)
#else
#define BrowserLog(...) do { if (0) { NSLog(__VA_ARGS__); } } while (0)
#endif
