#import <Foundation/Foundation.h>

@class BrowserSiteSweepController;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserSiteSweepControllerDelegate <NSObject>
/// Put this address on screen. The sweep drives the ordinary browser, so what
/// it finds is what browsing finds.
- (void)siteSweepController:(BrowserSiteSweepController *)controller
              wantsLoadOfURL:(NSURL *)URL;
- (void)siteSweepControllerDidFinish:(BrowserSiteSweepController *)controller;
/// Abandon whatever is loading. A page that never settles otherwise holds
/// the web view and every site after it is recorded as a timeout it had
/// nothing to do with.
- (void)siteSweepControllerWantsStop:(BrowserSiteSweepController *)controller;
@end

/// Walks a bundled list of sites, one at a time, and writes down what each
/// one did: loaded, failed, timed out, or took the web process down with it.
///
/// Reporting a browser problem by hand means noticing it, remembering the
/// address and describing it afterwards. This does the noticing.
///
/// Its position is kept on disk, so a sweep that ends with the app being
/// killed carries on from the site after the one that killed it rather than
/// starting again and dying in the same place.
@interface BrowserSiteSweepController : NSObject

@property (nonatomic, weak, nullable) id<BrowserSiteSweepControllerDelegate> delegate;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger siteCount;
@property (nonatomic, readonly) NSUInteger currentIndex;

- (void)startFromBeginning:(BOOL)fromBeginning;
- (void)stop;

/// Called by the host as the page being swept settles one way or the other.
- (void)noteLoadStarted;
- (void)noteLoadFinished;
- (void)noteLoadFailedWithError:(nullable NSError *)error;
- (void)noteWebContentProcessDidTerminate;

@end

NS_ASSUME_NONNULL_END
