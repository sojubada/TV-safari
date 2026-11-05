#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BrowserViewModel;
@class BrowserNavigationService;

@interface BrowserSessionStore : NSObject

- (BOOL)restoreSessionIntoViewModel:(BrowserViewModel *)viewModel;
- (void)saveSessionForViewModel:(BrowserViewModel *)viewModel;
- (nullable NSURLRequest *)consumeSavedURLToReopenRequestWithNavigationService:(BrowserNavigationService *)navigationService;

@end

NS_ASSUME_NONNULL_END
