#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserDOMInteractionService;
@class BrowserNavigationService;
@class BrowserVideoPlaybackCoordinator;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserPageActionCoordinatorHost <NSObject>

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController;
- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request;

@optional
/// A Bluetooth keyboard is attached: type into the page's field in place, with
/// 두벌식 Hangul composition, instead of opening the Apple TV keyboard. NO when
/// in-place typing can't start, and the Apple TV keyboard is used instead.
- (BOOL)browserPageActionCoordinatorBeginHardwareTypingForFieldType:(NSString *)fieldType
                                                         atDOMPoint:(CGPoint)point
                                                            webView:(BrowserWebView *)webView
                                                       existingText:(NSString *)existingText;

@end

@interface BrowserPageActionCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
    videoPlaybackCoordinator:(BrowserVideoPlaybackCoordinator *)videoPlaybackCoordinator NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (NSString *)hoverStateAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;
- (BOOL)handlePageSelectionAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;

/// The Apple TV keyboard for a page field, skipping in-place keyboard typing
/// (used when a keyboard looked attached but never sent a key).
- (void)presentSystemKeyboardForFieldType:(NSString *)fieldType
                               atDOMPoint:(CGPoint)point
                                  webView:(BrowserWebView *)webView;
/// Writes text into the page's field and fires input/change.
- (void)fillEditableElementAtPoint:(CGPoint)point webView:(BrowserWebView *)webView text:(NSString *)text;
/// Writes text into the page's field and sends it, like Enter on a computer.
- (void)fillAndSendEditableElementAtPoint:(CGPoint)point webView:(BrowserWebView *)webView text:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
