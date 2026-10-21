#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Long diagnostic text, scrollable with the remote. An alert truncates, which
// hid exactly the lines the probes exist to show.
@interface BrowserReportViewController : UIViewController

- (instancetype)initWithTitle:(NSString *)title reportText:(NSString *)reportText NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibName bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
