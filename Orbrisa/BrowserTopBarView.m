#import "BrowserTopBarView.h"
#import "BrowserLocalization.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

// Overall bar
// Sizes follow Apple's tvOS guidelines: content stays inside the 60 pt top / 80 pt side safe area,
// the tab bar is 68 pt high, focused items grow about 1.05-1.1x, and text is at least 29 pt (25 pt secondary).
static CGFloat const kTopBarHorizontalInset = 80.0;
static CGFloat const kTopBarVerticalInset = 60.0; // tvOS top safe area
static CGFloat const kTopBarHeight = 68.0;      // tvOS tab bar height
static CGFloat const kTopBarMaxWidth = 1760.0;
static CGFloat const kTopBarMinWidth = 900.0;

// Side islands
static CGFloat const kTopBarIslandPadding = 6.0;
static CGFloat const kTopBarButtonSize = 56.0;
static CGFloat const kTopBarButtonSpacing = 4.0;
static CGFloat const kTopBarIslandGap = 28.0;
static CGFloat const kTopBarIconPointSize = 26.0;
static CGFloat const kTopBarFocusedButtonScale = 1.1;

// Center pill
static CGFloat const kTopBarCenterMaxWidth = 820.0;
static CGFloat const kTopBarCenterMinWidth = 420.0;
static CGFloat const kTopBarCenterTextInset = 32.0;
static CGFloat const kTopBarCenterLineSpacing = 0.0;
static CGFloat const kTopBarCenterFocusedScale = 1.05;
static CGFloat const kTopBarProgressHeight = 4.0;

static CGFloat const kTopBarDisabledIconAlpha = 0.38;

// Reader button (inside the address pill) and RSS button (right next to it)
static CGFloat const kTopBarReaderHeight = 48.0;
static CGFloat const kTopBarReaderInset = 11.0;
static CGFloat const kTopBarFeedSize = 60.0;
static CGFloat const kTopBarFeedGap = 32.0; // room for the address pill growing when focused

#pragma mark - Focus button

@interface BrowserTopBarFocusButton : UIButton

@property (nonatomic) BrowserTopBarAction topBarAction;
@property (nonatomic) BOOL focusAllowed;
@property (nonatomic) UIImageView *iconView;

@end

@implementation BrowserTopBarFocusButton

- (BOOL)canBecomeFocused {
    return self.focusAllowed && !self.hidden && self.alpha > 0.01;
}

- (UIFocusSoundIdentifier)soundIdentifierForFocusUpdateInContext:(__unused UIFocusUpdateContext *)context {
    return UIFocusSoundIdentifierDefault;
}

@end

#pragma mark - Loading indicator

// Callers keep using -startAnimating / -stopAnimating; the bar listens and drives its progress line.
@interface BrowserTopBarLoadingIndicator : UIActivityIndicatorView

@property (nonatomic, copy) void (^animatingDidChange)(BOOL animating);

@end

@implementation BrowserTopBarLoadingIndicator

- (void)startAnimating {
    BOOL wasAnimating = self.isAnimating;
    [super startAnimating];
    if (!wasAnimating && self.animatingDidChange != nil) {
        self.animatingDidChange(YES);
    }
}

- (void)stopAnimating {
    BOOL wasAnimating = self.isAnimating;
    [super stopAnimating];
    if (wasAnimating && self.animatingDidChange != nil) {
        self.animatingDidChange(NO);
    }
}

@end

#pragma mark - Top bar

@interface BrowserTopBarView ()

@property (nonatomic) UIView *leftContainerView;
@property (nonatomic) UIVisualEffectView *leftEffectView;
@property (nonatomic) UIView *centerContainerView;
@property (nonatomic) UIVisualEffectView *centerEffectView;
@property (nonatomic) UIView *rightContainerView;
@property (nonatomic) UIVisualEffectView *rightEffectView;

@property (nonatomic) UIImageView *backImageView;
@property (nonatomic) UIImageView *refreshImageView;
@property (nonatomic) UIImageView *forwardImageView;
@property (nonatomic) UIImageView *homeImageView;
@property (nonatomic) UIImageView *tabsImageView;
@property (nonatomic) UIImageView *fullscreenImageView;
@property (nonatomic) UIImageView *menuImageView;
@property (nonatomic) UILabel *URLLabel;
@property (nonatomic) UILabel *subtitleLabel;
@property (nonatomic) UILabel *tabCountLabel;
@property (nonatomic) CAShapeLayer *tabBackSquareLayer;
@property (nonatomic) UIView *centerFocusFillView;
@property (nonatomic) UIView *progressView;
@property (nonatomic) UIActivityIndicatorView *loadingSpinner;

@property (nonatomic) NSArray<BrowserTopBarFocusButton *> *focusButtons;
@property (nonatomic) BrowserTopBarFocusButton *backFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *refreshFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *forwardFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *homeFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *tabsFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *URLFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *fullscreenFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *menuFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *readerFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *feedFocusButton;
@property (nonatomic) UILabel *readerLabel;
@property (nonatomic) UIImageView *readerIconView;
@property (nonatomic) BOOL readerAvailable;
@property (nonatomic) BOOL feedAvailable;
@property (nonatomic) BrowserTopBarFocusButton *lastFocusedButton;
@property (nonatomic, getter=isFocusModeActive) BOOL focusModeActive;

@property (nonatomic) BOOL centerFocused;
@property (nonatomic) BOOL loading;
@property (nonatomic) CGFloat progressFraction;
@property (nonatomic, copy) NSString *subtitleText;
@property (nonatomic) BOOL pageIsLight;
@property (nonatomic) BOOL subtitleSecure;
@property (nonatomic) BOOL overrideTitleActive;
@property (nonatomic, copy) NSString *stashedTitleText;
@property (nonatomic, copy) NSString *stashedSubtitleText;
@property (nonatomic) BOOL stashedSubtitleSecure;

@end

NSNotificationName const BrowserGlassAmountDidChangeNotification = @"BrowserGlassAmountDidChangeNotification";
static NSString * const kBrowserGlassAmountKey = @"BrowserGlassAmount";
static NSInteger const kBrowserGlassFillTag = 0x6A55;

CGFloat BrowserGlassAmount(void) {
    NSNumber *value = [[NSUserDefaults standardUserDefaults] objectForKey:kBrowserGlassAmountKey];
    return value != nil ? MIN(MAX(value.doubleValue, 0.0), 1.0) : 1.0;
}

void BrowserSetGlassAmount(CGFloat amount) {
    amount = MIN(MAX(amount, 0.0), 1.0);
    [[NSUserDefaults standardUserDefaults] setDouble:amount forKey:kBrowserGlassAmountKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlassAmountDidChangeNotification object:nil];
}

void BrowserApplyGlassAmount(UIVisualEffectView *effectView, UIColor *solidColor) {
    if (effectView == nil) {
        return;
    }
    UIView *fill = [effectView.contentView viewWithTag:kBrowserGlassFillTag];
    if (fill == nil) {
        fill = [[UIView alloc] initWithFrame:effectView.contentView.bounds];
        fill.tag = kBrowserGlassFillTag;
        fill.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        fill.userInteractionEnabled = NO;
        [effectView.contentView insertSubview:fill atIndex:0];
    }
    fill.backgroundColor = solidColor;
    fill.alpha = 1.0 - BrowserGlassAmount();
}

@implementation BrowserTopBarView

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithEffect:(UIVisualEffect *)effect {
    self = [super initWithEffect:effect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];

    // The storyboard still carries the old icon views; keep only the islands built in code.
    NSArray<UIView *> *ownViews = @[self.leftContainerView, self.centerContainerView, self.rightContainerView, self.feedFocusButton];
    for (UIView *subview in [self.contentView.subviews copy]) {
        if (![ownViews containsObject:subview]) {
            [subview removeFromSuperview];
        }
    }
}

#pragma mark Setup

- (void)commonInit {
    self.effect = nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.userInteractionEnabled = YES;
    self.contentView.clipsToBounds = NO;

    _subtitleText = @"";
    _pageIsLight = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(glassAmountDidChange:)
                                                 name:BrowserGlassAmountDidChangeNotification
                                               object:nil];

    // Islands
    _leftContainerView = [self newIslandContainerView];
    _leftEffectView = [self newIslandEffectViewInContainer:_leftContainerView];
    _centerContainerView = [self newIslandContainerView];
    _centerEffectView = [self newIslandEffectViewInContainer:_centerContainerView];
    _rightContainerView = [self newIslandContainerView];
    _rightEffectView = [self newIslandEffectViewInContainer:_rightContainerView];

    // Left island: back, forward, reload
    _backFocusButton = [self newFocusButtonForAction:BrowserTopBarActionBack symbolName:@"chevron.backward" accessibilityLabel:BrowserLocalized(@"Back")];
    _forwardFocusButton = [self newFocusButtonForAction:BrowserTopBarActionForward symbolName:@"chevron.forward" accessibilityLabel:BrowserLocalized(@"Forward")];
    _refreshFocusButton = [self newFocusButtonForAction:BrowserTopBarActionRefresh symbolName:@"arrow.clockwise" accessibilityLabel:BrowserLocalized(@"Reload")];
    for (BrowserTopBarFocusButton *button in @[_backFocusButton, _forwardFocusButton, _refreshFocusButton]) {
        [_leftEffectView.contentView addSubview:button];
    }

    // Right island: home, tabs, fullscreen, menu
    _homeFocusButton = [self newFocusButtonForAction:BrowserTopBarActionHome symbolName:@"house" accessibilityLabel:BrowserLocalized(@"Home")];
    _tabsFocusButton = [self newFocusButtonForAction:BrowserTopBarActionTabs symbolName:@"square.on.square" accessibilityLabel:BrowserLocalized(@"Tabs")];
    _fullscreenFocusButton = [self newFocusButtonForAction:BrowserTopBarActionFullscreen symbolName:@"arrow.up.left.and.arrow.down.right" accessibilityLabel:BrowserLocalized(@"Top Navigation Visibility")];
    _menuFocusButton = [self newFocusButtonForAction:BrowserTopBarActionMenu symbolName:@"ellipsis" accessibilityLabel:BrowserLocalized(@"Menu")];
    for (BrowserTopBarFocusButton *button in @[_homeFocusButton, _tabsFocusButton, _fullscreenFocusButton, _menuFocusButton]) {
        [_rightEffectView.contentView addSubview:button];
    }

    _tabCountLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _tabCountLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
    _tabCountLabel.layer.borderWidth = 2.5;
    _tabCountLabel.layer.cornerRadius = 6.0;
    _tabCountLabel.layer.borderColor = [self idleTintColor].CGColor;
    _tabCountLabel.adjustsFontSizeToFitWidth = YES;
    _tabCountLabel.minimumScaleFactor = 0.7;
    _tabCountLabel.textAlignment = NSTextAlignmentCenter;
    _tabCountLabel.textColor = [self idleTintColor];
    _tabCountLabel.userInteractionEnabled = NO;
    _tabCountLabel.hidden = YES;
    [_tabsFocusButton addSubview:_tabCountLabel];
    // The second, rear square of the tabs icon (only its visible top and right edges).
    _tabBackSquareLayer = [CAShapeLayer layer];
    _tabBackSquareLayer.fillColor = UIColor.clearColor.CGColor;
    _tabBackSquareLayer.strokeColor = [self idleTintColor].CGColor;
    _tabBackSquareLayer.lineWidth = 2.5;
    _tabBackSquareLayer.lineCap = kCALineCapRound;
    _tabBackSquareLayer.lineJoin = kCALineJoinRound;
    _tabBackSquareLayer.hidden = YES;
    [_tabsFocusButton.layer addSublayer:_tabBackSquareLayer];

    _backImageView = _backFocusButton.iconView;
    _forwardImageView = _forwardFocusButton.iconView;
    _refreshImageView = _refreshFocusButton.iconView;
    _homeImageView = _homeFocusButton.iconView;
    _tabsImageView = _tabsFocusButton.iconView;
    _fullscreenImageView = _fullscreenFocusButton.iconView;
    _menuImageView = _menuFocusButton.iconView;

    // Center pill: title, address, progress line
    UIView *centerContent = _centerEffectView.contentView;

    _centerFocusFillView = [[UIView alloc] initWithFrame:CGRectZero];
    _centerFocusFillView.backgroundColor = [self focusFillColor];
    _centerFocusFillView.alpha = 0.0;
    _centerFocusFillView.userInteractionEnabled = NO;
    [centerContent addSubview:_centerFocusFillView];

    _URLLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _URLLabel.text = BrowserLocalized(@"New Tab");
    _URLLabel.textAlignment = NSTextAlignmentCenter;
    _URLLabel.textColor = [self idleTintColor];
    _URLLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightSemibold];
    _URLLabel.adjustsFontSizeToFitWidth = NO;
    _URLLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _URLLabel.userInteractionEnabled = NO;
    [centerContent addSubview:_URLLabel];

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightMedium];
    _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _subtitleLabel.userInteractionEnabled = NO;
    [centerContent addSubview:_subtitleLabel];

    _progressView = [[UIView alloc] initWithFrame:CGRectZero];
    _progressView.backgroundColor = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1.0];
    _progressView.alpha = 0.0;
    _progressView.userInteractionEnabled = NO;
    [centerContent addSubview:_progressView];

    BrowserTopBarLoadingIndicator *spinner = [[BrowserTopBarLoadingIndicator alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.hidesWhenStopped = YES;
    spinner.alpha = 0.0; // replaced visually by the progress line
    spinner.userInteractionEnabled = NO;
    __weak __typeof__(self) weakSelf = self;
    spinner.animatingDidChange = ^(BOOL animating) {
        [weakSelf setLoading:animating];
    };
    _loadingSpinner = spinner;
    [centerContent addSubview:spinner];

    _URLFocusButton = [self newFocusButtonForAction:BrowserTopBarActionURL symbolName:nil accessibilityLabel:BrowserLocalized(@"Enter URL or Search")];
    [centerContent addSubview:_URLFocusButton];

    // "Reader" button on the right of the address pill – only when the page has an article.
    _readerFocusButton = [self newFocusButtonForAction:BrowserTopBarActionReader symbolName:nil accessibilityLabel:BrowserLocalized(@"Open in Reader")];
    _readerFocusButton.backgroundColor = UIColor.whiteColor;
    _readerFocusButton.layer.cornerRadius = kTopBarReaderHeight / 2.0;
    _readerIconView = [[UIImageView alloc] initWithImage:[self symbolImageNamed:@"text.alignleft" pointSize:20.0]];
    _readerIconView.tintColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    _readerIconView.contentMode = UIViewContentModeCenter;
    _readerIconView.userInteractionEnabled = NO;
    [_readerFocusButton addSubview:_readerIconView];
    _readerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _readerLabel.text = BrowserLocalized(@"Reader");
    _readerLabel.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightBold];
    _readerLabel.textColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    _readerLabel.userInteractionEnabled = NO;
    [_readerFocusButton addSubview:_readerLabel];
    _readerFocusButton.hidden = YES;
    _readerFocusButton.alpha = 0.0;
    [centerContent addSubview:_readerFocusButton];

    // RSS button right next to the address pill – only when the page offers a feed.
    _feedFocusButton = [self newFocusButtonForAction:BrowserTopBarActionFeed symbolName:@"dot.radiowaves.up.forward" accessibilityLabel:BrowserLocalized(@"Subscribe to Feed")];
    _feedFocusButton.backgroundColor = UIColor.systemOrangeColor;
    _feedFocusButton.iconView.tintColor = UIColor.whiteColor;
    _feedFocusButton.layer.cornerRadius = kTopBarFeedSize / 2.0;
    _feedFocusButton.layer.borderColor = UIColor.whiteColor.CGColor;
    _feedFocusButton.layer.shadowColor = UIColor.blackColor.CGColor;
    _feedFocusButton.layer.shadowOffset = CGSizeMake(0.0, 6.0);
    _feedFocusButton.layer.shadowRadius = 12.0;
    _feedFocusButton.layer.shadowOpacity = 0.25;
    [self.contentView addSubview:_feedFocusButton];
    [self applyFeedLook];

    _focusButtons = @[
        _backFocusButton,
        _forwardFocusButton,
        _refreshFocusButton,
        _URLFocusButton,
        _readerFocusButton,
        _feedFocusButton,
        _homeFocusButton,
        _tabsFocusButton,
        _fullscreenFocusButton,
        _menuFocusButton
    ];

    [self refreshSubtitle];
    [self applyVisualStyle];
    [self updateFocusAllowed];
}

- (UIView *)newIslandContainerView {
    UIView *containerView = [[UIView alloc] initWithFrame:CGRectZero];
    containerView.backgroundColor = UIColor.clearColor;
    containerView.userInteractionEnabled = YES;
    containerView.clipsToBounds = NO;
    [self.contentView addSubview:containerView];
    return containerView;
}

- (UIVisualEffectView *)newIslandEffectViewInContainer:(UIView *)containerView {
    UIVisualEffectView *effectView = [[UIVisualEffectView alloc] initWithEffect:nil];
    effectView.userInteractionEnabled = YES;
    effectView.clipsToBounds = YES;
    [containerView addSubview:effectView];
    return effectView;
}

- (UIImage *)symbolImageNamed:(NSString *)name pointSize:(CGFloat)pointSize {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                                weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:configuration];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (BrowserTopBarFocusButton *)newFocusButtonForAction:(BrowserTopBarAction)action
                                           symbolName:(NSString *)symbolName
                                   accessibilityLabel:(NSString *)accessibilityLabel {
    BrowserTopBarFocusButton *button = [BrowserTopBarFocusButton buttonWithType:UIButtonTypeCustom];
    button.topBarAction = action;
    button.backgroundColor = UIColor.clearColor;
    button.clipsToBounds = NO;
    button.accessibilityLabel = accessibilityLabel;
    button.accessibilityTraits = UIAccessibilityTraitButton;
    if (symbolName != nil) {
        UIImageView *iconView = [[UIImageView alloc] initWithImage:[self symbolImageNamed:symbolName pointSize:kTopBarIconPointSize]];
        iconView.contentMode = UIViewContentModeCenter;
        iconView.tintColor = [self idleTintColor];
        iconView.userInteractionEnabled = NO;
        [button addSubview:iconView];
        button.iconView = iconView;
    }
    [button addTarget:self action:@selector(handleFocusButtonPrimaryAction:) forControlEvents:UIControlEventPrimaryActionTriggered];
    return button;
}

#pragma mark Colors and effects

// Two looks, picked from the page behind the bar:
//  light page -> grey glass with white symbols (white glass would vanish on a white page)
//  dark page  -> light, almost white glass with dark symbols
- (UIColor *)idleTintColor {
    return self.pageIsLight ? [UIColor colorWithWhite:1.0 alpha:0.95] : [UIColor colorWithWhite:0.12 alpha:0.92];
}

- (UIColor *)focusedTintColor {
    return self.pageIsLight ? [UIColor colorWithWhite:0.11 alpha:1.0] : UIColor.whiteColor;
}

- (UIColor *)focusFillColor {
    return self.pageIsLight ? UIColor.whiteColor : [UIColor colorWithWhite:0.12 alpha:1.0];
}

- (UIColor *)subtitleColorFocused:(BOOL)focused {
    if (self.pageIsLight) {
        return focused ? [UIColor colorWithWhite:0.37 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.75];
    }
    return focused ? [UIColor colorWithWhite:1.0 alpha:0.75] : [UIColor colorWithWhite:0.12 alpha:0.62];
}

- (UIColor *)glassTintColor {
    return self.pageIsLight ? [UIColor colorWithWhite:0.22 alpha:0.42] : [UIColor colorWithWhite:1.0 alpha:0.62];
}

- (void)setPageIsLight:(BOOL)pageIsLight animated:(BOOL)animated {
    if (_pageIsLight == pageIsLight) {
        return;
    }
    _pageIsLight = pageIsLight;

    void (^changes)(void) = ^{
        [self applyVisualStyle];
        self.centerFocusFillView.backgroundColor = [self focusFillColor];
        for (BrowserTopBarFocusButton *button in self.focusButtons) {
            BOOL focused = self.focusModeActive && button.isFocused;
            [self applyFocusAppearanceToButton:button focused:focused];
        }
        [self refreshSubtitle];
    };
    if (animated) {
        [UIView animateWithDuration:0.35 animations:changes];
    } else {
        changes();
    }
}

- (BOOL)usesGlass {
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        return YES;
    }
#endif
    return NO;
}

- (UIVisualEffect *)newIslandEffect {
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        UIGlassEffect *glassEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        glassEffect.interactive = YES;
        glassEffect.tintColor = [self glassTintColor];
        return glassEffect;
    }
#endif
    return [UIBlurEffect effectWithStyle:self.pageIsLight ? UIBlurEffectStyleDark : UIBlurEffectStyleLight];
}

- (void)glassAmountDidChange:(NSNotification *)notification {
    (void)notification;
    // Only the solid layer changes – rebuilding the glass effects on every slider step made it lag.
    for (UIVisualEffectView *effectView in @[self.leftEffectView, self.centerEffectView, self.rightEffectView]) {
        BrowserApplyGlassAmount(effectView, [self solidIslandColor]);
    }
}

/// The bar without glass: the same grey / light look as the glass, but solid.
- (UIColor *)solidIslandColor {
    return self.pageIsLight ? [UIColor colorWithWhite:0.30 alpha:1.0] : [UIColor colorWithWhite:0.93 alpha:1.0];
}

- (void)applyVisualStyle {
    self.effect = nil;

    NSArray<UIView *> *containers = @[self.leftContainerView, self.centerContainerView, self.rightContainerView];
    NSArray<UIVisualEffectView *> *effectViews = @[self.leftEffectView, self.centerEffectView, self.rightEffectView];
    BOOL usesGlass = [self usesGlass];

    for (NSUInteger index = 0; index < containers.count; index++) {
        UIView *containerView = containers[index];
        UIVisualEffectView *effectView = effectViews[index];
        effectView.effect = [self newIslandEffect];
        effectView.alpha = usesGlass ? 1.0 : 0.98;
        BrowserApplyGlassAmount(effectView, [self solidIslandColor]);

        if (usesGlass) {
            // A thin bright rim and a soft drop shadow give the glass its "liquid" edge.
            containerView.layer.shadowColor = UIColor.blackColor.CGColor;
            containerView.layer.shadowOpacity = self.pageIsLight ? 0.22 : 0.30;
            containerView.layer.shadowRadius = 24.0;
            containerView.layer.shadowOffset = CGSizeMake(0.0, 10.0);
            containerView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:self.pageIsLight ? 0.35 : 0.55].CGColor;
            containerView.layer.borderWidth = 1.0;
        } else {
            containerView.layer.shadowColor = UIColor.blackColor.CGColor;
            containerView.layer.shadowOpacity = 0.28;
            containerView.layer.shadowOffset = CGSizeMake(0.0, 12.0);
            containerView.layer.shadowRadius = 22.0;
            containerView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
            containerView.layer.borderWidth = 1.0;
        }
    }
}

#pragma mark Layout

- (CGFloat)islandWidthForButtonCount:(NSUInteger)buttonCount {
    if (buttonCount == 0) {
        return 0.0;
    }
    return (kTopBarIslandPadding * 2.0) +
        (kTopBarButtonSize * buttonCount) +
        (kTopBarButtonSpacing * (buttonCount - 1));
}

- (void)layoutSubviews {
    [super layoutSubviews];

    self.contentView.frame = self.bounds;

    NSArray<BrowserTopBarFocusButton *> *leftButtons = @[self.backFocusButton, self.forwardFocusButton, self.refreshFocusButton];
    NSArray<BrowserTopBarFocusButton *> *rightButtons = @[self.homeFocusButton, self.tabsFocusButton, self.fullscreenFocusButton, self.menuFocusButton];

    CGFloat availableWidth = MIN(CGRectGetWidth(self.bounds) - (kTopBarHorizontalInset * 2.0), kTopBarMaxWidth);
    availableWidth = MAX(availableWidth, kTopBarMinWidth);
    CGFloat originX = floor((CGRectGetWidth(self.bounds) - availableWidth) / 2.0);
    CGFloat originY = kTopBarVerticalInset;

    CGFloat leftWidth = [self islandWidthForButtonCount:leftButtons.count];
    CGFloat rightWidth = [self islandWidthForButtonCount:rightButtons.count];

    // Transforms must be identity while frames are set.
    CGAffineTransform centerTransform = self.centerContainerView.transform;
    self.centerContainerView.transform = CGAffineTransformIdentity;

    self.leftContainerView.frame = CGRectMake(originX, originY, leftWidth, kTopBarHeight);
    self.rightContainerView.frame = CGRectMake(originX + availableWidth - rightWidth, originY, rightWidth, kTopBarHeight);

    // The center pill stays centered on screen, but never runs into the side islands.
    CGFloat minCenterX = CGRectGetMaxX(self.leftContainerView.frame) + kTopBarIslandGap;
    CGFloat maxCenterMaxX = CGRectGetMinX(self.rightContainerView.frame) - kTopBarIslandGap;
    maxCenterMaxX -= kTopBarFeedSize + kTopBarFeedGap; // the RSS button is always next to the pill
    CGFloat centerWidth = MIN(kTopBarCenterMaxWidth, MAX(kTopBarCenterMinWidth, maxCenterMaxX - minCenterX));
    CGFloat centerX = MAX(minCenterX, floor((CGRectGetWidth(self.bounds) - centerWidth) / 2.0));
    if (centerX + centerWidth > maxCenterMaxX) {
        centerWidth = MAX(200.0, maxCenterMaxX - centerX);
    }
    self.centerContainerView.frame = CGRectMake(centerX, originY, centerWidth, kTopBarHeight);
    CGAffineTransform feedTransform = self.feedFocusButton.transform;
    self.feedFocusButton.transform = CGAffineTransformIdentity;
    self.feedFocusButton.frame = CGRectMake(centerX + centerWidth + kTopBarFeedGap,
                                            originY + floor((kTopBarHeight - kTopBarFeedSize) / 2.0),
                                            kTopBarFeedSize, kTopBarFeedSize);
    self.feedFocusButton.iconView.frame = self.feedFocusButton.bounds;
    self.feedFocusButton.transform = feedTransform;

    for (UIView *containerView in @[self.leftContainerView, self.centerContainerView, self.rightContainerView]) {
        CGFloat cornerRadius = CGRectGetHeight(containerView.bounds) / 2.0;
        containerView.layer.cornerRadius = cornerRadius;
        containerView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:containerView.bounds
                                                                    cornerRadius:cornerRadius].CGPath;
    }
    for (UIVisualEffectView *effectView in @[self.leftEffectView, self.centerEffectView, self.rightEffectView]) {
        effectView.frame = effectView.superview.bounds;
        effectView.layer.cornerRadius = CGRectGetHeight(effectView.bounds) / 2.0;
    }

    [self layoutButtons:leftButtons];
    [self layoutButtons:rightButtons];
    [self layoutTabCountLabel];
    [self layoutCenterContent];

    self.centerContainerView.transform = centerTransform;
}

- (void)layoutButtons:(NSArray<BrowserTopBarFocusButton *> *)buttons {
    CGFloat x = kTopBarIslandPadding;
    CGFloat y = floor((kTopBarHeight - kTopBarButtonSize) / 2.0);
    for (BrowserTopBarFocusButton *button in buttons) {
        CGAffineTransform transform = button.transform;
        button.transform = CGAffineTransformIdentity;
        button.frame = CGRectMake(x, y, kTopBarButtonSize, kTopBarButtonSize);
        button.layer.cornerRadius = kTopBarButtonSize / 2.0;
        button.iconView.frame = button.bounds;
        button.transform = transform;
        x += kTopBarButtonSize + kTopBarButtonSpacing;
    }
}

- (void)layoutTabCountLabel {
    // Like the tabs symbol: a front square with the number (bottom left) and a rear square peeking out top right.
    CGFloat side = 25.0;
    CGFloat offset = 6.0;
    CGFloat originX = floor((kTopBarButtonSize - side - offset) / 2.0);
    CGFloat originY = floor((kTopBarButtonSize - side + offset) / 2.0);
    self.tabCountLabel.frame = CGRectMake(originX, originY, side, side);

    CGFloat r = 6.0;
    CGFloat left = originX + offset;
    CGFloat top = originY - offset;
    CGFloat right = originX + side + offset;
    CGFloat bottom = originY + side - offset;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(left, originY - 1.0)];
    [path addLineToPoint:CGPointMake(left, top + r)];
    [path addArcWithCenter:CGPointMake(left + r, top + r) radius:r startAngle:M_PI endAngle:M_PI * 1.5 clockwise:YES];
    [path addLineToPoint:CGPointMake(right - r, top)];
    [path addArcWithCenter:CGPointMake(right - r, top + r) radius:r startAngle:M_PI * 1.5 endAngle:0 clockwise:YES];
    [path addLineToPoint:CGPointMake(right, bottom - r)];
    [path addArcWithCenter:CGPointMake(right - r, bottom - r) radius:r startAngle:0 endAngle:M_PI_2 clockwise:YES];
    [path addLineToPoint:CGPointMake(originX + side + 1.0, bottom)];
    self.tabBackSquareLayer.frame = self.tabsFocusButton.bounds;
    self.tabBackSquareLayer.path = path.CGPath;
}

- (void)layoutCenterContent {
    CGRect bounds = self.centerEffectView.contentView.bounds;
    CGFloat readerWidth = 0.0;
    if (self.readerAvailable) {
        CGFloat labelWidth = ceil([self.readerLabel sizeThatFits:CGSizeMake(300.0, kTopBarReaderHeight)].width);
        readerWidth = 18.0 + 24.0 + 8.0 + labelWidth + 20.0;
        CGAffineTransform readerTransform = self.readerFocusButton.transform;
        self.readerFocusButton.transform = CGAffineTransformIdentity;
        self.readerFocusButton.frame = CGRectMake(CGRectGetWidth(bounds) - kTopBarReaderInset - readerWidth,
                                                  floor((CGRectGetHeight(bounds) - kTopBarReaderHeight) / 2.0),
                                                  readerWidth, kTopBarReaderHeight);
        self.readerIconView.frame = CGRectMake(18.0, 0.0, 24.0, kTopBarReaderHeight);
        self.readerLabel.frame = CGRectMake(18.0 + 24.0 + 8.0, 0.0, labelWidth, kTopBarReaderHeight);
        self.readerFocusButton.transform = readerTransform;
    }
    // The title stays centred, so it keeps the same room on both sides of the Reader button.
    CGFloat textInset = MAX(kTopBarCenterTextInset, readerWidth > 0.0 ? readerWidth + kTopBarReaderInset + 12.0 : 0.0);
    CGFloat textWidth = MAX(0.0, CGRectGetWidth(bounds) - (textInset * 2.0));
    CGFloat titleHeight = ceil(self.URLLabel.font.lineHeight);
    CGFloat subtitleHeight = ceil(self.subtitleLabel.font.lineHeight);
    CGFloat blockHeight = titleHeight + kTopBarCenterLineSpacing + subtitleHeight;
    CGFloat textY = floor((CGRectGetHeight(bounds) - blockHeight) / 2.0);

    self.centerFocusFillView.frame = bounds;
    self.URLLabel.frame = CGRectMake(textInset, textY, textWidth, titleHeight);
    self.subtitleLabel.frame = CGRectMake(textInset,
                                          CGRectGetMaxY(self.URLLabel.frame) + kTopBarCenterLineSpacing,
                                          textWidth,
                                          subtitleHeight);
    self.loadingSpinner.frame = CGRectMake(0.0, 0.0, 1.0, 1.0);
    self.URLFocusButton.frame = readerWidth > 0.0 ? CGRectMake(0.0, 0.0, CGRectGetWidth(bounds) - readerWidth - kTopBarReaderInset, CGRectGetHeight(bounds))
                                                  : bounds;
    [self layoutProgressView];
}

- (void)layoutProgressView {
    CGRect bounds = self.centerEffectView.contentView.bounds;
    CGFloat fraction = MIN(MAX(self.progressFraction, 0.0), 1.0);
    self.progressView.frame = CGRectMake(0.0,
                                         CGRectGetHeight(bounds) - kTopBarProgressHeight,
                                         floor(CGRectGetWidth(bounds) * fraction),
                                         kTopBarProgressHeight);
}

- (CGRect)interactiveFrameForView:(UIView *)view {
    return [self convertRect:view.bounds fromView:view];
}

#pragma mark Content

- (void)setOverrideTitle:(NSString *)title subtitle:(NSString *)subtitle {
    if (title != nil) {
        if (!self.overrideTitleActive) {
            self.stashedTitleText = self.URLLabel.text ?: @"";
            self.stashedSubtitleText = self.subtitleText ?: @"";
            self.stashedSubtitleSecure = self.subtitleSecure;
            self.overrideTitleActive = YES;
        }
        self.URLLabel.text = title;
        self.subtitleText = subtitle ?: @"";
        self.subtitleSecure = NO;
    } else if (self.overrideTitleActive) {
        self.overrideTitleActive = NO;
        self.URLLabel.text = self.stashedTitleText ?: @"";
        self.subtitleText = self.stashedSubtitleText ?: @"";
        self.subtitleSecure = self.stashedSubtitleSecure;
    }
    [self refreshSubtitle];
}

- (void)setOverrideTitle:(NSString *)title subtitle:(NSString *)subtitle symbolName:(NSString *)symbolName {
    [self setOverrideTitle:title subtitle:subtitle];
    UIImage *symbol = (title != nil && symbolName.length > 0)
        ? [[self symbolImageNamed:symbolName pointSize:22.0] imageWithTintColor:UIColor.systemOrangeColor renderingMode:UIImageRenderingModeAlwaysOriginal] : nil;
    if (symbol == nil) {
        return;
    }
    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = symbol;
    CGFloat capHeight = self.URLLabel.font.capHeight;
    attachment.bounds = CGRectMake(0.0, floor((capHeight - symbol.size.height) / 2.0), symbol.size.width, symbol.size.height);
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:title]]];
    [text addAttribute:NSFontAttributeName value:self.URLLabel.font range:NSMakeRange(0, text.length)];
    self.URLLabel.attributedText = text;
    [self setNeedsLayout];
}

- (void)setPageTitle:(NSString *)title URLString:(NSString *)URLString {
    NSString *trimmedTitle = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if ([trimmedTitle isEqualToString:@"New Tab"]) {
        trimmedTitle = @"";
    }

    NSString *address = URLString ?: @"";
    NSURL *URL = address.length > 0 ? [NSURL URLWithString:address] : nil;
    NSString *host = URL.host ?: @"";
    if ([host.lowercaseString hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    BOOL secure = [URL.scheme.lowercaseString isEqualToString:@"https"];

    NSString *titleText = nil;
    NSString *subtitleText = nil;
    BOOL subtitleSecure = NO;
    if (address.length == 0) {
        titleText = BrowserLocalized(@"New Tab");
        subtitleText = BrowserLocalized(@"Enter address or search");
    } else if (trimmedTitle.length > 0) {
        titleText = trimmedTitle;
        subtitleText = host.length > 0 ? host : address;
        subtitleSecure = secure;
    } else {
        titleText = host.length > 0 ? host : address;
        subtitleText = address;
        subtitleSecure = secure;
    }

    if (self.overrideTitleActive) {
        // Settings are open: remember the page, show it again when they close.
        self.stashedTitleText = titleText;
        self.stashedSubtitleText = subtitleText;
        self.stashedSubtitleSecure = subtitleSecure;
        return;
    }
    self.URLLabel.text = titleText;
    self.subtitleText = subtitleText;
    self.subtitleSecure = subtitleSecure;

    self.URLFocusButton.accessibilityValue = address.length > 0 ? address : nil;
    [self refreshSubtitle];
}

- (void)refreshSubtitle {
    UIColor *color = [self subtitleColorFocused:self.centerFocused];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];

    if (self.subtitleSecure) {
        UIImage *lockImage = [[self symbolImageNamed:@"lock.fill" pointSize:13.0] imageWithTintColor:color
                                                                                        renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (lockImage != nil) {
            NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
            attachment.image = lockImage;
            CGFloat capHeight = self.subtitleLabel.font.capHeight;
            attachment.bounds = CGRectMake(0.0,
                                           floor((capHeight - lockImage.size.height) / 2.0),
                                           lockImage.size.width,
                                           lockImage.size.height);
            [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
        }
    }

    [text appendAttributedString:[[NSAttributedString alloc] initWithString:self.subtitleText ?: @""]];
    [text addAttributes:@{
        NSFontAttributeName: self.subtitleLabel.font,
        NSForegroundColorAttributeName: color
    } range:NSMakeRange(0, text.length)];

    self.subtitleLabel.attributedText = text;
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
}

- (void)setTabCount:(NSUInteger)tabCount {
    self.tabCountLabel.text = tabCount > 99 ? @"99+" : [NSString stringWithFormat:@"%lu", (unsigned long)tabCount];
    self.tabCountLabel.hidden = tabCount == 0;
    self.tabsFocusButton.iconView.hidden = tabCount > 0; // the two squares with the number replace the symbol
    self.tabBackSquareLayer.hidden = tabCount == 0;
    self.tabsFocusButton.accessibilityValue = tabCount > 0 ? [NSString stringWithFormat:BrowserLocalized(@"%lu open"), (unsigned long)tabCount] : nil;
}

- (void)applyFeedLook {
    // Orange when the page offers a feed (subscribe), grey otherwise (opens the feeds overview).
    self.feedFocusButton.backgroundColor = self.feedAvailable ? UIColor.systemOrangeColor : [UIColor colorWithWhite:0.42 alpha:0.6];
    self.feedFocusButton.iconView.tintColor = UIColor.whiteColor;
    self.feedFocusButton.accessibilityLabel = self.feedAvailable ? BrowserLocalized(@"Subscribe to Feed") : BrowserLocalized(@"Feeds");
}

- (void)setReaderAvailable:(BOOL)readerAvailable feedAvailable:(BOOL)feedAvailable {
    if (_readerAvailable == readerAvailable && _feedAvailable == feedAvailable) {
        return;
    }
    BOOL readerChanged = (_readerAvailable != readerAvailable);
    _readerAvailable = readerAvailable;
    _feedAvailable = feedAvailable;
    if (readerAvailable) {
        self.readerFocusButton.hidden = NO;
    }
    [self setNeedsLayout];
    [UIView animateWithDuration:0.25 animations:^{
        [self applyFeedLook];
        if (readerChanged) {
            self.readerFocusButton.alpha = readerAvailable ? 1.0 : 0.0;
        }
        [self layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        self.readerFocusButton.hidden = !self.readerAvailable;
    }];
}

- (void)setCanGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward {
    self.backFocusButton.iconView.alpha = canGoBack ? 1.0 : kTopBarDisabledIconAlpha;
    self.forwardFocusButton.iconView.alpha = canGoForward ? 1.0 : kTopBarDisabledIconAlpha;
}

#pragma mark Loading

- (void)setLoading:(BOOL)loading {
    if (_loading == loading) {
        return;
    }
    _loading = loading;

    [self.progressView.layer removeAllAnimations];

    if (loading) {
        // There is no real progress value, so creep towards 85 % like Safari does.
        self.progressFraction = 0.08;
        [self layoutProgressView];
        self.progressView.alpha = 1.0;
        [UIView animateWithDuration:6.0
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            self.progressFraction = 0.85;
            [self layoutProgressView];
        } completion:nil];
        return;
    }

    [UIView animateWithDuration:0.25
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.progressFraction = 1.0;
        [self layoutProgressView];
    } completion:^(__unused BOOL finished) {
        if (self.loading) {
            return;
        }
        [UIView animateWithDuration:0.3 animations:^{
            self.progressView.alpha = 0.0;
        } completion:^(__unused BOOL fadeFinished) {
            if (!self.loading) {
                self.progressFraction = 0.0;
                [self layoutProgressView];
            }
        }];
    }];
}

#pragma mark Focus

- (void)updateFocusAllowed {
    for (BrowserTopBarFocusButton *button in self.focusButtons) {
        button.focusAllowed = self.focusModeActive;
    }
}

- (void)setFocusModeActive:(BOOL)focusModeActive {
    if (_focusModeActive == focusModeActive) {
        return;
    }

    _focusModeActive = focusModeActive;
    [self updateFocusAllowed];

    if (!focusModeActive) {
        self.lastFocusedButton = nil;
        for (BrowserTopBarFocusButton *button in self.focusButtons) {
            [self applyFocusAppearanceToButton:button focused:NO];
        }
    }
    [self setNeedsLayout];
}

- (UIView *)preferredFocusItem {
    if (!self.focusModeActive) {
        return nil;
    }
    return self.lastFocusedButton ?: self.URLFocusButton;
}

- (void)applyFocusAppearanceToButton:(BrowserTopBarFocusButton *)button focused:(BOOL)focused {
    if (button == nil) {
        return;
    }

    if (button == self.URLFocusButton) {
        self.centerFocused = focused;
        self.centerFocusFillView.alpha = focused ? 1.0 : 0.0;
        self.URLLabel.textColor = focused ? [self focusedTintColor] : [self idleTintColor];
        self.centerContainerView.transform = focused ? CGAffineTransformMakeScale(kTopBarCenterFocusedScale, kTopBarCenterFocusedScale)
                                                     : CGAffineTransformIdentity;
        [self refreshSubtitle];
        return;
    }

    if (button == self.readerFocusButton) {
        // Stays inside the pill: no growing, just the tvOS blue when focused.
        UIColor *content = focused ? UIColor.whiteColor : [UIColor colorWithWhite:0.11 alpha:1.0];
        button.backgroundColor = focused ? UIColor.systemBlueColor : UIColor.whiteColor;
        self.readerLabel.textColor = content;
        self.readerIconView.tintColor = content;
        return;
    }
    if (button == self.feedFocusButton) {
        button.transform = focused ? CGAffineTransformMakeScale(kTopBarFocusedButtonScale, kTopBarFocusedButtonScale) : CGAffineTransformIdentity;
        button.layer.borderWidth = focused ? 3.0 : 0.0;
        button.layer.shadowOpacity = focused ? 0.45 : 0.25;
        return;
    }

    button.backgroundColor = focused ? [self focusFillColor] : UIColor.clearColor;
    button.transform = focused ? CGAffineTransformMakeScale(kTopBarFocusedButtonScale, kTopBarFocusedButtonScale)
                               : CGAffineTransformIdentity;
    button.iconView.tintColor = focused ? [self focusedTintColor] : [self idleTintColor];
    if (button == self.tabsFocusButton) {
        UIColor *countColor = focused ? [self focusedTintColor] : [self idleTintColor];
        self.tabCountLabel.textColor = countColor;
        self.tabCountLabel.layer.borderColor = countColor.CGColor;
        self.tabBackSquareLayer.strokeColor = countColor.CGColor;
    }
}

- (void)handleFocusButtonPrimaryAction:(BrowserTopBarFocusButton *)button {
    id<BrowserTopBarViewDelegate> delegate = self.delegate;
    if (delegate == nil) {
        return;
    }
    [delegate browserTopBarView:self didTriggerAction:button.topBarAction];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];

    BrowserTopBarFocusButton *nextFocusedButton = [context.nextFocusedView isKindOfClass:[BrowserTopBarFocusButton class]] ? (BrowserTopBarFocusButton *)context.nextFocusedView : nil;
    BrowserTopBarFocusButton *previousFocusedButton = [context.previouslyFocusedView isKindOfClass:[BrowserTopBarFocusButton class]] ? (BrowserTopBarFocusButton *)context.previouslyFocusedView : nil;

    if (nextFocusedButton != nil) {
        self.lastFocusedButton = nextFocusedButton;
    }

    BOOL showNextFocus = self.focusModeActive && nextFocusedButton != nil;
    [coordinator addCoordinatedAnimations:^{
        if (previousFocusedButton != nextFocusedButton) {
            [self applyFocusAppearanceToButton:previousFocusedButton focused:NO];
        }
        [self applyFocusAppearanceToButton:nextFocusedButton focused:showNextFocus];
    } completion:nil];
}

@end
