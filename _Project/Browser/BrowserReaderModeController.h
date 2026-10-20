#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserReaderModeController : NSObject

- (BOOL)isReaderModeActiveForWebView:(nullable BrowserWebView *)webView;
- (NSString *)enableReaderModeForWebView:(nullable BrowserWebView *)webView fontSize:(NSUInteger)fontSize;
- (void)disableReaderModeForWebView:(nullable BrowserWebView *)webView;

@end

NS_ASSUME_NONNULL_END
