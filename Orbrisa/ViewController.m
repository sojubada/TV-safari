//
//  ViewController.m
//  Orbrisa
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "BrowserMenuCoordinator.h"
#import "BrowserLocalization.h"
#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserRemoteInputController.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "BrowserReaderViewController.h"
#import "BrowserFeedStore.h"
#import "BrowserFeedsViewController.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";

#pragma mark - Usage guide (Siri Remote)

typedef NS_ENUM(NSInteger, BrowserRemoteIconKind) {
    BrowserRemoteIconKindSwipe = 0,     // finger on the clickpad surface
    BrowserRemoteIconKindCenter,        // clicking the middle of the clickpad
    BrowserRemoteIconKindRingUp,
    BrowserRemoteIconKindRingDown,
    BrowserRemoteIconKindRingAll,       // clicking the ring up/down/left/right
    BrowserRemoteIconKindBack,          // the "<" back button
    BrowserRemoteIconKindPlayPause,
    BrowserRemoteIconKindRedButton
};

static UIImage *BrowserGuideSymbol(NSArray<NSString *> *names, CGFloat pointSize) {
    if (@available(tvOS 13, *)) {
        UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
        for (NSString *name in names) {
            UIImage *image = [UIImage systemImageNamed:name withConfiguration:configuration];
            if (image != nil) {
                return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            }
        }
    }
    return nil;
}

/// A small drawing of the part of the Siri Remote (silver, clickpad with ring) that is used.
@interface BrowserRemoteIconView : UIView
- (instancetype)initWithKind:(BrowserRemoteIconKind)kind badge:(nullable NSString *)badge;
@end

@implementation BrowserRemoteIconView {
    BrowserRemoteIconKind _kind;
}

- (instancetype)initWithKind:(BrowserRemoteIconKind)kind badge:(NSString *)badge {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, 96.0, 96.0)];
    if (self) {
        _kind = kind;
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.widthAnchor constraintEqualToConstant:96.0].active = YES;
        [self.heightAnchor constraintEqualToConstant:96.0].active = YES;

        UIImage *symbol = nil;
        UIColor *symbolColor = UIColor.whiteColor;
        switch (kind) {
            case BrowserRemoteIconKindSwipe:
                symbol = BrowserGuideSymbol(@[@"hand.draw.fill", @"hand.point.up.left.fill", @"arrow.up.and.down.and.arrow.left.and.right"], 30.0);
                symbolColor = [UIColor colorWithWhite:0.12 alpha:1.0];
                break;
            case BrowserRemoteIconKindBack:
                symbol = BrowserGuideSymbol(@[@"chevron.backward", @"chevron.left"], 30.0);
                break;
            case BrowserRemoteIconKindPlayPause:
                symbol = BrowserGuideSymbol(@[@"playpause.fill", @"playpause"], 28.0);
                break;
            case BrowserRemoteIconKindRedButton:
                symbol = BrowserGuideSymbol(@[@"chevron.down"], 26.0);
                break;
            default:
                break;
        }
        if (symbol != nil) {
            UIImageView *imageView = [[UIImageView alloc] initWithImage:symbol];
            imageView.tintColor = symbolColor;
            imageView.contentMode = UIViewContentModeCenter;
            imageView.frame = CGRectMake(0.0, 0.0, 96.0, 96.0);
            [self addSubview:imageView];
        }

        if (badge.length > 0) {
            UILabel *badgeLabel = [UILabel new];
            badgeLabel.text = badge;
            badgeLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
            badgeLabel.textColor = [UIColor colorWithWhite:0.1 alpha:1.0];
            badgeLabel.backgroundColor = [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0];
            badgeLabel.textAlignment = NSTextAlignmentCenter;
            badgeLabel.layer.cornerRadius = 13.0;
            badgeLabel.layer.masksToBounds = YES;
            CGSize size = [badgeLabel sizeThatFits:CGSizeMake(200.0, 26.0)];
            CGFloat width = MAX(34.0, size.width + 16.0);
            badgeLabel.frame = CGRectMake(96.0 - width + 6.0, 96.0 - 26.0, width, 26.0);
            [self addSubview:badgeLabel];
        }
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGPoint center = CGPointMake(48.0, 48.0);
    UIColor *line = [UIColor colorWithWhite:1.0 alpha:0.85];
    UIColor *body = [UIColor colorWithWhite:1.0 alpha:0.14];
    UIColor *active = UIColor.whiteColor;

    if (_kind == BrowserRemoteIconKindBack || _kind == BrowserRemoteIconKindPlayPause) {
        // Round button of the remote.
        UIBezierPath *button = [UIBezierPath bezierPathWithArcCenter:center radius:30.0 startAngle:0.0 endAngle:M_PI * 2.0 clockwise:YES];
        [[UIColor colorWithWhite:0.18 alpha:1.0] setFill];
        [button fill];
        [line setStroke];
        button.lineWidth = 2.5;
        [button stroke];
        return;
    }
    if (_kind == BrowserRemoteIconKindRedButton) {
        UIBezierPath *button = [UIBezierPath bezierPathWithArcCenter:center radius:30.0 startAngle:0.0 endAngle:M_PI * 2.0 clockwise:YES];
        [[UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0] setFill];
        [button fill];
        return;
    }

    // Clickpad: outer ring with the touch surface in the middle.
    CGFloat outer = 42.0;
    CGFloat inner = 19.0;
    UIBezierPath *pad = [UIBezierPath bezierPathWithArcCenter:center radius:outer startAngle:0.0 endAngle:M_PI * 2.0 clockwise:YES];
    [(_kind == BrowserRemoteIconKindSwipe ? [UIColor colorWithWhite:1.0 alpha:0.9] : body) setFill];
    [pad fill];
    [line setStroke];
    pad.lineWidth = 2.5;
    [pad stroke];

    if (_kind == BrowserRemoteIconKindSwipe) {
        return;
    }

    UIBezierPath *innerCircle = [UIBezierPath bezierPathWithArcCenter:center radius:inner startAngle:0.0 endAngle:M_PI * 2.0 clockwise:YES];
    innerCircle.lineWidth = 2.0;
    [line setStroke];
    [innerCircle stroke];

    if (_kind == BrowserRemoteIconKindCenter) {
        [active setFill];
        [innerCircle fill];
        return;
    }

    // Highlighted parts of the ring (up = -90°).
    NSArray<NSNumber *> *angles;
    switch (_kind) {
        case BrowserRemoteIconKindRingUp: angles = @[@(-M_PI_2)]; break;
        case BrowserRemoteIconKindRingDown: angles = @[@(M_PI_2)]; break;
        default: angles = @[@(-M_PI_2), @(0.0), @(M_PI_2), @(M_PI)]; break;
    }
    CGFloat half = (_kind == BrowserRemoteIconKindRingAll) ? 0.42 : 0.6;
    [active setFill];
    for (NSNumber *angleNumber in angles) {
        CGFloat angle = angleNumber.doubleValue;
        UIBezierPath *segment = [UIBezierPath bezierPath];
        [segment addArcWithCenter:center radius:outer - 3.0 startAngle:angle - half endAngle:angle + half clockwise:YES];
        [segment addArcWithCenter:center radius:inner + 4.0 startAngle:angle + half endAngle:angle - half clockwise:NO];
        [segment closePath];
        [segment fill];
    }
}

@end

/// Full-screen guide with every remote gesture of the browser, drawn with the Siri Remote parts.
@interface BrowserUsageGuideViewController : UIViewController
@end

@implementation BrowserUsageGuideViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (UIView *)rowWithKind:(BrowserRemoteIconKind)kind badge:(NSString *)badge title:(NSString *)title text:(NSString *)text {
    BrowserRemoteIconView *icon = [[BrowserRemoteIconView alloc] initWithKind:kind badge:badge];

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:27.0 weight:UIFontWeightSemibold];
    titleLabel.textColor = UIColor.whiteColor;

    UILabel *textLabel = [UILabel new];
    textLabel.text = text;
    textLabel.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightRegular];
    textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    textLabel.numberOfLines = 4;

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, textLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 3.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, texts]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 24.0;
    return row;
}

- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text.uppercaseString;
    label.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    return label;
}

- (UIStackView *)columnWithViews:(NSArray<UIView *> *)views {
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:views];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 16.0;
    column.alignment = UIStackViewAlignmentFill;
    return column;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    backdrop.frame = self.view.bounds;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:backdrop];
    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:dim];

    UILabel *title = [UILabel new];
    title.text = BrowserLocalized(@"Using the Siri Remote");
    title.font = [UIFont systemFontOfSize:46.0 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UIStackView *left = [self columnWithViews:@[
        [self sectionLabel:BrowserLocalized(@"Cursor & Scrolling")],
        [self rowWithKind:BrowserRemoteIconKindSwipe badge:nil
                    title:BrowserLocalized(@"Swipe on the clickpad")
                     text:BrowserLocalized(@"Moves the cursor. In scroll mode the page scrolls – scrolling down hides the bar, scrolling up brings it back.")],
        [self rowWithKind:BrowserRemoteIconKindCenter badge:nil
                    title:BrowserLocalized(@"Press the center")
                     text:BrowserLocalized(@"Clicks at the cursor. Text fields open the keyboard right away, “Search” submits.")],
        [self rowWithKind:BrowserRemoteIconKindCenter badge:@"2×"
                    title:BrowserLocalized(@"Press the center twice")
                     text:BrowserLocalized(@"Switches between cursor mode and scroll mode.")],
        [self sectionLabel:BrowserLocalized(@"Link Navigation")],
        [self rowWithKind:BrowserRemoteIconKindRingDown badge:BrowserLocalized(@"hold")
                    title:BrowserLocalized(@"Hold the bottom of the ring")
                     text:BrowserLocalized(@"Turns link navigation on or off. A white frame shows the selected link.")],
        [self rowWithKind:BrowserRemoteIconKindRingAll badge:nil
                    title:BrowserLocalized(@"Ring up / down / left / right")
                     text:BrowserLocalized(@"Jumps to the next link. At the very top it continues into the bar (or to the red button).")],
        [self rowWithKind:BrowserRemoteIconKindCenter badge:nil
                    title:BrowserLocalized(@"Press the center")
                     text:BrowserLocalized(@"Opens the selected link.")],
    ]];

    UIStackView *right = [self columnWithViews:@[
        [self sectionLabel:BrowserLocalized(@"Top Bar")],
        [self rowWithKind:BrowserRemoteIconKindRingUp badge:nil
                    title:BrowserLocalized(@"Press the top of the ring")
                     text:BrowserLocalized(@"Jumps into the bar: Back, Forward, Reload, Address, Home, Tabs, Full Screen, Menu. The bottom of the ring leaves it again.")],
        [self rowWithKind:BrowserRemoteIconKindCenter badge:nil
                    title:BrowserLocalized(@"Click the address")
                     text:BrowserLocalized(@"The keyboard opens right away. An address opens the page, anything else is searched on Google.")],
        [self rowWithKind:BrowserRemoteIconKindRedButton badge:nil
                    title:BrowserLocalized(@"Red button")
                     text:BrowserLocalized(@"When the bar is hidden (full screen), clicking the red button at the top brings it back.")],
        [self sectionLabel:BrowserLocalized(@"Buttons")],
        [self rowWithKind:BrowserRemoteIconKindBack badge:nil
                    title:BrowserLocalized(@"Back button")
                     text:BrowserLocalized(@"Goes back one page. Closes menus, the keyboard and link navigation. On the first page: quits the app.")],
        [self rowWithKind:BrowserRemoteIconKindPlayPause badge:nil
                    title:@"Play/Pause"
                     text:BrowserLocalized(@"Quick menu: forward, enter an address, reload the page.")],
        [self rowWithKind:BrowserRemoteIconKindPlayPause badge:@"2×"
                    title:BrowserLocalized(@"Press Play/Pause twice")
                     text:BrowserLocalized(@"Opens Settings with favorites, history, appearance, font size and more.")],
    ]];

    UIStackView *third = [self columnWithViews:@[
        [self sectionLabel:@"Tabs"],
        [self rowWithKind:BrowserRemoteIconKindCenter badge:nil
                    title:BrowserLocalized(@"Tab icon in the bar")
                     text:BrowserLocalized(@"Shows all tabs with their logos. Ring left/right selects, click switches, Play/Pause closes the tab.")],
        [self sectionLabel:@"Videos"],
        [self rowWithKind:BrowserRemoteIconKindCenter badge:nil
                    title:BrowserLocalized(@"Start a video")
                     text:BrowserLocalized(@"Orbrisa asks: Full Screen (Apple TV player, without ads), Choose Video or Stay on Page.")],
        [self rowWithKind:BrowserRemoteIconKindSwipe badge:nil
                    title:BrowserLocalized(@"Swipe in the player")
                     text:BrowserLocalized(@"Scrubs forward and back. Press the center to confirm, ring left/right jumps 10 seconds.")],
        [self rowWithKind:BrowserRemoteIconKindBack badge:nil
                    title:BrowserLocalized(@"Back in the player")
                     text:BrowserLocalized(@"Closes the player and takes you back to the page.")],
    ]];

    UIStackView *columns = [[UIStackView alloc] initWithArrangedSubviews:@[left, right, third]];
    columns.axis = UILayoutConstraintAxisHorizontal;
    columns.distribution = UIStackViewDistributionFillEqually;
    columns.alignment = UIStackViewAlignmentTop;
    columns.spacing = 56.0;
    columns.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:columns];

    UILabel *footer = [UILabel new];
    footer.text = BrowserLocalized(@"Press Back to close");
    footer.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightMedium];
    footer.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:footer];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:60.0],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:80.0],
        [columns.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:30.0],
        [columns.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:80.0],
        [columns.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-80.0],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-40.0],
        [footer.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press.type == UIPressTypeMenu || press.type == UIPressTypeSelect || press.type == UIPressTypePlayPause) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

#pragma mark - What's New

/// Shown once per version (first install or update), like Apple's "What's New" screens; "Weiter" leads to the usage guide.
@interface BrowserWhatsNewViewController : UIViewController
@property (nonatomic, copy) void (^continueHandler)(void);
@property (nonatomic) UIButton *continueButton;
@property (nonatomic) BOOL showsGuideHint; // NO when opened from Settings → Help
@end

@implementation BrowserWhatsNewViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _showsGuideHint = YES;
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (UIView *)featureWithSymbol:(NSString *)symbol color:(UIColor *)color title:(NSString *)title text:(NSString *)text {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:46.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]];
    icon.tintColor = color;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:76.0].active = YES;

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:31.0 weight:UIFontWeightSemibold];
    titleLabel.textColor = UIColor.whiteColor;

    UILabel *textLabel = [UILabel new];
    textLabel.text = text;
    textLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightRegular];
    textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    textLabel.numberOfLines = 2;

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, textLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 4.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, texts]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 28.0;
    return row;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    backdrop.frame = self.view.bounds;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:backdrop];
    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:dim];

    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = BrowserLocalized(@"What's New in Orbrisa");
    titleLabel.font = [UIFont systemFontOfSize:64.0 weight:UIFontWeightBold];
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *versionLabel = [UILabel new];
    NSString *releaseLabel = [NSBundle.mainBundle objectForInfoDictionaryKey:@"OrbrisaReleaseLabel"];
    NSString *shownVersion = releaseLabel.length > 0 ? [NSString stringWithFormat:@"%@ %@", version, releaseLabel] : version;
    versionLabel.text = [NSString stringWithFormat:BrowserLocalized(@"Version %@"), shownVersion];
    versionLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightMedium];
    versionLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    versionLabel.textAlignment = NSTextAlignmentCenter;

    UIStackView *features = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self featureWithSymbol:@"text.alignleft" color:UIColor.systemOrangeColor
                          title:BrowserLocalized(@"Reader Mode")
                           text:BrowserLocalized(@"Only the article – large, calm text with your own size, background and font.")],
        [self featureWithSymbol:@"dot.radiowaves.up.forward" color:UIColor.systemBlueColor
                          title:BrowserLocalized(@"RSS Feeds")
                           text:BrowserLocalized(@"Subscribe to your favourite sites and see all new articles in one place.")],
        [self featureWithSymbol:@"ladybug.fill" color:UIColor.systemGreenColor
                          title:BrowserLocalized(@"This Is a Beta")
                           text:BrowserLocalized(@"Found a bug or have an idea? Report it on GitHub – a photo of your TV helps a lot.")],
    ]];
    features.axis = UILayoutConstraintAxisVertical;
    features.spacing = 34.0;
    features.alignment = UIStackViewAlignmentLeading;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = BrowserLocalized(@"Continue");
    configuration.baseBackgroundColor = UIColor.systemBlueColor;
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(18.0, 140.0, 18.0, 140.0);
    configuration.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
        NSMutableDictionary *updated = [attributes mutableCopy];
        updated[NSFontAttributeName] = [UIFont systemFontOfSize:30.0 weight:UIFontWeightSemibold];
        return updated;
    };
    button.configuration = configuration;
    [button addTarget:self action:@selector(continueTapped) forControlEvents:UIControlEventPrimaryActionTriggered];
    self.continueButton = button;

    UILabel *hintLabel = [UILabel new];
    hintLabel.text = BrowserLocalized(@"Afterwards, Orbrisa shows you how to use the Siri Remote.");
    hintLabel.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightRegular];
    hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:(self.showsGuideHint ? @[titleLabel, versionLabel, features, button, hintLabel] : @[titleLabel, versionLabel, features, button])];
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 18.0;
    [content setCustomSpacing:60.0 afterView:versionLabel];
    [content setCustomSpacing:70.0 afterView:features];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [content.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [content.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [features.widthAnchor constraintEqualToConstant:1000.0],
    ]];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return self.continueButton != nil ? @[self.continueButton] : @[];
}

- (void)continueTapped {
    void (^handler)(void) = self.continueHandler;
    self.continueHandler = nil;
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler != nil) {
            handler();
        }
    }];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (presses.anyObject.type == UIPressTypeMenu) {
        [self continueTapped];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic, copy) NSDictionary *pageArticle;
@property (nonatomic, copy) NSString *pageArticleURL;
@property (nonatomic) BOOL pageHasFeed;
@property (nonatomic) NSUInteger pageProbeGeneration;
@property (nonatomic, copy) NSString *autoReaderURL;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;
@property (nonatomic) UIView *showTopBarButton;
@property (nonatomic) UILabel *linkNavigationHintLabel;
@property (nonatomic) BOOL showTopBarButtonSelected;
/// The bar slides up out of view while scrolling down and comes back when scrolling up (like Safari).
@property (nonatomic) NSTimer *topBarScrollTimer;
@property (nonatomic) CGFloat lastScrollPosition;
@property (nonatomic, weak) UIScrollView *lastScrollView;
@property (nonatomic, getter=isTopBarScrolledAway) BOOL topBarScrolledAway;

@end

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.definesPresentationContext = YES;
    self.scrollViewAllowBounces = YES;

    self.preferencesStore = [BrowserPreferencesStore new];
    [self.preferencesStore ensureUserAgentConsistency];

    self.viewModel = [BrowserViewModel new];
    self.viewModel.topNavigationBarVisible = self.preferencesStore.topNavigationBarVisible;
    self.viewModel.textFontSize = self.preferencesStore.textFontSize;
    self.viewModel.fullscreenVideoPlaybackEnabled = self.preferencesStore.fullscreenVideoPlaybackEnabled;

    self.domInteractionService = [BrowserDOMInteractionService new];
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
    [self.view addSubview:self.remoteInputController.cursorView];
    self.videoPlaybackCoordinator = [[BrowserVideoPlaybackCoordinator alloc] initWithHost:self
                                                                      domInteractionService:self.domInteractionService];
    self.tabCoordinator = [[BrowserTabCoordinator alloc] initWithHost:self
                                                             viewModel:self.viewModel
                                                      preferencesStore:self.preferencesStore
                                                     navigationService:self.navigationService
                                                          sessionStore:self.sessionStore
                                                    browserContainerView:self.browserContainerView
                                                              rootView:self.view
                                                            topMenuView:self.topMenuView
                                                            cursorView:self.remoteInputController.cursorView
                                               manualScrollPanRecognizer:self.remoteInputController.manualScrollPanRecognizer
                                                           webViewDelegate:self
                                                       scrollViewAllowBounces:self.scrollViewAllowBounces];
    self.tabOverviewController = [[BrowserTabOverviewController alloc] initWithHost:self
                                                                            viewModel:self.viewModel
                                                                             rootView:self.view
                                                                           topMenuView:self.topMenuView
                                                                           cursorView:self.remoteInputController.cursorView];
    self.pageActionCoordinator = [[BrowserPageActionCoordinator alloc] initWithHost:self
                                                               domInteractionService:self.domInteractionService
                                                                   navigationService:self.navigationService
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator];

    self.topMenuView.delegate = self;
    self.topMenuView.loadingSpinner.hidesWhenStopped = YES;
    [self setUpShowTopBarButton];
    self.remoteInputController.cursorView.hidden = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalSelectPressEndedNotification:)
                                                 name:kBrowserGlobalSelectPressEndedNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleOpenAppURLNotification:)
                                                 name:@"BrowserOpenAppURLNotification"
                                               object:nil];

    [self.tabCoordinator restoreInitialStateOrCreateFirstTab];

    // "Automatic" dark mode: when the Apple TV switches between light and dark, the pages follow right away.
    [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withHandler:^(__unused id<UITraitEnvironment> environment, __unused UITraitCollection *previous) {
        if (BrowserWebView.forceDarkPages && BrowserWebView.appearanceMode == 0) {
            [[NSNotificationCenter defaultCenter] postNotificationName:BrowserForceDarkPagesDidChangeNotification object:nil];
        }
    }];

    __weak typeof(self) weakSelf = self;
    self.topBarScrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf updateTopBarForScrollPosition];
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tabCoordinator webViewDidAppear];
    [BrowserWebView applyAppearanceToWindows];
    [self openPendingAppURL];
    // The tips dialog used to pop up at every launch; it stays available in Settings → Help.
    self.displayedHintsOnLaunch = YES;
    [self showWhatsNewIfNeeded];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void)dealloc {
    [self.topBarScrollTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Bar hides while scrolling

- (void)updateTopBarForScrollPosition {
    UIScrollView *scrollView = self.webview.scrollView;
    if (scrollView == nil || !self.viewModel.topNavigationBarVisible || self.topMenuView.hidden) {
        [self setTopBarScrolledAway:NO animated:NO];
        self.lastScrollView = scrollView;
        return;
    }
    // Position measured from the very top of the page (0 = start of the page, right under the bar).
    CGFloat position = scrollView.contentOffset.y + scrollView.adjustedContentInset.top;
    if (scrollView != self.lastScrollView) {
        // Another tab or a new web view: start again with the bar visible.
        self.lastScrollView = scrollView;
        self.lastScrollPosition = position;
        [self setTopBarScrolledAway:NO animated:YES];
        return;
    }
    CGFloat delta = position - self.lastScrollPosition;
    BOOL busy = self.topBarFocusActive || self.presentedViewController != nil || self.tabOverviewController.visible;

    if (busy || position < 60.0) {
        [self setTopBarScrolledAway:NO animated:YES];
        self.lastScrollPosition = position;
    } else if (delta > 14.0) {
        [self setTopBarScrolledAway:YES animated:YES];
        self.lastScrollPosition = position;
    } else if (delta < -14.0) {
        [self setTopBarScrolledAway:NO animated:YES];
        self.lastScrollPosition = position;
    } else if (fabs(delta) > 200.0) {
        self.lastScrollPosition = position;
    }
}

- (void)setTopBarScrolledAway:(BOOL)scrolledAway animated:(BOOL)animated {
    if (self.topBarScrolledAway == scrolledAway) {
        return;
    }
    self.topBarScrolledAway = scrolledAway;
    UIView *bar = self.topMenuView;
    CGFloat distance = bar.center.y + (CGRectGetHeight(bar.bounds) / 2.0) + 30.0;
    void (^changes)(void) = ^{
        bar.transform = scrolledAway ? CGAffineTransformMakeTranslation(0.0, -distance) : CGAffineTransformIdentity;
        bar.alpha = scrolledAway ? 0.0 : 1.0;
    };
    bar.userInteractionEnabled = !scrolledAway;
    if (animated) {
        [UIView animateWithDuration:0.3
                              delay:0.0
             usingSpringWithDamping:1.0
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

#pragma mark - Notifications

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
    [self.tabCoordinator updateTopShelf];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
    [self.tabCoordinator updateTopShelf];
}

/// A link from the Top Shelf (the app was already running, or it just started with one).
- (void)handleOpenAppURLNotification:(NSNotification *)notification {
    (void)notification;
    [self openPendingAppURL];
}

- (void)openPendingAppURL {
    NSString *pending = [[NSUserDefaults standardUserDefaults] stringForKey:@"BrowserPendingAppURL"];
    if (pending.length == 0 || self.tabCoordinator == nil) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"BrowserPendingAppURL"];
    [self.tabCoordinator openAppURL:[NSURL URLWithString:pending]];
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleGlobalSelectPressEndedNotification:(NSNotification *)notification {
    (void)notification;
    [self.remoteInputController handleGlobalSelectPressEndedNotification];
}

#pragma mark - Helpers

- (BrowserWebView *)webview {
    return self.tabCoordinator.activeWebView;
}

- (CGPoint)browserDOMPointForCursor {
    return [self.domInteractionService DOMPointForCursorOrigin:self.remoteInputController.cursorView.frame.origin
                                                        inView:self.view
                                                       webView:self.webview];
}

- (void)loadHomePage {
    [self.tabCoordinator loadHomePage];
}

- (void)showAdvancedMenu {
    [self deactivateTopBarFocusMode];
    [self.menuCoordinator showAdvancedMenu];
}

- (BOOL)canActivateTopBarFocusMode {
    return self.presentedViewController == nil &&
        !self.tabOverviewController.visible &&
        self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden;
}

- (void)activateTopBarFocusMode {
    if (![self canActivateTopBarFocusMode]) {
        return;
    }
    [self refreshPageFeatures];
    if (self.topBarFocusActive) {
        return;
    }
    // Going up to the bar always brings it back, even when it slid away while scrolling.
    [self setTopBarScrolledAway:NO animated:YES];

    self.topBarFocusActive = YES;
    [self.topMenuView setFocusModeActive:YES];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)deactivateTopBarFocusMode {
    if (!self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = NO;
    [self.topMenuView setFocusModeActive:NO];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)performTopBarAction:(BrowserTopBarAction)action {
    [self deactivateTopBarFocusMode];

    switch (action) {
        case BrowserTopBarActionBack:
            if (self.webview.canGoBack) {
                [self.webview goBack];
            }
            break;
        case BrowserTopBarActionRefresh:
            [self.webview reload];
            break;
        case BrowserTopBarActionForward:
            if (self.webview.canGoForward) {
                [self.webview goForward];
            }
            break;
        case BrowserTopBarActionHome:
            [self loadHomePage];
            break;
        case BrowserTopBarActionTabs:
            [self browserShowTabOverview];
            break;
        case BrowserTopBarActionURL:
            [self showInputURLorSearchGoogle];
            break;
        case BrowserTopBarActionFullscreen:
            if (self.viewModel.topNavigationBarVisible) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Hide Top Navigation Bar?")
                                                                                         message:BrowserLocalized(@"You can still open Settings by double-tapping the Play/Pause button.")
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Hide Bar")
                                                                    style:UIAlertActionStyleDestructive
                                                                  handler:^(__unused UIAlertAction *action) {
                    [self browserHideTopNav];
                }]];
                [self browserPresentViewController:alertController];
            } else {
                [self browserShowTopNav];
            }
            break;
        case BrowserTopBarActionReader:
            [self deactivateTopBarFocusMode];
            [self browserShowReader];
            break;
        case BrowserTopBarActionFeed:
            [self deactivateTopBarFocusMode];
            if (self.pageHasFeed) {
                [self browserSubscribeToPageFeed];
            } else {
                [self browserShowFeeds];
            }
            break;
        case BrowserTopBarActionMenu:
            [self showAdvancedMenu];
            break;
    }
}

- (void)updateTextFontSize {
    if (self.webview == nil) {
        return;
    }

    NSString *jsString = [[NSString alloc] initWithFormat:
                          @"(function(){"
                           "var value='%lu%%';"
                           "var multiplier=%lu/100;"
                           "if (document.documentElement && document.documentElement.style) {"
                               "document.documentElement.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.documentElement.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (document.body && document.body.style) {"
                               "document.body.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.body.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (!document.body || !window.getComputedStyle) { return value; }"
                           "var elements = document.querySelectorAll('body, body *');"
                           "for (var i = 0; i < elements.length; i++) {"
                               "var element = elements[i];"
                               "if (!element || !element.tagName) { continue; }"
                               "var tagName = element.tagName.toLowerCase();"
                               "if (tagName === 'script' || tagName === 'style' || tagName === 'noscript') { continue; }"
                               "var originalSize = element.getAttribute('data-browser-original-font-size');"
                               "if (!originalSize) {"
                                   "var computedSize = window.getComputedStyle(element).fontSize || '';"
                                   "if (computedSize.indexOf('px') == -1) { continue; }"
                                   "var parsedSize = parseFloat(computedSize);"
                                   "if (!isFinite(parsedSize) || parsedSize <= 0) { continue; }"
                                   "originalSize = String(parsedSize);"
                                   "element.setAttribute('data-browser-original-font-size', originalSize);"
                               "}"
                               "var baseSize = parseFloat(originalSize);"
                               "if (!isFinite(baseSize) || baseSize <= 0) { continue; }"
                               "element.style.setProperty('font-size', (baseSize * multiplier) + 'px', 'important');"
                           "}"
                           "return value;"
                          "})()",
                          (unsigned long)self.viewModel.textFontSize,
                          (unsigned long)self.viewModel.textFontSize];
    [self.webview stringByEvaluatingJavaScriptFromString:jsString];
}

- (void)showInputURLorSearchGoogle {
    // Straight to the Apple TV keyboard, without the "Enter URL or Search Terms" window in between.
    // An almost invisible text field: becoming first responder brings up the full-screen tvOS keyboard.
    UIView *hostView = self.view;
    if (hostView.window == nil) {
        return;
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0.0, 0.0, 2.0, 2.0)];
    textField.alpha = 0.02;
    textField.keyboardType = UIKeyboardTypeDefault;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    // The keyboard's main key reads "Search": a web address opens the site, anything else is searched on Google.
    textField.returnKeyType = UIReturnKeySearch;

    __weak typeof(self) weakSelf = self;
    __weak UITextField *weakField = textField;
    __block BOOL finished = NO;
    [textField addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        UITextField *field = weakField;
        if (field == nil || finished) {
            return;
        }
        finished = YES;
        NSString *text = [field.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [field removeFromSuperview];
        if (text.length > 0) {
            [weakSelf openAddressOrSearch:text];
        }
    }] forControlEvents:UIControlEventEditingDidEndOnExit];
    // Leaving the keyboard with the Menu button: nothing happens.
    [textField addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        UITextField *field = weakField;
        if (field == nil || finished) {
            return;
        }
        finished = YES;
        [field removeFromSuperview];
    }] forControlEvents:UIControlEventEditingDidEnd];

    [hostView addSubview:textField];
    if (![textField becomeFirstResponder]) {
        [textField removeFromSuperview];
    }
}

- (BOOL)textLooksLikeWebAddress:(NSString *)text {
    if ([text rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) {
        return NO;
    }
    NSString *lowercase = text.lowercaseString;
    if ([lowercase hasPrefix:@"http://"] || [lowercase hasPrefix:@"https://"] || [lowercase hasPrefix:@"localhost"]) {
        return YES;
    }
    // Something like "apple.com" or "srf.ch/news": a dot with letters on both sides.
    NSRange dot = [text rangeOfString:@"."];
    return dot.location != NSNotFound && dot.location > 0 && dot.location < text.length - 1;
}

- (void)openAddressOrSearch:(NSString *)text {
    NSURLRequest *request = nil;
    if ([self textLooksLikeWebAddress:text]) {
        request = [self.navigationService requestForEnteredAddressString:text];
    }
    if (request == nil) {
        request = [self.navigationService googleSearchRequestForQuery:text];
    }
    if (request != nil) {
        [self.webview loadRequest:request];
    }
}

- (void)requestURLorSearchInput {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Quick Menu")
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    if (self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Go Forward")
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self.webview goForward];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Enter Address or Search with Google")
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showInputURLorSearchGoogle];
    }]];

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Open in Reader")
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self browserShowReader];
        }]];
    }

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Reload Page")
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            self.tabCoordinator.previousURL = @"";
            [self.webview reload];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

/// First start of a new version: "What's New", then the usage guide.
- (void)showWhatsNewIfNeeded {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (version.length == 0 || [[defaults stringForKey:@"BrowserWhatsNewShownVersion"] isEqualToString:version]) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ViewController *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.presentedViewController != nil || strongSelf.view.window == nil) {
            return; // try again at the next start
        }
        [defaults setObject:version forKey:@"BrowserWhatsNewShownVersion"];
        BrowserWhatsNewViewController *whatsNew = [BrowserWhatsNewViewController new];
        whatsNew.continueHandler = ^{
            [weakSelf showHintsAlert];
        };
        [strongSelf presentViewController:whatsNew animated:YES completion:nil];
    });
}

- (void)showHintsAlert {
    BrowserUsageGuideViewController *guide = [BrowserUsageGuideViewController new];
    if (self.presentedViewController != nil) {
        __weak typeof(self) weakSelf = self;
        [self.presentedViewController dismissViewControllerAnimated:NO completion:^{
            [weakSelf presentViewController:guide animated:YES completion:nil];
        }];
        return;
    }
    [self presentViewController:guide animated:YES completion:nil];
}

- (void)browserHandlePrimaryAction {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        return;
    }

    if ([self cursorIsOverShowTopBarButton]) {
        [self browserShowTopNav];
        return;
    }

    // The page now runs underneath the floating bar, so check the bar's own area instead of the web view's top edge.
    CGPoint cursorTip = self.remoteInputController.cursorView.frame.origin;
    if (self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden &&
        !self.topBarScrolledAway &&
        cursorTip.y < CGRectGetMaxY(self.topMenuView.frame)) {
        [self activateTopBarFocusMode];
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.topBarFocusActive) {
        UIView *preferredFocusItem = [self.topMenuView preferredFocusItem];
        if (preferredFocusItem != nil) {
            return @[preferredFocusItem];
        }
    }
    return [super preferredFocusEnvironments];
}

#pragma mark - BrowserTopBarViewDelegate

- (void)browserTopBarView:(__unused BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action {
    [self performTopBarAction:action];
}

#pragma mark - BrowserMenuCoordinatorHost

- (BrowserWebView *)browserWebView {
    return self.webview;
}

- (NSString *)browserPreviousURL {
    return self.tabCoordinator.previousURL;
}

- (void)setBrowserPreviousURL:(NSString *)browserPreviousURL {
    self.tabCoordinator.previousURL = browserPreviousURL ?: @"";
}

- (NSUInteger)browserTextFontSize {
    return self.viewModel.textFontSize;
}

- (void)setBrowserTextFontSize:(NSUInteger)browserTextFontSize {
    self.viewModel.textFontSize = browserTextFontSize;
    self.preferencesStore.textFontSize = self.viewModel.textFontSize;
}

- (BOOL)browserTopMenuShowing {
    return self.viewModel.topNavigationBarVisible;
}

- (BOOL)browserFullscreenVideoPlaybackEnabled {
    return self.viewModel.fullscreenVideoPlaybackEnabled;
}

- (void)setBrowserFullscreenVideoPlaybackEnabled:(BOOL)browserFullscreenVideoPlaybackEnabled {
    self.viewModel.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
    self.preferencesStore.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
}

- (void)browserPresentViewController:(UIViewController *)viewController {
    [self deactivateTopBarFocusMode];
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserLoadHomePage {
    [self loadHomePage];
}

- (void)browserSetSettingsTitleShown:(BOOL)shown {
    // While Settings are open the address field reads "Einstellungen", like in the prototype.
    [self.topMenuView setOverrideTitle:(shown ? BrowserLocalized(@"Settings") : nil) subtitle:(shown ? @"Orbrisa" : nil)];
}

#pragma mark - Reader & feeds

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"OK") style:UIAlertActionStyleCancel handler:nil]];
    [self browserPresentViewController:alert];
}

- (void)refreshPageFeatures {
    // A quick look at the page (a few paragraphs of text? a feed link in the head?) – fast enough to run while it loads.
    if (self.webview == nil || [BrowserWebView isWaitingForPage]) {
        return;
    }
    static NSString * const probe =
        @"(function(){try{var n=0,c=0,ps=document.querySelectorAll('p');"
        @"for(var i=0;i<ps.length&&i<500;i++){var t=(ps[i].textContent||'').trim().length;if(t>=60){n++;c+=t;}}"
        @"var f=document.querySelector('link[rel~=\"alternate\"][type*=\"rss\"],link[rel~=\"alternate\"][type*=\"atom\"],link[rel~=\"alternate\"][type*=\"feed\"]');"
        @"return (n>=3&&c>=600?'1':'0')+(f?'1':'0');}catch(e){return '00';}})()";
    NSString *result = [self.webview stringByEvaluatingJavaScriptFromString:probe] ?: @"";
    BOOL reader = [result hasPrefix:@"1"];
    BOOL feed = result.length >= 2 && [result characterAtIndex:1] == '1';
    self.pageHasFeed = feed;
    [self.topMenuView setReaderAvailable:reader feedAvailable:feed];
    [self openReaderAutomaticallyIfWanted:reader];
}

- (void)openReaderAutomaticallyIfWanted:(BOOL)readerAvailable {
    // "Always Open in Reader" for this site: open each article once, as soon as its text is there.
    NSURL *URL = self.webview.request.URL;
    NSString *page = URL.absoluteString ?: @"";
    if (!readerAvailable || page.length == 0 || [self.autoReaderURL isEqualToString:page] || self.presentedViewController != nil
        || ![BrowserReaderViewController opensAutomaticallyForURL:URL]) {
        return;
    }
    NSString *script = [BrowserReaderViewController extractionScript];
    NSDictionary *article = script.length > 0
        ? [BrowserReaderViewController articleFromJavaScriptResult:[self.webview stringByEvaluatingJavaScriptFromString:script]] : nil;
    if (article == nil) {
        return; // not enough text yet – the next check tries again
    }
    self.autoReaderURL = page;
    self.pageArticle = article;
    self.pageArticleURL = page;
    [self browserPresentViewController:[[BrowserReaderViewController alloc] initWithArticle:article]];
}

- (void)schedulePageFeatureChecksForWebView:(id)webView delays:(NSArray<NSNumber *> *)delays {
    NSUInteger generation = ++self.pageProbeGeneration;
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ViewController *strongSelf = weakSelf;
            if (strongSelf == nil || generation != strongSelf.pageProbeGeneration || webView != strongSelf.webview) {
                return; // a newer page took over
            }
            [strongSelf refreshPageFeatures];
        });
    }
}

- (void)browserShowReader {
    NSString *page = self.webview.request.URL.absoluteString ?: @"";
    NSDictionary *article = (self.pageArticle != nil && [self.pageArticleURL isEqualToString:page]) ? self.pageArticle : nil;
    if (article == nil) {
        NSString *script = [BrowserReaderViewController extractionScript];
        NSString *result = (script.length > 0 && self.webview != nil) ? [self.webview stringByEvaluatingJavaScriptFromString:script] : nil;
        article = [BrowserReaderViewController articleFromJavaScriptResult:result];
    }
    if (article == nil) {
        [self showSimpleAlertWithTitle:BrowserLocalized(@"Reader Not Available")
                               message:BrowserLocalized(@"This page has no article that Orbrisa can show in the Reader.")];
        return;
    }
    [self browserPresentViewController:[[BrowserReaderViewController alloc] initWithArticle:article]];
}

- (void)browserShowFeeds {
    BrowserFeedsViewController *feeds = [BrowserFeedsViewController new];
    __weak typeof(self) weakSelf = self;
    // Like the tab overview: the top bar stays, its address field reads "Feeds · 4 new articles".
    feeds.headerChanged = ^(NSString *subtitle) {
        [weakSelf.topMenuView setOverrideTitle:(subtitle != nil ? BrowserLocalized(@"Feeds") : nil)
                                      subtitle:subtitle
                                    symbolName:@"dot.radiowaves.up.forward"];
    };
    feeds.addFeed = ^{
        [weakSelf browserSubscribeToPageFeed];
    };
    feeds.openArticle = ^(NSString *URLString) {
        NSURLRequest *request = [weakSelf.navigationService requestForURLString:URLString];
        if (request != nil) {
            [weakSelf.webview loadRequest:request];
        }
    };
    [self browserPresentViewController:feeds];
}

- (void)browserSubscribeToPageFeed {
    NSString *script = [BrowserFeedStore detectionScript];
    NSString *result = (script.length > 0 && self.webview != nil) ? [self.webview stringByEvaluatingJavaScriptFromString:script] : nil;
    id json = result.length > 0 ? [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    NSArray *feeds = ([json isKindOfClass:[NSDictionary class]] && [json[@"feeds"] isKindOfClass:[NSArray class]]) ? json[@"feeds"] : @[];
    NSString *site = ([json isKindOfClass:[NSDictionary class]] && [json[@"site"] isKindOfClass:[NSString class]]) ? json[@"site"] : @"";
    NSDictionary *feed = [feeds.firstObject isKindOfClass:[NSDictionary class]] ? feeds.firstObject : nil;
    NSString *feedURL = [feed[@"url"] isKindOfClass:[NSString class]] ? feed[@"url"] : @"";
    if (feedURL.length == 0) {
        [self showSimpleAlertWithTitle:BrowserLocalized(@"No Feed Found")
                               message:BrowserLocalized(@"This page doesn't offer an RSS feed.")];
        return;
    }

    BrowserFeedStore *store = [BrowserFeedStore sharedStore];
    __weak typeof(self) weakSelf = self;
    if ([store isSubscribedToURL:feedURL]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Already Subscribed") message:site
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Open Feeds") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf browserShowFeeds];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"OK") style:UIAlertActionStyleCancel handler:nil]];
        [self browserPresentViewController:alert];
        return;
    }

    NSString *announcedTitle = [feed[@"title"] isKindOfClass:[NSString class]] ? feed[@"title"] : @"";
    [store fetchFeedAtURL:feedURL completion:^(NSString *title, NSArray<BrowserFeedItem *> *items, __unused NSError *error) {
        ViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (items.count == 0) {
            [strongSelf showSimpleAlertWithTitle:BrowserLocalized(@"Feed Not Readable")
                                         message:BrowserLocalized(@"Orbrisa found a feed on this page, but couldn't load it.")];
            return;
        }
        NSString *name = title.length > 0 ? title : (announcedTitle.length > 0 ? announcedTitle : site);
        NSMutableString *latest = [NSMutableString string];
        for (NSUInteger i = 0; i < MIN((NSUInteger)3, items.count); i++) {
            [latest appendFormat:@"%@• %@", i > 0 ? @"\n" : @"", items[i].title];
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:BrowserLocalized(@"Feed Found: %@"), name]
                                                                       message:latest
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Subscribe") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [[BrowserFeedStore sharedStore] subscribeToURL:feedURL title:name];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Not Now") style:UIAlertActionStyleCancel handler:nil]];
        [strongSelf browserPresentViewController:alert];
    }];
}

- (void)browserShowWhatsNew {
    // From the menu: the same screen as after an update; "Weiter" closes it (no usage guide afterwards).
    BrowserWhatsNewViewController *whatsNew = [BrowserWhatsNewViewController new];
    whatsNew.showsGuideHint = NO;
    if (self.presentedViewController != nil) {
        __weak typeof(self) weakSelf = self;
        [self.presentedViewController dismissViewControllerAnimated:NO completion:^{
            [weakSelf presentViewController:whatsNew animated:YES completion:nil];
        }];
        return;
    }
    [self presentViewController:whatsNew animated:YES completion:nil];
}

- (void)browserShowHints {
    [self showHintsAlert];
}

- (void)browserShowTabOverview {
    [self deactivateTopBarFocusMode];
    [self.tabCoordinator prepareTabOverviewThumbnails];
    [self.tabOverviewController show];
}

- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserHideTopNav {
    [self deactivateTopBarFocusMode];
    self.viewModel.topNavigationBarVisible = NO;
    self.preferencesStore.topNavigationBarVisible = NO;
    [self.tabCoordinator setTopNavigationVisible:NO];
    [self updateShowTopBarButtonAnimated:YES];
}

- (void)browserShowTopNav {
    [self setShowTopBarButtonSelected:NO animated:NO];
    self.viewModel.topNavigationBarVisible = YES;
    self.preferencesStore.topNavigationBarVisible = YES;
    [self.tabCoordinator setTopNavigationVisible:YES];
    [self updateShowTopBarButtonAnimated:YES];
}

#pragma mark - Link navigation (arrow clicks jump between links)

static NSString *BrowserLinkNavigationScript(void) {
    static NSString *script = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        script =
    @"(function(cmd, topInset){\n"
    @"var N = window.__tvLinkNav;\n"
    @"if (!N) {\n"
    @"  N = window.__tvLinkNav = {cur: null};\n"
    @"}\n"
    @"if (!document.getElementById('__tvLinkNavStyle')) {\n"
    @"  var st = document.createElement('style');\n"
    @"  st.id = '__tvLinkNavStyle';\n"
    @"  st.textContent = '.__tvLinkNavFocus{outline:4px solid #FFFFFF !important;outline-offset:3px !important;border-radius:12px !important;box-shadow:0 0 0 7px rgba(0,0,0,0.55),0 18px 40px rgba(0,0,0,0.45) !important;background-color:rgba(255,255,255,0.14) !important;transition:outline-offset .15s ease, box-shadow .15s ease !important;}';\n"
    @"  (document.head || document.documentElement).appendChild(st);\n"
    @"}\n"
    @"var SELECTOR = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=option],[onclick],[tabindex]:not([tabindex=\"-1\"])';\n"
    @"function shown(el){\n"
    @"  var r = el.getBoundingClientRect();\n"
    @"  if (r.width < 4 || r.height < 4) { return false; }\n"
    @"  if (r.bottom <= 0 || r.right <= 0 || r.top >= innerHeight || r.left >= innerWidth) { return false; }\n"
    @"  var s = getComputedStyle(el);\n"
    @"  return s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity || '1') > 0.05;\n"
    @"}\n"
    @"function candidates(){ return Array.prototype.filter.call(document.querySelectorAll(SELECTOR), shown); }\n"
    @"function setCur(el){\n"
    @"  if (N.cur && N.cur.classList) { N.cur.classList.remove('__tvLinkNavFocus'); }\n"
    @"  N.cur = el;\n"
    @"  if (!el) { return; }\n"
    @"  el.classList.add('__tvLinkNavFocus');\n"
    @"  var r = el.getBoundingClientRect();\n"
    @"  var hidden = scrollY > 0 ? topInset : 0;\n"
    @"  if (r.top < hidden || r.bottom > innerHeight) { el.scrollIntoView({block: 'center', inline: 'nearest'}); }\n"
    @"}\n"
    @"function mid(r){ return {x: r.left + r.width / 2, y: r.top + r.height / 2}; }\n"
    @"if (cmd === 'clear') { setCur(null); return 'ok'; }\n"
    @"if (cmd === 'activate') {\n"
    @"  var el = N.cur;\n"
    @"  if (!el || !document.contains(el)) { return 'none'; }\n"
    @"  var r = el.getBoundingClientRect();\n"
    @"  var p = mid(r);\n"
    @"  return 'point:' + Math.round(p.x) + ',' + Math.round(p.y);\n"
    @"}\n"
    @"var list = candidates();\n"
    @"if (!N.cur || !document.contains(N.cur) || !shown(N.cur)) {\n"
    @"  if (!list.length) {\n"
    @"    if (cmd === 'down') { scrollBy(0, innerHeight * 0.6); return 'scrolled'; }\n"
    @"    if (cmd === 'up') { if (scrollY <= 0) { return 'top'; } scrollBy(0, -innerHeight * 0.6); return 'scrolled'; }\n"
    @"    return 'none';\n"
    @"  }\n"
    @"  list.sort(function(a, b){\n"
    @"    var ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();\n"
    @"    return cmd === 'up' ? ((rb.bottom - ra.bottom) || (ra.left - rb.left)) : ((ra.top - rb.top) || (ra.left - rb.left));\n"
    @"  });\n"
    @"  setCur(list[0]);\n"
    @"  return 'ok';\n"
    @"}\n"
    @"var cr = N.cur.getBoundingClientRect(), c = mid(cr), best = null, bestScore = Infinity;\n"
    @"list.forEach(function(el){\n"
    @"  if (el === N.cur || el.contains(N.cur) || N.cur.contains(el)) { return; }\n"
    @"  var r = el.getBoundingClientRect(), p = mid(r), dx = p.x - c.x, dy = p.y - c.y, along, across;\n"
    @"  if (cmd === 'down') { if (r.top < cr.bottom - 2) { return; } along = dy; across = Math.abs(dx); }\n"
    @"  else if (cmd === 'up') { if (r.bottom > cr.top + 2) { return; } along = -dy; across = Math.abs(dx); }\n"
    @"  else if (cmd === 'right') { if (r.left < cr.right - 2) { return; } along = dx; across = Math.abs(dy); }\n"
    @"  else { if (r.right > cr.left + 2) { return; } along = -dx; across = Math.abs(dy); }\n"
    @"  var score = along + across * 2.5;\n"
    @"  if (score < bestScore) { bestScore = score; best = el; }\n"
    @"});\n"
    @"if (best) { setCur(best); return 'ok'; }\n"
    @"if (cmd === 'down') {\n"
    @"  if (innerHeight + scrollY >= document.documentElement.scrollHeight - 2) { return 'edge'; }\n"
    @"  scrollBy(0, innerHeight * 0.6); return 'scrolled';\n"
    @"}\n"
    @"if (cmd === 'up') {\n"
    @"  if (scrollY <= 0) { return 'top'; }\n"
    @"  scrollBy(0, -innerHeight * 0.6); return 'scrolled';\n"
    @"}\n"
    @"return 'edge';\n"
    @"})\n";
    });
    return script;
}

- (NSString *)runLinkNavigationCommand:(NSString *)command {
    if (self.webview == nil || self.webview.request == nil) {
        return @"none";
    }
    // Part of the page sits under the floating top bar; the script keeps the highlighted link out of that strip.
    NSInteger innerWidth = [[self.webview stringByEvaluatingJavaScriptFromString:@"window.innerWidth"] integerValue];
    CGFloat scale = innerWidth > 0 ? CGRectGetWidth(self.webview.frame) / (CGFloat)innerWidth : 1.0;
    CGFloat barHeight = (self.viewModel.topNavigationBarVisible && !self.topMenuView.hidden) ? CGRectGetMaxY(self.topMenuView.frame) : 0.0;
    CGFloat topInsetCSS = scale > 0.0 ? barHeight / scale : barHeight;
    NSString *script = [NSString stringWithFormat:@"%@('%@', %.1f)", BrowserLinkNavigationScript(), command, topInsetCSS];
    return [self.webview stringByEvaluatingJavaScriptFromString:script] ?: @"none";
}

- (void)browserRemoteInputControllerLinkNavigationDidChangeActive:(BOOL)active {
    UIImageView *cursorView = self.remoteInputController.cursorView;
    [UIView animateWithDuration:0.2 animations:^{
        cursorView.alpha = active ? 0.0 : 1.0;
    }];
    if (!active) {
        [self setShowTopBarButtonSelected:NO animated:YES];
    }
    if (active) {
        [self runLinkNavigationCommand:@"down"];
        [self showLinkNavigationHint:BrowserLocalized(@"Link navigation on · Arrows: switch · Click: open · Hold bottom: mouse")];
    } else {
        [self runLinkNavigationCommand:@"clear"];
        [self showLinkNavigationHint:BrowserLocalized(@"Mouse on · Hold bottom: link navigation")];
    }
}

- (NSString *)browserRemoteInputControllerLinkNavigationMove:(NSString *)direction {
    if (self.showTopBarButtonSelected) {
        if ([direction isEqualToString:@"down"]) {
            [self setShowTopBarButtonSelected:NO animated:YES];
            return [self runLinkNavigationCommand:@"down"];
        }
        return @"ok"; // nothing above or beside the red button
    }
    return [self runLinkNavigationCommand:direction];
}

- (BOOL)browserRemoteInputControllerLinkNavigationSelectShowBarButton {
    UIView *button = self.showTopBarButton;
    if (button == nil || button.hidden || button.alpha < 0.5) {
        return NO;
    }
    [self runLinkNavigationCommand:@"clear"];
    [self setShowTopBarButtonSelected:YES animated:YES];
    return YES;
}

- (void)setShowTopBarButtonSelected:(BOOL)selected animated:(BOOL)animated {
    if (_showTopBarButtonSelected == selected) {
        return;
    }
    _showTopBarButtonSelected = selected;
    UIView *button = self.showTopBarButton;
    // Same focus language as the rest: a white ring, lifted and a little larger.
    void (^changes)(void) = ^{
        button.transform = selected ? CGAffineTransformMakeScale(1.25, 1.25) : CGAffineTransformIdentity;
        button.layer.borderWidth = selected ? 4.0 : 2.0;
        button.layer.borderColor = (selected ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.85]).CGColor;
        button.layer.shadowOpacity = selected ? 0.6 : 0.35;
        button.layer.shadowRadius = selected ? 18.0 : 10.0;
    };
    if (animated) {
        [UIView animateWithDuration:0.2 animations:changes];
    } else {
        changes();
    }
}

- (void)browserRemoteInputControllerLinkNavigationActivate {
    if (self.showTopBarButtonSelected) {
        [self setShowTopBarButtonSelected:NO animated:NO];
        [self browserShowTopNav];
        return;
    }
    NSString *result = [self runLinkNavigationCommand:@"activate"];
    if (![result hasPrefix:@"point:"]) {
        [self runLinkNavigationCommand:@"down"];
        return;
    }
    NSArray<NSString *> *parts = [[result substringFromIndex:6] componentsSeparatedByString:@","];
    if (parts.count != 2) {
        return;
    }
    CGPoint domPoint = CGPointMake(parts[0].doubleValue, parts[1].doubleValue);
    [self runLinkNavigationCommand:@"clear"];
    // Same path as a cursor click, so links, text fields and videos behave exactly as before.
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
}

- (void)showLinkNavigationHint:(NSString *)text {
    UILabel *label = self.linkNavigationHintLabel;
    if (label == nil) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.82];
        label.layer.cornerRadius = 30.0;
        label.layer.masksToBounds = YES;
        label.alpha = 0.0;
        label.userInteractionEnabled = NO;
        [self.view addSubview:label];
        self.linkNavigationHintLabel = label;
    }

    label.text = text;
    CGSize textSize = [label sizeThatFits:CGSizeMake(CGRectGetWidth(self.view.bounds) - 160.0, 60.0)];
    CGFloat width = ceil(textSize.width) + 72.0;
    label.frame = CGRectMake(floor((CGRectGetWidth(self.view.bounds) - width) / 2.0),
                             CGRectGetHeight(self.view.bounds) - 140.0,
                             width,
                             60.0);
    [self.view bringSubviewToFront:label];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideLinkNavigationHint) object:nil];
    [UIView animateWithDuration:0.2 animations:^{
        label.alpha = 1.0;
    }];
    [self performSelector:@selector(hideLinkNavigationHint) withObject:nil afterDelay:3.0];
}

- (void)hideLinkNavigationHint {
    [UIView animateWithDuration:0.4 animations:^{
        self.linkNavigationHintLabel.alpha = 0.0;
    }];
}

#pragma mark - Red button that brings the hidden top bar back

static CGFloat const kShowTopBarButtonSize = 56.0;
static CGFloat const kShowTopBarButtonTopInset = 60.0; // tvOS top safe area, same line as the bar
static CGFloat const kShowTopBarButtonHitSlop = 24.0;

- (void)setUpShowTopBarButton {
    UIView *button = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, kShowTopBarButtonSize, kShowTopBarButtonSize)];
    button.backgroundColor = UIColor.systemRedColor;
    button.layer.cornerRadius = kShowTopBarButtonSize / 2.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    button.layer.borderWidth = 2.0;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.35;
    button.layer.shadowRadius = 10.0;
    button.layer.shadowOffset = CGSizeMake(0.0, 4.0);
    button.userInteractionEnabled = NO; // clicks come from the remote's cursor, see -browserHandlePrimaryAction
    button.isAccessibilityElement = YES;
    button.accessibilityLabel = BrowserLocalized(@"Show Top Navigation Bar");
    button.accessibilityTraits = UIAccessibilityTraitButton;

    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:24.0
                                                                                                weight:UIImageSymbolWeightBold];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down" withConfiguration:configuration]];
    iconView.tintColor = UIColor.whiteColor;
    iconView.contentMode = UIViewContentModeCenter;
    iconView.frame = button.bounds;
    iconView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [button addSubview:iconView];

    UIView *cursorView = self.remoteInputController.cursorView;
    if (cursorView.superview == self.view) {
        [self.view insertSubview:button belowSubview:cursorView];
    } else {
        [self.view addSubview:button];
    }
    self.showTopBarButton = button;
    [self updateShowTopBarButtonAnimated:NO];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.showTopBarButton == nil) {
        return;
    }
    CGFloat width = CGRectGetWidth(self.view.bounds);
    // bounds + center (not frame): the button is scaled while it fades out.
    self.showTopBarButton.bounds = CGRectMake(0.0, 0.0, kShowTopBarButtonSize, kShowTopBarButtonSize);
    self.showTopBarButton.center = CGPointMake(width / 2.0, kShowTopBarButtonTopInset + (kShowTopBarButtonSize / 2.0));
    UIView *cursorView = self.remoteInputController.cursorView;
    if (cursorView.superview == self.view) {
        [self.view bringSubviewToFront:cursorView];
    }
    [self updateShowTopBarButtonAnimated:NO];
}

- (void)updateShowTopBarButtonAnimated:(BOOL)animated {
    UIView *button = self.showTopBarButton;
    if (button == nil) {
        return;
    }
    BOOL shouldShow = !self.viewModel.topNavigationBarVisible;
    CGFloat targetAlpha = shouldShow ? 1.0 : 0.0;
    if (button.alpha == targetAlpha && button.hidden == !shouldShow) {
        return;
    }

    if (shouldShow) {
        button.hidden = NO;
    }
    void (^changes)(void) = ^{
        button.alpha = targetAlpha;
        button.transform = shouldShow ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.6, 0.6);
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        button.hidden = self.viewModel.topNavigationBarVisible;
    };
    if (animated) {
        [UIView animateWithDuration:0.25 animations:changes completion:completion];
    } else {
        changes();
        completion(YES);
    }
}

- (BOOL)cursorIsOverShowTopBarButton {
    UIView *button = self.showTopBarButton;
    if (button == nil || button.hidden || button.alpha < 0.5) {
        return NO;
    }
    UIView *cursorView = self.remoteInputController.cursorView;
    // The cursor image's tip is its top-left corner.
    CGPoint cursorTip = [cursorView.superview convertPoint:cursorView.frame.origin toView:self.view];
    CGPoint center = button.center;
    CGFloat half = (kShowTopBarButtonSize / 2.0) + kShowTopBarButtonHitSlop;
    CGRect hitFrame = CGRectMake(center.x - half, center.y - half, half * 2.0, half * 2.0);
    return CGRectContainsPoint(hitFrame, cursorTip);
}

- (void)browserUpdateTextFontSize {
    [self updateTextFontSize];
}

- (void)browserCaptureSnapshotForCurrentTab {
    [self.tabCoordinator captureSnapshotForCurrentTab];
}

- (void)browserRecreateActiveWebViewPreservingCurrentURL {
    [self.tabCoordinator recreateActiveWebViewPreservingCurrentURL];
}

- (void)browserBringCursorToFront {
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];
}

#pragma mark - BrowserVideoPlaybackCoordinatorHost

- (BOOL)browserIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (CGPoint)browserDOMCursorPoint {
    return [self browserDOMPointForCursor];
}

- (UIViewController *)browserPresentedViewController {
    return self.presentedViewController;
}

- (NSString *)browserCurrentPageTitle {
    return self.webview.title;
}

#pragma mark - BrowserTabCoordinatorHost

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (void)browserTabCoordinatorUpdateTextFontSize {
    [self updateTextFontSize];
}

- (BOOL)browserTabCoordinatorIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (BOOL)browserTabCoordinatorIsTabOverviewVisible {
    return self.tabOverviewController.visible;
}

#pragma mark - BrowserTabOverviewControllerHost

- (BOOL)browserTabOverviewControllerCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (void)browserTabOverviewControllerSetCursorModeEnabled:(BOOL)enabled {
    [self.remoteInputController setCursorModeEnabled:enabled];
}

- (void)browserTabOverviewControllerPresentViewController:(UIViewController *)viewController {
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserTabOverviewControllerCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserTabOverviewControllerSwitchToTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator switchToTabAtIndex:tabIndex];
}

- (void)browserTabOverviewControllerCloseTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator closeTabAtIndex:tabIndex];
}

#pragma mark - BrowserPageActionCoordinatorHost

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request {
    return [self.tabCoordinator createNewTabWithRequest:request];
}

#pragma mark - BrowserRemoteInputControllerHost

- (UIScrollView *)browserRemoteInputControllerActiveScrollView {
    return self.webview.scrollView;
}

- (UIViewController *)browserRemoteInputControllerPresentedViewController {
    // A screen that is closing or no longer visible (e.g. a full-screen video that was left) must not
    // keep swallowing the remote's presses, otherwise nothing reacts any more.
    UIViewController *presented = self.presentedViewController;
    if ([presented isKindOfClass:[UIAlertController class]]) {
        // A closing question window still counts, so the press that answered it doesn't also click the page.
        return presented;
    }
    if (presented == nil || presented.isBeingDismissed || presented.view.window == nil ||
        presented.view.hidden || presented.view.alpha < 0.01) {
        return nil;
    }
    return presented;
}

- (BOOL)browserRemoteInputControllerTopBarFocusActive {
    return self.topBarFocusActive;
}

- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus {
    return [self canActivateTopBarFocusMode];
}

- (void)browserRemoteInputControllerActivateTopBarFocus {
    [self activateTopBarFocusMode];
}

- (void)browserRemoteInputControllerDeactivateTopBarFocus {
    [self deactivateTopBarFocusMode];
}

- (BOOL)browserRemoteInputControllerTabOverviewVisible {
    return self.tabOverviewController.visible;
}

- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point {
    return [self.tabOverviewController containsPoint:point];
}

- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point {
    return [self.tabOverviewController handleSelectionAtPoint:point];
}

- (void)browserRemoteInputControllerDismissTabOverview {
    [self.tabOverviewController dismiss];
}

- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction {
    [self.tabOverviewController handleAlternateAction];
}

- (void)browserRemoteInputControllerHandlePrimaryAction {
    [self browserHandlePrimaryAction];
}

- (void)browserRemoteInputControllerHandleMenuPress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.webview.canGoBack) {
        [self.webview goBack];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Exit App?")
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Exit")
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            exit(EXIT_SUCCESS);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Dismiss") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)browserRemoteInputControllerHandlePlayPausePress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self requestURLorSearchInput];
    }
}

- (void)browserRemoteInputControllerHandleAdvancedMenuPress {
    [self showAdvancedMenu];
}

- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point {
    if (self.webview.request == nil) {
        return @"false";
    }
    CGPoint webPoint = [self.view convertPoint:point toView:self.webview];
    if (webPoint.y < 0) {
        return @"false";
    }
    CGPoint domPoint = [self browserDOMPointForCursor];
    return [self.pageActionCoordinator hoverStateAtDOMPoint:domPoint webView:self.webview];
}

- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled {
    self.webview.userInteractionEnabled = enabled;
}

- (void)browserRemoteInputControllerPersistSession {
    [self.tabCoordinator persistSession];
}

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    return [self.tabCoordinator createNewTabWithRequest:request];
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)navigationType;
    [self.tabCoordinator prepareTabForRequest:request webView:webView];
    return YES;
}

- (void)webViewDidStartLoad:(id)webView {
    if (webView == self.webview) {
        self.pageArticle = nil;
        self.pageHasFeed = NO;
        [self.topMenuView setReaderAvailable:NO feedAvailable:NO];
        // Check while the page is still loading – articles usually have their text long before the ads and images are done.
        [self schedulePageFeatureChecksForWebView:webView delays:@[@0.9, @1.8, @3.0, @4.5, @6.5]];
    }
    [self.tabCoordinator webViewDidStartLoad:webView];
}

- (void)webViewDidCommitNavigation:(id)webView {
    [self.tabCoordinator webViewDidCommitNavigation:webView];
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    if (webView == self.webview) {
        [self schedulePageFeatureChecksForWebView:webView delays:@[@0.15, @1.5]];
    }
    if (self.tabOverviewController.visible) {
        BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
        NSInteger tabIndex = tab != nil ? [self.viewModel.tabs indexOfObject:tab] : NSNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.tabOverviewController.visible) {
                return;
            }
            if (tabIndex != NSNotFound) {
                [self.tabOverviewController updateCardAtIndex:tabIndex];
            } else {
                [self.tabOverviewController reload];
            }
        });
    }
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
    BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSURL *failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    NSURLRequest *currentRequest = [webView request];
    NSString *currentRequestURLString = currentRequest.URL.absoluteString ?: @"";
    if (failingURL != nil &&
        currentRequestURLString.length > 0 &&
        ![failingURL.absoluteString isEqualToString:currentRequestURLString]) {
        return;
    }

    if (tab == self.tabCoordinator.activeTab) {
        [self.topMenuView.loadingSpinner stopAnimating];
    }
    if (tab != self.tabCoordinator.activeTab) {
        return;
    }
    if ([self.navigationService shouldIgnoreLoadError:error]) {
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Could Not Load Webpage")
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Google This Page")
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            if (searchRequest != nil) {
                [weakSelf.webview loadRequest:searchRequest];
            }
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Reload Page")
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Enter an Address or Search")
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf requestURLorSearchInput];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Presses / Touches

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesBegan:presses withEvent:event];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if ([self.remoteInputController handlePressesEnded:presses withEvent:event]) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesBegan:touches withEvent:event]) {
        return;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesMoved:touches withEvent:event]) {
        return;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesCancelled:touches withEvent:event];
}

@end
