#import "BrowserTabOverviewController.h"
#import "BrowserLocalization.h"

#import "BrowserTabViewModel.h"
#import "BrowserTopBarView.h"
#import "BrowserViewModel.h"

@class BrowserTabOverviewViewController;


/// The tab's page title; an empty tab ("New Tab" in the model) shows the host or a localized "New Tab".
static NSString *BrowserTabDisplayTitle(BrowserTabViewModel *tab, NSString *host) {
    NSString *title = tab.title ?: @"";
    if (title.length > 0 && ![title isEqualToString:@"New Tab"]) {
        return title;
    }
    return host.length > 0 ? host : BrowserLocalized(@"New Tab");
}

@interface BrowserTabOverviewController ()

@property (nonatomic, weak) id<BrowserTabOverviewControllerHost> host;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic, readwrite, getter=isVisible) BOOL visible;
@property (nonatomic) BOOL cursorModeBeforeShowing;
@property (nonatomic, weak) BrowserTabOverviewViewController *presentedOverviewViewController;

- (NSInteger)numberOfDisplayItems;
- (NSInteger)activeTabDisplayItemIndex;
- (nullable BrowserTabViewModel *)tabForDisplayItemIndex:(NSInteger)displayItemIndex;
- (void)handleSelectionForDisplayItemIndex:(NSInteger)displayItemIndex;
- (void)handleCloseRequestForDisplayItemIndex:(NSInteger)displayItemIndex;
- (void)handleAlternateAction;
- (void)reloadPresentedOverviewIfNeeded;
- (void)overviewViewControllerDidDisappear:(BrowserTabOverviewViewController *)viewController;

@end

#pragma mark - Tab strip (Safari-style row under the address bar)

static CGFloat const kTabStripTop = 148.0;          // just below the top bar (60 + 68 + gap)
static CGFloat const kTabStripSideInset = 80.0;      // same as the top bar
static CGFloat const kTabStripMaxWidth = 1760.0;
static CGFloat const kTabStripHeight = 92.0;         // room for the focus zoom
static CGFloat const kTabPillWidth = 330.0;
static CGFloat const kTabPillHeight = 64.0;
static CGFloat const kTabPillSpacing = 18.0;
static CGFloat const kTabPreviewWidth = 584.0;       // the size of the old tab card picture
static CGFloat const kTabPreviewImageHeight = 329.0; // 16:9
static CGFloat const kTabPreviewHeight = 329.0 + 118.0;

static UIColor *BrowserTabAccentColor(void) {
    return [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0];
}

/// A stable colour per site for the little round badge in front of the tab name.
static UIColor *BrowserTabBadgeColor(NSString *key) {
    NSArray<UIColor *> *palette = @[
        [UIColor colorWithRed:0.20 green:0.52 blue:0.98 alpha:1.0],
        [UIColor colorWithRed:0.96 green:0.36 blue:0.30 alpha:1.0],
        [UIColor colorWithRed:0.18 green:0.72 blue:0.46 alpha:1.0],
        [UIColor colorWithRed:0.98 green:0.62 blue:0.16 alpha:1.0],
        [UIColor colorWithRed:0.62 green:0.38 blue:0.94 alpha:1.0],
        [UIColor colorWithRed:0.10 green:0.70 blue:0.80 alpha:1.0],
    ];
    NSUInteger hash = 0;
    for (NSUInteger i = 0; i < key.length; i++) {
        hash = hash * 31 + [key characterAtIndex:i];
    }
    return palette[hash % palette.count];
}

static NSString *BrowserTabHost(BrowserTabViewModel *tab) {
    NSString *URLString = tab.URLString.length > 0 ? tab.URLString : tab.requestURL;
    NSString *host = [NSURL URLWithString:URLString ?: @""].host ?: @"";
    if ([host hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    return host;
}

/// Site logos, loaded once per address and kept in memory.
static NSCache<NSString *, UIImage *> *BrowserTabIconCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 120;
    });
    return cache;
}

static void BrowserTabLoadIcon(NSString *URLString, void (^completion)(UIImage *image)) {
    UIImage *cached = URLString.length > 0 ? [BrowserTabIconCache() objectForKey:URLString] : nil;
    if (cached != nil || URLString.length == 0) {
        completion(cached);
        return;
    }
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        completion(nil);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:8.0];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        UIImage *image = (error == nil && data.length > 0) ? [UIImage imageWithData:data] : nil;
        if (image != nil && image.size.width >= 8.0) {
            [BrowserTabIconCache() setObject:image forKey:URLString];
        } else {
            image = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(image);
        });
    }] resume];
}

/// Menu switch: colour each tab in the main colour of its site's logo (YouTube red, …).
static NSString * const kBrowserTabSiteColorsKey = @"BrowserTabSiteColors";

/// The main colour of a logo: the most common clearly coloured hue (black, white and grey are ignored).
static UIColor *BrowserTabBrandColor(UIImage *image, NSString *cacheKey) {
    static NSCache<NSString *, id> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    id cached = cacheKey.length > 0 ? [cache objectForKey:cacheKey] : nil;
    if (cached != nil) {
        return [cached isKindOfClass:[UIColor class]] ? cached : nil;
    }
    CGImageRef cgImage = image.CGImage;
    if (cgImage == NULL) {
        return nil;
    }
    const size_t side = 32;
    uint8_t pixels[32 * 32 * 4];
    memset(pixels, 0, sizeof(pixels));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (context == NULL) {
        return nil;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), cgImage);
    CGContextRelease(context);

    double weight[12] = {0}, sumR[12] = {0}, sumG[12] = {0}, sumB[12] = {0};
    for (size_t i = 0; i < side * side; i++) {
        double a = pixels[i * 4 + 3] / 255.0;
        if (a < 0.5) {
            continue;
        }
        double r = pixels[i * 4] / 255.0 / a, g = pixels[i * 4 + 1] / 255.0 / a, b = pixels[i * 4 + 2] / 255.0 / a;
        CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 0;
        [[UIColor colorWithRed:MIN(r, 1.0) green:MIN(g, 1.0) blue:MIN(b, 1.0) alpha:1.0] getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
        if (saturation < 0.35 || brightness < 0.25) {
            continue;
        }
        int bin = MIN(11, (int)(hue * 12.0));
        double w = saturation * brightness;
        weight[bin] += w; sumR[bin] += r * w; sumG[bin] += g * w; sumB[bin] += b * w;
    }
    int best = -1;
    double total = 0;
    for (int bin = 0; bin < 12; bin++) {
        total += weight[bin];
        if (best < 0 || weight[bin] > weight[best]) {
            best = bin;
        }
    }
    UIColor *color = nil;
    // At least a bit of the logo must be coloured, else it is a black/white logo.
    if (best >= 0 && weight[best] > 6.0) {
        color = [UIColor colorWithRed:sumR[best] / weight[best] green:sumG[best] / weight[best] blue:sumB[best] / weight[best] alpha:1.0];
    }
    if (cacheKey.length > 0) {
        [cache setObject:(color ?: (id)[NSNull null]) forKey:cacheKey];
    }
    return color;
}

static BOOL BrowserTabColorIsLight(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return (0.299 * r + 0.587 * g + 0.114 * b) > 0.72;
}

@interface BrowserTabStripCell : UICollectionViewCell
- (void)configureWithTab:(BrowserTabViewModel *)tab activeTab:(BOOL)activeTab;
@end

@interface BrowserTabStripCell ()
@property (nonatomic) UIView *pillView;
@property (nonatomic) UILabel *badgeLabel;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UIImageView *iconView;
@property (nonatomic, copy) NSString *iconURLString;
@property (nonatomic) UIColor *siteColor;
@property (nonatomic) BOOL activeTab;
@property (nonatomic) BOOL addItem;
@end

@implementation BrowserTabStripCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

        _pillView = [[UIView alloc] initWithFrame:CGRectMake(0.0, (CGRectGetHeight(frame) - kTabPillHeight) / 2.0, kTabPillWidth, kTabPillHeight)];
        _pillView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _pillView.layer.cornerRadius = kTabPillHeight / 2.0;
        _pillView.layer.borderWidth = 0.0;
        [self.contentView addSubview:_pillView];

        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 12.0, 40.0, 40.0)];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
        _badgeLabel.textColor = UIColor.whiteColor;
        _badgeLabel.layer.cornerRadius = 20.0;
        _badgeLabel.layer.masksToBounds = YES;
        [_pillView addSubview:_badgeLabel];

        // The site's logo sits on a small white rounded square, so dark logos stay visible on the dark pill.
        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(12.0, 12.0, 40.0, 40.0)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.backgroundColor = UIColor.whiteColor;
        _iconView.layer.cornerRadius = 10.0;
        _iconView.layer.masksToBounds = YES;
        _iconView.hidden = YES;
        [_pillView addSubview:_iconView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(64.0, 0.0, kTabPillWidth - 84.0, kTabPillHeight)];
        _titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightMedium];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [_pillView addSubview:_titleLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.transform = CGAffineTransformIdentity;
    self.iconView.image = nil;
    self.iconView.hidden = YES;
    self.iconURLString = nil;
    self.siteColor = nil;
}

- (void)showIconFromURLString:(NSString *)URLString {
    self.iconURLString = URLString;
    self.iconView.hidden = YES;
    self.badgeLabel.hidden = NO;
    if (URLString.length == 0) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    BrowserTabLoadIcon(URLString, ^(UIImage *image) {
        // The cell may show another tab by now.
        if (image == nil || ![weakSelf.iconURLString isEqualToString:URLString]) {
            return;
        }
        weakSelf.iconView.image = image;
        weakSelf.iconView.hidden = NO;
        weakSelf.badgeLabel.hidden = YES;
        BOOL colorsOn = [[NSUserDefaults standardUserDefaults] boolForKey:kBrowserTabSiteColorsKey];
        if (colorsOn) {
            weakSelf.siteColor = BrowserTabBrandColor(image, URLString);
            [weakSelf updateAppearance];
        }
    });
}

- (void)configureWithTab:(BrowserTabViewModel *)tab activeTab:(BOOL)activeTab {
    self.addItem = (tab == nil);
    self.siteColor = nil;
    [self showIconFromURLString:(tab != nil ? tab.iconURLString : @"")];
    self.activeTab = activeTab;
    if (self.addItem) {
        self.badgeLabel.text = @"+";
        self.badgeLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
        self.titleLabel.text = BrowserLocalized(@"New Tab");
    } else {
        NSString *host = BrowserTabHost(tab);
        NSString *title = BrowserTabDisplayTitle(tab, host);
        NSString *letterSource = host.length > 0 ? host : title;
        self.badgeLabel.text = letterSource.length > 0 ? [[letterSource substringToIndex:1] uppercaseString] : @"•";
        self.badgeLabel.backgroundColor = BrowserTabBadgeColor(host.length > 0 ? host : title);
        self.titleLabel.text = title;
    }
    [self updateAppearance];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    [coordinator addCoordinatedAnimations:^{
        [self updateAppearance];
    } completion:nil];
}

- (void)updateAppearance {
    BOOL focused = self.isFocused;
    UIColor *siteColor = self.siteColor;
    if (siteColor != nil) {
        // Site colours: the pill is the logo's colour; focus makes it fully opaque, with a white ring.
        BOOL light = BrowserTabColorIsLight(siteColor);
        self.pillView.backgroundColor = [siteColor colorWithAlphaComponent:focused ? 1.0 : 0.78];
        self.titleLabel.textColor = light ? [UIColor colorWithWhite:0.08 alpha:1.0] : UIColor.whiteColor;
        self.pillView.layer.borderColor = UIColor.whiteColor.CGColor;
        self.pillView.layer.borderWidth = focused ? 3.0 : (self.activeTab ? 2.0 : 0.0);
    } else {
        self.pillView.backgroundColor = focused ? UIColor.whiteColor : [UIColor colorWithWhite:0.12 alpha:0.86];
        self.titleLabel.textColor = focused ? [UIColor colorWithWhite:0.08 alpha:1.0] : UIColor.whiteColor;
        self.pillView.layer.borderColor = BrowserTabAccentColor().CGColor;
        self.pillView.layer.borderWidth = (self.activeTab && !focused) ? 3.0 : 0.0;
    }
    self.layer.shadowColor = (siteColor ?: UIColor.blackColor).CGColor;
    self.layer.shadowOffset = CGSizeMake(0.0, 8.0);
    self.layer.shadowOpacity = focused ? 0.45 : 0.0;
    self.layer.shadowRadius = 14.0;
    self.transform = focused ? CGAffineTransformMakeScale(1.08, 1.08) : CGAffineTransformIdentity;
}

@end

/// The big picture of the focused tab, hanging below its pill.
@interface BrowserTabPreviewView : UIView
@property (nonatomic) UIImageView *imageView;
@property (nonatomic) UIImageView *plusView;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *urlLabel;
@property (nonatomic) UILabel *hintLabel;
@property (nonatomic) UIImageView *iconView;
@property (nonatomic, copy) NSString *iconURLString;
- (void)configureWithTab:(BrowserTabViewModel *)tab activeTab:(BOOL)activeTab;
@end

@implementation BrowserTabPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOffset = CGSizeMake(0.0, 18.0);
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 30.0;

        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        glass.frame = self.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerRadius = 30.0;
        glass.layer.masksToBounds = YES;
        BrowserApplyGlassAmount(glass, [UIColor colorWithWhite:0.13 alpha:1.0]);
        [self addSubview:glass];

        _imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0.0, 0.0, kTabPreviewWidth, kTabPreviewImageHeight)];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        _imageView.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
        [glass.contentView addSubview:_imageView];

        UIImageSymbolConfiguration *plusConfig = [UIImageSymbolConfiguration configurationWithPointSize:80.0 weight:UIImageSymbolWeightMedium];
        _plusView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus" withConfiguration:plusConfig]];
        _plusView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _plusView.frame = CGRectMake((kTabPreviewWidth - 120.0) / 2.0, (kTabPreviewImageHeight - 120.0) / 2.0, 120.0, 120.0);
        _plusView.contentMode = UIViewContentModeScaleAspectFit;
        [glass.contentView addSubview:_plusView];

        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(30.0, kTabPreviewImageHeight + 18.0, 36.0, 36.0)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.backgroundColor = UIColor.whiteColor;
        _iconView.layer.cornerRadius = 9.0;
        _iconView.layer.masksToBounds = YES;
        _iconView.hidden = YES;
        [glass.contentView addSubview:_iconView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(30.0, kTabPreviewImageHeight + 18.0, kTabPreviewWidth - 60.0, 36.0)];
        _titleLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        [glass.contentView addSubview:_titleLabel];

        _urlLabel = [[UILabel alloc] initWithFrame:CGRectMake(30.0, kTabPreviewImageHeight + 56.0, kTabPreviewWidth - 60.0, 28.0)];
        _urlLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightRegular];
        _urlLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.58];
        _urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [glass.contentView addSubview:_urlLabel];

        _hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(30.0, kTabPreviewImageHeight + 86.0, kTabPreviewWidth - 60.0, 24.0)];
        _hintLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightRegular];
        _hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
        [glass.contentView addSubview:_hintLabel];
    }
    return self;
}

- (void)layoutTitleWithIcon:(BOOL)hasIcon {
    self.iconView.hidden = !hasIcon;
    CGFloat x = hasIcon ? 30.0 + 36.0 + 14.0 : 30.0;
    self.titleLabel.frame = CGRectMake(x, kTabPreviewImageHeight + 18.0, kTabPreviewWidth - x - 30.0, 36.0);
}

- (void)configureWithTab:(BrowserTabViewModel *)tab activeTab:(BOOL)activeTab {
    NSString *iconURL = tab != nil ? tab.iconURLString : @"";
    self.iconURLString = iconURL;
    [self layoutTitleWithIcon:NO];
    if (iconURL.length > 0) {
        __weak typeof(self) weakSelf = self;
        BrowserTabLoadIcon(iconURL, ^(UIImage *image) {
            if (image == nil || ![weakSelf.iconURLString isEqualToString:iconURL]) {
                return;
            }
            weakSelf.iconView.image = image;
            [weakSelf layoutTitleWithIcon:YES];
        });
    }
    if (tab == nil) {
        self.imageView.image = nil;
        self.plusView.hidden = NO;
        self.titleLabel.text = BrowserLocalized(@"New Tab");
        self.urlLabel.text = BrowserLocalized(@"Opens the home page");
        self.hintLabel.text = BrowserLocalized(@"Click: open");
        return;
    }
    self.plusView.hidden = YES;
    self.imageView.image = tab.snapshotImage;
    NSString *host = BrowserTabHost(tab);
    self.titleLabel.text = BrowserTabDisplayTitle(tab, host);
    self.urlLabel.text = tab.URLString.length > 0 ? tab.URLString : BrowserLocalized(@"Home Page");
    self.hintLabel.text = activeTab ? BrowserLocalized(@"Current tab  ·  Play/Pause: close") : BrowserLocalized(@"Click: switch  ·  Play/Pause: close");
}

@end

@interface BrowserTabOverviewViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>

- (instancetype)initWithOverviewController:(BrowserTabOverviewController *)overviewController;
- (void)reload;
- (void)updateCardAtTabIndex:(NSInteger)tabIndex;
- (void)handleAlternateAction;

@end

@interface BrowserTabOverviewViewController ()

@property (nonatomic, weak) BrowserTabOverviewController *overviewController;
@property (nonatomic) UIView *dimView;
@property (nonatomic) UICollectionView *collectionView;
@property (nonatomic) BrowserTabPreviewView *previewView;
@property (nonatomic) NSInteger preferredFocusItemIndex;
@property (nonatomic) NSInteger previewItemIndex;

@end

@implementation BrowserTabOverviewViewController

- (instancetype)initWithOverviewController:(BrowserTabOverviewController *)overviewController {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _overviewController = overviewController;
        _preferredFocusItemIndex = NSNotFound;
        _previewItemIndex = NSNotFound;
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (CGFloat)stripWidth {
    return MIN(CGRectGetWidth(self.view.bounds) - (kTabStripSideInset * 2.0), kTabStripMaxWidth);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // Frosted glass over the page below the bar (Liquid Glass look), so the strip and the picture stand out;
    // the bar itself stays sharp.
    UIVisualEffectView *dimView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular]];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    dimView.userInteractionEnabled = NO;
    dimView.alpha = 0.85; // lighter frost: the page stays recognisable behind the tabs
    UIView *tint = [[UIView alloc] initWithFrame:dimView.contentView.bounds];
    tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tint.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.06];
    [dimView.contentView addSubview:tint];
    BrowserApplyGlassAmount(dimView, [UIColor colorWithWhite:0.06 alpha:0.94]);
    [self.view addSubview:dimView];
    self.dimView = dimView;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumLineSpacing = kTabPillSpacing;
    layout.minimumInteritemSpacing = kTabPillSpacing;
    layout.sectionInset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
    layout.itemSize = CGSizeMake(kTabPillWidth, kTabStripHeight);

    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    collectionView.backgroundColor = UIColor.clearColor;
    collectionView.clipsToBounds = NO;
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.showsVerticalScrollIndicator = NO;
    collectionView.remembersLastFocusedIndexPath = YES;
    collectionView.dataSource = self;
    collectionView.delegate = self;
    [collectionView registerClass:[BrowserTabStripCell class] forCellWithReuseIdentifier:@"TabPill"];
    [self.view addSubview:collectionView];
    self.collectionView = collectionView;

    BrowserTabPreviewView *previewView = [[BrowserTabPreviewView alloc] initWithFrame:CGRectMake(0.0, 0.0, kTabPreviewWidth, kTabPreviewHeight)];
    previewView.alpha = 0.0;
    [self.view addSubview:previewView];
    self.previewView = previewView;

    [NSLayoutConstraint activateConstraints:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kTabStripTop - 8.0],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [collectionView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [collectionView.widthAnchor constraintEqualToConstant:[self stripWidth]],
        [collectionView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kTabStripTop],
        [collectionView.heightAnchor constraintEqualToConstant:kTabStripHeight],
    ]];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.overviewController overviewViewControllerDidDisappear:self];
}

/// Puts the big picture under the pill of the given item (and fills it in).
- (void)showPreviewForItemIndex:(NSInteger)itemIndex animated:(BOOL)animated {
    if (itemIndex == NSNotFound || itemIndex >= [self.overviewController numberOfDisplayItems]) {
        self.previewView.alpha = 0.0;
        return;
    }
    BrowserTabViewModel *tab = [self.overviewController tabForDisplayItemIndex:itemIndex];
    BOOL activeTab = tab != nil && itemIndex == [self.overviewController activeTabDisplayItemIndex];
    [self.previewView configureWithTab:tab activeTab:activeTab];

    [self.collectionView layoutIfNeeded];
    UICollectionViewLayoutAttributes *attributes = [self.collectionView layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:itemIndex inSection:0]];
    CGRect pill = attributes != nil ? [self.collectionView convertRect:attributes.frame toView:self.view] : CGRectZero;
    CGFloat minX = (CGRectGetWidth(self.view.bounds) - [self stripWidth]) / 2.0;
    CGFloat maxX = minX + [self stripWidth] - kTabPreviewWidth;
    CGFloat x = MIN(MAX(CGRectGetMidX(pill) - kTabPreviewWidth / 2.0, minX), maxX);
    CGRect target = CGRectMake(x, kTabStripTop + kTabStripHeight + 16.0, kTabPreviewWidth, kTabPreviewHeight);

    BOOL wasHidden = self.previewView.alpha < 0.01;
    void (^changes)(void) = ^{
        self.previewView.frame = target;
        self.previewView.alpha = 1.0;
        self.previewView.transform = CGAffineTransformIdentity;
    };
    if (wasHidden) {
        self.previewView.frame = target;
        self.previewView.transform = CGAffineTransformMakeScale(0.92, 0.92);
    }
    if (animated) {
        [UIView animateWithDuration:0.22 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:changes completion:nil];
    } else {
        changes();
    }
    self.previewItemIndex = itemIndex;
}

- (void)reload {
    NSInteger itemCount = [self.overviewController numberOfDisplayItems];
    if (self.preferredFocusItemIndex == NSNotFound) {
        self.preferredFocusItemIndex = [self currentFocusedItemIndex];
    }
    if (self.preferredFocusItemIndex == NSNotFound) {
        self.preferredFocusItemIndex = [self.overviewController activeTabDisplayItemIndex];
    }
    if (itemCount > 0) {
        self.preferredFocusItemIndex = MIN(MAX(self.preferredFocusItemIndex, 0), itemCount - 1);
    }
    [self.collectionView reloadData];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsFocusUpdate];
        [self updateFocusIfNeeded];
        NSInteger focused = [self currentFocusedItemIndex];
        [self showPreviewForItemIndex:(focused != NSNotFound ? focused : self.preferredFocusItemIndex) animated:YES];
    });
}

- (void)updateCardAtTabIndex:(NSInteger)tabIndex {
    NSInteger itemIndex = tabIndex;
    if (itemIndex < 0 || itemIndex >= self.overviewController.viewModel.tabs.count) {
        [self reload];
        return;
    }
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:itemIndex inSection:0];
    if ([[self.collectionView indexPathsForVisibleItems] containsObject:indexPath]) {
        [self.collectionView reloadItemsAtIndexPaths:@[indexPath]];
    } else {
        [self.collectionView reloadData];
    }
    if (self.previewItemIndex == itemIndex) {
        [self showPreviewForItemIndex:itemIndex animated:NO];
    }
}

- (void)handleAlternateAction {
    NSInteger focusedItemIndex = [self currentFocusedItemIndex];
    if (focusedItemIndex == NSNotFound || focusedItemIndex >= self.overviewController.viewModel.tabs.count) {
        return;
    }
    self.preferredFocusItemIndex = focusedItemIndex;
    [self.overviewController handleCloseRequestForDisplayItemIndex:focusedItemIndex];
}

- (NSInteger)currentFocusedItemIndex {
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
        if (cell.isFocused) {
            return indexPath.item;
        }
    }
    return NSNotFound;
}

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return section == 0 ? [self.overviewController numberOfDisplayItems] : 0;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BrowserTabStripCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"TabPill" forIndexPath:indexPath];
    BrowserTabViewModel *tab = [self.overviewController tabForDisplayItemIndex:indexPath.item];
    BOOL activeTab = tab != nil && indexPath.item == [self.overviewController activeTabDisplayItemIndex];
    [cell configureWithTab:tab activeTab:activeTab];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didUpdateFocusInContext:(UICollectionViewFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    (void)collectionView;
    (void)coordinator;
    NSIndexPath *next = context.nextFocusedIndexPath;
    if (next != nil) {
        // After the scroll that brings the pill into view, so the picture lines up with it.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showPreviewForItemIndex:next.item animated:YES];
        });
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.collectionView && self.previewItemIndex != NSNotFound && self.previewView.alpha > 0.0) {
        [self showPreviewForItemIndex:self.previewItemIndex animated:NO];
    }
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    [self.overviewController handleSelectionForDisplayItemIndex:indexPath.item];
}

- (NSIndexPath *)indexPathForPreferredFocusedViewInCollectionView:(UICollectionView *)collectionView {
    NSInteger itemCount = [self.overviewController numberOfDisplayItems];
    if (itemCount == 0) {
        return nil;
    }
    NSInteger preferredItemIndex = self.preferredFocusItemIndex;
    if (preferredItemIndex == NSNotFound) {
        preferredItemIndex = [self.overviewController activeTabDisplayItemIndex];
    }
    preferredItemIndex = MIN(MAX(preferredItemIndex, 0), itemCount - 1);
    return [NSIndexPath indexPathForItem:preferredItemIndex inSection:0];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.collectionView];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        [self.overviewController dismiss];
        return;
    }
    if (press != nil && press.type == UIPressTypePlayPause) {
        [self handleAlternateAction];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@implementation BrowserTabOverviewController

- (instancetype)initWithHost:(id<BrowserTabOverviewControllerHost>)host
                   viewModel:(BrowserViewModel *)viewModel
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView {
    (void)rootView;
    (void)topMenuView;
    (void)cursorView;
    self = [super init];
    if (self) {
        _host = host;
        _viewModel = viewModel;
    }
    return self;
}

- (NSInteger)numberOfDisplayItems {
    return self.viewModel.tabs.count + 1;
}

- (NSInteger)activeTabDisplayItemIndex {
    return self.viewModel.activeTabIndex == NSNotFound ? 0 : self.viewModel.activeTabIndex;
}

- (BrowserTabViewModel *)tabForDisplayItemIndex:(NSInteger)displayItemIndex {
    if (displayItemIndex < 0 || displayItemIndex >= self.viewModel.tabs.count) {
        return nil;
    }
    return self.viewModel.tabs[displayItemIndex];
}

- (void)show {
    if (self.visible) {
        [self reload];
        return;
    }

    self.cursorModeBeforeShowing = [self.host browserTabOverviewControllerCursorModeEnabled];
    self.visible = YES;
    [self.host browserTabOverviewControllerSetCursorModeEnabled:NO];

    BrowserTabOverviewViewController *viewController = [[BrowserTabOverviewViewController alloc] initWithOverviewController:self];
    self.presentedOverviewViewController = viewController;
    [self.host browserTabOverviewControllerPresentViewController:viewController];
}

- (void)dismiss {
    if (!self.visible) {
        return;
    }

    BrowserTabOverviewViewController *viewController = self.presentedOverviewViewController;
    if (viewController == nil) {
        [self overviewViewControllerDidDisappear:nil];
        return;
    }
    [viewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)reload {
    [self reloadPresentedOverviewIfNeeded];
}

- (void)updateCardAtIndex:(NSInteger)tabIndex {
    [self.presentedOverviewViewController updateCardAtTabIndex:tabIndex];
}

- (BOOL)containsPoint:(CGPoint)viewPoint {
    (void)viewPoint;
    return NO;
}

- (BOOL)handleSelectionAtPoint:(CGPoint)viewPoint {
    (void)viewPoint;
    return NO;
}

- (void)handleSelectionForDisplayItemIndex:(NSInteger)displayItemIndex {
    if (displayItemIndex >= self.viewModel.tabs.count) {
        BrowserTabOverviewViewController *viewController = self.presentedOverviewViewController;
        if (viewController == nil) {
            [self.host browserTabOverviewControllerCreateNewTabLoadingHomePage:YES];
            return;
        }

        [viewController dismissViewControllerAnimated:YES completion:^{
            [self.host browserTabOverviewControllerCreateNewTabLoadingHomePage:YES];
        }];
        return;
    }

    [self.host browserTabOverviewControllerSwitchToTabAtIndex:displayItemIndex];
    [self dismiss];
}

- (void)handleCloseRequestForDisplayItemIndex:(NSInteger)displayItemIndex {
    NSInteger tabIndex = displayItemIndex;
    if (tabIndex < 0 || tabIndex >= self.viewModel.tabs.count || self.viewModel.tabs.count <= 1) {
        return;
    }

    [self.host browserTabOverviewControllerCloseTabAtIndex:tabIndex];
    [self reloadPresentedOverviewIfNeeded];
}

- (void)handleAlternateAction {
    [self.presentedOverviewViewController handleAlternateAction];
}

- (void)reloadPresentedOverviewIfNeeded {
    [self.presentedOverviewViewController reload];
}

- (void)overviewViewControllerDidDisappear:(BrowserTabOverviewViewController *)viewController {
    if (viewController != nil && viewController != self.presentedOverviewViewController) {
        return;
    }

    self.presentedOverviewViewController = nil;
    if (!self.visible) {
        return;
    }

    self.visible = NO;
    [self.host browserTabOverviewControllerSetCursorModeEnabled:self.cursorModeBeforeShowing];
}

@end
