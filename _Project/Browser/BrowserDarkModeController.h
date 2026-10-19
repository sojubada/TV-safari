#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserDarkModeController : NSObject

- (NSString *)applyDarkModeToWebView:(nullable BrowserWebView *)webView;
- (NSString *)removeDarkModeFromWebView:(nullable BrowserWebView *)webView;
- (void)syncDarkModeState:(BOOL)enabled forWebView:(nullable BrowserWebView *)webView;

@end

NS_ASSUME_NONNULL_END