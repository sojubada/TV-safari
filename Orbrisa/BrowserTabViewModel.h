#import <UIKit/UIKit.h>

@interface BrowserTabViewModel : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy) NSString *requestURL;
@property (nonatomic, copy) NSString *previousURL;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *URLString;
/// The site's icon (apple-touch-icon / favicon) for the tab strip; empty until the page has loaded.
@property (nonatomic, copy) NSString *iconURLString;
@property (nonatomic, strong) UIImage *snapshotImage;
@property (nonatomic) CGPoint savedScrollOffset;
@property (nonatomic) BOOL hasSavedScrollOffset;
@property (nonatomic) BOOL needsScrollRestore;

- (instancetype)initWithSessionRepresentation:(NSDictionary *)sessionRepresentation;
- (NSDictionary *)sessionRepresentation;

@end
