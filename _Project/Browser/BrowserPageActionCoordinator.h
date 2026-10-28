#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "BrowserRemoteInputController.h"

@class BrowserDOMInteractionService;
@class BrowserNavigationService;
@class BrowserPreferencesStore;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserPageActionCoordinatorHost <NSObject>

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController;
- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request;
/// Asks the host to type into this field from a connected hardware
/// keyboard. NO when there is none, and the system text entry screen is
/// then the way in.
/// How far keyboard detection got, named in the dialog that appears when
/// direct typing could not start.
- (NSString *)browserPageActionCoordinatorKeyboardDetectionSummary;
- (BOOL)browserPageActionCoordinatorBeginHardwareTypingAtDOMPoint:(CGPoint)point
                                                          webView:(BrowserWebView *)webView
                                                     existingText:(NSString *)existingText;

@end

@interface BrowserPageActionCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
            preferencesStore:(BrowserPreferencesStore *)preferencesStore NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (NSString *)hoverStateAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;
- (BOOL)handlePageSelectionAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView
                               source:(BrowserPageActivationSource)source;

@end

NS_ASSUME_NONNULL_END