#import "BrowserProbeWorkbenchViewController.h"

static CGFloat const kWorkbenchRowHeight = 64.0;
static CGFloat const kWorkbenchHeaderHeight = 50.0;

@implementation BrowserWorkbenchItem

+ (instancetype)itemWithTitle:(NSString *)title action:(NSString * _Nullable (^)(void))action {
    BrowserWorkbenchItem *item = [BrowserWorkbenchItem new];
    if (item) {
        item->_title = [title copy];
        item->_action = [action copy];
    }
    return item;
}

@end

@implementation BrowserWorkbenchSection

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserWorkbenchItem *> *)items {
    BrowserWorkbenchSection *section = [BrowserWorkbenchSection new];
    if (section) {
        section->_title = [title copy] ?: @"";
        section->_items = [items copy] ?: @[];
    }
    return section;
}

@end

@interface BrowserProbeWorkbenchViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, copy) NSArray<BrowserWorkbenchSection *> *sections;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) UILabel *titleLabel;

@end

@implementation BrowserProbeWorkbenchViewController

- (instancetype)initWithSections:(NSArray<BrowserWorkbenchSection *> *)sections {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _sections = [sections copy] ?: @[];
    }
    return self;
}

- (void)setSections:(NSArray<BrowserWorkbenchSection *> *)sections {
    _sections = [sections copy] ?: @[];
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.97];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = @"탐침 작업대";
    self.titleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.97];
    self.titleLabel.font = [UIFont systemFontOfSize:34.0 weight:UIFontWeightBold];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleLabel];

    UILabel *hintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    hintLabel.text = @"오른쪽 페이지에 바로 적용됩니다 · Menu로 닫기";
    hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    hintLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightRegular];
    hintLabel.numberOfLines = 2;
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:hintLabel];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.rowHeight = kWorkbenchRowHeight;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];

    self.resultLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.resultLabel.text = @"항목을 고르면 결과가 여기에 나옵니다.";
    self.resultLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    self.resultLabel.font = [UIFont fontWithName:@"Menlo" size:24.0]
        ?: [UIFont systemFontOfSize:24.0 weight:UIFontWeightRegular];
    self.resultLabel.numberOfLines = 0;
    self.resultLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.resultLabel];

    UIView *resultBackground = [[UIView alloc] initWithFrame:CGRectZero];
    resultBackground.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    resultBackground.layer.cornerRadius = 10.0;
    resultBackground.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view insertSubview:resultBackground belowSubview:self.resultLabel];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:guide.topAnchor constant:16.0],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24.0],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor constant:-24.0],

        [hintLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:6.0],
        [hintLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24.0],
        [hintLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24.0],

        [self.tableView.topAnchor constraintEqualToAnchor:hintLabel.bottomAnchor constant:10.0],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:resultBackground.topAnchor constant:-12.0],

        [resultBackground.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:18.0],
        [resultBackground.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-18.0],
        [resultBackground.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-16.0],
        [resultBackground.heightAnchor constraintGreaterThanOrEqualToConstant:120.0],

        [self.resultLabel.leadingAnchor constraintEqualToAnchor:resultBackground.leadingAnchor constant:16.0],
        [self.resultLabel.trailingAnchor constraintEqualToAnchor:resultBackground.trailingAnchor constant:-16.0],
        [self.resultLabel.topAnchor constraintEqualToAnchor:resultBackground.topAnchor constant:14.0],
        [self.resultLabel.bottomAnchor constraintEqualToAnchor:resultBackground.bottomAnchor constant:-14.0],
    ]];

    UITapGestureRecognizer *menuRecognizer =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuPress)];
    menuRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    [self.view addGestureRecognizer:menuRecognizer];
}

- (void)handleMenuPress {
    [self.workbenchDelegate probeWorkbenchDidRequestClose:self];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return self.tableView != nil ? @[self.tableView] : @[];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return 0;
    }
    return (NSInteger)self.sections[(NSUInteger)section].items.count;
}

- (CGFloat)tableView:(__unused UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count ||
        self.sections[(NSUInteger)section].title.length == 0) {
        return 0.0;
    }
    return kWorkbenchHeaderHeight;
}

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
    label.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-16.0],
        [label.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8.0],
    ]];
    return header;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const kIdentifier = @"BrowserWorkbenchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kIdentifier];
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = [self itemAtIndexPath:indexPath].title;
    cell.textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    cell.textLabel.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightMedium];
    cell.textLabel.numberOfLines = 2;
    return cell;
}

#pragma mark - UITableViewDelegate

- (BOOL)tableView:(__unused UITableView *)tableView canFocusRowAtIndexPath:(__unused NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    BrowserWorkbenchItem *item = [self itemAtIndexPath:indexPath];
    if (item.action == nil) {
        return;
    }
    NSString *result = item.action();
    self.resultLabel.text = result.length > 0 ? result : @"(결과 없음)";
    [self.tableView reloadData];
}

- (BrowserWorkbenchItem *)itemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section < 0 || indexPath.section >= (NSInteger)self.sections.count) {
        return nil;
    }
    BrowserWorkbenchSection *section = self.sections[(NSUInteger)indexPath.section];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)section.items.count) {
        return nil;
    }
    return section.items[(NSUInteger)indexPath.row];
}

@end
