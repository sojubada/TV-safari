//
//  BrowserReaderViewController.m
//  Orbrisa
//

#import "BrowserReaderViewController.h"
#import "BrowserLocalization.h"
#import "BrowserWebView.h"

static NSString * const kReaderThemeKey = @"BrowserReaderTheme";
static NSString * const kReaderSizeKey = @"BrowserReaderSize";
static NSString * const kReaderSerifKey = @"BrowserReaderSerif";
enum { kReaderSizeCount = 5 };
static NSUInteger const kReaderMaxImages = 12;

typedef struct {
    __unsafe_unretained NSString *name;
    UInt32 background;
    UInt32 text;
    UInt32 muted;
    UInt32 accent;
} BrowserReaderTheme;

static BrowserReaderTheme const kReaderThemes[] = {
    {@"Light", 0xFFFFFF, 0x1C1C1E, 0x5B5B62, 0xC4570A},
    {@"Sepia", 0xF4ECD8, 0x3B2F1E, 0x6E5D45, 0xB0530C},
    {@"Grey", 0x3A3A3C, 0xF2F2F7, 0xC7C7CC, 0xFFB340},
    {@"Dark", 0x1C1C1E, 0xF2F2F7, 0xAEAEB2, 0xFF9F0A},
};
static NSInteger const kReaderThemeCount = sizeof(kReaderThemes) / sizeof(kReaderThemes[0]);

static UIColor *BrowserReaderColor(UInt32 hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1.0];
}

@interface BrowserReaderViewController ()
@property (nonatomic, copy) NSDictionary *article;
@property (nonatomic) UITextView *textView;
@property (nonatomic) UIVisualEffectView *hintView;
@property (nonatomic) UILabel *hintLabel;
@property (nonatomic) UIVisualEffectView *panelView;
@property (nonatomic) UIButton *smallerButton;
@property (nonatomic) UIButton *biggerButton;
@property (nonatomic) NSArray<UIView *> *sizeDots;
@property (nonatomic) NSArray<UIButton *> *themeButtons;
@property (nonatomic) UIButton *serifButton;
@property (nonatomic) UIButton *systemButton;
@property (nonatomic) UIButton *alwaysButton;
@property (nonatomic) UILabel *alwaysLabel;
@property (nonatomic) UIView *alwaysTrack;
@property (nonatomic) UIView *alwaysKnob;
@property (nonatomic, weak) UIButton *focusedControl;
@property (nonatomic) NSLayoutConstraint *textCenterConstraint;
@property (nonatomic) NSLayoutConstraint *textWidthConstraint;
@property (nonatomic) NSMutableDictionary<NSString *, UIImage *> *images;
@property (nonatomic) CGFloat panStartOffset;
@property (nonatomic) NSInteger theme;
@property (nonatomic) NSInteger size;
@property (nonatomic) BOOL serif;
@end

@implementation BrowserReaderViewController

#pragma mark - Page script

+ (NSString *)extractionScript {
    NSString *path = [NSBundle.mainBundle pathForResource:@"ReaderExtract" ofType:@"js"];
    return path != nil ? ([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"") : @"";
}

+ (NSDictionary *)articleFromJavaScriptResult:(NSString *)result {
    if (result.length == 0) {
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSArray *blocks = [json[@"blocks"] isKindOfClass:[NSArray class]] ? json[@"blocks"] : @[];
    NSUInteger paragraphs = 0;
    NSUInteger characters = 0;
    for (NSDictionary *block in blocks) {
        if ([block isKindOfClass:[NSDictionary class]] && [block[@"t"] isEqual:@"p"]) {
            paragraphs += 1;
            characters += [block[@"s"] length];
        }
    }
    // A real article: a few paragraphs with some text in them (menus and start pages are not).
    if (paragraphs < 3 || characters < 600) {
        return nil;
    }
    return json;
}

#pragma mark - Life cycle

- (instancetype)initWithArticle:(NSDictionary *)article {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _article = [article copy];
        _images = [NSMutableDictionary dictionary];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _theme = [defaults objectForKey:kReaderThemeKey] != nil ? [defaults integerForKey:kReaderThemeKey]
                                                                  : ([BrowserWebView websitesShouldBeDark] ? 3 : 1);
        _theme = MIN(MAX(_theme, 0), kReaderThemeCount - 1);
        _size = [defaults objectForKey:kReaderSizeKey] != nil ? [defaults integerForKey:kReaderSizeKey] : 2;
        _size = MIN(MAX(_size, 0), kReaderSizeCount - 1);
        _serif = [defaults objectForKey:kReaderSerifKey] != nil ? [defaults boolForKey:kReaderSerifKey] : YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UITextView *textView = [UITextView new];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.selectable = NO;
    textView.userInteractionEnabled = NO; // scrolling is driven by the remote below
    textView.scrollEnabled = YES;
    textView.backgroundColor = UIColor.clearColor;
    textView.textContainerInset = UIEdgeInsetsMake(110.0, 0.0, 220.0, 0.0);
    textView.textContainer.lineFragmentPadding = 0.0;
    textView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:textView];
    self.textView = textView;

    UIVisualEffectView *hintView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    hintView.translatesAutoresizingMaskIntoConstraints = NO;
    hintView.layer.cornerRadius = 27.0;
    hintView.layer.masksToBounds = YES;
    UILabel *hintLabel = [UILabel new];
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    hintLabel.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightMedium];
    hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    hintLabel.text = BrowserLocalized(@"Swipe: scroll  ·  Play/Pause: appearance  ·  Back: close Reader");
    [hintView.contentView addSubview:hintLabel];
    [self.view addSubview:hintView];
    self.hintView = hintView;
    self.hintLabel = hintLabel;

    [self buildPanel];

    self.textCenterConstraint = [textView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor];
    self.textWidthConstraint = [textView.widthAnchor constraintEqualToConstant:1160.0];
    [NSLayoutConstraint activateConstraints:@[
        self.textCenterConstraint,
        self.textWidthConstraint,
        [textView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [hintLabel.leadingAnchor constraintEqualToAnchor:hintView.contentView.leadingAnchor constant:28.0],
        [hintLabel.trailingAnchor constraintEqualToAnchor:hintView.contentView.trailingAnchor constant:-28.0],
        [hintLabel.centerYAnchor constraintEqualToAnchor:hintView.contentView.centerYAnchor],
        [hintView.heightAnchor constraintEqualToConstant:54.0],
        [hintView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [hintView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-40.0],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.allowedTouchTypes = @[@(UITouchTypeIndirect)];
    [self.view addGestureRecognizer:pan];

    [self applyAppearanceKeepingPosition:NO];
    [self loadImages];

    // The hint fades after a few seconds, so only the text is left.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.6 animations:^{ self.hintView.alpha = 0.0; }];
    });
}

#pragma mark - Appearance

- (BrowserReaderTheme)currentTheme {
    return kReaderThemes[self.theme];
}

- (CGFloat)bodySize {
    static CGFloat const sizes[kReaderSizeCount] = {26.0, 30.0, 34.0, 39.0, 45.0};
    return sizes[self.size];
}

- (UIFont *)fontOfSize:(CGFloat)size weight:(UIFontWeight)weight italic:(BOOL)italic {
    UIFont *font = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *descriptor = font.fontDescriptor;
    if (self.serif) {
        descriptor = [descriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif] ?: descriptor;
    }
    if (italic) {
        descriptor = [descriptor fontDescriptorWithSymbolicTraits:descriptor.symbolicTraits | UIFontDescriptorTraitItalic] ?: descriptor;
    }
    return [UIFont fontWithDescriptor:descriptor size:size];
}

- (NSMutableParagraphStyle *)paragraphWithSpacing:(CGFloat)spacing indent:(CGFloat)indent {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineHeightMultiple = 1.32;
    paragraph.paragraphSpacing = spacing;
    paragraph.firstLineHeadIndent = indent;
    paragraph.headIndent = indent;
    return paragraph;
}

- (NSAttributedString *)articleText {
    BrowserReaderTheme theme = [self currentTheme];
    UIColor *text = BrowserReaderColor(theme.text);
    UIColor *muted = BrowserReaderColor(theme.muted);
    UIColor *accent = BrowserReaderColor(theme.accent);
    CGFloat body = [self bodySize];
    CGFloat width = self.textWidthConstraint != nil ? self.textWidthConstraint.constant : 1160.0;
    NSMutableAttributedString *out = [NSMutableAttributedString new];

    void (^append)(NSString *, NSDictionary *) = ^(NSString *string, NSDictionary *attributes) {
        if (string.length > 0) {
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:string attributes:attributes]];
        }
    };

    // Site · reading time
    NSString *site = [self.article[@"site"] isKindOfClass:[NSString class]] ? [self.article[@"site"] uppercaseString] : @"";
    NSInteger words = [self.article[@"words"] integerValue];
    NSInteger minutes = MAX(1, (NSInteger)lround(words / 200.0));
    append(site, @{NSFontAttributeName: [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: accent});
    append([NSString stringWithFormat:@"  ·  %@\n", [NSString stringWithFormat:BrowserLocalized(@"%ld min read"), (long)minutes]],
           @{NSFontAttributeName: [UIFont systemFontOfSize:22.0 weight:UIFontWeightMedium], NSForegroundColorAttributeName: muted,
             NSParagraphStyleAttributeName: [self paragraphWithSpacing:18.0 indent:0.0]});

    // Title
    NSString *title = [self.article[@"title"] isKindOfClass:[NSString class]] ? self.article[@"title"] : @"";
    NSMutableParagraphStyle *titleParagraph = [self paragraphWithSpacing:22.0 indent:0.0];
    titleParagraph.lineHeightMultiple = 1.08;
    append([title stringByAppendingString:@"\n"], @{NSFontAttributeName: [self fontOfSize:round(body * 1.95) weight:UIFontWeightBold italic:NO],
                                                    NSForegroundColorAttributeName: text, NSParagraphStyleAttributeName: titleParagraph});

    NSString *byline = [self.article[@"byline"] isKindOfClass:[NSString class]] ? self.article[@"byline"] : @"";
    if (byline.length > 0) {
        append([byline stringByAppendingString:@"\n"], @{NSFontAttributeName: [UIFont systemFontOfSize:24.0 weight:UIFontWeightMedium],
                                                         NSForegroundColorAttributeName: muted,
                                                         NSParagraphStyleAttributeName: [self paragraphWithSpacing:26.0 indent:0.0]});
    }

    // Hero image (from the page's preview image) when the article itself starts without one.
    NSArray *blocks = [self.article[@"blocks"] isKindOfClass:[NSArray class]] ? self.article[@"blocks"] : @[];
    NSString *hero = [self.article[@"image"] isKindOfClass:[NSString class]] ? self.article[@"image"] : @"";
    BOOL articleHasImage = NO;
    for (NSDictionary *block in blocks) {
        if ([block isKindOfClass:[NSDictionary class]] && [block[@"t"] isEqual:@"img"]) {
            articleHasImage = YES;
            break;
        }
    }
    if (hero.length > 0 && !articleHasImage) {
        [self appendImageNamed:hero width:width to:out];
    }

    NSDictionary *bodyAttributes = @{NSFontAttributeName: [self fontOfSize:body weight:UIFontWeightRegular italic:NO],
                                     NSForegroundColorAttributeName: text,
                                     NSParagraphStyleAttributeName: [self paragraphWithSpacing:round(body * 0.85) indent:0.0]};
    for (NSDictionary *block in blocks) {
        if (![block isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *type = block[@"t"];
        NSString *string = [block[@"s"] isKindOfClass:[NSString class]] ? block[@"s"] : @"";
        if ([type isEqual:@"img"]) {
            [self appendImageNamed:block[@"src"] width:width to:out];
        } else if ([type isEqual:@"h"]) {
            NSMutableParagraphStyle *heading = [self paragraphWithSpacing:round(body * 0.5) indent:0.0];
            heading.paragraphSpacingBefore = round(body * 0.6);
            append([string stringByAppendingString:@"\n"], @{NSFontAttributeName: [self fontOfSize:round(body * 1.22) weight:UIFontWeightBold italic:NO],
                                                             NSForegroundColorAttributeName: text, NSParagraphStyleAttributeName: heading});
        } else if ([type isEqual:@"li"]) {
            NSMutableParagraphStyle *item = [self paragraphWithSpacing:round(body * 0.35) indent:0.0];
            item.headIndent = round(body * 1.1);
            append([NSString stringWithFormat:@"•\t%@\n", string], @{NSFontAttributeName: [self fontOfSize:body weight:UIFontWeightRegular italic:NO],
                                                                     NSForegroundColorAttributeName: text, NSParagraphStyleAttributeName: item});
        } else if ([type isEqual:@"q"]) {
            append([string stringByAppendingString:@"\n"], @{NSFontAttributeName: [self fontOfSize:round(body * 1.05) weight:UIFontWeightRegular italic:YES],
                                                             NSForegroundColorAttributeName: muted,
                                                             NSParagraphStyleAttributeName: [self paragraphWithSpacing:round(body * 0.85) indent:round(body * 1.4)]});
        } else if ([type isEqual:@"pre"]) {
            append([string stringByAppendingString:@"\n"], @{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:round(body * 0.8) weight:UIFontWeightRegular],
                                                             NSForegroundColorAttributeName: text,
                                                             NSParagraphStyleAttributeName: [self paragraphWithSpacing:round(body * 0.85) indent:0.0]});
        } else {
            append([string stringByAppendingString:@"\n"], bodyAttributes);
        }
    }
    return out;
}

- (void)appendImageNamed:(NSString *)URLString width:(CGFloat)width to:(NSMutableAttributedString *)out {
    UIImage *image = [URLString isKindOfClass:[NSString class]] ? self.images[URLString] : nil;
    if (image == nil || image.size.width < 1.0) {
        return; // not loaded (yet) – the text is rebuilt once it is
    }
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;
    CGFloat height = MIN(width * image.size.height / image.size.width, 760.0);
    CGFloat drawWidth = height * image.size.width / image.size.height;
    attachment.bounds = CGRectMake(0.0, 0.0, drawWidth, height);
    NSMutableParagraphStyle *paragraph = [self paragraphWithSpacing:30.0 indent:0.0];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineHeightMultiple = 1.0;
    NSMutableAttributedString *imageString = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    [imageString appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    [imageString addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, imageString.length)];
    [out appendAttributedString:imageString];
}

- (void)applyAppearanceKeepingPosition:(BOOL)keepPosition {
    CGFloat ratio = 0.0;
    if (keepPosition && self.textView.contentSize.height > 1.0) {
        ratio = self.textView.contentOffset.y / self.textView.contentSize.height;
    }
    self.view.backgroundColor = BrowserReaderColor([self currentTheme].background);
    self.textView.attributedText = [self articleText];
    [self.textView layoutIfNeeded];
    if (keepPosition) {
        CGFloat y = ratio * self.textView.contentSize.height;
        [self.textView setContentOffset:CGPointMake(0.0, [self clampedOffset:y]) animated:NO];
    }
    [self updatePanelTitles];
}

- (void)loadImages {
    NSMutableArray<NSString *> *URLs = [NSMutableArray array];
    NSString *hero = [self.article[@"image"] isKindOfClass:[NSString class]] ? self.article[@"image"] : @"";
    if (hero.length > 0) {
        [URLs addObject:hero];
    }
    for (NSDictionary *block in self.article[@"blocks"]) {
        if ([block isKindOfClass:[NSDictionary class]] && [block[@"t"] isEqual:@"img"] && [block[@"src"] isKindOfClass:[NSString class]] &&
            URLs.count < kReaderMaxImages) {
            [URLs addObject:block[@"src"]];
        }
    }
    __weak typeof(self) weakSelf = self;
    for (NSString *URLString in URLs) {
        NSURL *URL = [NSURL URLWithString:URLString];
        if (URL == nil) {
            continue;
        }
        [[NSURLSession.sharedSession dataTaskWithURL:URL completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
            if (image == nil) {
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                BrowserReaderViewController *strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                strongSelf.images[URLString] = image;
                [strongSelf applyAppearanceKeepingPosition:YES];
            });
        }] resume];
    }
}

#pragma mark - Appearance panel (like the "Reader 2" concept)

static NSString * const kReaderAlwaysHostsKey = @"BrowserReaderAlwaysHosts";

+ (BOOL)opensAutomaticallyForURL:(NSURL *)URL {
    NSString *host = URL.host.lowercaseString;
    if (host.length == 0) {
        return NO;
    }
    return [[NSUserDefaults.standardUserDefaults arrayForKey:kReaderAlwaysHostsKey] containsObject:host];
}

- (NSString *)articleHost {
    NSString *URLString = [self.article[@"url"] isKindOfClass:[NSString class]] ? self.article[@"url"] : @"";
    return [NSURL URLWithString:URLString].host.lowercaseString ?: @"";
}

- (BOOL)alwaysOpens {
    NSString *host = [self articleHost];
    return host.length > 0 && [[NSUserDefaults.standardUserDefaults arrayForKey:kReaderAlwaysHostsKey] containsObject:host];
}

- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text.uppercaseString;
    label.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    return label;
}

- (UIButton *)panelControlWithSize:(CGSize)size radius:(CGFloat)radius {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = radius;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOffset = CGSizeMake(0.0, 8.0);
    button.layer.shadowRadius = 14.0;
    if (size.width > 0.0) {
        [button.widthAnchor constraintEqualToConstant:size.width].active = YES;
    }
    [button.heightAnchor constraintEqualToConstant:size.height].active = YES;
    [button addTarget:self action:@selector(panelControlPressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
    return button;
}

- (void)buildPanel {
    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 40.0;
    panel.layer.masksToBounds = YES;
    panel.alpha = 0.0;
    panel.hidden = YES;
    UIView *tint = [UIView new];
    tint.translatesAutoresizingMaskIntoConstraints = NO;
    tint.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.20 alpha:0.6];
    [panel.contentView addSubview:tint];

    UILabel *title = [UILabel new];
    title.text = BrowserLocalized(@"Appearance");
    title.font = [UIFont systemFontOfSize:40.0 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;

    // Font size: A – five dots – A
    self.smallerButton = [self panelControlWithSize:CGSizeMake(76.0, 76.0) radius:22.0];
    [self.smallerButton setTitle:@"A" forState:UIControlStateNormal];
    self.smallerButton.titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightSemibold];
    self.smallerButton.accessibilityLabel = BrowserLocalized(@"Smaller");
    self.biggerButton = [self panelControlWithSize:CGSizeMake(76.0, 76.0) radius:22.0];
    [self.biggerButton setTitle:@"A" forState:UIControlStateNormal];
    self.biggerButton.titleLabel.font = [UIFont systemFontOfSize:38.0 weight:UIFontWeightSemibold];
    self.biggerButton.accessibilityLabel = BrowserLocalized(@"Bigger");
    NSMutableArray<UIView *> *dots = [NSMutableArray array];
    for (NSInteger i = 0; i < kReaderSizeCount; i++) {
        UIView *dot = [UIView new];
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        CGFloat side = 14.0 + i * 4.0;
        dot.layer.cornerRadius = side / 2.0;
        [dot.widthAnchor constraintEqualToConstant:side].active = YES;
        [dot.heightAnchor constraintEqualToConstant:side].active = YES;
        [dots addObject:dot];
    }
    self.sizeDots = dots;
    UIStackView *dotRow = [[UIStackView alloc] initWithArrangedSubviews:dots];
    dotRow.axis = UILayoutConstraintAxisHorizontal;
    dotRow.alignment = UIStackViewAlignmentCenter;
    dotRow.distribution = UIStackViewDistributionEqualSpacing;
    UIStackView *sizeRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.smallerButton, dotRow, self.biggerButton]];
    sizeRow.axis = UILayoutConstraintAxisHorizontal;
    sizeRow.alignment = UIStackViewAlignmentCenter;
    sizeRow.spacing = 26.0;

    // Background: four round swatches with "Aa"
    NSMutableArray<UIButton *> *themeButtons = [NSMutableArray array];
    NSMutableArray<UIView *> *themeColumns = [NSMutableArray array];
    UIFontDescriptor *serifDescriptor = [[UIFont systemFontOfSize:34.0 weight:UIFontWeightSemibold].fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif];
    UIFont *swatchFont = serifDescriptor != nil ? [UIFont fontWithDescriptor:serifDescriptor size:34.0] : [UIFont systemFontOfSize:34.0 weight:UIFontWeightSemibold];
    for (NSInteger i = 0; i < kReaderThemeCount; i++) {
        UIButton *swatch = [self panelControlWithSize:CGSizeMake(96.0, 96.0) radius:48.0];
        swatch.backgroundColor = BrowserReaderColor(kReaderThemes[i].background);
        [swatch setTitle:@"Aa" forState:UIControlStateNormal];
        [swatch setTitleColor:BrowserReaderColor(kReaderThemes[i].text) forState:UIControlStateNormal];
        swatch.titleLabel.font = swatchFont;
        swatch.accessibilityLabel = BrowserLocalized(kReaderThemes[i].name);
        [themeButtons addObject:swatch];
        UILabel *name = [UILabel new];
        name.text = BrowserLocalized(kReaderThemes[i].name);
        name.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightMedium];
        name.textColor = UIColor.whiteColor;
        UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[swatch, name]];
        column.axis = UILayoutConstraintAxisVertical;
        column.alignment = UIStackViewAlignmentCenter;
        column.spacing = 12.0;
        [themeColumns addObject:column];
    }
    self.themeButtons = themeButtons;
    UIStackView *themeRow = [[UIStackView alloc] initWithArrangedSubviews:themeColumns];
    themeRow.axis = UILayoutConstraintAxisHorizontal;
    themeRow.distribution = UIStackViewDistributionEqualSpacing;

    // Font: Serif · System
    self.serifButton = [self panelControlWithSize:CGSizeMake(0.0, 76.0) radius:38.0];
    [self.serifButton setTitle:BrowserLocalized(@"Serif") forState:UIControlStateNormal];
    self.systemButton = [self panelControlWithSize:CGSizeMake(0.0, 76.0) radius:38.0];
    [self.systemButton setTitle:BrowserLocalized(@"System") forState:UIControlStateNormal];
    for (UIButton *button in @[self.serifButton, self.systemButton]) {
        button.titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightSemibold];
    }
    UIStackView *fontRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.serifButton, self.systemButton]];
    fontRow.axis = UILayoutConstraintAxisHorizontal;
    fontRow.distribution = UIStackViewDistributionFillEqually;
    fontRow.spacing = 12.0;

    // Always open this site in the Reader
    self.alwaysButton = [self panelControlWithSize:CGSizeMake(0.0, 80.0) radius:40.0];
    self.alwaysLabel = [UILabel new];
    self.alwaysLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.alwaysLabel.text = BrowserLocalized(@"Always Open in Reader");
    self.alwaysLabel.font = [UIFont systemFontOfSize:23.0 weight:UIFontWeightMedium];
    self.alwaysLabel.userInteractionEnabled = NO;
    self.alwaysTrack = [UIView new];
    self.alwaysTrack.translatesAutoresizingMaskIntoConstraints = NO;
    self.alwaysTrack.layer.cornerRadius = 23.0;
    self.alwaysTrack.userInteractionEnabled = NO;
    self.alwaysKnob = [UIView new];
    self.alwaysKnob.backgroundColor = UIColor.whiteColor;
    self.alwaysKnob.layer.cornerRadius = 19.0;
    self.alwaysKnob.userInteractionEnabled = NO;
    [self.alwaysTrack addSubview:self.alwaysKnob];
    [self.alwaysButton addSubview:self.alwaysLabel];
    [self.alwaysButton addSubview:self.alwaysTrack];
    [NSLayoutConstraint activateConstraints:@[
        [self.alwaysLabel.leadingAnchor constraintEqualToAnchor:self.alwaysButton.leadingAnchor constant:26.0],
        [self.alwaysLabel.centerYAnchor constraintEqualToAnchor:self.alwaysButton.centerYAnchor],
        [self.alwaysTrack.trailingAnchor constraintEqualToAnchor:self.alwaysButton.trailingAnchor constant:-20.0],
        [self.alwaysTrack.centerYAnchor constraintEqualToAnchor:self.alwaysButton.centerYAnchor],
        [self.alwaysTrack.widthAnchor constraintEqualToConstant:84.0],
        [self.alwaysTrack.heightAnchor constraintEqualToConstant:46.0],
    ]];

    UIView *spacer = [UIView new];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title,
        [self sectionLabel:BrowserLocalized(@"Font Size")], sizeRow,
        [self sectionLabel:BrowserLocalized(@"Background")], themeRow,
        [self sectionLabel:BrowserLocalized(@"Font")], fontRow,
        spacer, self.alwaysButton,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16.0;
    [stack setCustomSpacing:34.0 afterView:title];
    [stack setCustomSpacing:34.0 afterView:sizeRow];
    [stack setCustomSpacing:34.0 afterView:themeRow];
    [panel.contentView addSubview:stack];
    [self.view addSubview:panel];
    self.panelView = panel;

    [NSLayoutConstraint activateConstraints:@[
        [tint.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor],
        [tint.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor],
        [tint.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor],
        [tint.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-60.0],
        [panel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:60.0],
        [panel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-60.0],
        [panel.widthAnchor constraintEqualToConstant:600.0],
        [stack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:44.0],
        [stack.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-44.0],
        [stack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:40.0],
        [stack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-40.0],
    ]];
}

- (void)styleControl:(UIButton *)button selected:(BOOL)selected {
    // Focused or chosen: white with dark text. Otherwise: a soft glass capsule with white text.
    BOOL focused = (button == self.focusedControl);
    BOOL light = focused || selected;
    button.backgroundColor = light ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.12];
    [button setTitleColor:light ? [UIColor colorWithWhite:0.11 alpha:1.0] : UIColor.whiteColor forState:UIControlStateNormal];
    button.transform = focused ? CGAffineTransformMakeScale(1.06, 1.06) : CGAffineTransformIdentity;
    button.layer.shadowOpacity = focused ? 0.4 : 0.0;
}

- (void)updatePanelTitles {
    [self styleControl:self.smallerButton selected:NO];
    [self styleControl:self.biggerButton selected:NO];
    [self.smallerButton setTitleColor:(self.focusedControl == self.smallerButton ? [UIColor colorWithWhite:0.11 alpha:1.0]
                                       : [UIColor colorWithWhite:1.0 alpha:self.size == 0 ? 0.35 : 1.0]) forState:UIControlStateNormal];
    [self.biggerButton setTitleColor:(self.focusedControl == self.biggerButton ? [UIColor colorWithWhite:0.11 alpha:1.0]
                                      : [UIColor colorWithWhite:1.0 alpha:self.size == kReaderSizeCount - 1 ? 0.35 : 1.0]) forState:UIControlStateNormal];
    for (NSInteger i = 0; i < (NSInteger)self.sizeDots.count; i++) {
        self.sizeDots[(NSUInteger)i].backgroundColor = i <= self.size ? UIColor.systemBlueColor : [UIColor colorWithWhite:1.0 alpha:0.22];
    }
    for (NSInteger i = 0; i < (NSInteger)self.themeButtons.count; i++) {
        UIButton *swatch = self.themeButtons[(NSUInteger)i];
        BOOL focused = (swatch == self.focusedControl);
        BOOL chosen = (i == self.theme);
        swatch.layer.borderWidth = chosen ? 5.0 : 2.0;
        swatch.layer.borderColor = (chosen ? UIColor.systemBlueColor : [UIColor colorWithWhite:1.0 alpha:0.2]).CGColor;
        swatch.transform = focused ? CGAffineTransformMakeScale(1.12, 1.12) : CGAffineTransformIdentity;
        swatch.layer.shadowOpacity = focused ? 0.5 : 0.0;
    }
    [self styleControl:self.serifButton selected:self.serif];
    [self styleControl:self.systemButton selected:!self.serif];

    BOOL always = [self alwaysOpens];
    BOOL alwaysFocused = (self.focusedControl == self.alwaysButton);
    self.alwaysButton.backgroundColor = alwaysFocused ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.1];
    self.alwaysButton.transform = alwaysFocused ? CGAffineTransformMakeScale(1.04, 1.04) : CGAffineTransformIdentity;
    self.alwaysButton.layer.shadowOpacity = alwaysFocused ? 0.4 : 0.0;
    self.alwaysLabel.textColor = alwaysFocused ? [UIColor colorWithWhite:0.11 alpha:1.0] : UIColor.whiteColor;
    self.alwaysTrack.backgroundColor = always ? UIColor.systemBlueColor
                                              : (alwaysFocused ? [UIColor colorWithWhite:0.0 alpha:0.16] : [UIColor colorWithWhite:0.47 alpha:0.5]);
    self.alwaysKnob.frame = CGRectMake(always ? 42.0 : 4.0, 4.0, 38.0, 38.0);
}

- (void)panelControlPressed:(UIButton *)button {
    if (button == self.smallerButton) {
        self.size = MAX(0, self.size - 1);
    } else if (button == self.biggerButton) {
        self.size = MIN(kReaderSizeCount - 1, self.size + 1);
    } else if ([self.themeButtons containsObject:button]) {
        self.theme = (NSInteger)[self.themeButtons indexOfObject:button];
    } else if (button == self.serifButton) {
        self.serif = YES;
    } else if (button == self.systemButton) {
        self.serif = NO;
    } else if (button == self.alwaysButton) {
        NSString *host = [self articleHost];
        if (host.length > 0) {
            NSMutableArray *hosts = [[NSUserDefaults.standardUserDefaults arrayForKey:kReaderAlwaysHostsKey] mutableCopy] ?: [NSMutableArray array];
            if ([hosts containsObject:host]) {
                [hosts removeObject:host];
            } else {
                [hosts addObject:host];
            }
            [NSUserDefaults.standardUserDefaults setObject:hosts forKey:kReaderAlwaysHostsKey];
        }
        [UIView animateWithDuration:0.2 animations:^{ [self updatePanelTitles]; }];
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:self.theme forKey:kReaderThemeKey];
    [defaults setInteger:self.size forKey:kReaderSizeKey];
    [defaults setBool:self.serif forKey:kReaderSerifKey];
    [self applyAppearanceKeepingPosition:YES];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    UIView *next = context.nextFocusedView;
    self.focusedControl = [next isKindOfClass:[UIButton class]] && [next isDescendantOfView:self.panelView] ? (UIButton *)next : nil;
    [coordinator addCoordinatedAnimations:^{ [self updatePanelTitles]; } completion:nil];
}

- (BOOL)panelVisible {
    return !self.panelView.hidden;
}

- (void)setPanelVisible:(BOOL)visible {
    if (visible == [self panelVisible]) {
        return;
    }
    if (visible) {
        self.panelView.hidden = NO;
    }
    // The article moves to the left so the panel does not cover it.
    self.textCenterConstraint.constant = visible ? -330.0 : 0.0;
    self.textWidthConstraint.constant = visible ? 1020.0 : 1160.0;
    [self applyAppearanceKeepingPosition:YES];
    [UIView animateWithDuration:0.3 animations:^{
        self.panelView.alpha = visible ? 1.0 : 0.0;
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        if (!visible) {
            self.panelView.hidden = YES;
        }
        [self setNeedsFocusUpdate];
        [self updateFocusIfNeeded];
    }];
    [self setNeedsFocusUpdate];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return [self panelVisible] ? @[self.biggerButton] : @[];
}

#pragma mark - Scrolling with the remote

- (CGFloat)clampedOffset:(CGFloat)y {
    CGFloat maxY = MAX(0.0, self.textView.contentSize.height - CGRectGetHeight(self.textView.bounds));
    return MIN(MAX(y, 0.0), maxY);
}

- (void)scrollBy:(CGFloat)delta animated:(BOOL)animated {
    CGFloat y = [self clampedOffset:self.textView.contentOffset.y + delta];
    if (animated) {
        [UIView animateWithDuration:0.35 delay:0.0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.textView.contentOffset = CGPointMake(0.0, y);
        } completion:nil];
    } else {
        self.textView.contentOffset = CGPointMake(0.0, y);
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if ([self panelVisible]) {
        return;
    }
    CGFloat translation = [pan translationInView:self.view].y;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            self.panStartOffset = self.textView.contentOffset.y;
            break;
        case UIGestureRecognizerStateChanged:
            self.textView.contentOffset = CGPointMake(0.0, [self clampedOffset:self.panStartOffset - translation * 1.6]);
            break;
        case UIGestureRecognizerStateEnded: {
            // A little momentum, like a normal list on the Apple TV.
            CGFloat velocity = [pan velocityInView:self.view].y;
            [self scrollBy:-velocity * 0.35 animated:YES];
            break;
        }
        default:
            break;
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (![self panelVisible]) {
        CGFloat page = CGRectGetHeight(self.view.bounds) * 0.75;
        if (press.type == UIPressTypeDownArrow) {
            [self scrollBy:page animated:YES];
            return;
        }
        if (press.type == UIPressTypeUpArrow) {
            [self scrollBy:-page animated:YES];
            return;
        }
    }
    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
        return; // handled when the press ends
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press.type == UIPressTypeMenu) {
        if ([self panelVisible]) {
            [self setPanelVisible:NO];
        } else {
            [self dismissViewControllerAnimated:YES completion:nil];
        }
        return;
    }
    if (press.type == UIPressTypePlayPause) {
        [self setPanelVisible:![self panelVisible]];
        return;
    }
    if (!([self panelVisible]) && (press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow)) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end
