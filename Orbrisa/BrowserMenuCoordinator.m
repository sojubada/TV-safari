#import "BrowserMenuCoordinator.h"
#import "BrowserLocalization.h"
#import "BrowserLog.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"
#import "BrowserTopBarView.h"

static UIColor *MenuTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

static NSString * const kBrowserMediaDiagnosticsLogPrefix = @"[MediaDiagnostics]";
static NSString * const kBrowserWebKitMediaPrefsLogPrefix = @"[WebKitMediaPrefs]";

typedef void (^BrowserAdvancedMenuItemHandler)(void);

@interface BrowserAdvancedMenuItem : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic) UIAlertActionStyle style;
@property (nonatomic, copy) BrowserAdvancedMenuItemHandler handler;
/// Set for on/off settings: the row shows a switch and stays in the menu when clicked.
@property (nonatomic, copy) BOOL (^toggleValue)(void);
@property (nonatomic, copy) void (^toggleChanged)(BOOL on);
/// Optional: the row only shows while this returns YES (e.g. the glass intensity only with Liquid Glass on).
@property (nonatomic, copy) BOOL (^visible)(void);
/// Optional: a value shown on the right (e.g. "Automatic"); with `stayOpen` the click changes it in place.
@property (nonatomic, copy) NSString *(^detailValue)(void);
@property (nonatomic) BOOL stayOpen;

+ (instancetype)itemWithTitle:(NSString *)title
                        style:(UIAlertActionStyle)style
                      handler:(BrowserAdvancedMenuItemHandler)handler;

@end

@implementation BrowserAdvancedMenuItem

+ (instancetype)itemWithTitle:(NSString *)title
                        style:(UIAlertActionStyle)style
                      handler:(BrowserAdvancedMenuItemHandler)handler {
    BrowserAdvancedMenuItem *item = [BrowserAdvancedMenuItem new];
    item.title = title ?: @"";
    item.style = style;
    item.handler = handler;
    return item;
}

@end

/// An Apple-style switch (tvOS has no UISwitch): green in light mode, blue in dark mode.
@interface BrowserMenuToggleView : UIView
@property (nonatomic, getter=isOn) BOOL on;
@property (nonatomic) BOOL rowFocused;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end

@interface BrowserMenuToggleView ()
@property (nonatomic) UIView *knobView;
@end

@implementation BrowserMenuToggleView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, 80.0, 46.0)];
    if (self) {
        self.userInteractionEnabled = NO;
        self.layer.cornerRadius = 23.0;
        _knobView = [[UIView alloc] initWithFrame:CGRectMake(4.0, 4.0, 38.0, 38.0)];
        _knobView.backgroundColor = UIColor.whiteColor;
        _knobView.layer.cornerRadius = 19.0;
        _knobView.layer.shadowColor = UIColor.blackColor.CGColor;
        _knobView.layer.shadowOpacity = 0.25;
        _knobView.layer.shadowRadius = 3.0;
        _knobView.layer.shadowOffset = CGSizeMake(0.0, 2.0);
        [self addSubview:_knobView];
        [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withTarget:self action:@selector(update)];
        [self update];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(80.0, 46.0);
}

- (UIColor *)onColor {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    return dark ? UIColor.systemBlueColor : UIColor.systemGreenColor;
}

- (void)update {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    UIColor *offColor = (self.rowFocused || !dark) ? [UIColor colorWithWhite:0.0 alpha:0.16] : [UIColor colorWithWhite:1.0 alpha:0.28];
    self.backgroundColor = self.on ? [self onColor] : offColor;
    self.knobView.frame = CGRectMake(self.on ? 80.0 - 4.0 - 38.0 : 4.0, 4.0, 38.0, 38.0);
}

- (void)setOn:(BOOL)on {
    [self setOn:on animated:NO];
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    _on = on;
    if (animated) {
        [UIView animateWithDuration:0.22 delay:0.0 usingSpringWithDamping:0.8 initialSpringVelocity:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState animations:^{ [self update]; } completion:nil];
    } else {
        [self update];
    }
}

- (void)setRowFocused:(BOOL)rowFocused {
    _rowFocused = rowFocused;
    [self update];
}


@end

@interface BrowserAdvancedMenuSection : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuItem *> *items;

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserAdvancedMenuItem *> *)items;

@end

@implementation BrowserAdvancedMenuSection

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserAdvancedMenuItem *> *)items {
    BrowserAdvancedMenuSection *section = [BrowserAdvancedMenuSection new];
    section.title = title ?: @"";
    section.items = [items copy] ?: @[];
    return section;
}

@end

@interface BrowserAdvancedMenuViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

- (instancetype)initWithTitle:(NSString *)title
                     sections:(NSArray<BrowserAdvancedMenuSection *> *)sections
                   footerText:(NSString *)footerText;

@end

@interface BrowserAdvancedMenuViewController ()

@property (nonatomic, copy) NSString *menuTitle;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuSection *> *sections;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic) UIView *dimView;
@property (nonatomic) UIVisualEffectView *panelView;
@property (nonatomic) UITableView *tableView;
@property (nonatomic) NSLayoutConstraint *panelTrailingConstraint;
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) BOOL didAnimateIn;
@property (nonatomic) BOOL dismissalInProgress;
@property (nonatomic) BOOL usingNativeGlassEffect;
@property (nonatomic, copy) void (^visibilityChanged)(BOOL shown);

@end

@implementation BrowserAdvancedMenuViewController

- (UIVisualEffect *)panelEffect {
    Class glassEffectClass = NSClassFromString(@"UIGlassEffect");
    if (glassEffectClass != Nil) {
        id effect = [[glassEffectClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) {
            return (UIVisualEffect *)effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
}

- (instancetype)initWithTitle:(NSString *)title
                     sections:(NSArray<BrowserAdvancedMenuSection *> *)sections
                   footerText:(NSString *)footerText {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _menuTitle = [title copy] ?: @"Menu";
        _sections = [sections copy] ?: @[];
        _footerText = [footerText copy] ?: @"";
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (UIColor *)solidPanelColor {
    return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:0.12 alpha:1.0]
                                                                                : [UIColor colorWithWhite:0.95 alpha:1.0];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // Centered under the top bar, like the tvOS Settings app (prototype 3).
    self.panelWidth = MIN(1080.0, CGRectGetWidth(UIScreen.mainScreen.bounds) - 160.0);
    self.usingNativeGlassEffect = (NSClassFromString(@"UIGlassEffect") != Nil);

    UIView *dimView = [UIView new];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    dimView.alpha = 0.0;
    [self.view addSubview:dimView];
    self.dimView = dimView;

    UIVisualEffectView *panelView = [[UIVisualEffectView alloc] initWithEffect:[self panelEffect]];
    panelView.translatesAutoresizingMaskIntoConstraints = NO;
    panelView.backgroundColor = UIColor.clearColor;
    panelView.layer.cornerRadius = 40.0;
    panelView.alpha = 0.0;
    panelView.transform = CGAffineTransformMakeScale(0.96, 0.96);
    panelView.layer.masksToBounds = YES;
    panelView.layer.borderWidth = self.usingNativeGlassEffect ? 0.0 : 1.0;
    panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    [self.view addSubview:panelView];
    self.panelView = panelView;
    BrowserApplyGlassAmount(panelView, [self solidPanelColor]);

    UIView *panelTint = nil;
    if (!self.usingNativeGlassEffect) {
        panelTint = [UIView new];
        panelTint.translatesAutoresizingMaskIntoConstraints = NO;
        panelTint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        [panelView.contentView addSubview:panelTint];
    }

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = self.menuTitle;
    titleLabel.font = [UIFont boldSystemFontOfSize:34.0];
    titleLabel.textAlignment = NSTextAlignmentLeft;
    if (@available(tvOS 13.0, *)) {
        titleLabel.textColor = UIColor.labelColor;
    } else {
        titleLabel.textColor = UIColor.whiteColor;
    }
    titleLabel.hidden = YES; // the address bar shows "Einstellungen" instead
    [panelView.contentView addSubview:titleLabel];

    UIView *separator = [UIView new];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(tvOS 13.0, *)) {
        separator.backgroundColor = UIColor.separatorColor;
    } else {
        separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    }
    separator.hidden = YES;
    [panelView.contentView addSubview:separator];

    UILabel *footerLabel = [UILabel new];
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    footerLabel.text = self.footerText;
    footerLabel.textAlignment = NSTextAlignmentCenter;
    footerLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightRegular];
    if (@available(tvOS 13.0, *)) {
        footerLabel.textColor = UIColor.secondaryLabelColor;
    } else {
        footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    }
    [panelView.contentView addSubview:footerLabel];

    UIImage *studioTextImage = [[UIImage imageNamed:@"DiMarcoStudioText"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImage *studioDotImage = [UIImage imageNamed:@"DiMarcoStudioDot"];
    UIImageView *studioLogoView = [[UIImageView alloc] initWithImage:studioTextImage];
    studioLogoView.translatesAutoresizingMaskIntoConstraints = NO;
    studioLogoView.contentMode = UIViewContentModeScaleAspectFit;
    if (@available(tvOS 13.0, *)) {
        studioLogoView.tintColor = UIColor.labelColor;
    } else {
        studioLogoView.tintColor = UIColor.whiteColor;
    }
    studioLogoView.isAccessibilityElement = YES;
    studioLogoView.accessibilityLabel = @"di marco studio";
    [panelView.contentView addSubview:studioLogoView];
    UIImageView *studioDotView = [[UIImageView alloc] initWithImage:studioDotImage];
    studioDotView.translatesAutoresizingMaskIntoConstraints = NO;
    studioDotView.contentMode = UIViewContentModeScaleAspectFit;
    [studioLogoView addSubview:studioDotView];
    CGFloat studioLogoAspect = (studioTextImage.size.height > 0.0) ? (studioTextImage.size.width / studioTextImage.size.height) : 8.42;

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.rowHeight = 84.0;
    if (@available(tvOS 15.0, *)) {
        tableView.sectionHeaderTopPadding = 0.0;
    }
    tableView.backgroundColor = UIColor.clearColor;
    tableView.preservesSuperviewLayoutMargins = NO;
    tableView.layoutMargins = UIEdgeInsetsZero;
    if (@available(tvOS 11.0, *)) {
        tableView.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
        tableView.insetsLayoutMarginsFromSafeArea = NO;
    }
    tableView.cellLayoutMarginsFollowReadableWidth = NO;
    tableView.clipsToBounds = NO;
    tableView.layer.cornerRadius = 0.0;
    tableView.remembersLastFocusedIndexPath = YES;
    tableView.contentInset = UIEdgeInsetsZero;
    tableView.showsVerticalScrollIndicator = NO;
    if (@available(tvOS 11.0, *)) {
        tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        tableView.insetsContentViewsToSafeArea = NO;
    }
    [panelView.contentView addSubview:tableView];
    self.tableView = tableView;

    self.panelTrailingConstraint = [panelView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.widthAnchor constraintEqualToConstant:self.panelWidth],
        [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:148.0], // below the top bar
        [panelView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-52.0],
        self.panelTrailingConstraint,

        [titleLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:32.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-32.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panelView.topAnchor constant:26.0],

        [separator.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:20.0],
        [separator.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-20.0],
        [separator.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:20.0],
        [separator.heightAnchor constraintEqualToConstant:1.0],

        [tableView.topAnchor constraintEqualToAnchor:panelView.topAnchor constant:18.0],
        [tableView.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:34.0],
        [tableView.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-34.0],
        [tableView.bottomAnchor constraintEqualToAnchor:footerLabel.topAnchor constant:-8.0],

        [footerLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:24.0],
        [footerLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-24.0],
        [footerLabel.bottomAnchor constraintEqualToAnchor:studioLogoView.topAnchor constant:-10.0],

        [studioLogoView.centerXAnchor constraintEqualToAnchor:panelView.centerXAnchor],
        [studioLogoView.bottomAnchor constraintEqualToAnchor:panelView.bottomAnchor constant:-22.0],
        [studioLogoView.heightAnchor constraintEqualToConstant:26.0],
        [studioLogoView.widthAnchor constraintEqualToAnchor:studioLogoView.heightAnchor multiplier:studioLogoAspect],
        [studioDotView.leadingAnchor constraintEqualToAnchor:studioLogoView.leadingAnchor],
        [studioDotView.trailingAnchor constraintEqualToAnchor:studioLogoView.trailingAnchor],
        [studioDotView.topAnchor constraintEqualToAnchor:studioLogoView.topAnchor],
        [studioDotView.bottomAnchor constraintEqualToAnchor:studioLogoView.bottomAnchor],
    ]];
    if (panelTint != nil) {
        [constraints addObject:[panelTint.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor]];
        [constraints addObject:[panelTint.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor]];
        [constraints addObject:[panelTint.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor]];
        [constraints addObject:[panelTint.bottomAnchor constraintEqualToAnchor:panelView.contentView.bottomAnchor]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.didAnimateIn && self.visibilityChanged != nil) {
        self.visibilityChanged(YES);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didAnimateIn) {
        return;
    }
    self.didAnimateIn = YES;
    [UIView animateWithDuration:0.28
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.dimView.alpha = 1.0;
        self.panelView.alpha = 1.0;
        self.panelView.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (!self.isBeingDismissed) {
        return;
    }
    if (self.visibilityChanged != nil) {
        self.visibilityChanged(NO);
    }
    if (self.dismissalInProgress) {
        return;
    }

    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (coordinator != nil) {
        [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            self.dimView.alpha = 0.0;
            self.panelView.alpha = 0.0;
            self.panelView.transform = CGAffineTransformMakeScale(0.96, 0.96);
        } completion:nil];
        return;
    }

    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.dimView.alpha = 0.0;
        self.panelView.alpha = 0.0;
        self.panelView.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:nil];
}

- (void)dismissMenuWithCompletion:(void (^)(void))completion {
    if (self.dismissalInProgress) {
        return;
    }
    self.dismissalInProgress = YES;
    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.dimView.alpha = 0.0;
        self.panelView.alpha = 0.0;
        self.panelView.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:completion];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

/// The rows of a section that are shown right now.
- (NSArray<BrowserAdvancedMenuItem *> *)visibleItemsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return @[];
    }
    NSMutableArray<BrowserAdvancedMenuItem *> *items = [NSMutableArray array];
    for (BrowserAdvancedMenuItem *item in self.sections[(NSUInteger)section].items) {
        if (item.visible == nil || item.visible()) {
            [items addObject:item];
        }
    }
    return items;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return 0;
    }
    return (NSInteger)[self visibleItemsInSection:section].count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return nil;
    }
    return self.sections[(NSUInteger)section].title;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (title.length == 0) {
        return [UIView new];
    }
    UIView *header = [UIView new];
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title.uppercaseString;
    label.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];
    BOOL dark = tableView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    label.textColor = dark ? [UIColor colorWithWhite:1.0 alpha:0.5] : [UIColor colorWithWhite:0.0 alpha:0.5];
    [header addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:28.0],
        [label.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-28.0],
        [label.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6.0],
    ]];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (title.length == 0) {
        return 12.0;
    }
    return section == 0 ? 44.0 : 62.0;
}

- (UIView *)tableView:(__unused UITableView *)tableView viewForFooterInSection:(__unused NSInteger)section {
    return [UIView new];
}

- (CGFloat)tableView:(__unused UITableView *)tableView heightForFooterInSection:(__unused NSInteger)section {
    return 0.01;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const kCellIdentifier = @"BrowserAdvancedMenuCell";
    static NSInteger const kMenuTitleLabelTag = 9191;
    static NSInteger const kMenuFocusBackgroundTag = 9292;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kCellIdentifier];
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.clipsToBounds = NO;
        cell.contentView.clipsToBounds = NO;
        cell.preservesSuperviewLayoutMargins = NO;
        cell.layoutMargins = UIEdgeInsetsZero;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([cell respondsToSelector:@selector(setFocusStyle:)]) {
            [cell setValue:@(1) forKey:@"focusStyle"]; // UITableViewCellFocusStyleCustom
        }

        UIView *focusBackgroundView = [UIView new];
        focusBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
        focusBackgroundView.tag = kMenuFocusBackgroundTag;
        // Like the tvOS Settings app: every row is a capsule – translucent at rest, solid white when focused.
        focusBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        focusBackgroundView.layer.cornerRadius = 38.0;
        focusBackgroundView.layer.shadowColor = UIColor.blackColor.CGColor;
        focusBackgroundView.layer.shadowOpacity = 0.3;
        focusBackgroundView.layer.shadowRadius = 14.0;
        focusBackgroundView.layer.shadowOffset = CGSizeMake(0.0, 6.0);
        focusBackgroundView.layer.shadowOpacity = 0.0;
        [cell.contentView addSubview:focusBackgroundView];

        UIImageView *chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
                                                                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24.0 weight:UIImageSymbolWeightSemibold]]];
        chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        chevronView.tag = 9393;
        chevronView.contentMode = UIViewContentModeScaleAspectFit;
        [cell.contentView addSubview:chevronView];

        UILabel *detailLabel = [UILabel new];
        detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        detailLabel.tag = 9595;
        detailLabel.font = [UIFont systemFontOfSize:27.0 weight:UIFontWeightRegular];
        detailLabel.textAlignment = NSTextAlignmentRight;
        [cell.contentView addSubview:detailLabel];

        BrowserMenuToggleView *toggleView = [BrowserMenuToggleView new];
        toggleView.translatesAutoresizingMaskIntoConstraints = NO;
        toggleView.tag = 9494;
        [cell.contentView addSubview:toggleView];

        UILabel *titleLabel = [UILabel new];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.tag = kMenuTitleLabelTag;
        titleLabel.font = [UIFont systemFontOfSize:31.0 weight:UIFontWeightRegular];
        titleLabel.textAlignment = NSTextAlignmentLeft;
        titleLabel.numberOfLines = 1;
        [cell.contentView addSubview:titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [focusBackgroundView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:0.0],
            [focusBackgroundView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:0.0],
            [focusBackgroundView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4.0],
            [focusBackgroundView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4.0],

            [titleLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:28.0],
            [titleLabel.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-16.0],
            [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],

            [chevronView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-26.0],
            [chevronView.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [chevronView.widthAnchor constraintEqualToConstant:18.0],

            [detailLabel.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-14.0],
            [detailLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],

            [toggleView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-20.0],
            [toggleView.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [toggleView.widthAnchor constraintEqualToConstant:80.0],
            [toggleView.heightAnchor constraintEqualToConstant:46.0],
        ]];
    }

    BrowserAdvancedMenuItem *item = [self visibleItemsInSection:indexPath.section][(NSUInteger)indexPath.row];
    UILabel *titleLabel = (UILabel *)[cell.contentView viewWithTag:kMenuTitleLabelTag];
    UIView *focusBackgroundView = [cell.contentView viewWithTag:kMenuFocusBackgroundTag];
    titleLabel.text = item.title;
    (void)focusBackgroundView;
    BrowserMenuToggleView *toggleView = (BrowserMenuToggleView *)[cell.contentView viewWithTag:9494];
    UIView *chevronView = [cell.contentView viewWithTag:9393];
    BOOL isToggle = item.toggleValue != nil;
    toggleView.hidden = !isToggle;
    chevronView.hidden = isToggle;
    if (isToggle) {
        [toggleView setOn:item.toggleValue() animated:NO];
    }
    UILabel *detailLabel = (UILabel *)[cell.contentView viewWithTag:9595];
    detailLabel.text = item.detailValue != nil ? item.detailValue() : nil;
    [self applyFocused:cell.isFocused toCell:cell item:item];
    return cell;
}

- (BrowserAdvancedMenuItem *)menuItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath == nil || (NSUInteger)indexPath.section >= self.sections.count) {
        return nil;
    }
    NSArray<BrowserAdvancedMenuItem *> *items = [self visibleItemsInSection:indexPath.section];
    if ((NSUInteger)indexPath.row >= items.count) {
        return nil;
    }
    return items[(NSUInteger)indexPath.row];
}

- (void)applyFocused:(BOOL)focused toCell:(UITableViewCell *)cell item:(BrowserAdvancedMenuItem *)item {
    if (cell == nil) {
        return;
    }
    UILabel *titleLabel = (UILabel *)[cell.contentView viewWithTag:9191];
    UIView *focusBackgroundView = [cell.contentView viewWithTag:9292];
    BOOL destructive = item.style == UIAlertActionStyleDestructive;

    UIColor *titleColor = nil;
    if (focused) {
        titleColor = destructive ? UIColor.systemRedColor : [UIColor colorWithWhite:0.11 alpha:1.0];
    } else if (destructive) {
        titleColor = UIColor.systemRedColor;
    } else {
        titleColor = UIColor.labelColor; // follows the Apple TV's light/dark appearance
    }

    // Rows follow the Apple TV's light/dark look, so the text stays readable on light glass too.
    BOOL dark = cell.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    UIColor *restingText = dark ? UIColor.whiteColor : [UIColor colorWithWhite:0.08 alpha:1.0];
    titleLabel.textColor = focused ? titleColor : (destructive ? UIColor.systemRedColor : restingText);
    titleLabel.font = [UIFont systemFontOfSize:29.0 weight:UIFontWeightMedium];
    focusBackgroundView.backgroundColor = focused ? UIColor.whiteColor
                                                  : (dark ? [UIColor colorWithWhite:1.0 alpha:0.14] : [UIColor colorWithWhite:0.0 alpha:0.07]);
    focusBackgroundView.layer.shadowOpacity = focused ? 0.3 : 0.0;
    UIImageView *chevronView = (UIImageView *)[cell.contentView viewWithTag:9393];
    chevronView.tintColor = focused ? [UIColor colorWithWhite:0.45 alpha:1.0]
                                    : (dark ? [UIColor colorWithWhite:1.0 alpha:0.45] : [UIColor colorWithWhite:0.0 alpha:0.35]);
    cell.contentView.transform = focused ? CGAffineTransformMakeScale(1.03, 1.03) : CGAffineTransformIdentity;
    ((BrowserMenuToggleView *)[cell.contentView viewWithTag:9494]).rowFocused = focused;
    ((UILabel *)[cell.contentView viewWithTag:9595]).textColor = focused ? [UIColor colorWithWhite:0.4 alpha:1.0]
                                                                         : (dark ? [UIColor colorWithWhite:1.0 alpha:0.55] : [UIColor colorWithWhite:0.0 alpha:0.45]);
    cell.layer.zPosition = focused ? 1.0 : 0.0;
}

- (void)tableView:(UITableView *)tableView
didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context
withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    NSIndexPath *previousIndexPath = context.previouslyFocusedIndexPath;
    NSIndexPath *nextIndexPath = context.nextFocusedIndexPath;

    UITableViewCell *previousCell = previousIndexPath ? [tableView cellForRowAtIndexPath:previousIndexPath] : nil;
    UITableViewCell *nextCell = nextIndexPath ? [tableView cellForRowAtIndexPath:nextIndexPath] : nil;

    BrowserAdvancedMenuItem *previousItem = [self menuItemAtIndexPath:previousIndexPath];
    BrowserAdvancedMenuItem *nextItem = [self menuItemAtIndexPath:nextIndexPath];
    [coordinator addCoordinatedAnimations:^{
        if (previousCell != nextCell) {
            [self applyFocused:NO toCell:previousCell item:previousItem];
        }
        [self applyFocused:YES toCell:nextCell item:nextItem];
    } completion:nil];
}

/// Rows that depend on a switch (like "Liquid Glass Intensity") slide in or out when it is flipped.
- (void)updateDependentRowsInSection:(NSInteger)section
                              before:(NSArray<BrowserAdvancedMenuItem *> *)before
                           tableView:(UITableView *)tableView {
    NSArray<BrowserAdvancedMenuItem *> *after = [self visibleItemsInSection:section];
    if ([before isEqualToArray:after]) {
        return;
    }
    NSMutableArray<NSIndexPath *> *deleted = [NSMutableArray array];
    NSMutableArray<NSIndexPath *> *inserted = [NSMutableArray array];
    [before enumerateObjectsUsingBlock:^(BrowserAdvancedMenuItem *item, NSUInteger index, __unused BOOL *stop) {
        if (![after containsObject:item]) {
            [deleted addObject:[NSIndexPath indexPathForRow:(NSInteger)index inSection:section]];
        }
    }];
    [after enumerateObjectsUsingBlock:^(BrowserAdvancedMenuItem *item, NSUInteger index, __unused BOOL *stop) {
        if (![before containsObject:item]) {
            [inserted addObject:[NSIndexPath indexPathForRow:(NSInteger)index inSection:section]];
        }
    }];
    [tableView performBatchUpdates:^{
        [tableView deleteRowsAtIndexPaths:deleted withRowAnimation:UITableViewRowAnimationFade];
        [tableView insertRowsAtIndexPaths:inserted withRowAnimation:UITableViewRowAnimationFade];
    } completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BrowserAdvancedMenuItem *item = [self visibleItemsInSection:indexPath.section][(NSUInteger)indexPath.row];
    if (item.toggleValue != nil) {
        NSArray<BrowserAdvancedMenuItem *> *visibleBefore = [self visibleItemsInSection:indexPath.section];
        // Switches flip in place; the menu stays open.
        BOOL on = !item.toggleValue();
        if (item.toggleChanged != nil) {
            item.toggleChanged(on);
        }
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        [(BrowserMenuToggleView *)[cell.contentView viewWithTag:9494] setOn:item.toggleValue() animated:YES];
        [self updateDependentRowsInSection:indexPath.section before:visibleBefore tableView:tableView];
        return;
    }
    if (item.stayOpen) {
        if (item.handler != nil) {
            item.handler();
        }
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        ((UILabel *)[cell.contentView viewWithTag:9595]).text = item.detailValue != nil ? item.detailValue() : nil;
        return;
    }
    BrowserAdvancedMenuItemHandler handler = item.handler;
    [self dismissMenuWithCompletion:^{
        if (handler != nil) {
            handler();
        }
    }];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.tableView];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        [self dismissMenuWithCompletion:nil];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@interface BrowserMenuCoordinator ()

@property (nonatomic, weak) id<BrowserMenuCoordinatorHost> host;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;

@end

#pragma mark - Liquid Glass slider (tvOS has no UISlider)

/// Focusable stand-in for a slider, so the remote's presses reach the view controller.
@interface BrowserGlassSliderTrackView : UIView
@end

@implementation BrowserGlassSliderTrackView
- (BOOL)canBecomeFocused {
    return YES;
}
@end

@interface BrowserGlassSliderViewController : UIViewController
@property (nonatomic) UIVisualEffectView *panelView;
@property (nonatomic) BrowserGlassSliderTrackView *trackView;
@property (nonatomic) UIView *trackFillView;
@property (nonatomic) UIView *knobView;
@property (nonatomic) UILabel *valueLabel;
@property (nonatomic) CGFloat panStartAmount;
// Optional: turn the slider into another setting (e.g. font size). Without these it controls Liquid Glass.
@property (nonatomic, copy) NSString *sliderTitle;
@property (nonatomic, copy) NSString *lowText;
@property (nonatomic, copy) NSString *highText;
@property (nonatomic, copy) NSString *lowSymbol;
@property (nonatomic, copy) NSString *highSymbol;
@property (nonatomic, copy) CGFloat (^getValue)(void);          // 0…1
@property (nonatomic, copy) void (^setValue)(CGFloat value);     // 0…1
@property (nonatomic, copy) NSString *(^valueText)(CGFloat value);
@property (nonatomic) CGFloat steps;      // rounding grid over the whole range
@property (nonatomic) CGFloat pressStep;  // change per left/right press
@end

@implementation BrowserGlassSliderViewController

static CGFloat const kGlassSliderTrackWidth = 680.0;

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark; // white text needs dark glass, also in light mode
        _steps = 20.0;
        _pressStep = 0.1;
    }
    return self;
}

- (CGFloat)currentValue {
    return self.getValue != nil ? self.getValue() : BrowserGlassAmount();
}

- (void)applyValue:(CGFloat)value {
    value = MIN(MAX(value, 0.0), 1.0);
    if (self.setValue != nil) {
        self.setValue(value);
        [self refresh];
    } else {
        BrowserSetGlassAmount(value);
    }
}

- (UIVisualEffect *)panelEffect {
    Class glassEffectClass = NSClassFromString(@"UIGlassEffect");
    if (glassEffectClass != Nil) {
        id effect = [[glassEffectClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) {
            return (UIVisualEffect *)effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight alpha:(CGFloat)alpha {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:alpha];
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];

    UIVisualEffectView *panelView = [[UIVisualEffectView alloc] initWithEffect:[self panelEffect]];
    panelView.translatesAutoresizingMaskIntoConstraints = NO;
    panelView.layer.cornerRadius = 44.0;
    panelView.layer.masksToBounds = YES;
    [self.view addSubview:panelView];
    self.panelView = panelView;
    // A dark veil inside the glass keeps the white text readable over bright pages.
    UIView *veil = [[UIView alloc] initWithFrame:panelView.contentView.bounds];
    veil.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    veil.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    veil.userInteractionEnabled = NO;
    [panelView.contentView addSubview:veil];

    UILabel *titleLabel = [self labelWithText:(self.sliderTitle ?: BrowserLocalized(@"Liquid Glass")) size:38.0 weight:UIFontWeightBold alpha:1.0];
    UILabel *valueLabel = [self labelWithText:@"" size:30.0 weight:UIFontWeightSemibold alpha:0.85];
    self.valueLabel = valueLabel;
    UILabel *offLabel = [self labelWithText:(self.lowText ?: BrowserLocalized(@"Off")) size:24.0 weight:UIFontWeightMedium alpha:0.6];
    UILabel *onLabel = [self labelWithText:(self.highText ?: BrowserLocalized(@"Liquid")) size:24.0 weight:UIFontWeightMedium alpha:0.6];
    UILabel *hintLabel = [self labelWithText:BrowserLocalized(@"Swipe or press left/right  ·  Click: done") size:22.0 weight:UIFontWeightRegular alpha:0.5];

    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *solidIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(self.lowSymbol ?: @"square.fill") withConfiguration:iconConfig]];
    UIImageView *glassIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(self.highSymbol ?: @"drop.fill") withConfiguration:iconConfig]];
    for (UIImageView *icon in @[solidIcon, glassIcon]) {
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.8];
        icon.contentMode = UIViewContentModeScaleAspectFit;
    }

    BrowserGlassSliderTrackView *trackView = [BrowserGlassSliderTrackView new];
    trackView.translatesAutoresizingMaskIntoConstraints = NO;
    trackView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    trackView.layer.cornerRadius = 9.0;
    self.trackView = trackView;

    UIView *fillView = [UIView new];
    fillView.backgroundColor = UIColor.whiteColor;
    fillView.layer.cornerRadius = 9.0;
    [trackView addSubview:fillView];
    self.trackFillView = fillView;

    UIView *knobView = [UIView new];
    knobView.backgroundColor = UIColor.whiteColor;
    knobView.layer.cornerRadius = 24.0;
    knobView.layer.shadowColor = UIColor.blackColor.CGColor;
    knobView.layer.shadowOpacity = 0.35;
    knobView.layer.shadowRadius = 10.0;
    knobView.layer.shadowOffset = CGSizeMake(0.0, 4.0);
    [trackView addSubview:knobView];
    self.knobView = knobView;

    for (UIView *subview in @[titleLabel, valueLabel, solidIcon, trackView, glassIcon, offLabel, onLabel, hintLabel]) {
        [panelView.contentView addSubview:subview];
    }

    [NSLayoutConstraint activateConstraints:@[
        [panelView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [panelView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [panelView.widthAnchor constraintEqualToConstant:kGlassSliderTrackWidth + 260.0],
        [panelView.heightAnchor constraintEqualToConstant:340.0],

        [titleLabel.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor constant:56.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor constant:44.0],
        [valueLabel.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor constant:-56.0],
        [valueLabel.firstBaselineAnchor constraintEqualToAnchor:titleLabel.firstBaselineAnchor],

        [trackView.centerXAnchor constraintEqualToAnchor:panelView.contentView.centerXAnchor],
        [trackView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:62.0],
        [trackView.widthAnchor constraintEqualToConstant:kGlassSliderTrackWidth],
        [trackView.heightAnchor constraintEqualToConstant:18.0],

        [solidIcon.trailingAnchor constraintEqualToAnchor:trackView.leadingAnchor constant:-30.0],
        [solidIcon.centerYAnchor constraintEqualToAnchor:trackView.centerYAnchor],
        [glassIcon.leadingAnchor constraintEqualToAnchor:trackView.trailingAnchor constant:30.0],
        [glassIcon.centerYAnchor constraintEqualToAnchor:trackView.centerYAnchor],

        [offLabel.leadingAnchor constraintEqualToAnchor:trackView.leadingAnchor],
        [offLabel.topAnchor constraintEqualToAnchor:trackView.bottomAnchor constant:26.0],
        [onLabel.trailingAnchor constraintEqualToAnchor:trackView.trailingAnchor],
        [onLabel.topAnchor constraintEqualToAnchor:trackView.bottomAnchor constant:26.0],

        [hintLabel.centerXAnchor constraintEqualToAnchor:panelView.contentView.centerXAnchor],
        [hintLabel.bottomAnchor constraintEqualToAnchor:panelView.contentView.bottomAnchor constant:-34.0],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.view addGestureRecognizer:pan];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:BrowserGlassAmountDidChangeNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return self.trackView != nil ? @[self.trackView] : @[];
}

- (void)refresh {
    CGFloat amount = MIN(MAX([self currentValue], 0.0), 1.0);
    CGFloat width = kGlassSliderTrackWidth; // fixed, so it is right before the first layout pass too
    self.trackFillView.frame = CGRectMake(0.0, 0.0, MAX(18.0, width * amount), 18.0);
    self.knobView.frame = CGRectMake(width * amount - 24.0, -15.0, 48.0, 48.0);
    NSInteger percent = (NSInteger)lround(amount * 100.0);
    if (self.valueText != nil) {
        self.valueLabel.text = self.valueText(amount);
    } else {
        self.valueLabel.text = percent == 0 ? BrowserLocalized(@"Off") : [NSString stringWithFormat:@"%ld %%", (long)percent];
    }
    BrowserApplyGlassAmount(self.panelView, [UIColor colorWithWhite:0.12 alpha:1.0]);
}

- (void)changeBy:(CGFloat)delta {
    CGFloat amount = round(([self currentValue] + delta) * self.steps) / self.steps;
    [UIView animateWithDuration:0.15 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        [self applyValue:amount];
    } completion:nil];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.panStartAmount = [self currentValue];
    }
    if (pan.state == UIGestureRecognizerStateChanged || pan.state == UIGestureRecognizerStateEnded) {
        CGFloat dx = [pan translationInView:self.view].x;
        CGFloat amount = round((self.panStartAmount + dx / 900.0) * self.steps) / self.steps;
        amount = MIN(MAX(amount, 0.0), 1.0);
        if (fabs(amount - [self currentValue]) > 0.001) {
            [self applyValue:amount];
        }
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press.type == UIPressTypeLeftArrow) {
        [self changeBy:-self.pressStep];
        return;
    }
    if (press.type == UIPressTypeRightArrow) {
        [self changeBy:self.pressStep];
        return;
    }
    if (press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
        return; // keep focus on the slider
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press.type == UIPressTypeSelect || press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow ||
        press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@implementation BrowserMenuCoordinator

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _host = host;
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
    }
    return self;
}

- (void)showAdvancedMenu {
    BrowserAdvancedMenuViewController *menuViewController = [[BrowserAdvancedMenuViewController alloc] initWithTitle:@"Orbrisa"
                                                                                                            sections:[self advancedMenuSections]
                                                                                                          footerText:[self advancedMenuFooterText]];
    __weak typeof(self) weakSelf = self;
    menuViewController.visibilityChanged = ^(BOOL shown) {
        [weakSelf.host browserSetSettingsTitleShown:shown];
    };
    [self.host browserPresentViewController:menuViewController];
}

- (UIAlertController *)browserAlertControllerWithTitle:(NSString *)title message:(NSString *)message {
    return [UIAlertController alertControllerWithTitle:title
                                               message:message
                                        preferredStyle:UIAlertControllerStyleAlert];
}

- (UIAlertAction *)browserActionWithTitle:(NSString *)title
                                    style:(UIAlertActionStyle)style
                                  handler:(void (^ __nullable)(UIAlertAction *action))handler {
    return [UIAlertAction actionWithTitle:title style:style handler:handler];
}

- (BrowserAdvancedMenuItem *)advancedMenuItemWithTitle:(NSString *)title
                                                  style:(UIAlertActionStyle)style
                                                handler:(BrowserAdvancedMenuItemHandler)handler {
    return [BrowserAdvancedMenuItem itemWithTitle:title style:style handler:handler];
}

- (BrowserAdvancedMenuItem *)toggleMenuItemWithTitle:(NSString *)title
                                               value:(BOOL (^)(void))value
                                             changed:(void (^)(BOOL on))changed {
    BrowserAdvancedMenuItem *item = [BrowserAdvancedMenuItem itemWithTitle:title style:UIAlertActionStyleDefault handler:nil];
    item.toggleValue = value;
    item.toggleChanged = changed;
    return item;
}

- (UIAlertAction *)browserCancelAction {
    return [self browserActionWithTitle:nil style:UIAlertActionStyleCancel handler:nil];
}

- (BOOL)stringHasVisibleContent:(NSString *)string {
    NSString *trimmedString = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmedString.length > 0;
}

- (NSString *)displayTitleForStoredTitle:(NSString *)storedTitle
                               URLString:(NSString *)URLString
                              includeURL:(BOOL)includeURL {
    NSString *displayTitle = [self stringHasVisibleContent:storedTitle] ? storedTitle : URLString;
    if (includeURL && [self stringHasVisibleContent:storedTitle] && [self stringHasVisibleContent:URLString]) {
        return [NSString stringWithFormat:@"%@ - %@", storedTitle, URLString];
    }
    return displayTitle ?: @"";
}

- (void)loadStoredURLString:(NSString *)URLString {
    if (![self stringHasVisibleContent:URLString]) {
        return;
    }
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    NSString *userAgent = self.preferencesStore.userAgent;
    if (userAgent.length > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
    [[self.host browserWebView] loadRequest:request];
}

- (void)saveFavoritesArray:(NSArray *)favorites {
    [[NSUserDefaults standardUserDefaults] setObject:favorites forKey:@"FAVORITES"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)presentDeleteFavoriteMenu {
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:BrowserLocalized(@"Delete a Favorite")
                                                                       message:BrowserLocalized(@"Select a Favorite to Delete")];
    __weak typeof(self) weakSelf = self;
    
    [favorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        if (![weakSelf stringHasVisibleContent:URLString]) {
            return;
        }
        
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:NO];
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            NSMutableArray *updatedFavorites = [favorites mutableCopy];
            [updatedFavorites removeObjectAtIndex:index];
            [weakSelf saveFavoritesArray:updatedFavorites];
        }]];
    }];
    
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentAddFavoritePrompt {
    NSString *pageTitle = [[self.host browserWebView] title];
    NSURLRequest *request = [[self.host browserWebView] request];
    NSString *currentURL = request.URL.absoluteString ?: @"";
    UIAlertController *alertController = [self browserAlertControllerWithTitle:BrowserLocalized(@"Name New Favorite")
                                                                       message:currentURL];
    __weak typeof(self) weakSelf = self;
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeDefault;
        textField.placeholder = BrowserLocalized(@"Name New Favorite");
        textField.text = pageTitle;
        textField.textColor = MenuTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];
    
    [alertController addAction:[self browserActionWithTitle:BrowserLocalized(@"Save")
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
        UITextField *titleTextField = alertController.textFields.firstObject;
        NSString *savedTitle = titleTextField.text;
        if (![weakSelf stringHasVisibleContent:savedTitle]) {
            savedTitle = currentURL;
        }
        
        NSArray *favoriteEntry = @[currentURL, savedTitle ?: @""];
        NSMutableArray *favorites = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"] mutableCopy];
        if (favorites == nil) {
            favorites = [NSMutableArray array];
        }
        [favorites addObject:favoriteEntry];
        [weakSelf saveFavoritesArray:favorites];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentFavoritesMenu {
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:BrowserLocalized(@"Favorites") message:@""];
    __weak typeof(self) weakSelf = self;
    
    [favorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:NO];
        if (![weakSelf stringHasVisibleContent:displayTitle]) {
            return;
        }
        
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }];
    
    if (favorites.count > 0) {
        [alertController addAction:[self browserActionWithTitle:BrowserLocalized(@"Delete a Favorite")
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentDeleteFavoriteMenu];
        }]];
    }
    
    [alertController addAction:[self browserActionWithTitle:BrowserLocalized(@"Add Current Page to Favorites")
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf presentAddFavoritePrompt];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentHistoryMenu {
    NSArray *historyEntries = [[NSUserDefaults standardUserDefaults] arrayForKey:@"HISTORY"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:BrowserLocalized(@"History") message:@""];
    __weak typeof(self) weakSelf = self;
    
    if (historyEntries.count > 0) {
        [alertController addAction:[self browserActionWithTitle:BrowserLocalized(@"Clear History")
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"HISTORY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];
    }
    
    [historyEntries enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:YES];
        if (![weakSelf stringHasVisibleContent:displayTitle]) {
            return;
        }
        
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }];
    
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)applyUserAgent:(NSString *)userAgent mobileMode:(BOOL)mobileMode {
    self.preferencesStore.userAgent = userAgent;
    self.preferencesStore.mobileModeEnabled = mobileMode;
    
    NSURLRequest *request = [[self.host browserWebView] request];
    if (request != nil && [self stringHasVisibleContent:request.URL.absoluteString]) {
        [self.host browserCaptureSnapshotForCurrentTab];
    }
    
    __weak typeof(self) weakSelf = self;
    [BrowserWebView resetWebsiteDataWithCompletion:^{
        [weakSelf.host browserRecreateActiveWebViewPreservingCurrentURL];
        [weakSelf.host browserBringCursorToFront];
    }];
}

- (void)setPageScalingEnabled:(BOOL)enabled {
    self.preferencesStore.scalePagesToFit = enabled;
    [[self.host browserWebView] setScalesPageToFit:enabled];
    if (enabled) {
        [[self.host browserWebView] setContentMode:UIViewContentModeScaleAspectFit];
    }
    [[self.host browserWebView] reload];
}

- (void)clearCacheAndReload {
    __weak typeof(self) weakSelf = self;
    [BrowserWebView clearCachedDataWithCompletion:^{
        weakSelf.host.browserPreviousURL = @"";
        [[weakSelf.host browserWebView] reload];
    }];
}

- (void)clearCookiesAndReload {
    __weak typeof(self) weakSelf = self;
    [BrowserWebView clearCookiesWithCompletion:^{
        weakSelf.host.browserPreviousURL = @"";
        [[weakSelf.host browserWebView] reload];
    }];
}

- (NSString *)mediaDiagnosticsJavaScript {
    return @"(function(){"
            "function canPlay(type){"
                "try {"
                    "var video=document.createElement('video');"
                    "if (!video || typeof video.canPlayType!=='function') { return 'n/a'; }"
                    "var value=video.canPlayType(type);"
                    "return value ? String(value) : '';"
                "} catch (error) { return 'error'; }"
            "}"
            "function mse(type){"
                "try {"
                    "if (typeof MediaSource==='undefined' || typeof MediaSource.isTypeSupported!=='function') { return 'n/a'; }"
                    "return MediaSource.isTypeSupported(type) ? 'yes' : 'no';"
                "} catch (error) { return 'error'; }"
            "}"
            "function probeGlobal(name){"
                "try {"
                    "var value=window[name];"
                    "if (typeof value==='undefined') { return 'undefined'; }"
                    "if (value === null) { return 'null'; }"
                    "return typeof value;"
                "} catch (error) { return 'error'; }"
            "}"
            "var video=document.querySelector('video');"
            "var result={"
                "href:(window.location && window.location.href) ? String(window.location.href) : '',"
                "title:(document && document.title) ? String(document.title) : '',"
                "userAgent:(navigator && navigator.userAgent) ? String(navigator.userAgent) : '',"
                "platform:(navigator && navigator.platform) ? String(navigator.platform) : '',"
                "mediaSource:(typeof MediaSource!=='undefined') ? 'yes' : 'no',"
                "managedMediaSource:(typeof ManagedMediaSource!=='undefined') ? 'yes' : 'no',"
                "mediaCapabilities:(typeof navigator.mediaCapabilities!=='undefined') ? 'yes' : 'no',"
                "videoElement:video ? 'yes' : 'no',"
                "videoSrc:video ? String(video.currentSrc||video.src||'') : '',"
                "globalMediaSource:probeGlobal('MediaSource'),"
                "globalManagedMediaSource:probeGlobal('ManagedMediaSource'),"
                "globalWebKitMediaSource:probeGlobal('WebKitMediaSource'),"
                "globalSourceBuffer:probeGlobal('SourceBuffer'),"
                "globalManagedSourceBuffer:probeGlobal('ManagedSourceBuffer'),"
                "globalWebKitSourceBuffer:probeGlobal('WebKitSourceBuffer'),"
                "hls:canPlay('application/vnd.apple.mpegurl'),"
                "mp4H264:canPlay('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"'),"
                "mp4Hevc:canPlay('video/mp4; codecs=\"hvc1.1.6.L93.B0, mp4a.40.2\"'),"
                "webmVp9:canPlay('video/webm; codecs=\"vp9\"'),"
                "mp4Av1:canPlay('video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"'),"
                "webmAv1:canPlay('video/webm; codecs=\"av01.0.05M.08\"'),"
                "mseMp4H264:mse('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"'),"
                "mseWebmVp9:mse('video/webm; codecs=\"vp9\"'),"
                "mseMp4Av1:mse('video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"'),"
                "mseWebmAv1:mse('video/webm; codecs=\"av01.0.05M.08\"')"
            "};"
            "return JSON.stringify(result);"
           "})()";
}

- (NSDictionary *)mediaDiagnosticsDictionary {
    NSString *resultString = [[self.host browserWebView] stringByEvaluatingJavaScriptFromString:[self mediaDiagnosticsJavaScript]];
    if (![self stringHasVisibleContent:resultString]) {
        return nil;
    }

    NSData *resultData = [resultString dataUsingEncoding:NSUTF8StringEncoding];
    if (resultData == nil) {
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:resultData options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return object;
}

- (NSString *)stringValueForDiagnosticsKey:(NSString *)key dictionary:(NSDictionary *)dictionary fallback:(NSString *)fallback {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSString class]] && [self stringHasVisibleContent:value]) {
        return value;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *stringValue = [value stringValue];
        if ([self stringHasVisibleContent:stringValue]) {
            return stringValue;
        }
    }
    return fallback;
}

- (void)presentMediaDiagnostics {
    NSDictionary *diagnostics = [self mediaDiagnosticsDictionary];
    if (diagnostics == nil) {
        UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Media Diagnostics"
                                                                           message:@"The page did not return diagnostics data."];
        [alertController addAction:[self browserCancelAction]];
        [self.host browserPresentViewController:alertController];
        return;
    }

    BOOL mobileModeEnabled = self.preferencesStore.mobileModeEnabled;
    NSString *message = [NSString stringWithFormat:
                         @"Mode: %@\n"
                          "URL: %@\n"
                          "UA: %@\n\n"
                          "MediaSource: %@\n"
                          "ManagedMediaSource: %@\n"
                          "MediaCapabilities: %@\n"
                          "Video Element: %@\n"
                          "Video Src: %@\n\n"
                          "Global MediaSource: %@\n"
                          "Global ManagedMediaSource: %@\n"
                          "Global WebKitMediaSource: %@\n"
                          "Global SourceBuffer: %@\n"
                          "Global ManagedSourceBuffer: %@\n"
                          "Global WebKitSourceBuffer: %@\n\n"
                          "canPlay HLS: %@\n"
                          "canPlay MP4 H.264: %@\n"
                          "canPlay MP4 HEVC: %@\n"
                          "canPlay WebM VP9: %@\n"
                          "canPlay MP4 AV1: %@\n"
                          "canPlay WebM AV1: %@\n\n"
                          "MSE MP4 H.264: %@\n"
                          "MSE WebM VP9: %@\n"
                          "MSE MP4 AV1: %@\n"
                          "MSE WebM AV1: %@",
                         mobileModeEnabled ? @"Mobile" : @"Desktop",
                         [self stringValueForDiagnosticsKey:@"href" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"userAgent" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"mediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"managedMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mediaCapabilities" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"videoElement" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"videoSrc" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"globalMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalManagedMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalWebKitMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalManagedSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalWebKitSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"hls" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4H264" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4Hevc" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"webmVp9" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4Av1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"webmAv1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseMp4H264" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseWebmVp9" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseMp4Av1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseWebmAv1" dictionary:diagnostics fallback:@"n/a"]];

    BrowserLog(@"%@ %@", kBrowserMediaDiagnosticsLogPrefix, message);

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Media Diagnostics"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentWebKitRuntimeMediaPreferences {
    NSString *report = [[self.host browserWebView] runtimeMediaPreferenceReport];
    if (![self stringHasVisibleContent:report]) {
        report = @"No runtime WebKit media preference information was returned.";
    }

    BrowserLog(@"%@ %@", kBrowserWebKitMediaPrefsLogPrefix, report);

    NSString *message = report;
    if (message.length > 1800) {
        message = [[message substringToIndex:1800] stringByAppendingString:@"\n\nFull report logged to console."];
    }

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"WebKit Media Prefs"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (BrowserAdvancedMenuItem *)topNavigationVisibilityMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self toggleMenuItemWithTitle:BrowserLocalized(@"Top Navigation Bar")
                                   value:^BOOL{ return weakSelf.host.browserTopMenuShowing; }
                                 changed:^(BOOL on) {
        if (on) {
            [weakSelf.host browserShowTopNav];
        } else {
            [weakSelf.host browserHideTopNav];
        }
    }];
}

- (BrowserAdvancedMenuItem *)homePageMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"Go To Home Page")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserLoadHomePage];
    }];
}

- (BrowserAdvancedMenuItem *)setCurrentPageAsHomePageMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"Set Current Page As Home Page")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        NSURLRequest *request = [[self.host browserWebView] request];
        if (request != nil && [self stringHasVisibleContent:request.URL.absoluteString]) {
            self.preferencesStore.homePageURLString = request.URL.absoluteString;
        }
    }];
}

- (BrowserAdvancedMenuItem *)readerMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"Open in Reader")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowReader];
    }];
}

- (BrowserAdvancedMenuItem *)feedsMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"Feeds")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowFeeds];
    }];
}

- (BrowserAdvancedMenuItem *)subscribeToFeedMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"Subscribe to Feed")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserSubscribeToPageFeed];
    }];
}

- (BrowserAdvancedMenuItem *)whatsNewMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"What's New")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowWhatsNew];
    }];
}

- (BrowserAdvancedMenuItem *)usageGuideMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"Usage Guide")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowHints];
    }];
}

- (BrowserAdvancedMenuItem *)showTabsMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"Show Tabs")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowTabOverview];
    }];
}

- (BrowserAdvancedMenuItem *)newTabMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"Open New Tab")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserCreateNewTabLoadingHomePage:YES];
    }];
}

- (BrowserAdvancedMenuItem *)favoritesMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"Favorites")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentFavoritesMenu];
    }];
}

- (BrowserAdvancedMenuItem *)historyMenuItem {
    return [self advancedMenuItemWithTitle:BrowserLocalized(@"History")
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentHistoryMenu];
    }];
}

- (BrowserAdvancedMenuItem *)userAgentModeMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self toggleMenuItemWithTitle:BrowserLocalized(@"Mobile Version of Websites")
                                   value:^BOOL{ return weakSelf.preferencesStore.mobileModeEnabled; }
                                 changed:^(BOOL on) {
        [weakSelf applyUserAgent:(on ? BrowserPreferencesStore.mobileUserAgent : BrowserPreferencesStore.desktopUserAgent) mobileMode:on];
    }];
}

- (BrowserAdvancedMenuItem *)pageScalingMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self toggleMenuItemWithTitle:BrowserLocalized(@"Scale Pages to Fit")
                                   value:^BOOL{ return [[weakSelf.host browserWebView] scalesPageToFit]; }
                                 changed:^(BOOL on) { [weakSelf setPageScalingEnabled:on]; }];
}

- (BrowserAdvancedMenuItem *)darkModeForWebsitesMenuItem {
    return [self toggleMenuItemWithTitle:BrowserLocalized(@"Dark Mode")
                                   value:^BOOL{ return BrowserWebView.forceDarkPages; }
                                 changed:^(BOOL on) { BrowserWebView.forceDarkPages = on; }];
}

/// Under "Dark Mode": Automatic (follows the Apple TV) → Light → Dark, changed with each click.
- (BrowserAdvancedMenuItem *)appearanceModeMenuItem {
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:BrowserLocalized(@"Appearance")
                                                              style:UIAlertActionStyleDefault
                                                            handler:^{
        BrowserWebView.appearanceMode = (BrowserWebView.appearanceMode + 1) % 3;
    }];
    item.stayOpen = YES;
    item.detailValue = ^NSString *{
        switch (BrowserWebView.appearanceMode) {
            case 1:
                return BrowserLocalized(@"Light");
            case 2:
                return BrowserLocalized(@"Dark");
            default:
                return BrowserLocalized(@"Automatic");
        }
    };
    item.visible = ^BOOL{ return BrowserWebView.forceDarkPages; };
    return item;
}

- (BrowserAdvancedMenuItem *)liquidGlassMenuItem {
    // On/off; turning it back on restores the last intensity from the slider.
    return [self toggleMenuItemWithTitle:BrowserLocalized(@"Liquid Glass")
                                   value:^BOOL{ return BrowserGlassAmount() > 0.001; }
                                 changed:^(BOOL on) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (on) {
            NSNumber *last = [defaults objectForKey:@"BrowserGlassAmountLast"];
            BrowserSetGlassAmount(last.doubleValue > 0.04 ? last.doubleValue : 1.0);
        } else {
            [defaults setDouble:BrowserGlassAmount() forKey:@"BrowserGlassAmountLast"];
            BrowserSetGlassAmount(0.0);
        }
    }];
}

static NSUInteger const kBrowserFontSizeMin = 50;
static NSUInteger const kBrowserFontSizeMax = 200;

- (BrowserAdvancedMenuItem *)fontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:BrowserLocalized(@"Font Size")
                                                              style:UIAlertActionStyleDefault
                                                            handler:^{
        BrowserGlassSliderViewController *slider = [BrowserGlassSliderViewController new];
        CGFloat range = (CGFloat)(kBrowserFontSizeMax - kBrowserFontSizeMin);
        slider.sliderTitle = BrowserLocalized(@"Font Size");
        slider.lowText = [NSString stringWithFormat:@"%lu %%", (unsigned long)kBrowserFontSizeMin];
        slider.highText = [NSString stringWithFormat:@"%lu %%", (unsigned long)kBrowserFontSizeMax];
        slider.lowSymbol = @"textformat.size.smaller";
        slider.highSymbol = @"textformat.size.larger";
        slider.steps = range / 5.0;        // 5 % steps
        slider.pressStep = 5.0 / range;    // one press = 5 %
        slider.getValue = ^CGFloat{
            NSUInteger size = MIN(MAX(weakSelf.host.browserTextFontSize, kBrowserFontSizeMin), kBrowserFontSizeMax);
            return (CGFloat)(size - kBrowserFontSizeMin) / range;
        };
        slider.setValue = ^(CGFloat value) {
            NSUInteger size = kBrowserFontSizeMin + (NSUInteger)lround(value * range / 5.0) * 5;
            if (size != weakSelf.host.browserTextFontSize) {
                weakSelf.host.browserTextFontSize = size;
                [weakSelf.host browserUpdateTextFontSize];
            }
        };
        slider.valueText = ^NSString *(CGFloat value) {
            NSUInteger size = kBrowserFontSizeMin + (NSUInteger)lround(value * range / 5.0) * 5;
            return size == 100 ? BrowserLocalized(@"100 % (Default)") : [NSString stringWithFormat:@"%lu %%", (unsigned long)size];
        };
        [weakSelf.host browserPresentViewController:slider];
    }];
    item.detailValue = ^NSString *{
        return [NSString stringWithFormat:@"%lu %%", (unsigned long)weakSelf.host.browserTextFontSize];
    };
    return item;
}

- (BrowserAdvancedMenuItem *)liquidGlassIntensityMenuItem {
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:BrowserLocalized(@"Liquid Glass Intensity")
                                                              style:UIAlertActionStyleDefault
                                                            handler:^{
        [self.host browserPresentViewController:[BrowserGlassSliderViewController new]];
    }];
    item.visible = ^BOOL{ return BrowserGlassAmount() > 0.001; };
    return item;
}

- (BrowserAdvancedMenuItem *)tabSiteColorsMenuItem {
    return [self toggleMenuItemWithTitle:BrowserLocalized(@"Tabs in Site Colors")
                                   value:^BOOL{ return [[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserTabSiteColors"]; }
                                 changed:^(BOOL on) { [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"BrowserTabSiteColors"]; }];
}

- (BrowserAdvancedMenuItem *)autoAcceptCookiesMenuItem {
    return [self toggleMenuItemWithTitle:BrowserLocalized(@"Accept Cookie Banners Automatically")
                                   value:^BOOL{ return BrowserWebView.autoAcceptCookies; }
                                 changed:^(BOOL on) { BrowserWebView.autoAcceptCookies = on; }];
}

- (BrowserAdvancedMenuItem *)fullscreenVideoPlaybackToggleMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self toggleMenuItemWithTitle:BrowserLocalized(@"Full Screen Player")
                                   value:^BOOL{ return weakSelf.host.browserFullscreenVideoPlaybackEnabled; }
                                 changed:^(BOOL on) { weakSelf.host.browserFullscreenVideoPlaybackEnabled = on; }];
}

- (NSArray<BrowserAdvancedMenuSection *> *)advancedMenuSections {
    BrowserAdvancedMenuItem *mediaDiagnosticsItem = [self advancedMenuItemWithTitle:@"Media Diagnostics"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        [self presentMediaDiagnostics];
    }];
    BrowserAdvancedMenuItem *webkitMediaPrefsItem = [self advancedMenuItemWithTitle:@"Inspect WebKit Media Prefs"
                                                                                style:UIAlertActionStyleDefault
                                                                              handler:^{
        [self presentWebKitRuntimeMediaPreferences];
    }];
    BrowserAdvancedMenuItem *clearCacheItem = [self advancedMenuItemWithTitle:BrowserLocalized(@"Clear Cache")
                                                                         style:UIAlertActionStyleDestructive
                                                                       handler:^{
        [self clearCacheAndReload];
    }];
    BrowserAdvancedMenuItem *clearCookiesItem = [self advancedMenuItemWithTitle:BrowserLocalized(@"Clear Cookies")
                                                                           style:UIAlertActionStyleDestructive
                                                                         handler:^{
        [self clearCookiesAndReload];
    }];

    NSMutableArray<BrowserAdvancedMenuSection *> *sections = [@[
        [BrowserAdvancedMenuSection sectionWithTitle:BrowserLocalized(@"Navigation")
                                               items:@[
            [self homePageMenuItem],
            [self setCurrentPageAsHomePageMenuItem],
            [self favoritesMenuItem],
            [self historyMenuItem],
            [self showTabsMenuItem],
            [self newTabMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:BrowserLocalized(@"Reader & Feeds")
                                               items:@[
            [self readerMenuItem],
            [self feedsMenuItem],
            [self subscribeToFeedMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:BrowserLocalized(@"Appearance")
                                               items:@[
            [self liquidGlassMenuItem],
            [self liquidGlassIntensityMenuItem],
            [self darkModeForWebsitesMenuItem],
            [self appearanceModeMenuItem],
            [self tabSiteColorsMenuItem],
            [self topNavigationVisibilityMenuItem],
            [self pageScalingMenuItem],
            [self fontSizeMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:BrowserLocalized(@"Video Playback")
                                               items:@[
            [self fullscreenVideoPlaybackToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:BrowserLocalized(@"Compatibility")
                                               items:@[
            [self userAgentModeMenuItem],
            [self autoAcceptCookiesMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:BrowserLocalized(@"Maintenance")
                                               items:@[
            clearCacheItem,
            clearCookiesItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:BrowserLocalized(@"Help")
                                               items:@[
            [self whatsNewMenuItem],
            [self usageGuideMenuItem],
        ]],
    ] mutableCopy];
#if DEBUG
    // Developer tools: only in Debug builds from Xcode, never in a release.
    [sections insertObject:[BrowserAdvancedMenuSection sectionWithTitle:@"Diagnostics"
                                                                   items:@[mediaDiagnosticsItem, webkitMediaPrefsItem]]
                   atIndex:sections.count - 2];
#else
    (void)mediaDiagnosticsItem;
    (void)webkitMediaPrefsItem;
#endif
    return sections;
}

- (NSString *)advancedMenuFooterText {
    NSDictionary *infoDictionary = NSBundle.mainBundle.infoDictionary;
    NSString *version = infoDictionary[@"CFBundleShortVersionString"];
    BOOL hasVersion = [self stringHasVisibleContent:version];

    if (hasVersion) {
        NSString *label = infoDictionary[@"OrbrisaReleaseLabel"];
        if ([self stringHasVisibleContent:label]) {
            version = [NSString stringWithFormat:@"%@ %@", version, label];
        }
        return [NSString stringWithFormat:BrowserLocalized(@"Version %@"), version];
    }
    return @"";
}

@end
