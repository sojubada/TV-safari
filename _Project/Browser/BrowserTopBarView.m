#import "BrowserTopBarView.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

static CGFloat const kTopBarHorizontalInset = 40.0;
static CGFloat const kTopBarVerticalInset = 8.0;
static CGFloat const kTopBarHeight = 86.0;
static CGFloat const kTopBarMaxWidth = 1760.0;
static CGFloat const kTopBarIconSize = 52.0;
static CGFloat const kTopBarLeadingPadding = 28.0;
static CGFloat const kTopBarTrailingPadding = 26.0;
static CGFloat const kTopBarIconSpacing = 24.0;
static CGFloat const kTopBarLabelSpacing = 20.0;
static CGFloat const kTopBarSpinnerSpacing = 22.0;
static CGFloat const kTopBarFocusHighlightInset = 10.0;
static CGFloat const kTopBarUniformFocusHeight = 72.0;
static CGFloat const kTopBarSymbolPointSize = 34.0;
static CGFloat const kTopBarSeparatorWidth = 2.0;
static CGFloat const kTopBarSeparatorHeight = 38.0;
static CGFloat const kTopBarSeparatorSpacing = 20.0;

@interface BrowserTopBarFocusButton : UIButton

@property (nonatomic) BrowserTopBarAction topBarAction;

@end

@implementation BrowserTopBarFocusButton

- (BOOL)canBecomeFocused {
    return self.enabled && !self.hidden && self.alpha > 0.01;
}

- (UIFocusSoundIdentifier)soundIdentifierForFocusUpdateInContext:(__unused UIFocusUpdateContext *)context {
    return UIFocusSoundIdentifierDefault;
}

@end

@interface BrowserTopBarView ()

@property (nonatomic) UIView *chromeContainerView;
@property (nonatomic) UIVisualEffectView *chromeEffectView;
@property (nonatomic) UIImageView *exitImageView;
@property (nonatomic) UIView *exitSeparatorView;
@property (nonatomic) UIImageView *backImageView;
@property (nonatomic) UIImageView *refreshImageView;
@property (nonatomic) UIImageView *forwardImageView;
@property (nonatomic) UIImageView *homeImageView;
@property (nonatomic) UIImageView *tabsImageView;
@property (nonatomic) UIImageView *settingsImageView;
@property (nonatomic) UIImageView *privacyImageView;
@property (nonatomic) UIImageView *readingImageView;
@property (nonatomic) UIImageView *bookmarksImageView;
@property (nonatomic) UIImageView *fullscreenImageView;
@property (nonatomic) UIImageView *menuImageView;
@property (nonatomic) UILabel *URLLabel;
@property (nonatomic) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic) UIView *focusGlowView;
@property (nonatomic) UIView *focusHighlightView;
@property (nonatomic) NSArray<BrowserTopBarFocusButton *> *focusButtons;
@property (nonatomic) BrowserTopBarFocusButton *exitFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *backFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *refreshFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *forwardFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *homeFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *tabsFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *URLFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *settingsFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *privacyFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *readingFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *bookmarksFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *fullscreenFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *menuFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *lastFocusedButton;
@property (nonatomic, getter=isFocusModeActive) BOOL focusModeActive;

@end

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

    for (UIView *subview in [self.contentView.subviews copy]) {
        if (subview != self.chromeContainerView) {
            [subview removeFromSuperview];
        }
    }
}

- (void)commonInit {
    self.effect = nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.userInteractionEnabled = YES;
    self.contentView.clipsToBounds = NO;

    self.chromeContainerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.chromeContainerView.backgroundColor = UIColor.clearColor;
    self.chromeContainerView.userInteractionEnabled = YES;
    self.chromeContainerView.clipsToBounds = NO;
    [self.contentView addSubview:self.chromeContainerView];

    self.chromeEffectView = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.chromeEffectView.userInteractionEnabled = YES;
    self.chromeEffectView.clipsToBounds = YES;
    [self.chromeContainerView addSubview:self.chromeEffectView];

    self.focusGlowView = [[UIView alloc] initWithFrame:CGRectZero];
    self.focusGlowView.backgroundColor = UIColor.clearColor;
    self.focusGlowView.userInteractionEnabled = NO;
    self.focusGlowView.hidden = YES;
    self.focusGlowView.layer.shadowColor = [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0].CGColor;
    self.focusGlowView.layer.shadowOffset = CGSizeZero;
    self.focusGlowView.layer.shadowOpacity = 0.0;
    self.focusGlowView.layer.shadowRadius = 18.0;
    [self.chromeContainerView insertSubview:self.focusGlowView belowSubview:self.chromeEffectView];

    self.focusHighlightView = [[UIView alloc] initWithFrame:CGRectZero];
    self.focusHighlightView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    self.focusHighlightView.layer.cornerRadius = 22.0;
    self.focusHighlightView.alpha = 0.0;
    self.focusHighlightView.hidden = YES;
    self.focusHighlightView.userInteractionEnabled = NO;
    [self.chromeEffectView.contentView addSubview:self.focusHighlightView];

    _exitImageView = [self newIconViewWithSymbolName:@"power" fallbackImageNamed:nil];
    _backImageView = [self newIconViewWithSymbolName:@"chevron.backward" fallbackImageNamed:@"go-back-left-arrow"];
    _refreshImageView = [self newIconViewWithSymbolName:@"arrow.clockwise" fallbackImageNamed:@"refresh-button"];
    _forwardImageView = [self newIconViewWithSymbolName:@"chevron.forward" fallbackImageNamed:@"right-arrow-forward"];
    _homeImageView = [self newIconViewWithSymbolName:@"house" fallbackImageNamed:@"house-outline"];
    _tabsImageView = [self newIconViewWithSymbolName:@"square.on.square" fallbackImageNamed:@"multi-tab"];
    _settingsImageView = [self newIconViewWithSymbolName:@"gearshape" fallbackImageNamed:nil];
    _privacyImageView = [self newIconViewWithSymbolName:@"shield" fallbackImageNamed:nil];
    _readingImageView = [self newIconViewWithSymbolName:@"textformat.size" fallbackImageNamed:nil];
    _bookmarksImageView = [self newIconViewWithSymbolName:@"star" fallbackImageNamed:nil];
    _fullscreenImageView = [self newIconViewWithSymbolName:@"arrow.up.left.and.arrow.down.right" fallbackImageNamed:@"resize-arrows"];
    _menuImageView = [self newIconViewWithSymbolName:@"ellipsis.circle" fallbackImageNamed:@"menu-2"];

    _exitSeparatorView = [[UIView alloc] initWithFrame:CGRectZero];
    _exitSeparatorView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    _exitSeparatorView.layer.cornerRadius = kTopBarSeparatorWidth / 2.0;
    _exitSeparatorView.userInteractionEnabled = NO;
    [self.chromeEffectView.contentView addSubview:_exitSeparatorView];

    _URLLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _URLLabel.text = @"tvOS Browser";
    _URLLabel.textAlignment = NSTextAlignmentCenter;
    _URLLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    _URLLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _URLLabel.adjustsFontSizeToFitWidth = NO;
    _URLLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.chromeEffectView.contentView addSubview:_URLLabel];

    _loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingSpinner.color = [UIColor colorWithWhite:1.0 alpha:0.92];
    _loadingSpinner.tintColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _loadingSpinner.hidesWhenStopped = YES;
    [self.chromeEffectView.contentView addSubview:_loadingSpinner];

    NSArray<UIImageView *> *iconViews = @[
        _exitImageView,
        _backImageView,
        _refreshImageView,
        _forwardImageView,
        _homeImageView,
        _tabsImageView,
        _settingsImageView,
        _privacyImageView,
        _readingImageView,
        _bookmarksImageView,
        _fullscreenImageView,
        _menuImageView
    ];
    for (UIImageView *imageView in iconViews) {
        [self.chromeEffectView.contentView addSubview:imageView];
    }

    _exitFocusButton = [self newFocusButtonForAction:BrowserTopBarActionExit accessibilityLabel:@"Quit Browser"];
    _backFocusButton = [self newFocusButtonForAction:BrowserTopBarActionBack accessibilityLabel:@"Back"];
    _refreshFocusButton = [self newFocusButtonForAction:BrowserTopBarActionRefresh accessibilityLabel:@"Reload"];
    _forwardFocusButton = [self newFocusButtonForAction:BrowserTopBarActionForward accessibilityLabel:@"Forward"];
    _homeFocusButton = [self newFocusButtonForAction:BrowserTopBarActionHome accessibilityLabel:@"Home"];
    _tabsFocusButton = [self newFocusButtonForAction:BrowserTopBarActionTabs accessibilityLabel:@"Tabs"];
    _URLFocusButton = [self newFocusButtonForAction:BrowserTopBarActionURL accessibilityLabel:@"Enter URL or Search"];
    _settingsFocusButton = [self newFocusButtonForAction:BrowserTopBarActionSettings accessibilityLabel:@"Settings"];
    _privacyFocusButton = [self newFocusButtonForAction:BrowserTopBarActionPrivacy accessibilityLabel:@"Privacy and Blocking"];
    _readingFocusButton = [self newFocusButtonForAction:BrowserTopBarActionReading accessibilityLabel:@"Reading and Text Size"];
    _bookmarksFocusButton = [self newFocusButtonForAction:BrowserTopBarActionBookmarks accessibilityLabel:@"Favorites and History"];
    _fullscreenFocusButton = [self newFocusButtonForAction:BrowserTopBarActionFullscreen accessibilityLabel:@"Top Navigation Visibility"];
    _menuFocusButton = [self newFocusButtonForAction:BrowserTopBarActionMenu accessibilityLabel:@"Menu"];
    _focusButtons = @[
        _exitFocusButton,
        _backFocusButton,
        _refreshFocusButton,
        _forwardFocusButton,
        _homeFocusButton,
        _tabsFocusButton,
        _URLFocusButton,
        _settingsFocusButton,
        _privacyFocusButton,
        _readingFocusButton,
        _bookmarksFocusButton,
        _fullscreenFocusButton,
        _menuFocusButton
    ];
    for (BrowserTopBarFocusButton *button in _focusButtons) {
        [self.chromeEffectView.contentView addSubview:button];
    }

    [self applyVisualStyle];
    [self setFocusModeActive:NO];
}

// One symbol family at one weight and one point size, so the row reads as a
// set instead of eight separately drawn PNGs. The bundled art stays as the
// fallback for anything the running tvOS does not have a symbol for.
- (UIImageView *)newIconViewWithSymbolName:(NSString *)symbolName
                        fallbackImageNamed:(NSString *)fallbackImageName {
    UIImage *image = nil;
    if (symbolName.length > 0) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:kTopBarSymbolPointSize
                                                            weight:UIImageSymbolWeightSemibold];
        image = [UIImage systemImageNamed:symbolName withConfiguration:configuration];
    }

    BOOL usingSymbol = image != nil;
    if (image == nil && fallbackImageName.length > 0) {
        image = [UIImage imageNamed:fallbackImageName];
    }

    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.userInteractionEnabled = NO;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    if (usingSymbol) {
        imageView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        imageView.alpha = 1.0;
    } else {
        imageView.alpha = 0.95;
    }
    return imageView;
}

- (BrowserTopBarFocusButton *)newFocusButtonForAction:(BrowserTopBarAction)action
                                   accessibilityLabel:(NSString *)accessibilityLabel {
    BrowserTopBarFocusButton *button = [BrowserTopBarFocusButton buttonWithType:UIButtonTypeCustom];
    button.topBarAction = action;
    button.backgroundColor = UIColor.clearColor;
    button.hidden = YES;
    button.enabled = NO;
    button.accessibilityLabel = accessibilityLabel;
    button.accessibilityTraits = UIAccessibilityTraitButton;
    [button addTarget:self action:@selector(handleFocusButtonPrimaryAction:) forControlEvents:UIControlEventPrimaryActionTriggered];
    return button;
}

- (void)applyVisualStyle {
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        self.effect = nil;

        UIGlassEffect *glassEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        glassEffect.interactive = YES;
        glassEffect.tintColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        self.chromeEffectView.effect = glassEffect;
        self.chromeEffectView.alpha = 1.0;
        self.chromeContainerView.layer.shadowOpacity = 0.0;
        self.chromeContainerView.layer.shadowOffset = CGSizeZero;
        self.chromeContainerView.layer.shadowRadius = 0.0;
        self.chromeContainerView.layer.borderWidth = 0.0;
        return;
    }
#endif

    self.effect = nil;
    self.chromeEffectView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.chromeEffectView.alpha = 0.98;
    self.chromeContainerView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.chromeContainerView.layer.shadowOpacity = 0.28;
    self.chromeContainerView.layer.shadowOffset = CGSizeMake(0.0, 12.0);
    self.chromeContainerView.layer.shadowRadius = 22.0;
    self.chromeContainerView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    self.chromeContainerView.layer.borderWidth = 1.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    self.contentView.frame = self.bounds;

    CGFloat width = MIN(CGRectGetWidth(self.bounds) - (kTopBarHorizontalInset * 2.0), kTopBarMaxWidth);
    width = MAX(width, 860.0);
    CGFloat originX = floor((CGRectGetWidth(self.bounds) - width) / 2.0);
    CGRect chromeFrame = CGRectMake(originX, kTopBarVerticalInset, width, kTopBarHeight);

    self.chromeContainerView.frame = chromeFrame;
    self.chromeContainerView.layer.cornerRadius = chromeFrame.size.height / 2.0;
    self.chromeContainerView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.chromeContainerView.bounds
                                                                           cornerRadius:self.chromeContainerView.layer.cornerRadius].CGPath;

    self.chromeEffectView.frame = self.chromeContainerView.bounds;
    self.chromeEffectView.layer.cornerRadius = self.chromeContainerView.layer.cornerRadius;

    CGFloat iconY = floor((CGRectGetHeight(chromeFrame) - kTopBarIconSize) / 2.0);
    CGFloat leftX = kTopBarLeadingPadding;

    // Quit sits at the far left, fenced off by a hairline so it is never
    // mistaken for part of the navigation group next to it.
    self.exitImageView.frame = CGRectMake(leftX, iconY, kTopBarIconSize, kTopBarIconSize);
    leftX = CGRectGetMaxX(self.exitImageView.frame) + kTopBarSeparatorSpacing;
    self.exitSeparatorView.frame = CGRectMake(leftX,
                                              floor((CGRectGetHeight(chromeFrame) - kTopBarSeparatorHeight) / 2.0),
                                              kTopBarSeparatorWidth,
                                              kTopBarSeparatorHeight);
    leftX = CGRectGetMaxX(self.exitSeparatorView.frame) + kTopBarSeparatorSpacing;

    NSArray<UIImageView *> *leftIcons = @[
        self.backImageView,
        self.refreshImageView,
        self.forwardImageView,
        self.homeImageView,
        self.tabsImageView
    ];
    for (UIImageView *imageView in leftIcons) {
        imageView.frame = CGRectMake(leftX, iconY, kTopBarIconSize, kTopBarIconSize);
        leftX += kTopBarIconSize + kTopBarIconSpacing;
    }

    CGFloat rightX = CGRectGetWidth(chromeFrame) - kTopBarTrailingPadding - kTopBarIconSize;
    self.menuImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.menuImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.fullscreenImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.fullscreenImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.bookmarksImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.bookmarksImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.readingImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.readingImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.privacyImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.privacyImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.settingsImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    CGFloat spinnerSide = 34.0;
    rightX = CGRectGetMinX(self.settingsImageView.frame) - kTopBarSpinnerSpacing - spinnerSide;
    self.loadingSpinner.frame = CGRectMake(rightX,
                                           floor((CGRectGetHeight(chromeFrame) - spinnerSide) / 2.0),
                                           spinnerSide,
                                           spinnerSide);

    CGFloat labelOriginX = CGRectGetMaxX(self.tabsImageView.frame) + kTopBarLabelSpacing;
    CGFloat labelTrailingX = CGRectGetMinX(self.loadingSpinner.frame) - kTopBarLabelSpacing;
    CGFloat labelWidth = MAX(160.0, labelTrailingX - labelOriginX);
    self.URLLabel.frame = CGRectMake(labelOriginX,
                                     0.0,
                                     labelWidth,
                                     CGRectGetHeight(chromeFrame));

    self.exitFocusButton.frame = [self focusFrameForIconView:self.exitImageView];
    self.backFocusButton.frame = [self focusFrameForIconView:self.backImageView];
    self.refreshFocusButton.frame = [self focusFrameForIconView:self.refreshImageView];
    self.forwardFocusButton.frame = [self focusFrameForIconView:self.forwardImageView];
    self.homeFocusButton.frame = [self focusFrameForIconView:self.homeImageView];
    self.tabsFocusButton.frame = [self focusFrameForIconView:self.tabsImageView];
    self.URLFocusButton.frame = [self focusFrameForLabel:self.URLLabel];
    self.settingsFocusButton.frame = [self focusFrameForIconView:self.settingsImageView];
    self.privacyFocusButton.frame = [self focusFrameForIconView:self.privacyImageView];
    self.readingFocusButton.frame = [self focusFrameForIconView:self.readingImageView];
    self.bookmarksFocusButton.frame = [self focusFrameForIconView:self.bookmarksImageView];
    self.fullscreenFocusButton.frame = [self focusFrameForIconView:self.fullscreenImageView];
    self.menuFocusButton.frame = [self focusFrameForMenuIconView:self.menuImageView];

    if (!self.focusModeActive) {
        [self resetFocusVisualState];
        return;
    }

    [self updateHighlightFrameForCurrentFocus];
}

- (CGRect)interactiveFrameForView:(UIView *)view {
    return [self convertRect:view.bounds fromView:view];
}

- (CGFloat)screenCenterXForAction:(BrowserTopBarAction)action {
    UIView *icon = [self iconViewForAction:action];
    if (icon == nil) {
        return 0.0;
    }
    CGRect frameInWindow = [icon convertRect:icon.bounds toView:nil];
    return CGRectGetMidX(frameInWindow);
}

- (CGRect)uniformFocusFrameForRect:(CGRect)frame horizontalInset:(CGFloat)horizontalInset {
    CGFloat normalizedHeight = MIN(kTopBarUniformFocusHeight, CGRectGetHeight(self.chromeEffectView.bounds));
    CGFloat originY = floor((CGRectGetHeight(self.chromeEffectView.bounds) - normalizedHeight) / 2.0);
    frame.origin.x -= horizontalInset;
    frame.size.width += horizontalInset * 2.0;
    frame.origin.y = originY;
    frame.size.height = normalizedHeight;
    return CGRectIntegral(frame);
}

- (CGRect)focusFrameForIconView:(UIView *)view {
    CGRect frame = view.frame;
    return [self uniformFocusFrameForRect:frame horizontalInset:12.0];
}

- (CGRect)focusFrameForMenuIconView:(UIView *)view {
    return [self focusFrameForIconView:view];
}

- (CGRect)focusFrameForLabel:(UIView *)view {
    CGRect frame = view.frame;
    return [self uniformFocusFrameForRect:frame horizontalInset:16.0];
}

- (CGRect)highlightFrameForButton:(BrowserTopBarFocusButton *)button {
    CGRect frame = button.frame;
    frame = CGRectInset(frame, kTopBarFocusHighlightInset, 0.0);
    return CGRectIntegral(frame);
}

- (CGRect)glowFrameForButton:(BrowserTopBarFocusButton *)button {
    CGRect frame = [self highlightFrameForButton:button];
    return CGRectInset(frame, -4.0, -4.0);
}

- (void)ensureFocusGlowViewAttached {
    if (self.focusGlowView.superview == self.chromeContainerView) {
        return;
    }
    [self.focusGlowView removeFromSuperview];
    [self.chromeContainerView insertSubview:self.focusGlowView belowSubview:self.chromeEffectView];
}

// The pill is drawn behind the icons, so it is inserted below the first of
// them rather than on top.
- (void)ensureHighlightBelowIcons {
    UIView *container = self.chromeEffectView.contentView;
    if (self.focusHighlightView.superview != container) {
        [container addSubview:self.focusHighlightView];
    }
    [container insertSubview:self.focusHighlightView atIndex:0];
}

- (UIView *)iconViewForAction:(BrowserTopBarAction)action {
    switch (action) {
        case BrowserTopBarActionExit: return self.exitImageView;
        case BrowserTopBarActionBack: return self.backImageView;
        case BrowserTopBarActionRefresh: return self.refreshImageView;
        case BrowserTopBarActionForward: return self.forwardImageView;
        case BrowserTopBarActionHome: return self.homeImageView;
        case BrowserTopBarActionTabs: return self.tabsImageView;
        case BrowserTopBarActionReading: return self.readingImageView;
        case BrowserTopBarActionBookmarks: return self.bookmarksImageView;
        case BrowserTopBarActionPrivacy: return self.privacyImageView;
        case BrowserTopBarActionSettings: return self.settingsImageView;
        case BrowserTopBarActionFullscreen: return self.fullscreenImageView;
        case BrowserTopBarActionMenu: return self.menuImageView;
        case BrowserTopBarActionURL: return self.URLLabel;
    }
    return nil;
}

- (void)applyFocusAppearanceToButton:(BrowserTopBarFocusButton *)focusedButton {
    UIColor *restingTint = [UIColor colorWithWhite:1.0 alpha:0.92];
    UIColor *focusedTint = [UIColor colorWithRed:0.07 green:0.09 blue:0.10 alpha:1.0];
    UIView *focusedIcon = focusedButton != nil ? [self iconViewForAction:focusedButton.topBarAction] : nil;

    for (BrowserTopBarFocusButton *button in self.focusButtons) {
        UIView *icon = [self iconViewForAction:button.topBarAction];
        BOOL isFocused = (icon != nil && icon == focusedIcon);
        CGFloat scale = isFocused ? 1.12 : 1.0;
        icon.transform = CGAffineTransformMakeScale(scale, scale);
        if ([icon isKindOfClass:[UILabel class]]) {
            ((UILabel *)icon).textColor = isFocused ? focusedTint : [UIColor colorWithWhite:1.0 alpha:0.72];
        } else {
            icon.tintColor = isFocused ? focusedTint : restingTint;
        }
    }
}

- (void)resetFocusVisualState {
    [self.focusGlowView.layer removeAllAnimations];
    [self.focusHighlightView.layer removeAllAnimations];
    self.focusGlowView.hidden = YES;
    self.focusGlowView.alpha = 0.0;
    self.focusGlowView.frame = CGRectZero;
    self.focusGlowView.layer.shadowOpacity = 0.0;
    self.focusGlowView.layer.shadowPath = nil;

    self.focusHighlightView.hidden = YES;
    self.focusHighlightView.alpha = 0.0;
    self.focusHighlightView.frame = CGRectZero;
    [self applyFocusAppearanceToButton:nil];

    [self.focusGlowView removeFromSuperview];
    [self.layer setNeedsDisplay];
}

- (void)updateHighlightFrameForCurrentFocus {
    if (!self.focusModeActive || self.lastFocusedButton == nil || !self.lastFocusedButton.focused) {
        return;
    }
    [self showFocusDecorationForButton:self.lastFocusedButton];
}

- (void)showFocusDecorationForButton:(BrowserTopBarFocusButton *)button {
    [self ensureFocusGlowViewAttached];
    CGRect glowFrame = [self glowFrameForButton:button];
    self.focusGlowView.hidden = NO;
    self.focusGlowView.alpha = 1.0;
    self.focusGlowView.frame = glowFrame;
    self.focusGlowView.layer.cornerRadius = MIN(CGRectGetHeight(glowFrame) / 2.0, 24.0);
    self.focusGlowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.focusGlowView.bounds
                                                                     cornerRadius:self.focusGlowView.layer.cornerRadius].CGPath;
    self.focusGlowView.layer.shadowOpacity = 0.55;

    CGRect pillFrame = [self highlightFrameForButton:button];
    [self ensureHighlightBelowIcons];
    self.focusHighlightView.hidden = NO;
    self.focusHighlightView.alpha = 1.0;
    self.focusHighlightView.frame = pillFrame;
    self.focusHighlightView.layer.cornerRadius = MIN(CGRectGetHeight(pillFrame) / 2.0, 26.0);
    [self applyFocusAppearanceToButton:button];
}

- (void)setFocusModeActive:(BOOL)focusModeActive {
    if (_focusModeActive == focusModeActive) {
        return;
    }

    _focusModeActive = focusModeActive;
    for (BrowserTopBarFocusButton *button in self.focusButtons) {
        button.hidden = !focusModeActive;
        button.enabled = focusModeActive;
    }

    if (!focusModeActive) {
        self.lastFocusedButton = nil;
        [self resetFocusVisualState];
    } else {
        [self setNeedsLayout];
    }
}

- (UIView *)preferredFocusItem {
    if (!self.focusModeActive) {
        return nil;
    }
    return self.lastFocusedButton ?: self.URLFocusButton;
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

    [coordinator addCoordinatedAnimations:^{
        if (!self.focusModeActive || nextFocusedButton == nil) {
            self.focusGlowView.alpha = 0.0;
            self.focusGlowView.layer.shadowOpacity = 0.0;
            self.focusHighlightView.alpha = 0.0;
            return;
        }

        [self showFocusDecorationForButton:nextFocusedButton];
        previousFocusedButton.alpha = 1.0;
        nextFocusedButton.alpha = 1.0;
    } completion:^{
        if (!self.focusModeActive || nextFocusedButton == nil) {
            [self resetFocusVisualState];
        }
    }];
}

@end
