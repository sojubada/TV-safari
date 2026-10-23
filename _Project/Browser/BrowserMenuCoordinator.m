#import "BrowserMenuCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserContentBlockerController.h"
#import "BrowserWebPlatformProbe.h"
#import "BrowserReportViewController.h"
#import "BrowserWebView.h"
#import "BrowserFavoritesStore.h"

static UIColor *MenuTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

static NSString * const kBrowserMediaDiagnosticsLogPrefix = @"[MediaDiagnostics]";
static NSString * const kBrowserWebKitMediaPrefsLogPrefix = @"[WebKitMediaPrefs]";
static NSString * const kBrowserScrollDiagnosticsLogPrefix = @"[ScrollDiagnostics]";

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

    NSLog(@"%@ %@", kBrowserMediaDiagnosticsLogPrefix, message);

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

    NSLog(@"%@ %@", kBrowserWebKitMediaPrefsLogPrefix, report);

    NSString *message = report;
    if (message.length > 1800) {
        message = [[message substringToIndex:1800] stringByAppendingString:@"\n\nFull report logged to console."];
    }

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"WebKit Media Prefs"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (NSString *)pageScrollDiagnosticsJavaScript {
    return @"(function(){"
            "var docEl = document.documentElement;"
            "var body = document.body;"
            "var docScrollHeight = docEl ? (docEl.scrollHeight || 0) : 0;"
            "var bodyScrollHeight = body ? (body.scrollHeight || 0) : 0;"
            "var winInnerHeight = window.innerHeight || 0;"
            "var winInnerWidth = window.innerWidth || 0;"
            "var count = 0;"
            "var maxScrollHeight = 0;"
            "var maxContainerDesc = 'none';"
            "if (document.querySelectorAll && window.getComputedStyle) {"
                "var all = document.querySelectorAll('*');"
                "for (var i = 0; i < all.length; i++) {"
                    "var el = all[i];"
                    "if (el === docEl || el === body) { continue; }"
                    "var sh = el.scrollHeight || 0;"
                    "var ch = el.clientHeight || 0;"
                    "if (sh > ch + 1) {"
                        "var st = window.getComputedStyle(el);"
                        "var oy = st ? (st.overflowY || st.overflow || '') : '';"
                        "if (oy === 'auto' || oy === 'scroll' || oy === 'overlay') {"
                            "count++;"
                            "if (sh > maxScrollHeight) {"
                                "maxScrollHeight = sh;"
                                "var tag = el.tagName ? el.tagName.toLowerCase() : 'el';"
                                "var idStr = el.id ? ('#' + el.id) : '';"
                                "maxContainerDesc = tag + idStr;"
                            "}"
                        "}"
                    "}"
                "}"
            "}"
            "return JSON.stringify({"
                "docScrollHeight: docScrollHeight,"
                "bodyScrollHeight: bodyScrollHeight,"
                "innerHeight: winInnerHeight,"
                "innerWidth: winInnerWidth,"
                "scrollableCount: count,"
                "maxContainerScrollHeight: maxScrollHeight,"
                "maxContainerDesc: maxContainerDesc"
            "});"
           "})()";
}

- (void)presentPageScrollDiagnostics {
    BrowserWebView *webView = [self.host browserWebView];
    UIScrollView *scrollView = webView.scrollView;
    CGFloat contentSizeHeight = scrollView ? scrollView.contentSize.height : 0.0;
    CGFloat boundsHeight = scrollView ? CGRectGetHeight(scrollView.bounds) : 0.0;
    CGFloat offsetY = scrollView ? scrollView.contentOffset.y : 0.0;

    NSString *jsResult = [webView stringByEvaluatingJavaScriptFromString:[self pageScrollDiagnosticsJavaScript]];
    NSDictionary *dict = nil;
    if ([self stringHasVisibleContent:jsResult]) {
        NSData *data = [jsResult dataUsingEncoding:NSUTF8StringEncoding];
        if (data != nil) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                dict = obj;
            }
        }
    }

    CGFloat pageZoom = 1.0;
    @try {
        id zoomVal = [webView valueForKey:@"pageZoom"];
        if ([zoomVal respondsToSelector:@selector(doubleValue)]) {
            pageZoom = (CGFloat)[zoomVal doubleValue];
        }
    } @catch (__unused NSException *exception) {
        NSInteger innerWidth = [dict[@"innerWidth"] respondsToSelector:@selector(integerValue)] ? [dict[@"innerWidth"] integerValue] : 0;
        if (innerWidth > 0 && CGRectGetWidth(webView.frame) > 0.0) {
            pageZoom = CGRectGetWidth(webView.frame) / (CGFloat)innerWidth;
        }
    }

    NSString *message = [NSString stringWithFormat:
                         @"documentElement.scrollHeight: %@\n"
                          "body.scrollHeight: %@\n"
                          "window.innerHeight: %@\n\n"
                          "scrollView.contentSize.height: %.1f\n"
                          "scrollView.bounds.size.height: %.1f\n"
                          "scrollView.contentOffset.y: %.1f\n\n"
                          "Scrollable Containers: %@\n"
                          "Largest Container scrollHeight: %@ (%@)\n\n"
                          "pageZoom: %.2f (scalesPageToFit: %@)",
                         [self stringValueForDiagnosticsKey:@"docScrollHeight" dictionary:dict fallback:@"0"],
                         [self stringValueForDiagnosticsKey:@"bodyScrollHeight" dictionary:dict fallback:@"0"],
                         [self stringValueForDiagnosticsKey:@"innerHeight" dictionary:dict fallback:@"0"],
                         contentSizeHeight,
                         boundsHeight,
                         offsetY,
                         [self stringValueForDiagnosticsKey:@"scrollableCount" dictionary:dict fallback:@"0"],
                         [self stringValueForDiagnosticsKey:@"maxContainerScrollHeight" dictionary:dict fallback:@"0"],
                         [self stringValueForDiagnosticsKey:@"maxContainerDesc" dictionary:dict fallback:@"none"],
                         pageZoom,
                         webView.scalesPageToFit ? @"YES" : @"NO"];

    NSLog(@"%@ %@", kBrowserScrollDiagnosticsLogPrefix, message);

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Page Scroll Diagnostics"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentWebPlatformRuntimeReport {
    NSString *report = [BrowserWebPlatformProbe runtimeReportForWebView:[self.host browserWebView]];
    [self.host browserPresentViewController:
        [[BrowserReportViewController alloc] initWithTitle:@"WebKit Runtime" reportText:report]];
}

- (void)presentWebPlatformEngineReport {
    NSString *report = [BrowserWebPlatformProbe engineReportForWebView:[self.host browserWebView]];
    [self.host browserPresentViewController:
        [[BrowserReportViewController alloc] initWithTitle:@"Engine Capabilities" reportText:report]];
}

- (void)presentContentBlockerDiagnostics {
    NSString *report = [[BrowserContentBlockerController sharedController] diagnosticsReport];
    [self.host browserPresentViewController:
        [[BrowserReportViewController alloc] initWithTitle:@"Content Blocker Diagnostics" reportText:report]];
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

- (UIAlertAction *)wkWebViewProofOfConceptAction {
    return [self browserActionWithTitle:@"Open WKWebView PoC"
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction *action) {
        Class proofOfConceptControllerClass = NSClassFromString(@"BrowserWKWebViewProofOfConceptViewController");
        UIViewController *viewController = nil;
        if (proofOfConceptControllerClass != Nil) {
            viewController = [proofOfConceptControllerClass new];
            viewController.modalPresentationStyle = UIModalPresentationFullScreen;
        } else {
            viewController = [UIAlertController alertControllerWithTitle:@"WKWebView PoC Missing"
                                                                 message:@"The proof-of-concept controller was not compiled into this build."
                                                          preferredStyle:UIAlertControllerStyleAlert];
            [(UIAlertController *)viewController addAction:[self browserCancelAction]];
        }
        [self.host browserPresentViewController:viewController];
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

- (BrowserAdvancedMenuItem *)favoritesMenuItem {
    return [self advancedMenuItemWithTitle:@"Favorites"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentFavoritesMenu];
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

- (UIAlertAction *)playVideoUnderCursorAction {
    return [self browserActionWithTitle:@"Play Active Video"
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.host browserPlayVideoUnderCursorIfAvailable];
        });
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

- (NSArray<BrowserAdvancedMenuSection *> *)bookmarksMenuSections {
    NSMutableArray<BrowserAdvancedMenuItem *> *items = [NSMutableArray array];
    BrowserAdvancedMenuItem *toggleFavoriteItem = [self toggleFavoriteMenuItem];
    if (toggleFavoriteItem != nil) {
        [items addObject:toggleFavoriteItem];
    }
    [items addObjectsFromArray:@[
        [self favoritesMenuItem],
        [self historyMenuItem],
        [self homePageMenuItem],
        [self setCurrentPageAsHomePageMenuItem],
    ]];

    return @[[BrowserAdvancedMenuSection sectionWithTitle:@"Favorites & History" items:items]];
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
        [BrowserAdvancedMenuSection sectionWithTitle:@"Page Text Size" items:@[
            [self increasePageZoomMenuItem],
            [self decreasePageZoomMenuItem],
            [self resetPageZoomMenuItem],
            [self readingLayoutMenuItem],
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

- (BrowserAdvancedMenuItem *)readingLayoutMenuItem {
    BOOL enabled = self.preferencesStore.widenContentEnabled;
    NSString *title = enabled ? @"TV Reading Layout: On" : @"TV Reading Layout: Off";
    __weak typeof(self) weakSelf = self;
    return [self settingMenuItemWithTitle:title handler:^{
        [weakSelf.host browserWidenContent];
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
        [BrowserAdvancedMenuSection sectionWithTitle:@"Page Process" items:@[
            [self restartWebProcessMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Diagnostics" items:@[
            [self contentBlockerDiagnosticsMenuItem],
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
            [self readingLayoutMenuItem],
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

- (BrowserAdvancedMenuItem *)restartWebProcessMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:@"Restart Page Process"
                                     style:UIAlertActionStyleDestructive
                                   handler:^{
        [[weakSelf.host browserWebView] restartWebContentProcess];
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

- (BrowserAdvancedMenuItem *)contentBlockerDiagnosticsMenuItem {
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:@"Content Blocker Diagnostics"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [weakSelf presentContentBlockerDiagnostics];
    }];
}

- (NSArray<BrowserAdvancedMenuSection *> *)advancedMenuSections {
    BrowserAdvancedMenuItem *increaseFontSizeItem = [self increaseFontSizeMenuItem];
    BrowserAdvancedMenuItem *decreaseFontSizeItem = [self decreaseFontSizeMenuItem];
    BrowserAdvancedMenuItem *resetFontSizeItem = [self resetFontSizeMenuItem];
    BrowserAdvancedMenuItem *contentBlockerDiagnosticsItem = [self advancedMenuItemWithTitle:@"Content Blocker Diagnostics"
                                                                                       style:UIAlertActionStyleDefault
                                                                                     handler:^{
        [self presentContentBlockerDiagnostics];
    }];
    BrowserAdvancedMenuItem *pageScrollDiagnosticsItem = [self advancedMenuItemWithTitle:@"Page Scroll Diagnostics"
                                                                                   style:UIAlertActionStyleDefault
                                                                                 handler:^{
        [self presentPageScrollDiagnostics];
    }];
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
    BrowserAdvancedMenuItem *clearCacheItem = [self advancedMenuItemWithTitle:@"Clear Cache"
                                                                         style:UIAlertActionStyleDestructive
                                                                       handler:^{
        [self clearCacheAndReload];
    }];
    BrowserAdvancedMenuItem *clearCookiesItem = [self advancedMenuItemWithTitle:@"Clear Cookies"
                                                                           style:UIAlertActionStyleDestructive
                                                                         handler:^{
        [self clearCookiesAndReload];
    }];

    NSMutableArray<BrowserAdvancedMenuItem *> *navigationItems = [NSMutableArray arrayWithArray:@[
        [self homePageMenuItem],
        [self setCurrentPageAsHomePageMenuItem]
    ]];
    
    BrowserAdvancedMenuItem *toggleFavoriteItem = [self toggleFavoriteMenuItem];
    if (toggleFavoriteItem != nil) {
        [navigationItems addObject:toggleFavoriteItem];
    }
    
    [navigationItems addObjectsFromArray:@[
        [self favoritesMenuItem],
        [self historyMenuItem],
        [self showTabsMenuItem],
        [self newTabMenuItem],
    ]];

    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Navigation"
                                               items:navigationItems],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Scrolling & Input"
                                               items:@[
            [self tapToClickToggleMenuItem],
            [self openLinksInNewTabToggleMenuItem],
            [self dpadScrollToggleMenuItem],
            [self edgeAutoScrollToggleMenuItem],
            [self jsScrollFallbackToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Appearance"
                                               items:@[
            [self readerModeToggleMenuItem],
            [self forcedDarkModeToggleMenuItem],
            [self topNavigationVisibilityMenuItem],
            [self pageScalingMenuItem],
            [self increasePageZoomMenuItem],
            [self decreasePageZoomMenuItem],
            [self resetPageZoomMenuItem],
            [self readingLayoutMenuItem],
            increaseFontSizeItem,
            decreaseFontSizeItem,
            resetFontSizeItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Privacy & Blocking"
                                               items:@[
            [self contentBlockingToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Compatibility"
                                               items:@[
            [self lightenHeavySitesToggleMenuItem],
            [self userAgentModeMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Probe Workbench"
                                               items:@[
            [self advancedMenuItemWithTitle:@"탐침 작업대 열기" style:UIAlertActionStyleDefault handler:^{
                [self.host browserShowProbeWorkbench];
            }],
            [self advancedMenuItemWithTitle:@"WebKit Runtime (전체 리포트)" style:UIAlertActionStyleDefault handler:^{
                [self presentWebPlatformRuntimeReport];
            }],
            [self advancedMenuItemWithTitle:@"Engine Capabilities (전체 리포트)" style:UIAlertActionStyleDefault handler:^{
                [self presentWebPlatformEngineReport];
            }],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Diagnostics"
                                               items:@[
            contentBlockerDiagnosticsItem,
            pageScrollDiagnosticsItem,
            mediaDiagnosticsItem,
            webkitMediaPrefsItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Maintenance"
                                               items:@[
            clearCacheItem,
            clearCookiesItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Help"
                                               items:@[
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
