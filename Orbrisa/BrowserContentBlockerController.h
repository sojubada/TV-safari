#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserContentBlockerController : NSObject

@property (nonatomic, readonly) BOOL ruleListSupported;
@property (nonatomic, readonly, copy) NSString *compilationStatusString;
@property (nonatomic, readonly) NSUInteger ruleCount;

+ (instancetype)sharedController;
- (void)prepareRuleListIfNeeded;
- (nullable id)compiledRuleList;
- (NSString *)applyContentBlockingToWebView:(nullable BrowserWebView *)webView enabled:(BOOL)enabled;
- (NSString *)diagnosticsReport;

@end

NS_ASSUME_NONNULL_END