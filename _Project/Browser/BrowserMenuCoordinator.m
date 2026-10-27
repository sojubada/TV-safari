#import "BrowserMenuCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserContentBlockerController.h"
#import "BrowserWebView.h"
#import "BrowserFavoritesStore.h"

static UIColor *MenuTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

static NSString * const kBrowserWebKitMediaPrefsLogPrefix = @"[WebKitMediaPrefs]";

typedef void (^BrowserAdvancedMenuItemHandler)(void);

@interface BrowserAdvancedMenuItem : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic) UIAlertActionStyle style;
@property (nonatomic, copy) BrowserAdvancedMenuItemHandler handler;
// A setting changes in place and the menu stays up, so several can be
// changed without walking back to the icon in the bar for each one.
@property (nonatomic) BOOL keepsMenuOpen;

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

// Set to the screen x of the icon that opened the menu. The panel then drops
// down beneath that icon instead of sliding in from the right edge, so a menu
// reached from the bar reads as belonging to the icon that opened it.
@property (nonatomic) CGFloat anchorCenterX;

// Re-asked for after a setting changes, so row titles show the new state
// without the menu having to close.
@property (nonatomic, copy, nullable) NSArray<BrowserAdvancedMenuSection *> *(^sectionsProvider)(void);

@end

@interface BrowserAdvancedMenuViewController ()

@property (nonatomic, copy) NSString *menuTitle;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuSection *> *sections;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic) UIView *dimView;
@property (nonatomic) UIVisualEffectView *panelView;
@property (nonatomic) UITableView *tableView;
@property (nonatomic) NSLayoutConstraint *panelTrailingConstraint;
@property (nonatomic) NSLayoutConstraint *panelTopConstraint;
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) BOOL didAnimateIn;
@property (nonatomic) BOOL dismissalInProgress;
@property (nonatomic, nullable) NSIndexPath *focusIndexPathAfterReload;
@property (nonatomic) BOOL usingNativeGlassEffect;

@end

@implementation BrowserAdvancedMenuViewController

// Focus starts in the list, so a row is lit the moment the menu opens and
// the remote's direction pad moves between rows.
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    NSIndexPath *target = self.focusIndexPathAfterReload;
    if (target != nil) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:target];
        if (cell != nil) {
            return @[cell];
        }
    }
    if (self.tableView != nil) {
        return @[self.tableView];
    }
    return [super preferredFocusEnvironments];
}

- (BOOL)isAnchoredToBar {
    return self.anchorCenterX > 0.0;
}

- (CGFloat)anchoredPanelVisibleTopConstant {
    return 112.0;
}

// Sized from the rows it will show, clamped to what is left below the bar.
- (CGFloat)anchoredPanelHeight {
    CGFloat rowHeight = 68.0;
    CGFloat sectionHeaderHeight = 54.0;
    CGFloat chrome = 26.0 + 52.0 + 20.0 + 1.0 + 12.0 + 24.0;

    CGFloat content = 0.0;
    for (BrowserAdvancedMenuSection *section in self.sections) {
        if (section.title.length > 0) {
            content += sectionHeaderHeight;
        }
        content += rowHeight * (CGFloat)section.items.count;
    }

    CGFloat available = CGRectGetHeight(UIScreen.mainScreen.bounds)
        - [self anchoredPanelVisibleTopConstant] - 40.0;
    return MIN(MAX(content + chrome, 220.0), available);
}

- (CGFloat)anchoredPanelHiddenTopConstant {
    return -CGRectGetHeight(UIScreen.mainScreen.bounds);
}

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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    if ([self isAnchoredToBar]) {
        self.panelWidth = MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds) * 0.30, 460.0), 620.0);
    } else {
        self.panelWidth = MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds) * 0.38, 480.0), 700.0);
    }
    self.usingNativeGlassEffect = (NSClassFromString(@"UIGlassEffect") != Nil);

    UIView *dimView = [UIView new];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    dimView.backgroundColor = self.usingNativeGlassEffect ? UIColor.clearColor : [UIColor colorWithWhite:0.0 alpha:0.45];
    dimView.alpha = 0.0;
    [self.view addSubview:dimView];
    self.dimView = dimView;

    UIVisualEffectView *panelView = [[UIVisualEffectView alloc] initWithEffect:[self panelEffect]];
    panelView.translatesAutoresizingMaskIntoConstraints = NO;
    panelView.backgroundColor = UIColor.clearColor;
    panelView.layer.cornerRadius = 28.0;
    panelView.layer.masksToBounds = YES;
    panelView.layer.borderWidth = self.usingNativeGlassEffect ? 0.0 : 1.0;
    panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    [self.view addSubview:panelView];
    self.panelView = panelView;

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
    [panelView.contentView addSubview:titleLabel];

    UIView *separator = [UIView new];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(tvOS 13.0, *)) {
        separator.backgroundColor = UIColor.separatorColor;
    } else {
        separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    }
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

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.rowHeight = 68.0;
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

    self.panelTrailingConstraint = [panelView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                                                             constant:self.panelWidth + 32.0];
    self.panelTopConstraint = [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor
                                                                  constant:[self anchoredPanelHiddenTopConstant]];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.widthAnchor constraintEqualToConstant:self.panelWidth],

        [titleLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:32.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-32.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panelView.topAnchor constant:26.0],

        [separator.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:20.0],
        [separator.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-20.0],
        [separator.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:20.0],
        [separator.heightAnchor constraintEqualToConstant:1.0],

        [tableView.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:12.0],
        [tableView.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:16.0],
        [tableView.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-16.0],
        [tableView.bottomAnchor constraintEqualToAnchor:footerLabel.topAnchor constant:-8.0],

        [footerLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:24.0],
        [footerLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-24.0],
        [footerLabel.bottomAnchor constraintEqualToAnchor:panelView.bottomAnchor constant:-12.0],
    ]];
    if ([self isAnchoredToBar]) {
        // Clamped so a panel hung off an icon near either end stays on screen.
        CGFloat screenWidth = CGRectGetWidth(UIScreen.mainScreen.bounds);
        CGFloat halfWidth = self.panelWidth / 2.0;
        CGFloat margin = 40.0;
        CGFloat centerX = MIN(MAX(self.anchorCenterX, halfWidth + margin), screenWidth - halfWidth - margin);
        [constraints addObject:[panelView.centerXAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                                                      constant:centerX]];
        [constraints addObject:self.panelTopConstraint];
        NSLayoutConstraint *heightConstraint =
            [panelView.heightAnchor constraintEqualToConstant:[self anchoredPanelHeight]];
        heightConstraint.priority = UILayoutPriorityDefaultHigh;
        [constraints addObject:heightConstraint];
        [constraints addObject:[panelView.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor
                                                                               constant:-40.0]];
    } else {
        [constraints addObject:[panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16.0]];
        [constraints addObject:[panelView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16.0]];
        [constraints addObject:self.panelTrailingConstraint];
    }
    if (panelTint != nil) {
        [constraints addObject:[panelTint.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor]];
        [constraints addObject:[panelTint.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor]];
        [constraints addObject:[panelTint.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor]];
        [constraints addObject:[panelTint.bottomAnchor constraintEqualToAnchor:panelView.contentView.bottomAnchor]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didAnimateIn) {
        return;
    }
    self.didAnimateIn = YES;
    if ([self isAnchoredToBar]) {
        self.panelTopConstraint.constant = [self anchoredPanelVisibleTopConstant];
    } else {
        self.panelTrailingConstraint.constant = -16.0;
    }
    [UIView animateWithDuration:0.28
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.dimView.alpha = 1.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (!self.isBeingDismissed || self.dismissalInProgress) {
        return;
    }

    if ([self isAnchoredToBar]) {
        self.panelTopConstraint.constant = [self anchoredPanelHiddenTopConstant];
    } else {
        self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
    }
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (coordinator != nil) {
        [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            self.dimView.alpha = 0.0;
            [self.view layoutIfNeeded];
        } completion:nil];
        return;
    }

    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.dimView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)dismissMenuWithCompletion:(void (^)(void))completion {
    if (self.dismissalInProgress) {
        return;
    }
    self.dismissalInProgress = YES;
    if ([self isAnchoredToBar]) {
        self.panelTopConstraint.constant = [self anchoredPanelHiddenTopConstant];
    } else {
        self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
    }
    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.dimView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:completion];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return 0;
    }
    return (NSInteger)self.sections[(NSUInteger)section].items.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return nil;
    }
    return self.sections[(NSUInteger)section].title;
}

- (CGFloat)tableView:(__unused UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count ||
        self.sections[(NSUInteger)section].title.length == 0) {
        return 0.0;
    }
    return 54.0;
}

// The system header style is small, grey and uppercase, which disappears at
// three metres. These are the only labels that say what part of the menu you
// are in, so they are drawn bright and large instead.
- (UIView *)tableView:(__unused UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return nil;
    }
    NSString *title = self.sections[(NSUInteger)section].title;
    if (title.length == 0) {
        return nil;
    }

    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.backgroundColor = UIColor.clearColor;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    label.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBold];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:label];

    UIView *rule = [[UIView alloc] initWithFrame:CGRectZero];
    rule.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    rule.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:rule];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:28.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-28.0],
        [label.bottomAnchor constraintEqualToAnchor:rule.topAnchor constant:-8.0],
        [rule.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:28.0],
        [rule.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-28.0],
        [rule.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6.0],
        [rule.heightAnchor constraintEqualToConstant:2.0],
    ]];
    return header;
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
        focusBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.95];
        focusBackgroundView.layer.cornerRadius = 14.0;
        focusBackgroundView.alpha = 0.0;
        [cell.contentView addSubview:focusBackgroundView];

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
            [focusBackgroundView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:2.0],
            [focusBackgroundView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-2.0],

            [titleLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:24.0],
            [titleLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-24.0],
            [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    }

    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    UILabel *titleLabel = (UILabel *)[cell.contentView viewWithTag:kMenuTitleLabelTag];
    UIView *focusBackgroundView = [cell.contentView viewWithTag:kMenuFocusBackgroundTag];
    titleLabel.text = item.title;
    UIColor *titleColor = nil;
    if (item.style == UIAlertActionStyleDestructive) {
        titleColor = UIColor.redColor;
    } else if (@available(tvOS 13.0, *)) {
        titleColor = UIColor.labelColor;
    } else {
        titleColor = UIColor.whiteColor;
    }
    BOOL focused = cell.isFocused;
    if (focused && item.style != UIAlertActionStyleDestructive) {
        titleColor = [UIColor colorWithRed:0.07 green:0.09 blue:0.10 alpha:1.0];
    }
    titleLabel.textColor = titleColor;
    titleLabel.font = [UIFont systemFontOfSize:31.0
                                        weight:focused ? UIFontWeightSemibold : UIFontWeightRegular];
    focusBackgroundView.alpha = focused ? 1.0 : 0.0;
    return cell;
}

- (void)tableView:(UITableView *)tableView
didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context
withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    NSIndexPath *previousIndexPath = context.previouslyFocusedIndexPath;
    NSIndexPath *nextIndexPath = context.nextFocusedIndexPath;

    UITableViewCell *previousCell = previousIndexPath ? [tableView cellForRowAtIndexPath:previousIndexPath] : nil;
    UITableViewCell *nextCell = nextIndexPath ? [tableView cellForRowAtIndexPath:nextIndexPath] : nil;

    // The pill is solid now, so the label flips with it or the row becomes
    // white text on white.
    void (^applyFocus)(UITableViewCell *, BOOL) = ^(UITableViewCell *cell, BOOL isFocused) {
        if (cell == nil) {
            return;
        }
        [cell.contentView viewWithTag:9292].alpha = isFocused ? 1.0 : 0.0;

        UILabel *label = (UILabel *)[cell.contentView viewWithTag:9191];
        if (![label isKindOfClass:[UILabel class]]) {
            return;
        }
        label.font = [UIFont systemFontOfSize:31.0
                                       weight:isFocused ? UIFontWeightSemibold : UIFontWeightRegular];
        if ([label.textColor isEqual:UIColor.redColor]) {
            return;
        }
        if (isFocused) {
            label.textColor = [UIColor colorWithRed:0.07 green:0.09 blue:0.10 alpha:1.0];
        } else if (@available(tvOS 13.0, *)) {
            label.textColor = UIColor.labelColor;
        } else {
            label.textColor = UIColor.whiteColor;
        }
    };

    [coordinator addCoordinatedAnimations:^{
        applyFocus(previousCell, NO);
        applyFocus(nextCell, YES);
    } completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    BrowserAdvancedMenuItemHandler handler = item.handler;

    if (item.keepsMenuOpen && self.sectionsProvider != nil) {
        if (handler != nil) {
            handler();
        }
        NSArray<BrowserAdvancedMenuSection *> *refreshed = self.sectionsProvider();
        if (refreshed.count > 0) {
            self.sections = refreshed;
        }
        [self.tableView reloadData];
        self.focusIndexPathAfterReload = indexPath;
        [self setNeedsFocusUpdate];
        [self updateFocusIfNeeded];
        return;
    }

    [self dismissMenuWithCompletion:^{
        if (handler != nil) {
            handler();
        }
    }];
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
@property (nonatomic) BrowserFavoritesStore *favoritesStore;

@end

@implementation BrowserMenuCoordinator

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _host = host;
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
        _favoritesStore = [BrowserFavoritesStore new];
    }
    return self;
}

- (void)showAdvancedMenu {
    __weak typeof(self) weakSelf = self;
    BrowserAdvancedMenuViewController *menuViewController = [[BrowserAdvancedMenuViewController alloc] initWithTitle:@"tvOS Browser"
                                                                                                            sections:[self advancedMenuSections]
                                                                                                          footerText:[self advancedMenuFooterText]];
    menuViewController.sectionsProvider = ^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf advancedMenuSections] ?: @[];
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

- (BrowserAdvancedMenuItem *)markKeepsMenuOpen:(BrowserAdvancedMenuItem *)item {
    item.keepsMenuOpen = YES;
    return item;
}

- (BrowserAdvancedMenuItem *)settingMenuItemWithTitle:(NSString *)title
                                              handler:(BrowserAdvancedMenuItemHandler)handler {
    BrowserAdvancedMenuItem *item = [self advancedMenuItemWithTitle:title
                                                              style:UIAlertActionStyleDefault
                                                            handler:handler];
    item.keepsMenuOpen = YES;
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

- (void)presentDeleteFavoriteMenu {
    NSArray<NSArray<NSString *> *> *favorites = [self.favoritesStore favorites];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Delete a Favorite"
                                                                       message:@"Select a Favorite to Delete"];
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
            [weakSelf.favoritesStore removeFavoriteAtIndex:index];
        }]];
    }];
    
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentAddFavoritePrompt {
    NSString *pageTitle = [[self.host browserWebView] title];
    NSURLRequest *request = [[self.host browserWebView] request];
    NSString *currentURL = request.URL.absoluteString ?: @"";
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Name New Favorite"
                                                                       message:currentURL];
    __weak typeof(self) weakSelf = self;
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeDefault;
        textField.placeholder = @"Name New Favorite";
        textField.text = pageTitle;
        textField.textColor = MenuTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];
    
    [alertController addAction:[self browserActionWithTitle:@"Save"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
        UITextField *titleTextField = alertController.textFields.firstObject;
        NSString *savedTitle = titleTextField.text;
        if (![weakSelf stringHasVisibleContent:savedTitle]) {
            savedTitle = currentURL;
        }
        
        [weakSelf.favoritesStore addFavoriteWithURLString:currentURL title:savedTitle];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentFavoritesMenu {
    NSArray<NSArray<NSString *> *> *favorites = [self.favoritesStore favorites];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Favorites" message:@""];
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
        [alertController addAction:[self browserActionWithTitle:@"Delete a Favorite"
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentDeleteFavoriteMenu];
        }]];
    }
    
    [alertController addAction:[self browserActionWithTitle:@"Add Current Page to Favorites"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf presentAddFavoritePrompt];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentHistoryMenu {
    NSArray *historyEntries = [[NSUserDefaults standardUserDefaults] arrayForKey:@"HISTORY"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"History" message:@""];
    __weak typeof(self) weakSelf = self;
    
    if (historyEntries.count > 0) {
        [alertController addAction:[self browserActionWithTitle:@"Clear History"
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

- (BrowserAdvancedMenuItem *)contentBlockingToggleMenuItem {
    BOOL enabled = self.preferencesStore.contentBlockingEnabled;
    NSString *title = enabled ? @"Content Blocking: On" : @"Content Blocking: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.contentBlockingEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)forcedDarkModeToggleMenuItem {
    BOOL enabled = self.preferencesStore.forcedDarkModeEnabled;
    NSString *title = enabled ? @"Force Dark Mode: On" : @"Force Dark Mode: Off";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        weakSelf.preferencesStore.forcedDarkModeEnabled = !enabled;
        [weakSelf.host browserUpdateForcedDarkMode];
    }];
}

- (BrowserAdvancedMenuItem *)readerModeToggleMenuItem {
    BOOL isActive = [self.host browserIsReaderModeActive];
    NSString *title = isActive ? @"Exit Reader Mode" : @"Reader Mode";
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [weakSelf.host browserToggleReaderMode];
    }];
}

- (BrowserAdvancedMenuItem *)tapToClickToggleMenuItem {
    BOOL enabled = self.preferencesStore.tapToClickEnabled;
    NSString *title = enabled ? @"Tap to Click: On" : @"Tap to Click: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.tapToClickEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)openLinksInNewTabToggleMenuItem {
    BOOL enabled = self.preferencesStore.openLinksInNewTabOnClick;
    NSString *title = enabled ? @"Open Links in New Tab: On" : @"Open Links in New Tab: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.openLinksInNewTabOnClick = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)jsScrollFallbackToggleMenuItem {
    BOOL enabled = self.preferencesStore.jsScrollFallbackEnabled;
    NSString *title = enabled ? @"JS Scroll Fallback: On" : @"JS Scroll Fallback: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.jsScrollFallbackEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)dpadScrollToggleMenuItem {
    BOOL enabled = self.preferencesStore.dpadScrollEnabled;
    NSString *title = enabled ? @"D-Pad Page Scroll: On" : @"D-Pad Page Scroll: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.dpadScrollEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)edgeAutoScrollToggleMenuItem {
    BOOL enabled = self.preferencesStore.edgeAutoScrollEnabled;
    NSString *title = enabled ? @"Edge Auto-Scroll: On" : @"Edge Auto-Scroll: Off";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        self.preferencesStore.edgeAutoScrollEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)topNavigationVisibilityMenuItem {
    NSString *title = self.host.browserTopMenuShowing ? @"Hide Top Navigation bar" : @"Show Top Navigation bar";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        if (self.host.browserTopMenuShowing) {
            UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Hide Top Navigation bar?"
                                                                               message:@"You can still open the side menu by double-tapping the Play/Pause button."];
            [alertController addAction:[self browserActionWithTitle:@"Cancel"
                                                              style:UIAlertActionStyleCancel
                                                            handler:nil]];
            [alertController addAction:[self browserActionWithTitle:@"Hide Bar"
                                                              style:UIAlertActionStyleDestructive
                                                            handler:^(__unused UIAlertAction *action) {
                [self.host browserHideTopNav];
            }]];
            [self.host browserPresentViewController:alertController];
        } else {
            [self.host browserShowTopNav];
        }
    }];
}

- (BrowserAdvancedMenuItem *)homePageMenuItem {
    return [self advancedMenuItemWithTitle:@"Go To Home Page"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserLoadHomePage];
    }];
}

- (BrowserAdvancedMenuItem *)setCurrentPageAsHomePageMenuItem {
    return [self advancedMenuItemWithTitle:@"Set Current Page As Home Page"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        NSURLRequest *request = [[self.host browserWebView] request];
        if (request != nil && [self stringHasVisibleContent:request.URL.absoluteString]) {
            self.preferencesStore.homePageURLString = request.URL.absoluteString;
        }
    }];
}

- (BrowserAdvancedMenuItem *)usageGuideMenuItem {
    return [self advancedMenuItemWithTitle:@"Usage Guide"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowHints];
    }];
}

- (BrowserAdvancedMenuItem *)showTabsMenuItem {
    return [self advancedMenuItemWithTitle:@"Show Tabs"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowTabOverview];
    }];
}

- (BrowserAdvancedMenuItem *)newTabMenuItem {
    return [self advancedMenuItemWithTitle:@"Open New Tab"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserCreateNewTabLoadingHomePage:YES];
    }];
}

- (BrowserAdvancedMenuItem *)historyMenuItem {
    return [self advancedMenuItemWithTitle:@"History"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentHistoryMenu];
    }];
}

- (BrowserAdvancedMenuItem *)userAgentModeMenuItem {
    BOOL mobileModeEnabled = self.preferencesStore.mobileModeEnabled;
    NSString *title = mobileModeEnabled ? @"Switch To Desktop User Agent" : @"Switch To Mobile User Agent";
    NSString *userAgent = mobileModeEnabled ? BrowserPreferencesStore.desktopUserAgent : BrowserPreferencesStore.mobileUserAgent;
    BOOL mobileMode = !mobileModeEnabled;
    
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        [self applyUserAgent:userAgent mobileMode:mobileMode];
    }];
}

- (BrowserAdvancedMenuItem *)pageScalingMenuItem {
    BOOL scalesPageToFit = [[self.host browserWebView] scalesPageToFit];
    NSString *title = scalesPageToFit ? @"Stop Scaling Pages to Fit" : @"Scale Pages to Fit";
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        [self setPageScalingEnabled:!scalesPageToFit];
    }];
}

- (BrowserAdvancedMenuItem *)toggleFavoriteMenuItem {
    NSURLRequest *request = [[self.host browserWebView] request];
    NSString *currentURLString = request.URL.absoluteString;
    
    if (currentURLString.length == 0) {
        return nil;
    }
    
    BOOL isFavorite = [self.favoritesStore isFavoriteURLString:currentURLString];
    NSString *title = isFavorite ? @"Remove from Favorites" : @"Add to Favorites";
    
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        if (isFavorite) {
            [weakSelf.favoritesStore removeFavoriteWithURLString:currentURLString];
        } else {
            NSString *pageTitle = [[weakSelf.host browserWebView] title];
            [weakSelf.favoritesStore addFavoriteWithURLString:currentURLString title:pageTitle];
        }
    }];
}

- (BrowserAdvancedMenuItem *)increaseFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self markKeepsMenuOpen:[self advancedMenuItemWithTitle:@"Increase Font Size"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        weakSelf.host.browserTextFontSize += 5;
        [weakSelf.host browserUpdateTextFontSize];
    }]];
}

- (BrowserAdvancedMenuItem *)decreaseFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self markKeepsMenuOpen:[self advancedMenuItemWithTitle:@"Decrease Font Size"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        weakSelf.host.browserTextFontSize -= 5;
        [weakSelf.host browserUpdateTextFontSize];
    }]];
}

- (BrowserAdvancedMenuItem *)resetFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self markKeepsMenuOpen:[self advancedMenuItemWithTitle:@"Reset Font Size"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        weakSelf.host.browserTextFontSize = 100;
        [weakSelf.host browserUpdateTextFontSize];
    }]];
}

// The two icons beside the menu open a slice of it. Same items, same titles,
// reached in one click instead of scrolling the whole list from the sofa.
- (void)presentAnchoredMenuWithTitle:(NSString *)title
                            provider:(NSArray<BrowserAdvancedMenuSection *> *(^)(void))provider
                            anchorAt:(CGFloat)anchorCenterX {
    BrowserAdvancedMenuViewController *menuViewController =
        [[BrowserAdvancedMenuViewController alloc] initWithTitle:title
                                                        sections:provider()
                                                      footerText:@""];
    menuViewController.anchorCenterX = anchorCenterX;
    menuViewController.sectionsProvider = provider;
    [self.host browserPresentViewController:menuViewController];
}

// The star holds four things and nothing else: add or remove this page,
// delete one from the list, the folders, and the list itself.
- (NSArray<BrowserAdvancedMenuSection *> *)bookmarksMenuSections {
    NSMutableArray<BrowserAdvancedMenuItem *> *items = [NSMutableArray array];
    BrowserAdvancedMenuItem *toggleFavoriteItem = [self toggleFavoriteMenuItem];
    if (toggleFavoriteItem != nil) {
        [items addObject:toggleFavoriteItem];
    }
    [items addObject:[self deleteFavoriteMenuItem]];
    [items addObject:[self favoriteFoldersMenuItem]];

    NSMutableArray<BrowserAdvancedMenuSection *> *sections = [NSMutableArray array];
    [sections addObject:[BrowserAdvancedMenuSection sectionWithTitle:@"즐겨찾기" items:items]];

    // The list is what the star is for, so it is in the panel itself rather
    // than one row deeper behind a screen of its own.
    NSArray<BrowserAdvancedMenuItem *> *listItems = [self favoriteListMenuItemsInFolder:nil];
    if (listItems.count > 0) {
        [sections addObject:[BrowserAdvancedMenuSection sectionWithTitle:@"목록" items:listItems]];
    }

    return sections;
}

// One row per saved page, in the order they were saved. Choosing a row loads
// it and the panel closes behind it.
- (NSArray<BrowserAdvancedMenuItem *> *)favoriteListMenuItemsInFolder:(nullable NSString *)folder {
    NSArray<NSArray<NSString *> *> *favorites = (folder.length > 0)
        ? [self.favoritesStore favoritesInFolder:folder]
        : [self.favoritesStore favorites];
    NSMutableArray<BrowserAdvancedMenuItem *> *items = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;

    for (NSArray<NSString *> *entry in favorites) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        if (URLString.length == 0) {
            continue;
        }
        NSString *storedTitle = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [self displayTitleForStoredTitle:storedTitle
                                                        URLString:URLString
                                                       includeURL:NO];
        if (![self stringHasVisibleContent:displayTitle]) {
            continue;
        }
        [items addObject:[self advancedMenuItemWithTitle:displayTitle
                                                   style:UIAlertActionStyleDefault
                                                 handler:^{
            [weakSelf loadStoredURLString:URLString];
        }]];
    }

    return items;
}

- (BrowserAdvancedMenuItem *)deleteFavoriteMenuItem {
    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"즐겨찾기 삭제  (%lu개)",
                       (unsigned long)[self.favoritesStore count]];
    return [self advancedMenuItemWithTitle:title style:UIAlertActionStyleDestructive handler:^{
        [weakSelf presentDeleteFavoriteMenu];
    }];
}

- (BrowserAdvancedMenuItem *)favoriteFoldersMenuItem {
    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"폴더  (%lu개)",
                       (unsigned long)[self.favoritesStore folderNames].count];
    return [self advancedMenuItemWithTitle:title style:UIAlertActionStyleDefault handler:^{
        [weakSelf presentFavoriteFoldersMenu];
    }];
}

- (void)presentFavoriteFoldersMenu {
    __weak typeof(self) weakSelf = self;
    NSArray<NSString *> *folders = [self.favoritesStore folderNames];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"즐겨찾기 폴더" message:@""];

    for (NSString *folder in folders) {
        NSUInteger count = [self.favoritesStore favoritesInFolder:folder].count;
        NSString *title = [NSString stringWithFormat:@"%@  (%lu)", folder, (unsigned long)count];
        [alertController addAction:[self browserActionWithTitle:title
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentFavoritesInFolder:folder];
        }]];
    }

    NSString *currentURL = [self.host browserWebView].request.URL.absoluteString;
    if ([self.favoritesStore isFavoriteURLString:currentURL]) {
        [alertController addAction:[self browserActionWithTitle:@"이 페이지를 폴더에 넣기"
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentMoveCurrentFavoriteToFolderMenu];
        }]];
    }

    [alertController addAction:[self browserActionWithTitle:@"새 폴더 만들기"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf presentCreateFolderPrompt];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentFavoritesInFolder:(NSString *)folderName {
    __weak typeof(self) weakSelf = self;
    NSArray<NSArray<NSString *> *> *entries = [self.favoritesStore favoritesInFolder:folderName];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:folderName message:@""];

    for (NSArray<NSString *> *entry in entries) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *stored = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [self displayTitleForStoredTitle:stored URLString:URLString includeURL:NO];
        if (![self stringHasVisibleContent:displayTitle]) {
            continue;
        }
        [alertController addAction:[self browserActionWithTitle:displayTitle
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }

    // Removing a folder keeps its favorites; they go back to the top level.
    [alertController addAction:[self browserActionWithTitle:@"이 폴더 없애기 (즐겨찾기는 유지)"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf.favoritesStore removeFolderNamed:folderName];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentMoveCurrentFavoriteToFolderMenu {
    __weak typeof(self) weakSelf = self;
    NSString *currentURL = [self.host browserWebView].request.URL.absoluteString;
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"어느 폴더에 넣을까요" message:@""];

    for (NSString *folder in [self.favoritesStore folderNames]) {
        [alertController addAction:[self browserActionWithTitle:folder
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf.favoritesStore setFolder:folder forURLString:currentURL];
        }]];
    }
    [alertController addAction:[self browserActionWithTitle:@"폴더에서 꺼내기"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf.favoritesStore setFolder:nil forURLString:currentURL];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentCreateFolderPrompt {
    __weak typeof(self) weakSelf = self;
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"새 폴더" message:@"폴더 이름"];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"폴더 이름";
    }];
    [alertController addAction:[self browserActionWithTitle:@"만들기"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        NSString *name = alertController.textFields.firstObject.text;
        name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length > 0) {
            [weakSelf.favoritesStore createFolderNamed:name];
        }
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (NSArray<BrowserAdvancedMenuSection *> *)readingMenuSections {
    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Reading" items:@[
            [self readerModeToggleMenuItem],
            [self forcedDarkModeToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Reader Text Size" items:@[
            [self increaseReaderFontSizeMenuItem],
            [self decreaseReaderFontSizeMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"화면 채우기" items:@[
            [self narrowerLayoutMenuItem],
            [self widerLayoutMenuItem],
            [self printableArticleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Page Text Size" items:@[
            [self increasePageZoomMenuItem],
            [self decreasePageZoomMenuItem],
            [self resetPageZoomMenuItem],
            [self boldTextToggleMenuItem],
            [self increaseMinimumFontSizeMenuItem],
            [self decreaseMinimumFontSizeMenuItem],
            [self increaseFontSizeMenuItem],
            [self decreaseFontSizeMenuItem],
            [self resetFontSizeMenuItem],
            [self pageScalingMenuItem],
        ]],
    ];
}

// Fitting the screen to the page: the page is laid out at this width and
// scaled up to fill the display, so a desktop layout that caps itself near
// 1275 fills a 1920 screen instead of sitting in the middle of it.
- (BrowserAdvancedMenuItem *)narrowerLayoutMenuItem {
    NSUInteger width = self.preferencesStore.pageLayoutWidth;
    NSString *title = width > 0
        ? [NSString stringWithFormat:@"화면 더 크게  (레이아웃 %lupx)", (unsigned long)width]
        : @"화면 더 크게  (끔)";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        NSUInteger current = weakSelf.preferencesStore.pageLayoutWidth;
        weakSelf.preferencesStore.pageLayoutWidth = current == 0 ? 1280
            : (current > 900 ? current - 80 : current);
        [weakSelf.host browserApplyPageLayoutWidth];
    }];
}

- (BrowserAdvancedMenuItem *)widerLayoutMenuItem {
    NSUInteger width = self.preferencesStore.pageLayoutWidth;
    NSString *title = width > 0
        ? [NSString stringWithFormat:@"화면 작게  (레이아웃 %lupx)", (unsigned long)width]
        : @"화면 작게  (끔)";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        NSUInteger current = weakSelf.preferencesStore.pageLayoutWidth;
        weakSelf.preferencesStore.pageLayoutWidth = (current == 0 || current >= 1840) ? 0 : current + 80;
        [weakSelf.host browserApplyPageLayoutWidth];
    }];
}

- (BrowserAdvancedMenuItem *)printableArticleMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:@"기사만 깔끔하게 보기" style:UIAlertActionStyleDefault handler:^{
        if (![weakSelf.host browserOpenPrintableArticle]) {
            UIAlertController *alert =
                [weakSelf browserAlertControllerWithTitle:@"기사만 깔끔하게 보기"
                                                  message:@"네이버 뉴스 기사 페이지에서만 쓸 수 있습니다."];
            [alert addAction:[weakSelf browserCancelAction]];
            [weakSelf.host browserPresentViewController:alert];
        }
    }];
}

- (BrowserAdvancedMenuItem *)boldTextToggleMenuItem {
    BOOL enabled = self.preferencesStore.boldTextEnabled;
    NSString *title = enabled ? @"Bolder Text: On" : @"Bolder Text: Off";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        weakSelf.preferencesStore.boldTextEnabled = !enabled;
        [weakSelf.host browserUpdateTextFontSize];
    }];
}

- (BrowserAdvancedMenuItem *)increaseMinimumFontSizeMenuItem {
    NSUInteger size = self.preferencesStore.minimumFontSize;
    NSString *title = size > 0
        ? [NSString stringWithFormat:@"Minimum Text Bigger  (%lupt)", (unsigned long)size]
        : @"Minimum Text Bigger  (off)";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        weakSelf.preferencesStore.minimumFontSize = weakSelf.preferencesStore.minimumFontSize + 2;
        [weakSelf.host browserApplyReadingZoom];
        [weakSelf.host browserReloadActivePage];
    }];
}

- (BrowserAdvancedMenuItem *)decreaseMinimumFontSizeMenuItem {
    NSUInteger size = self.preferencesStore.minimumFontSize;
    NSString *title = size > 0
        ? [NSString stringWithFormat:@"Minimum Text Smaller  (%lupt)", (unsigned long)size]
        : @"Minimum Text Smaller  (off)";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        NSUInteger current = weakSelf.preferencesStore.minimumFontSize;
        weakSelf.preferencesStore.minimumFontSize = current >= 2 ? current - 2 : 0;
        [weakSelf.host browserApplyReadingZoom];
        [weakSelf.host browserReloadActivePage];
    }];
}

- (BrowserAdvancedMenuItem *)increasePageZoomMenuItem {
    NSString *title = [NSString stringWithFormat:@"Zoom In  (%lu%%)",
                       (unsigned long)self.preferencesStore.pageZoomPercent];
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        weakSelf.preferencesStore.pageZoomPercent = weakSelf.preferencesStore.pageZoomPercent + 10;
        [weakSelf.host browserApplyReadingZoom];
    }];
}

- (BrowserAdvancedMenuItem *)decreasePageZoomMenuItem {
    NSString *title = [NSString stringWithFormat:@"Zoom Out  (%lu%%)",
                       (unsigned long)self.preferencesStore.pageZoomPercent];
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        NSUInteger current = weakSelf.preferencesStore.pageZoomPercent;
        weakSelf.preferencesStore.pageZoomPercent = current > 10 ? current - 10 : current;
        [weakSelf.host browserApplyReadingZoom];
    }];
}

- (BrowserAdvancedMenuItem *)resetPageZoomMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:@"Reset Zoom to 100%" handler:^{
        weakSelf.preferencesStore.pageZoomPercent = 100;
        [weakSelf.host browserApplyReadingZoom];
    }];
}

- (BrowserAdvancedMenuItem *)increaseReaderFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"Larger Reader Text (%lu)",
                       (unsigned long)self.preferencesStore.readerFontSize];
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        weakSelf.preferencesStore.readerFontSize = weakSelf.preferencesStore.readerFontSize + 6;
        [weakSelf reapplyReaderModeIfActive];
    }];
}

- (BrowserAdvancedMenuItem *)decreaseReaderFontSizeMenuItem {
    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"Smaller Reader Text (%lu)",
                       (unsigned long)self.preferencesStore.readerFontSize];
    return [self settingMenuItemWithTitle:title
                                 handler:^{
        NSUInteger current = weakSelf.preferencesStore.readerFontSize;
        weakSelf.preferencesStore.readerFontSize = current > 6 ? current - 6 : current;
        [weakSelf reapplyReaderModeIfActive];
    }];
}

// A size change only shows once the page is rebuilt, so reader mode is turned
// off and on again when it is already showing.
- (void)reapplyReaderModeIfActive {
    if (![self.host browserIsReaderModeActive]) {
        return;
    }
    [self.host browserToggleReaderMode];
    [self.host browserToggleReaderMode];
}

- (NSArray<BrowserAdvancedMenuSection *> *)privacyMenuSections {
    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Blocking" items:@[
            [self contentBlockingToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Stored Data" items:@[
            [self clearCacheMenuItem],
            [self clearCookiesMenuItem],
        ]],
    ];
}

- (NSArray<BrowserAdvancedMenuSection *> *)settingsMenuSections {
    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Remote" items:@[
            [self tapToClickToggleMenuItem],
            [self openLinksInNewTabToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Scrolling" items:@[
            [self dpadScrollToggleMenuItem],
            [self edgeAutoScrollToggleMenuItem],
            [self jsScrollFallbackToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Reading" items:@[
            [self increasePageZoomMenuItem],
            [self decreasePageZoomMenuItem],
            [self resetPageZoomMenuItem],
            [self boldTextToggleMenuItem],
            [self increaseMinimumFontSizeMenuItem],
            [self decreaseMinimumFontSizeMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Page" items:@[
            [self lightenHeavySitesToggleMenuItem],
            [self userAgentModeMenuItem],
            [self topNavigationVisibilityMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Help" items:@[
            [self usageGuideMenuItem],
        ]],
    ];
}

- (void)showBookmarksMenuAnchoredAt:(CGFloat)anchorCenterX {
    __weak typeof(self) weakSelf = self;
    [self presentAnchoredMenuWithTitle:@"Bookmarks"
                              provider:^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf bookmarksMenuSections] ?: @[];
    }
                              anchorAt:anchorCenterX];
}

- (void)showReadingMenuAnchoredAt:(CGFloat)anchorCenterX {
    __weak typeof(self) weakSelf = self;
    [self presentAnchoredMenuWithTitle:@"Reading"
                              provider:^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf readingMenuSections] ?: @[];
    }
                              anchorAt:anchorCenterX];
}

- (void)showPrivacyMenuAnchoredAt:(CGFloat)anchorCenterX {
    __weak typeof(self) weakSelf = self;
    [self presentAnchoredMenuWithTitle:@"Privacy"
                              provider:^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf privacyMenuSections] ?: @[];
    }
                              anchorAt:anchorCenterX];
}

- (void)showSettingsMenuAnchoredAt:(CGFloat)anchorCenterX {
    __weak typeof(self) weakSelf = self;
    [self presentAnchoredMenuWithTitle:@"Settings"
                              provider:^NSArray<BrowserAdvancedMenuSection *> *{
        return [weakSelf settingsMenuSections] ?: @[];
    }
                              anchorAt:anchorCenterX];
}


- (BrowserAdvancedMenuItem *)lightenHeavySitesToggleMenuItem {
    BOOL enabled = self.preferencesStore.lightenHeavySitesEnabled;
    NSString *title = enabled ? @"Lighten Heavy Sites: On" : @"Lighten Heavy Sites: Off";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title
                                  handler:^{
        weakSelf.preferencesStore.lightenHeavySitesEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)clearCacheMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:@"Clear Cache"
                                     style:UIAlertActionStyleDestructive
                                   handler:^{
        [weakSelf clearCacheAndReload];
    }];
}

- (BrowserAdvancedMenuItem *)clearCookiesMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:@"Clear Cookies"
                                     style:UIAlertActionStyleDestructive
                                   handler:^{
        [weakSelf clearCookiesAndReload];
    }];
}

- (NSArray<BrowserAdvancedMenuSection *> *)advancedMenuSections {
    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Tabs" items:@[
            [self showTabsMenuItem],
            [self newTabMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Page" items:@[
            [self historyMenuItem],
            [self homePageMenuItem],
            [self setCurrentPageAsHomePageMenuItem],
            [self userAgentModeMenuItem],
            [self topNavigationVisibilityMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Maintenance" items:@[
            [self clearCacheMenuItem],
            [self clearCookiesMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Help" items:@[
            [self usageGuideMenuItem],
        ]],
    ];
}

- (NSString *)advancedMenuFooterText {
    NSDictionary *infoDictionary = NSBundle.mainBundle.infoDictionary;
    NSString *version = infoDictionary[@"CFBundleShortVersionString"];
    BOOL hasVersion = [self stringHasVisibleContent:version];

    if (hasVersion) {
        return [NSString stringWithFormat:@"Version %@", version];
    }
    return @"";
}

@end
