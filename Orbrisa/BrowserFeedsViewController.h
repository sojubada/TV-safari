//
//  BrowserFeedsViewController.h
//  Orbrisa
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// All subscribed feeds below the top bar (like the tab overview): the feeds on the left, their newest articles as cards on the right.
/// Click opens the article, Play/Pause on a feed unsubscribes, Back closes.
@interface BrowserFeedsViewController : UIViewController

/// Called with the article's address after the screen closed.
@property (nonatomic, copy, nullable) void (^openArticle)(NSString *URLString);
/// Called when the screen shows up (with the line for the address bar, e.g. "4 new articles"), when that line changes,
/// and with nil when the screen goes away.
@property (nonatomic, copy, nullable) void (^headerChanged)(NSString * _Nullable subtitle);
/// "Add Feed" was chosen: the screen is closed, look for a feed on the current page.
@property (nonatomic, copy, nullable) void (^addFeed)(void);

@end

NS_ASSUME_NONNULL_END
