#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One row of the workbench. The action runs against the live page that stays
/// visible on the right and returns a short line to show under the list, so a
/// result never covers the thing it is describing.
@interface BrowserWorkbenchItem : NSObject

@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString * _Nullable (^action)(void);

+ (instancetype)itemWithTitle:(NSString *)title action:(NSString * _Nullable (^)(void))action;

@end

@interface BrowserWorkbenchSection : NSObject

@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSArray<BrowserWorkbenchItem *> *items;

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserWorkbenchItem *> *)items;

@end

@protocol BrowserProbeWorkbenchDelegate;

/// The left-hand panel of the workbench. It is a child view controller rather
/// than a presented one: the web view keeps its process and is only narrowed,
/// so everything tried here is seen happening on the real page.
@interface BrowserProbeWorkbenchViewController : UIViewController

@property (nonatomic, weak) id<BrowserProbeWorkbenchDelegate> workbenchDelegate;

- (instancetype)initWithSections:(NSArray<BrowserWorkbenchSection *> *)sections NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)n bundle:(nullable NSBundle *)b NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Rebuilds the rows in place so toggle titles stay truthful after a change.
- (void)setSections:(NSArray<BrowserWorkbenchSection *> *)sections;

@end

@protocol BrowserProbeWorkbenchDelegate <NSObject>
- (void)probeWorkbenchDidRequestClose:(BrowserProbeWorkbenchViewController *)workbench;
@end

NS_ASSUME_NONNULL_END
