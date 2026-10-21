#import "BrowserReportViewController.h"

static NSInteger const kBrowserReportLabelTag = 7171;
static NSInteger const kBrowserReportFocusTag = 7272;

// Rows are focusable, which is what makes the direction pad scroll the report
// on tvOS. A plain text view is not focusable and would be stuck at the top.
@interface BrowserReportLineCell : UITableViewCell
@end

@implementation BrowserReportLineCell

- (BOOL)canBecomeFocused {
    return YES;
}

@end

@interface BrowserReportViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, copy) NSString *reportTitle;
@property (nonatomic, copy) NSArray<NSString *> *lines;
@property (nonatomic) UITableView *tableView;

@end

@implementation BrowserReportViewController

- (instancetype)initWithTitle:(NSString *)title reportText:(NSString *)reportText {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _reportTitle = [title copy] ?: @"Report";
        NSArray<NSString *> *rawLines = [(reportText ?: @"") componentsSeparatedByString:@"\n"];
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:rawLines.count];
        for (NSString *line in rawLines) {
            [lines addObject:line.length > 0 ? line : @" "];
        }
        _lines = lines.count > 0 ? lines : @[@"(empty)"];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.96];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = self.reportTitle;
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont systemFontOfSize:44.0 weight:UIFontWeightSemibold];
    [self.view addSubview:titleLabel];

    UILabel *hintLabel = [UILabel new];
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    hintLabel.text = @"Up / Down to scroll · Menu to close";
    hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    hintLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightRegular];
    [self.view addSubview:hintLabel];

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.backgroundColor = UIColor.clearColor;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 40.0;
    tableView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:tableView];
    self.tableView = tableView;

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:80.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-80.0],
        [titleLabel.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:40.0],

        [hintLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [hintLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6.0],

        [tableView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:60.0],
        [tableView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-60.0],
        [tableView.topAnchor constraintEqualToAnchor:hintLabel.bottomAnchor constant:20.0],
        [tableView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-40.0],
    ]];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return self.tableView != nil ? @[self.tableView] : [super preferredFocusEnvironments];
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.lines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const kCellIdentifier = @"BrowserReportLineCell";
    BrowserReportLineCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    if (cell == nil) {
        cell = [[BrowserReportLineCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kCellIdentifier];
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([cell respondsToSelector:@selector(setFocusStyle:)]) {
            [cell setValue:@(1) forKey:@"focusStyle"];
        }

        UIView *focusView = [UIView new];
        focusView.translatesAutoresizingMaskIntoConstraints = NO;
        focusView.tag = kBrowserReportFocusTag;
        focusView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        focusView.layer.cornerRadius = 8.0;
        focusView.alpha = 0.0;
        [cell.contentView addSubview:focusView];

        UILabel *label = [UILabel new];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.tag = kBrowserReportLabelTag;
        label.numberOfLines = 0;
        label.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        label.font = [UIFont monospacedSystemFontOfSize:27.0 weight:UIFontWeightRegular];
        [cell.contentView addSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [focusView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
            [focusView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
            [focusView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
            [focusView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],

            [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],
            [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:5.0],
            [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-5.0],
        ]];
    }

    UILabel *label = (UILabel *)[cell.contentView viewWithTag:kBrowserReportLabelTag];
    label.text = self.lines[(NSUInteger)indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView
didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context
withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    UITableViewCell *previousCell = context.previouslyFocusedIndexPath
        ? [tableView cellForRowAtIndexPath:context.previouslyFocusedIndexPath] : nil;
    UITableViewCell *nextCell = context.nextFocusedIndexPath
        ? [tableView cellForRowAtIndexPath:context.nextFocusedIndexPath] : nil;
    [coordinator addCoordinatedAnimations:^{
        [previousCell.contentView viewWithTag:kBrowserReportFocusTag].alpha = 0.0;
        [nextCell.contentView viewWithTag:kBrowserReportFocusTag].alpha = 1.0;
    } completion:nil];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end
