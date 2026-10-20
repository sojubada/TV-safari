#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

// Reports what this device's WebKit actually provides, rather than what the
// documentation says it should. Written after the file browser's PDFKit
// mistake: the API was documented for tvOS and absent from the SDK, so the
// rule since then is to probe the real thing before building on it.
@interface BrowserWebPlatformProbe : NSObject

// What the Objective-C runtime exposes: classes, selectors, process model.
+ (NSString *)runtimeReportForWebView:(nullable BrowserWebView *)webView;

// What the page's JavaScript engine supports. Runs in the loaded document.
+ (NSString *)engineReportForWebView:(nullable BrowserWebView *)webView;

// Script errors the page has reported since it loaded.
+ (NSString *)pageErrorReportForWebView:(nullable BrowserWebView *)webView;

// Installed at document start so errors are caught from the first line.
+ (NSString *)errorCaptureScript;

@end

NS_ASSUME_NONNULL_END
