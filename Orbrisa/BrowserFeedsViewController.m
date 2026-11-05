//
//  BrowserFeedsViewController.m
//  Orbrisa
//

#import "BrowserFeedsViewController.h"
#import "BrowserFeedStore.h"
#import "BrowserLocalization.h"

static CGFloat const kFeedsTop = 140.0;          // just below the top bar, like the tab overview
static CGFloat const kFeedsSidebarWidth = 440.0;
static CGFloat const kFeedsCardHeight = 330.0;
static CGFloat const kFeedsCardImageHeight = 190.0;

static UIColor *FeedsBackgroundColor(void) { return [UIColor colorWithRed:0.08 green:0.08 blue:0.09 alpha:1.0]; }
static UIColor *FeedsCardColor(void) { return [UIColor colorWithRed:0.15 green:0.15 blue:0.16 alpha:1.0]; }

static NSCache<NSString *, UIImage *> *FeedsImageCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 200;
    });
    return cache;
}

#pragma mark - Feed row (left)

@interface BrowserFeedRowCell : UITableViewCell
@property (nonatomic) UIView *capsule;
@property (nonatomic) UILabel *badge;
@property (nonatomic) UILabel *nameLabel;
@property (nonatomic) UILabel *countLabel;
@end

@implementation BrowserFeedRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.focusStyle = UITableViewCellFocusStyleCustom;
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

        _capsule = [UIView new];
        _capsule.translatesAutoresizingMaskIntoConstraints = NO;
        _capsule.layer.cornerRadius = 38.0;
        _capsule.layer.shadowColor = UIColor.blackColor.CGColor;
        _capsule.layer.shadowRadius = 14.0;
        _capsule.layer.shadowOffset = CGSizeMake(0.0, 6.0);
        [self.contentView addSubview:_capsule];

        _badge = [UILabel new];
        _badge.translatesAutoresizingMaskIntoConstraints = NO;
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.textColor = UIColor.whiteColor;
        _badge.font = [UIFont systemFontOfSize:23.0 weight:UIFontWeightBold];
        _badge.layer.cornerRadius = 14.0;
        _badge.layer.masksToBounds = YES;
        [_capsule addSubview:_badge];

        _nameLabel = [UILabel new];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightSemibold];
        [_capsule addSubview:_nameLabel];

        _countLabel = [UILabel new];
        _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _countLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightBold];
        _countLabel.textAlignment = NSTextAlignmentCenter;
        _countLabel.layer.cornerRadius = 17.0;
        _countLabel.layer.masksToBounds = YES;
        [_capsule addSubview:_countLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_capsule.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_capsule.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_capsule.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5.0],
            [_capsule.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5.0],
            [_badge.leadingAnchor constraintEqualToAnchor:_capsule.leadingAnchor constant:14.0],
            [_badge.centerYAnchor constraintEqualToAnchor:_capsule.centerYAnchor],
            [_badge.widthAnchor constraintEqualToConstant:48.0],
            [_badge.heightAnchor constraintEqualToConstant:48.0],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_badge.trailingAnchor constant:16.0],
            [_nameLabel.centerYAnchor constraintEqualToAnchor:_capsule.centerYAnchor],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_countLabel.leadingAnchor constant:-12.0],
            [_countLabel.trailingAnchor constraintEqualToAnchor:_capsule.trailingAnchor constant:-20.0],
            [_countLabel.centerYAnchor constraintEqualToAnchor:_capsule.centerYAnchor],
            [_countLabel.heightAnchor constraintEqualToConstant:34.0],
            [_countLabel.widthAnchor constraintGreaterThanOrEqualToConstant:40.0],
        ]];
        [self applyFocused:NO];
    }
    return self;
}

- (void)applyFocused:(BOOL)focused {
    self.capsule.backgroundColor = focused ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.07];
    self.capsule.layer.shadowOpacity = focused ? 0.35 : 0.0;
    self.nameLabel.textColor = focused ? [UIColor colorWithWhite:0.1 alpha:1.0] : [UIColor colorWithWhite:0.95 alpha:1.0];
    self.countLabel.backgroundColor = focused ? UIColor.systemBlueColor : [UIColor colorWithWhite:1.0 alpha:0.16];
    self.countLabel.textColor = UIColor.whiteColor;
    self.capsule.transform = focused ? CGAffineTransformMakeScale(1.03, 1.03) : CGAffineTransformIdentity;
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    BOOL focused = (context.nextFocusedView == self);
    [coordinator addCoordinatedAnimations:^{ [self applyFocused:focused]; } completion:nil];
}

@end

#pragma mark - Article card (right)

@interface BrowserFeedCardCell : UICollectionViewCell
@property (nonatomic) UIView *card;
@property (nonatomic) UIImageView *imageView;
@property (nonatomic) UILabel *metaLabel;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic, copy) NSString *imageURL;
@end

@implementation BrowserFeedCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _card = [UIView new];
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        _card.backgroundColor = FeedsCardColor();
        _card.layer.cornerRadius = 24.0;
        _card.layer.shadowColor = UIColor.blackColor.CGColor;
        _card.layer.shadowOpacity = 0.3;
        _card.layer.shadowRadius = 12.0;
        _card.layer.shadowOffset = CGSizeMake(0.0, 8.0);
        _card.layer.borderColor = UIColor.whiteColor.CGColor;
        [self.contentView addSubview:_card];

        UIView *clip = [UIView new];
        clip.translatesAutoresizingMaskIntoConstraints = NO;
        clip.layer.cornerRadius = 24.0;
        clip.layer.masksToBounds = YES;
        [_card addSubview:clip];

        _imageView = [UIImageView new];
        _imageView.translatesAutoresizingMaskIntoConstraints = NO;
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        [clip addSubview:_imageView];

        _metaLabel = [UILabel new];
        _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _metaLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightSemibold];
        _metaLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        [clip addSubview:_metaLabel];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:25.0 weight:UIFontWeightBold];
        _titleLabel.textColor = [UIColor colorWithWhite:0.96 alpha:1.0];
        _titleLabel.numberOfLines = 3;
        [clip addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [clip.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor],
            [clip.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],
            [clip.topAnchor constraintEqualToAnchor:_card.topAnchor],
            [clip.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],
            [_imageView.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
            [_imageView.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
            [_imageView.topAnchor constraintEqualToAnchor:clip.topAnchor],
            [_imageView.heightAnchor constraintEqualToConstant:kFeedsCardImageHeight],
            [_metaLabel.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor constant:22.0],
            [_metaLabel.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor constant:-22.0],
            [_metaLabel.topAnchor constraintEqualToAnchor:_imageView.bottomAnchor constant:16.0],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor constant:22.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor constant:-22.0],
            [_titleLabel.topAnchor constraintEqualToAnchor:_metaLabel.bottomAnchor constant:6.0],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageURL = nil;
    self.imageView.image = nil;
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    BOOL focused = (context.nextFocusedView == self);
    [coordinator addCoordinatedAnimations:^{
        self.card.transform = focused ? CGAffineTransformMakeScale(1.06, 1.06) : CGAffineTransformIdentity;
        self.card.layer.borderWidth = focused ? 5.0 : 0.0;
        self.card.layer.shadowOpacity = focused ? 0.55 : 0.3;
        self.layer.zPosition = focused ? 1.0 : 0.0;
    } completion:nil];
}

@end

#pragma mark - Screen

@interface BrowserFeedsViewController () <UITableViewDataSource, UITableViewDelegate, UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic) UIButton *allChip;
@property (nonatomic) UIButton *unreadChip;
@property (nonatomic) UIButton *addButton;
@property (nonatomic) BOOL unreadOnly;
@property (nonatomic, copy) NSString *headerSubtitle;
@property (nonatomic) UITableView *tableView;
@property (nonatomic) UICollectionView *collectionView;
@property (nonatomic) UILabel *emptyLabel;
@property (nonatomic) UIActivityIndicatorView *spinner;
@property (nonatomic, copy, nullable) NSString *selectedFeedURL;
@property (nonatomic, copy) NSArray<BrowserFeedItem *> *items;
@end

@implementation BrowserFeedsViewController

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        _items = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // The top bar stays visible above (it reads "Feeds"); everything below it gets a dark backdrop.
    self.view.backgroundColor = UIColor.clearColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIView *backdrop = [UIView new];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.backgroundColor = [FeedsBackgroundColor() colorWithAlphaComponent:0.97];
    backdrop.userInteractionEnabled = NO;
    [self.view addSubview:backdrop];
    UIView *topShade = [UIView new];
    topShade.translatesAutoresizingMaskIntoConstraints = NO;
    topShade.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    topShade.userInteractionEnabled = NO;
    [self.view addSubview:topShade];

    UILabel *sidebarTitle = [UILabel new];
    sidebarTitle.translatesAutoresizingMaskIntoConstraints = NO;
    sidebarTitle.text = BrowserLocalized(@"Subscribed").uppercaseString;
    sidebarTitle.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightSemibold];
    sidebarTitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    [self.view addSubview:sidebarTitle];

    self.allChip = [self chipWithTitle:BrowserLocalized(@"All")];
    self.unreadChip = [self chipWithTitle:BrowserLocalized(@"Unread")];
    UIStackView *chips = [[UIStackView alloc] initWithArrangedSubviews:@[self.allChip, self.unreadChip]];
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    chips.spacing = 14.0;
    [self.view addSubview:chips];

    UIButton *addButton = [UIButton buttonWithType:UIButtonTypeCustom];
    addButton.translatesAutoresizingMaskIntoConstraints = NO;
    addButton.layer.cornerRadius = 36.0;
    addButton.layer.shadowColor = UIColor.blackColor.CGColor;
    addButton.layer.shadowRadius = 14.0;
    addButton.layer.shadowOffset = CGSizeMake(0.0, 6.0);
    UIImageSymbolConfiguration *plusConfig = [UIImageSymbolConfiguration configurationWithPointSize:24.0 weight:UIImageSymbolWeightSemibold];
    [addButton setImage:[UIImage systemImageNamed:@"plus" withConfiguration:plusConfig] forState:UIControlStateNormal];
    [addButton setTitle:[@"  " stringByAppendingString:BrowserLocalized(@"Add Feed")] forState:UIControlStateNormal];
    addButton.titleLabel.font = [UIFont systemFontOfSize:25.0 weight:UIFontWeightSemibold];
    [addButton addTarget:self action:@selector(addFeedPressed) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.view addSubview:addButton];
    self.addButton = addButton;

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.rowHeight = 86.0;
    tableView.backgroundColor = UIColor.clearColor;
    tableView.clipsToBounds = NO;
    tableView.remembersLastFocusedIndexPath = YES;
    [tableView registerClass:[BrowserFeedRowCell class] forCellReuseIdentifier:@"feed"];
    [self.view addSubview:tableView];
    self.tableView = tableView;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 36.0;
    layout.minimumLineSpacing = 44.0;
    layout.sectionInset = UIEdgeInsetsMake(24.0, 24.0, 80.0, 24.0);
    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    collectionView.dataSource = self;
    collectionView.delegate = self;
    collectionView.backgroundColor = UIColor.clearColor;
    collectionView.clipsToBounds = NO;
    collectionView.remembersLastFocusedIndexPath = YES;
    [collectionView registerClass:[BrowserFeedCardCell class] forCellWithReuseIdentifier:@"card"];
    [self.view addSubview:collectionView];
    self.collectionView = collectionView;

    UILabel *emptyLabel = [UILabel new];
    emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    emptyLabel.numberOfLines = 0;
    emptyLabel.textAlignment = NSTextAlignmentCenter;
    emptyLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightMedium];
    emptyLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    emptyLabel.hidden = YES;
    [self.view addSubview:emptyLabel];
    self.emptyLabel = emptyLabel;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.color = UIColor.whiteColor;
    spinner.hidesWhenStopped = YES;
    [self.view addSubview:spinner];
    self.spinner = spinner;

    [NSLayoutConstraint activateConstraints:@[
        [topShade.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [topShade.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [topShade.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [topShade.bottomAnchor constraintEqualToAnchor:backdrop.topAnchor],
        [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kFeedsTop - 8.0],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [sidebarTitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:110.0],
        [sidebarTitle.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kFeedsTop + 12.0],
        [tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:80.0],
        [tableView.topAnchor constraintEqualToAnchor:sidebarTitle.bottomAnchor constant:12.0],
        [tableView.bottomAnchor constraintEqualToAnchor:addButton.topAnchor constant:-20.0],
        [tableView.widthAnchor constraintEqualToConstant:kFeedsSidebarWidth],
        [addButton.leadingAnchor constraintEqualToAnchor:tableView.leadingAnchor],
        [addButton.widthAnchor constraintEqualToConstant:kFeedsSidebarWidth],
        [addButton.heightAnchor constraintEqualToConstant:72.0],
        [addButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-50.0],

        [chips.leadingAnchor constraintEqualToAnchor:collectionView.leadingAnchor constant:24.0],
        [chips.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kFeedsTop + 4.0],
        [collectionView.leadingAnchor constraintEqualToAnchor:tableView.trailingAnchor constant:30.0],
        [collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-56.0],
        [collectionView.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8.0],
        [collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [emptyLabel.centerXAnchor constraintEqualToAnchor:collectionView.centerXAnchor],
        [emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [emptyLabel.widthAnchor constraintLessThanOrEqualToConstant:900.0],
        [spinner.centerXAnchor constraintEqualToAnchor:collectionView.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

    ]];

    if ([BrowserFeedStore sharedStore].subscriptions.count > 0) {
        [self.spinner startAnimating];
        __weak typeof(self) weakSelf = self;
        [[BrowserFeedStore sharedStore] refreshWithCompletion:^{
            [weakSelf.spinner stopAnimating];
            [weakSelf reloadContent];
        }];
    }
    [self reloadContent]; // shows the last loaded articles while the new ones come in
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.headerChanged != nil) {
        self.headerChanged(self.headerSubtitle ?: @"");
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isBeingDismissed && self.headerChanged != nil) {
        self.headerChanged(nil);
    }
}

#pragma mark - Chips & buttons

- (UIButton *)chipWithTitle:(NSString *)title {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    [chip setTitle:title forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:25.0 weight:UIFontWeightSemibold];
    CGFloat textWidth = ceil([title sizeWithAttributes:@{NSFontAttributeName: chip.titleLabel.font}].width);
    [chip.widthAnchor constraintEqualToConstant:textWidth + 60.0].active = YES;
    chip.layer.cornerRadius = 30.0;
    [chip.heightAnchor constraintEqualToConstant:60.0].active = YES;
    [chip addTarget:self action:@selector(chipPressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
    return chip;
}

- (void)updateControls {
    UIView *focused = (UIView *)[UIFocusSystem focusSystemForEnvironment:self].focusedItem;
    for (UIButton *chip in @[self.allChip, self.unreadChip]) {
        BOOL chosen = (chip == self.unreadChip) == self.unreadOnly;
        BOOL light = chosen || chip == focused;
        chip.backgroundColor = light ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.1];
        [chip setTitleColor:light ? [UIColor colorWithWhite:0.1 alpha:1.0] : UIColor.whiteColor forState:UIControlStateNormal];
        chip.transform = chip == focused ? CGAffineTransformMakeScale(1.08, 1.08) : CGAffineTransformIdentity;
    }
    BOOL addFocused = (self.addButton == focused);
    UIColor *addContent = addFocused ? [UIColor colorWithWhite:0.1 alpha:1.0] : UIColor.whiteColor;
    self.addButton.backgroundColor = addFocused ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.08];
    [self.addButton setTitleColor:addContent forState:UIControlStateNormal];
    self.addButton.tintColor = addContent;
    self.addButton.layer.shadowOpacity = addFocused ? 0.35 : 0.0;
    self.addButton.transform = addFocused ? CGAffineTransformMakeScale(1.03, 1.03) : CGAffineTransformIdentity;
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    [coordinator addCoordinatedAnimations:^{ [self updateControls]; } completion:nil];
}

- (void)chipPressed:(UIButton *)chip {
    BOOL unreadOnly = (chip == self.unreadChip);
    if (unreadOnly == self.unreadOnly) {
        return;
    }
    self.unreadOnly = unreadOnly;
    [self updateControls];
    [self reloadContent];
}

- (void)addFeedPressed {
    void (^addFeed)(void) = self.addFeed;
    [self dismissViewControllerAnimated:YES completion:^{
        if (addFeed != nil) {
            addFeed();
        }
    }];
}

- (NSArray<BrowserFeedItem *> *)visibleItemsForFeedURL:(nullable NSString *)URLString {
    BrowserFeedStore *store = [BrowserFeedStore sharedStore];
    NSArray<BrowserFeedItem *> *items = [store itemsForFeedURL:URLString];
    if (!self.unreadOnly) {
        return items;
    }
    return [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(BrowserFeedItem *item, __unused NSDictionary *bindings) {
        return ![store isRead:item];
    }]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
    CGFloat available = CGRectGetWidth(self.collectionView.bounds) - layout.sectionInset.left - layout.sectionInset.right;
    CGFloat width = floor((available - 2.0 * layout.minimumInteritemSpacing) / 3.0);
    if (width > 0.0 && fabs(layout.itemSize.width - width) > 0.5) {
        layout.itemSize = CGSizeMake(width, kFeedsCardHeight);
        [layout invalidateLayout];
    }
}

#pragma mark - Data

- (void)reloadContent {
    BrowserFeedStore *store = [BrowserFeedStore sharedStore];
    if (self.selectedFeedURL != nil && ![store isSubscribedToURL:self.selectedFeedURL]) {
        self.selectedFeedURL = nil;
    }
    self.items = [self visibleItemsForFeedURL:self.selectedFeedURL];
    NSUInteger unread = [store unreadCountForFeedURL:nil];
    NSString *subtitle = nil;
    if (store.subscriptions.count == 0) {
        subtitle = BrowserLocalized(@"No feeds yet");
    } else if (unread == 0) {
        subtitle = BrowserLocalized(@"All read");
    } else {
        subtitle = [NSString stringWithFormat:BrowserLocalized(@"%lu new articles"), (unsigned long)unread];
    }
    if (![subtitle isEqualToString:self.headerSubtitle]) {
        self.headerSubtitle = subtitle;
        if (self.headerChanged != nil && self.viewIfLoaded.window != nil) {
            self.headerChanged(subtitle);
        }
    }
    [self updateControls];

    if (store.subscriptions.count == 0) {
        self.emptyLabel.text = BrowserLocalized(@"No feeds yet. Open a website and choose “Subscribe to Feed” in Settings – Orbrisa finds the feed for you.");
    } else if (self.items.count == 0 && self.unreadOnly && !store.isRefreshing) {
        self.emptyLabel.text = BrowserLocalized(@"All read");
    } else if (self.items.count == 0 && !store.isRefreshing) {
        self.emptyLabel.text = BrowserLocalized(@"No articles found. The site may be offline – try again later.");
    }
    self.emptyLabel.hidden = !(store.subscriptions.count == 0 || (self.items.count == 0 && !store.isRefreshing));
    [self.tableView reloadData];
    [self.collectionView reloadData];
}

- (NSDictionary<NSString *, NSString *> *)feedAtRow:(NSInteger)row {
    NSArray *subscriptions = [BrowserFeedStore sharedStore].subscriptions;
    return (row >= 1 && row - 1 < (NSInteger)subscriptions.count) ? subscriptions[(NSUInteger)(row - 1)] : nil;
}

#pragma mark - Feeds (table)

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    NSUInteger count = [BrowserFeedStore sharedStore].subscriptions.count;
    return count == 0 ? 0 : (NSInteger)count + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BrowserFeedRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"feed" forIndexPath:indexPath];
    NSDictionary *feed = [self feedAtRow:indexPath.row];
    NSString *URLString = feed[@"url"];
    NSString *name = feed != nil ? feed[@"title"] : BrowserLocalized(@"All Articles");
    cell.nameLabel.text = name;
    cell.badge.text = feed != nil ? [[name substringToIndex:MIN((NSUInteger)1, name.length)] uppercaseString] : @"★";
    cell.badge.backgroundColor = feed != nil ? [BrowserFeedStore colorForFeedURL:URLString] : UIColor.systemOrangeColor;
    NSUInteger unread = [[BrowserFeedStore sharedStore] unreadCountForFeedURL:URLString];
    cell.countLabel.text = [NSString stringWithFormat:@" %lu ", (unsigned long)unread];
    cell.countLabel.hidden = (unread == 0);
    [cell applyFocused:cell.isFocused];
    return cell;
}

- (void)tableView:(UITableView *)tableView didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context
withAnimationCoordinator:(__unused UIFocusAnimationCoordinator *)coordinator {
    NSIndexPath *next = context.nextFocusedIndexPath;
    if (next == nil || ![context.nextFocusedView isDescendantOfView:tableView]) {
        return;
    }
    // Moving through the feeds shows their articles right away, like the Apple TV app.
    NSString *URLString = [self feedAtRow:next.row][@"url"];
    if ((URLString == nil && self.selectedFeedURL == nil) || [URLString isEqualToString:self.selectedFeedURL]) {
        return;
    }
    self.selectedFeedURL = URLString;
    self.items = [self visibleItemsForFeedURL:URLString];
    [self.collectionView reloadData];
}

#pragma mark - Articles (collection)

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView numberOfItemsInSection:(__unused NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BrowserFeedCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"card" forIndexPath:indexPath];
    BrowserFeedItem *item = self.items[(NSUInteger)indexPath.item];
    BOOL unread = ![[BrowserFeedStore sharedStore] isRead:item];
    NSString *meta = [NSString stringWithFormat:@"%@%@  ·  %@", unread ? @"● " : @"", item.feedTitle ?: @"", [BrowserFeedStore relativeDateString:item.date]];
    NSMutableAttributedString *metaText = [[NSMutableAttributedString alloc] initWithString:meta];
    if (unread) {
        [metaText addAttribute:NSForegroundColorAttributeName value:UIColor.systemBlueColor range:NSMakeRange(0, 1)];
    }
    cell.metaLabel.attributedText = metaText;
    cell.titleLabel.text = item.title;
    cell.imageView.backgroundColor = [BrowserFeedStore colorForFeedURL:item.feedURL];
    cell.imageURL = item.imageURL;

    UIImage *cached = item.imageURL != nil ? [FeedsImageCache() objectForKey:item.imageURL] : nil;
    if (cached != nil) {
        cell.imageView.image = cached;
    } else if (item.imageURL != nil) {
        NSString *imageURL = item.imageURL;
        NSURL *URL = [NSURL URLWithString:imageURL];
        if (URL != nil) {
            [[NSURLSession.sharedSession dataTaskWithURL:URL completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
                UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
                if (image == nil) {
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [FeedsImageCache() setObject:image forKey:imageURL];
                    if ([cell.imageURL isEqualToString:imageURL]) {
                        cell.imageView.image = image;
                    }
                });
            }] resume];
        }
    }
    return cell;
}

- (void)collectionView:(__unused UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    BrowserFeedItem *item = self.items[(NSUInteger)indexPath.item];
    [[BrowserFeedStore sharedStore] markRead:item];
    void (^open)(NSString *) = self.openArticle;
    NSString *link = item.link;
    [self dismissViewControllerAnimated:YES completion:^{
        if (open != nil && link.length > 0) {
            open(link);
        }
    }];
}

#pragma mark - Remote

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.items.count > 0) {
        return @[self.collectionView];
    }
    return [BrowserFeedStore sharedStore].subscriptions.count > 0 ? @[self.tableView] : @[self.addButton];
}

- (void)confirmUnsubscribeFromFeed:(NSDictionary<NSString *, NSString *> *)feed {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:BrowserLocalized(@"Unsubscribe from “%@”?"), feed[@"title"]]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Unsubscribe") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[BrowserFeedStore sharedStore] unsubscribeFromURL:feed[@"url"]];
        self.selectedFeedURL = nil;
        [self reloadContent];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press.type == UIPressTypeMenu) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (press.type == UIPressTypePlayPause) {
        id<UIFocusItem> focused = [UIFocusSystem focusSystemForEnvironment:self].focusedItem;
        if ([focused isKindOfClass:[BrowserFeedRowCell class]]) {
            NSIndexPath *indexPath = [self.tableView indexPathForCell:(BrowserFeedRowCell *)focused];
            NSDictionary *feed = indexPath != nil ? [self feedAtRow:indexPath.row] : nil;
            if (feed != nil) {
                [self confirmUnsubscribeFromFeed:feed];
            }
        }
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
        return;
    }
    [super pressesBegan:presses withEvent:event];
}

@end
