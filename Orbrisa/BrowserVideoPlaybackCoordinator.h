#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserDOMInteractionService;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserVideoPlaybackCoordinatorHost <NSObject>

@property (nonatomic, readonly) BrowserWebView *browserWebView;
@property (nonatomic, readonly) BOOL browserIsCursorModeEnabled;
@property (nonatomic, readonly) CGPoint browserDOMCursorPoint;
@property (nonatomic, readonly, nullable) UIViewController *browserPresentedViewController;
@property (nonatomic, readonly, nullable) NSString *browserCurrentPageTitle;
@property (nonatomic, readonly) BOOL browserFullscreenVideoPlaybackEnabled;

- (void)browserPresentViewController:(UIViewController *)viewController;

@end

@interface BrowserVideoPlaybackCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserVideoPlaybackCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService;
- (void)playVideoUnderCursorIfAvailable;
- (BOOL)handleSelectPressForVideoAtCursor;
/// YES when the page loaded a video stream the Apple TV player can open (HLS or a video file).
- (BOOL)hasCapturedStream;
/// Opens the page's video stream in the Apple TV player, starting at the given second. NO if there is none.
- (BOOL)playCapturedStreamAtTime:(NSTimeInterval)startTime;
/// Every playable stream of the page, best first, for a choice list.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)capturedStreamChoices;
/// Short readable name of a stream, e.g. "phncdn.com · 1080p · MP4".
- (NSString *)labelForCapturedStream:(NSDictionary<NSString *, NSString *> *)stream;
- (BOOL)playCapturedStream:(NSDictionary<NSString *, NSString *> *)stream atTime:(NSTimeInterval)startTime;

@end

NS_ASSUME_NONNULL_END
