# 소스 번들 — 작업 9 (읽기 모드)

> 이 파일은 작업 9 지침서와 **함께** 첨부합니다.
> 아래 코드는 작업 7(다크 모드)과 작업 8(콘텐츠 차단)이 모두 반영된 **현재 main 브랜치의 실제 원본**입니다.
> 커밋: `4a70a22` (Add ad and tracker blocking)
>
> 이 번들에 없는 파일은 수정하지 마십시오. 다른 파일의 내용이 필요하면 지어내지 말고 무엇이 필요한지 적어서 되물으십시오.

## 번들에 포함된 파일

| 파일 | 역할 | 이 작업에서 |
|---|---|---|
| `BrowserMenuCoordinator.h/.m` | 퀵/고급 메뉴 구성 | **수정** — `Appearance` 섹션에 `Reader Mode` 항목 |
| `ViewController.h/.m` | 메뉴·입력·탭 호스트 | **수정** — 컨트롤러 소유, 호스트 메서드 구현 |
| `BrowserDarkModeController.h/.m` | 작업 7 결과물 | 참고 — JS 주입 패턴, `data-browser-reader-mode` 건너뛰기 |
| `BrowserPreferencesStore.h` | 영구 설정 | 참고 — **작업 9에서는 값을 추가하지 않습니다** |
| `BrowserWebView.h` | WebKit 런타임 래퍼 | 참고 — `stringByEvaluatingJavaScriptFromString:` |
| `BrowserDOMInteractionService.h` | DOM 조회 서비스 | 참고 |
| `BrowserTabCoordinator.h` | 탭 관리 | 참고 — `activeWebView` |
| `BrowserContentBlockerController.h` | 작업 8 결과물 | 참고 |

### 주의

- `BrowserWebView`의 `stringByEvaluatingJavaScriptFromString:`은 **동기**입니다. 런루프를 돌리므로 반복 타이머나 `CADisplayLink`에서 부르면 안 됩니다. 메뉴 선택 시 한 번만 부르는 것은 괜찮습니다.
- `BrowserDarkModeController`는 이미 `data-browser-reader-mode` 속성이 있으면 주입을 건너뜁니다. 읽기 모드가 그 속성을 **설정해야** 동작합니다.
- 새 파일을 만들면 `project.pbxproj` 등록은 제가 합니다. 당신은 건드리지 마십시오.

---

FILE: _Project/Browser/BrowserMenuCoordinator.h

```objc
#import <UIKit/UIKit.h>
#import "BrowserWebView.h"

@class BrowserPreferencesStore;

@protocol BrowserMenuCoordinatorHost <NSObject>

@property (nonatomic, readonly) BrowserWebView *browserWebView;
@property (nonatomic, copy) NSString *browserPreviousURL;
@property (nonatomic) NSUInteger browserTextFontSize;
@property (nonatomic) BOOL browserFullscreenVideoPlaybackEnabled;
@property (nonatomic, readonly) BOOL browserTopMenuShowing;

- (void)browserPresentViewController:(UIViewController *)viewController;
- (void)browserLoadHomePage;
- (void)browserShowHints;
- (void)browserShowTabOverview;
- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage;
- (void)browserHideTopNav;
- (void)browserShowTopNav;
- (void)browserUpdateTextFontSize;
- (void)browserUpdateForcedDarkMode;
- (void)browserCaptureSnapshotForCurrentTab;
- (void)browserRecreateActiveWebViewPreservingCurrentURL;
- (void)browserBringCursorToFront;
- (void)browserPlayVideoUnderCursorIfAvailable;

@end

@interface BrowserMenuCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore;
- (void)showAdvancedMenu;

@end
```

---

FILE: _Project/Browser/BrowserMenuCoordinator.m

```objc
#import "BrowserMenuCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserContentBlockerController.h"
#import "BrowserWebView.h"

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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    self.panelWidth = MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds) * 0.38, 480.0), 700.0);
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

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.widthAnchor constraintEqualToConstant:self.panelWidth],
        [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16.0],
        [panelView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16.0],
        self.panelTrailingConstraint,

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
    self.panelTrailingConstraint.constant = -16.0;
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

    self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
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
    self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
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
        focusBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        focusBackgroundView.layer.cornerRadius = 12.0;
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
    titleLabel.textColor = titleColor;
    focusBackgroundView.alpha = cell.isFocused ? 1.0 : 0.0;
    return cell;
}

- (void)tableView:(UITableView *)tableView
didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context
withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    NSIndexPath *previousIndexPath = context.previouslyFocusedIndexPath;
    NSIndexPath *nextIndexPath = context.nextFocusedIndexPath;

    UITableViewCell *previousCell = previousIndexPath ? [tableView cellForRowAtIndexPath:previousIndexPath] : nil;
    UITableViewCell *nextCell = nextIndexPath ? [tableView cellForRowAtIndexPath:nextIndexPath] : nil;

    [coordinator addCoordinatedAnimations:^{
        UIView *previousFocusBackground = [previousCell.contentView viewWithTag:9292];
        previousFocusBackground.alpha = 0.0;

        UIView *nextFocusBackground = [nextCell.contentView viewWithTag:9292];
        nextFocusBackground.alpha = 1.0;
    } completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
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
    BrowserAdvancedMenuViewController *menuViewController = [[BrowserAdvancedMenuViewController alloc] initWithTitle:@"tvOS Browser"
                                                                                                            sections:[self advancedMenuSections]
                                                                                                          footerText:[self advancedMenuFooterText]];
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

- (void)presentContentBlockerDiagnostics {
    NSString *report = [[BrowserContentBlockerController sharedController] diagnosticsReport];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Content Blocker Diagnostics"
                                                                       message:report];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (BrowserAdvancedMenuItem *)contentBlockingToggleMenuItem {
    BOOL enabled = self.preferencesStore.contentBlockingEnabled;
    NSString *title = enabled ? @"Content Blocking: On" : @"Content Blocking: Off";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.preferencesStore.contentBlockingEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)forcedDarkModeToggleMenuItem {
    BOOL enabled = self.preferencesStore.forcedDarkModeEnabled;
    NSString *title = enabled ? @"Force Dark Mode: On" : @"Force Dark Mode: Off";
    __weak typeof(self) weakSelf = self;
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        weakSelf.preferencesStore.forcedDarkModeEnabled = !enabled;
        [weakSelf.host browserUpdateForcedDarkMode];
    }];
}

- (BrowserAdvancedMenuItem *)tapToClickToggleMenuItem {
    BOOL enabled = self.preferencesStore.tapToClickEnabled;
    NSString *title = enabled ? @"Tap to Click: On" : @"Tap to Click: Off";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.preferencesStore.tapToClickEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)openLinksInNewTabToggleMenuItem {
    BOOL enabled = self.preferencesStore.openLinksInNewTabOnClick;
    NSString *title = enabled ? @"Open Links in New Tab: On" : @"Open Links in New Tab: Off";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.preferencesStore.openLinksInNewTabOnClick = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)jsScrollFallbackToggleMenuItem {
    BOOL enabled = self.preferencesStore.jsScrollFallbackEnabled;
    NSString *title = enabled ? @"JS Scroll Fallback: On" : @"JS Scroll Fallback: Off";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.preferencesStore.jsScrollFallbackEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)dpadScrollToggleMenuItem {
    BOOL enabled = self.preferencesStore.dpadScrollEnabled;
    NSString *title = enabled ? @"D-Pad Page Scroll: On" : @"D-Pad Page Scroll: Off";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.preferencesStore.dpadScrollEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)edgeAutoScrollToggleMenuItem {
    BOOL enabled = self.preferencesStore.edgeAutoScrollEnabled;
    NSString *title = enabled ? @"Edge Auto-Scroll: On" : @"Edge Auto-Scroll: Off";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.preferencesStore.edgeAutoScrollEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)topNavigationVisibilityMenuItem {
    NSString *title = self.host.browserTopMenuShowing ? @"Hide Top Navigation bar" : @"Show Top Navigation bar";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
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
    
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self applyUserAgent:userAgent mobileMode:mobileMode];
    }];
}

- (BrowserAdvancedMenuItem *)pageScalingMenuItem {
    BOOL scalesPageToFit = [[self.host browserWebView] scalesPageToFit];
    NSString *title = scalesPageToFit ? @"Stop Scaling Pages to Fit" : @"Scale Pages to Fit";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
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

- (BrowserAdvancedMenuItem *)fullscreenVideoPlaybackToggleMenuItem {
    BOOL enabled = self.host.browserFullscreenVideoPlaybackEnabled;
    NSString *title = enabled ? @"Disable Full Screen player" : @"Enable Full Screen player";
    return [self advancedMenuItemWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        self.host.browserFullscreenVideoPlaybackEnabled = !enabled;
    }];
}

- (NSArray<BrowserAdvancedMenuSection *> *)advancedMenuSections {
    BrowserAdvancedMenuItem *increaseFontSizeItem = [self advancedMenuItemWithTitle:@"Increase Font Size"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        self.host.browserTextFontSize += 5;
        [self.host browserUpdateTextFontSize];
    }];
    BrowserAdvancedMenuItem *decreaseFontSizeItem = [self advancedMenuItemWithTitle:@"Decrease Font Size"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        self.host.browserTextFontSize -= 5;
        [self.host browserUpdateTextFontSize];
    }];
    BrowserAdvancedMenuItem *resetFontSizeItem = [self advancedMenuItemWithTitle:@"Reset Font Size"
                                                                            style:UIAlertActionStyleDefault
                                                                          handler:^{
        self.host.browserTextFontSize = 100;
        [self.host browserUpdateTextFontSize];
    }];
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

    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Navigation"
                                               items:@[
            [self homePageMenuItem],
            [self setCurrentPageAsHomePageMenuItem],
            [self favoritesMenuItem],
            [self historyMenuItem],
            [self showTabsMenuItem],
            [self newTabMenuItem],
        ]],
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
            [self forcedDarkModeToggleMenuItem],
            [self topNavigationVisibilityMenuItem],
            [self pageScalingMenuItem],
            increaseFontSizeItem,
            decreaseFontSizeItem,
            resetFontSizeItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Privacy & Blocking"
                                               items:@[
            [self contentBlockingToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Video Playback"
                                               items:@[
            [self fullscreenVideoPlaybackToggleMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Compatibility"
                                               items:@[
            [self userAgentModeMenuItem],
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
```

---

FILE: _Project/Browser/ViewController.h

```objc
//
//  ViewController.h
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import <UIKit/UIKit.h>
#import <GameKit/GameKit.h>

#import "BrowserWebView.h"
#import "BrowserTopBarView.h"

@interface ViewController : GCEventViewController <UIScrollViewDelegate, BrowserWebViewDelegate>

@property (nonatomic, retain) IBOutlet BrowserTopBarView *topMenuView;
@property (nonatomic, retain) IBOutlet UIView *browserContainerView;

@end
```

---

FILE: _Project/Browser/ViewController.m

```objc
//
//  ViewController.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "BrowserContentBlockerController.h"
#import "BrowserDarkModeController.h"
#import "BrowserMenuCoordinator.h"
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
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";

static UIColor *kTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserContentBlockerController *contentBlockerController;
@property (nonatomic) BrowserDarkModeController *darkModeController;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
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

    self.contentBlockerController = [BrowserContentBlockerController sharedController];
    [self.contentBlockerController prepareRuleListIfNeeded];

    self.darkModeController = [BrowserDarkModeController new];
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
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator
                                                                    preferencesStore:self.preferencesStore];

    self.topMenuView.delegate = self;
    self.topMenuView.loadingSpinner.hidesWhenStopped = YES;
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

    [self.tabCoordinator restoreInitialStateOrCreateFirstTab];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tabCoordinator webViewDidAppear];
    if (!self.preferencesStore.dontShowHintsOnLaunch && !self.displayedHintsOnLaunch) {
        [self showHintsAlert];
    }
    self.displayedHintsOnLaunch = YES;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
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
    if (self.topBarFocusActive) {
        return;
    }

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
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Hide Top Navigation bar?"
                                                                                         message:@"You can still open the side menu by double-tapping the Play/Pause button."
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Hide Bar"
                                                                    style:UIAlertActionStyleDestructive
                                                                  handler:^(__unused UIAlertAction *action) {
                    [self browserHideTopNav];
                }]];
                [self browserPresentViewController:alertController];
            } else {
                [self browserShowTopNav];
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
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Enter URL or Search Terms"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeURL;
        textField.placeholder = @"Enter URL or Search Terms";
        textField.textColor = kTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];

    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Search Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForQuery:textField.text];
        if (searchRequest != nil) {
            [weakSelf.webview loadRequest:searchRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Go To Website"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        if (textField.text.length == 0) {
            [weakSelf requestURLorSearchInput];
            return;
        }
        NSURLRequest *navigationRequest = [weakSelf.navigationService requestForEnteredAddressString:textField.text];
        if (navigationRequest != nil) {
            [weakSelf.webview loadRequest:navigationRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];

    UITextField *textField = alertController.textFields.firstObject;
    if (self.webview.request == nil || self.webview.request.URL.absoluteString.length > 0) {
        [textField becomeFirstResponder];
    }
}

- (void)requestURLorSearchInput {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Quick Menu"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    if (self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Go Forward"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self.webview goForward];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"Input URL or Search with Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showInputURLorSearchGoogle];
    }]];

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            self.tabCoordinator.previousURL = @"";
            [self.webview reload];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)showHintsAlert {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Usage Guide"
                                                                             message:@"Double press the touch area to switch between cursor & scroll mode.\nLightly tap the touch area while in cursor mode to click or open links in the current tab.\nPress and click the touch area on a link to open it in a new tab.\nSingle tap to Menu button to Go Back, or Exit on root page.\nSingle tap the Play/Pause button to: Go Forward, Enter URL or Reload Page.\nDouble tap the Play/Pause to show the Advanced Menu with more options.\nUse the tabs icon in the top bar to open the tab overview."
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    if (self.preferencesStore.dontShowHintsOnLaunch) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Always Show On Launch"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = NO;
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Don't Show This Again"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = YES;
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"Dismiss"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)browserHandlePrimaryActionWithSource:(BrowserPageActivationSource)source {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        return;
    }

    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    if (point.y < 0) {
        [self activateTopBarFocusMode];
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview source:source];
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
}

- (void)browserShowTopNav {
    self.viewModel.topNavigationBarVisible = YES;
    self.preferencesStore.topNavigationBarVisible = YES;
    [self.tabCoordinator setTopNavigationVisible:YES];
}

- (void)browserUpdateTextFontSize {
    [self updateTextFontSize];
}

- (void)browserUpdateForcedDarkMode {
    BOOL enabled = self.preferencesStore.forcedDarkModeEnabled;
    [self.darkModeController syncDarkModeState:enabled forWebView:self.webview];
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

- (void)browserPlayVideoUnderCursorIfAvailable {
    [self.videoPlaybackCoordinator playVideoUnderCursorIfAvailable];
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
    [self.darkModeController syncDarkModeState:self.preferencesStore.forcedDarkModeEnabled
                                    forWebView:self.webview];
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
    return self.presentedViewController;
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

- (void)browserRemoteInputControllerHandlePrimaryActionWithSource:(BrowserPageActivationSource)source {
    [self browserHandlePrimaryActionWithSource:source];
}

- (void)browserRemoteInputControllerHandleMenuPress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.webview.canGoBack) {
        [self.webview goBack];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Exit App?"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Exit"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            exit(EXIT_SUCCESS);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil]];
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

- (BOOL)browserRemoteInputControllerScrollActiveContainerByDelta:(CGPoint)delta atCursorPoint:(CGPoint)cursorPoint {
    if (self.webview == nil) {
        return NO;
    }
    CGPoint domPoint = [self.domInteractionService DOMPointForCursorOrigin:cursorPoint
                                                                    inView:self.view
                                                                   webView:self.webview];
    CGPoint clampedDOMPoint = CGPointMake(MAX(0.0, domPoint.x), MAX(0.0, domPoint.y));
    return [self.domInteractionService scrollActiveContainerByX:delta.x
                                                              y:delta.y
                                                        atPoint:clampedDOMPoint
                                                        webView:self.webview];
}

- (BOOL)browserRemoteInputControllerJSScrollFallbackEnabled {
    return self.preferencesStore.jsScrollFallbackEnabled;
}

- (BOOL)browserRemoteInputControllerDpadScrollEnabled {
    return self.preferencesStore.dpadScrollEnabled;
}

- (BOOL)browserRemoteInputControllerEdgeAutoScrollEnabled {
    return self.preferencesStore.edgeAutoScrollEnabled;
}

- (BOOL)browserRemoteInputControllerTapToClickEnabled {
    return self.preferencesStore.tapToClickEnabled;
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
    [self.tabCoordinator webViewDidStartLoad:webView];
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    if ([webView isKindOfClass:[BrowserWebView class]]) {
        if (self.preferencesStore.forcedDarkModeEnabled) {
            [self.darkModeController syncDarkModeState:YES forWebView:(BrowserWebView *)webView];
        }
        if (self.preferencesStore.contentBlockingEnabled) {
            BrowserWebView *targetWebView = (BrowserWebView *)webView;
            [[BrowserContentBlockerController sharedController] applyContentBlockingToWebView:targetWebView enabled:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[BrowserContentBlockerController sharedController] applyContentBlockingToWebView:targetWebView enabled:YES];
            });
        }
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

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Could Not Load Webpage"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Google This Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            if (searchRequest != nil) {
                [weakSelf.webview loadRequest:searchRequest];
            }
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Enter a URL or Search"
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

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesCancelled:presses withEvent:event];
    [super pressesCancelled:presses withEvent:event];
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
    [self.remoteInputController handleTouchesCancelled];
    [super touchesCancelled:touches withEvent:event];
}

@end
```

---

FILE: _Project/Browser/BrowserDarkModeController.h

```objc
#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserDarkModeController : NSObject

- (NSString *)applyDarkModeToWebView:(nullable BrowserWebView *)webView;
- (NSString *)removeDarkModeFromWebView:(nullable BrowserWebView *)webView;
- (void)syncDarkModeState:(BOOL)enabled forWebView:(nullable BrowserWebView *)webView;

@end

NS_ASSUME_NONNULL_END
```

---

FILE: _Project/Browser/BrowserDarkModeController.m

```objc
#import "BrowserDarkModeController.h"

#import "BrowserWebView.h"

@implementation BrowserDarkModeController

- (NSString *)applyDarkModeJavaScript {
    return @"(function(){"
            "var docEl = document.documentElement;"
            "if (!docEl) { return 'no-document'; }"
            "if (docEl.hasAttribute('data-browser-reader-mode')) {"
                "var existingReaderStyle = document.getElementById('__browser_forced_dark');"
                "if (existingReaderStyle && existingReaderStyle.parentNode) {"
                    "existingReaderStyle.parentNode.removeChild(existingReaderStyle);"
                "}"
                "return 'reader-mode';"
            "}"
            "var existing = document.getElementById('__browser_forced_dark');"
            "if (existing) { return 'already-applied'; }"
            "function parseRGBA(str) {"
                "if (!str || typeof str !== 'string') { return null; }"
                "var m = str.match(/rgba?\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)(?:\\s*,\\s*([\\d.]+))?\\s*\\)/i);"
                "if (!m) { return null; }"
                "var r = parseFloat(m[1]);"
                "var g = parseFloat(m[2]);"
                "var b = parseFloat(m[3]);"
                "var a = (typeof m[4] !== 'undefined' && m[4] !== '') ? parseFloat(m[4]) : 1.0;"
                "if (isNaN(r) || isNaN(g) || isNaN(b) || isNaN(a)) { return null; }"
                "return { r: r, g: g, b: b, a: a };"
            "}"
            "var bgColor = null;"
            "if (window.getComputedStyle) {"
                "if (document.body) {"
                    "var bodyBg = window.getComputedStyle(document.body).backgroundColor;"
                    "var parsedBody = parseRGBA(bodyBg);"
                    "if (parsedBody && parsedBody.a > 0) {"
                        "bgColor = parsedBody;"
                    "}"
                "}"
                "if (!bgColor && docEl) {"
                    "var htmlBg = window.getComputedStyle(docEl).backgroundColor;"
                    "var parsedHtml = parseRGBA(htmlBg);"
                    "if (parsedHtml && parsedHtml.a > 0) {"
                        "bgColor = parsedHtml;"
                    "}"
                "}"
            "}"
            "if (bgColor && bgColor.a > 0) {"
                "var luminance = (0.299 * bgColor.r + 0.587 * bgColor.g + 0.114 * bgColor.b) / 255.0;"
                "if (luminance < 0.4) {"
                    "return 'already-dark';"
                "}"
            "}"
            "var style = document.createElement('style');"
            "style.id = '__browser_forced_dark';"
            "style.textContent = 'html { filter: invert(1) hue-rotate(180deg) !important; background: #121212 !important; }\\n' +"
                                "'img, video, iframe, canvas, svg, picture, embed, object, [style*=\"background-image\"] { filter: invert(1) hue-rotate(180deg) !important; }';"
            "docEl.appendChild(style);"
            "return 'applied';"
           "})()";
}

- (NSString *)removeDarkModeJavaScript {
    return @"(function(){"
            "var existing = document.getElementById('__browser_forced_dark');"
            "if (existing && existing.parentNode) {"
                "existing.parentNode.removeChild(existing);"
                "return 'removed';"
            "}"
            "return 'none';"
           "})()";
}

- (NSString *)applyDarkModeToWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"";
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self applyDarkModeJavaScript]] ?: @"";
    NSLog(@"[InputTrace][DarkMode] apply result=%@", result);
    return result;
}

- (NSString *)removeDarkModeFromWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @"";
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self removeDarkModeJavaScript]] ?: @"";
    NSLog(@"[InputTrace][DarkMode] remove result=%@", result);
    return result;
}

- (void)syncDarkModeState:(BOOL)enabled forWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }
    if (enabled) {
        [self applyDarkModeToWebView:webView];
    } else {
        [self removeDarkModeFromWebView:webView];
    }
}

@end
```

---

FILE: _Project/Browser/BrowserPreferencesStore.h

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPreferencesStore : NSObject

+ (NSString *)desktopUserAgent;
+ (NSString *)mobileUserAgent;

@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL mobileModeEnabled;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) NSUInteger textFontSize;
@property (nonatomic) BOOL fullscreenVideoPlaybackEnabled;
@property (nonatomic) BOOL scalePagesToFit;
@property (nonatomic) BOOL dontShowHintsOnLaunch;
@property (nonatomic, copy) NSString *homePageURLString;
@property (nonatomic) BOOL jsScrollFallbackEnabled;
@property (nonatomic) BOOL dpadScrollEnabled;
@property (nonatomic) BOOL edgeAutoScrollEnabled;
@property (nonatomic) BOOL tapToClickEnabled;
@property (nonatomic) BOOL openLinksInNewTabOnClick;
@property (nonatomic) BOOL forcedDarkModeEnabled;
@property (nonatomic) BOOL contentBlockingEnabled;

- (void)ensureUserAgentConsistency;

@end

NS_ASSUME_NONNULL_END
```

---

FILE: _Project/Browser/BrowserWebView.h

```objc
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserWebViewDelegate <NSObject>

@optional
- (BOOL)webView:(id _Nonnull)webView shouldStartLoadWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (BOOL)webView:(id _Nonnull)webView shouldCreateNewTabWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (void)webViewDidStartLoad:(id _Nonnull)webView;
- (void)webViewDidFinishLoad:(id _Nonnull)webView;
- (void)webView:(id _Nonnull)webView didFailLoadWithError:(NSError * _Nonnull)error;

@end

@interface BrowserWebView : UIView

@property (nullable, nonatomic, weak) id<BrowserWebViewDelegate> delegate;
@property (nullable, nonatomic, readonly, strong) NSURLRequest *request;
@property (nullable, nonatomic, readonly, strong) UIScrollView *scrollView;
@property (nullable, nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, getter=canGoBack) BOOL canGoBack;
@property (nonatomic, readonly, getter=canGoForward) BOOL canGoForward;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic) BOOL scalesPageToFit;

- (instancetype)initWithUserAgent:(NSString * _Nullable)userAgent
      allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback NS_DESIGNATED_INITIALIZER;

- (void)loadRequest:(NSURLRequest * _Nullable)request;
- (void)reload;
- (void)goBack;
- (void)goForward;
- (nullable NSString *)stringByEvaluatingJavaScriptFromString:(NSString * _Nonnull)script;
- (NSString * _Nonnull)runtimeMediaPreferenceReport;
- (void)setUserAgent:(NSString * _Nullable)userAgent;
- (void)pauseAllMediaPlayback;

+ (void)installRuleListToConfiguration:(id)configuration;

+ (nullable NSData *)cookieDataRepresentation;
+ (NSArray<NSHTTPCookie *> * _Nonnull)allCookies;
+ (void)restoreCookiesFromData:(NSData * _Nullable)cookieData;
+ (void)clearCachedDataWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)clearCookiesWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)resetWebsiteDataWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
```

---

FILE: _Project/Browser/BrowserDOMInteractionService.h

```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserDOMInteractionService : NSObject

- (CGPoint)DOMPointForCursorOrigin:(CGPoint)cursorOrigin
                            inView:(UIView *)containerView
                           webView:(BrowserWebView *)webView;
- (NSString *)evaluateResolvedElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body;
- (NSString *)evaluateEditableElementJavaScriptAtPoint:(CGPoint)point
                                                webView:(BrowserWebView *)webView
                                                   body:(NSString *)body;
- (NSString *)evaluateHoverStateJavaScriptAtPoint:(CGPoint)point
                                           webView:(BrowserWebView *)webView;
- (NSString *)javaScriptEscapedString:(NSString *)string;
- (BOOL)scrollActiveContainerByX:(CGFloat)dx
                               y:(CGFloat)dy
                         atPoint:(CGPoint)domPoint
                         webView:(BrowserWebView *)webView;
- (NSDictionary *)videoInfoAtDOMPoint:(CGPoint)point
                               webView:(BrowserWebView *)webView;
- (NSDictionary *)linkInfoAtDOMPoint:(CGPoint)point
                              webView:(BrowserWebView *)webView;
- (NSDictionary *)directVideoInfoAtDOMPoint:(CGPoint)point
                                     webView:(BrowserWebView *)webView;
- (BOOL)isVideoActivationTargetAtDOMPoint:(CGPoint)point
                                   webView:(BrowserWebView *)webView;
- (BOOL)isVideoDismissTargetAtDOMPoint:(CGPoint)point
                                webView:(BrowserWebView *)webView;
- (NSDictionary *)primedVideoInfoAtDOMPoint:(CGPoint)point
                                     webView:(BrowserWebView *)webView;
- (NSDictionary *)activateVideoTargetAtDOMPoint:(CGPoint)point
                                         webView:(BrowserWebView *)webView
                                         timeout:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
```

---

FILE: _Project/Browser/BrowserTabCoordinator.h

```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserNavigationService;
@class BrowserPreferencesStore;
@class BrowserSessionStore;
@class BrowserTabViewModel;
@class BrowserTopBarView;
@class BrowserViewModel;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserTabCoordinatorHost <NSObject>

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController;
- (void)browserTabCoordinatorUpdateTextFontSize;
- (BOOL)browserTabCoordinatorIsCursorModeEnabled;
- (BOOL)browserTabCoordinatorIsTabOverviewVisible;

@end

@interface BrowserTabCoordinator : NSObject

@property (nonatomic, readonly, nullable) BrowserWebView *activeWebView;
@property (nonatomic, readonly, nullable) BrowserTabViewModel *activeTab;
@property (nonatomic, copy) NSString *requestURL;
@property (nonatomic, copy) NSString *previousURL;

- (instancetype)initWithHost:(id<BrowserTabCoordinatorHost>)host
                   viewModel:(BrowserViewModel *)viewModel
            preferencesStore:(BrowserPreferencesStore *)preferencesStore
           navigationService:(BrowserNavigationService *)navigationService
                sessionStore:(BrowserSessionStore *)sessionStore
           browserContainerView:(UIView *)browserContainerView
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView
     manualScrollPanRecognizer:(UIPanGestureRecognizer *)manualScrollPanRecognizer
             webViewDelegate:(id)webViewDelegate
         scrollViewAllowBounces:(BOOL)scrollViewAllowBounces NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)restoreInitialStateOrCreateFirstTab;
- (void)webViewDidAppear;
- (void)loadHomePage;
- (void)createNewTabLoadingHomePage:(BOOL)loadHomePage;
- (BOOL)createNewTabWithRequest:(NSURLRequest *)request;
- (void)switchToTabAtIndex:(NSInteger)tabIndex;
- (void)closeTabAtIndex:(NSInteger)tabIndex;
- (void)recreateActiveWebViewPreservingCurrentURL;
- (void)captureSnapshotForCurrentTab;
- (void)prepareTabOverviewThumbnails;
- (void)persistSession;
- (void)handleWebViewPanGesture:(UIPanGestureRecognizer *)gestureRecognizer;
- (void)webViewDidStartLoad:(id)webView;
- (void)webViewDidFinishLoad:(id)webView;
- (void)prepareTabForRequest:(NSURLRequest *)request webView:(id)webView;
- (void)setTopNavigationVisible:(BOOL)visible;
- (BrowserTabViewModel *)tabForWebView:(id)webView;
- (BOOL)isPrimaryDocumentRequest:(NSURLRequest *)request;

@end

NS_ASSUME_NONNULL_END
```

---

FILE: _Project/Browser/BrowserContentBlockerController.h

```objc
#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserContentBlockerController : NSObject

@property (nonatomic, readonly) BOOL ruleListSupported;
@property (nonatomic, readonly, copy) NSString *compilationStatusString;
@property (nonatomic, readonly) NSUInteger ruleCount;

+ (instancetype)sharedController;
- (void)prepareRuleListIfNeeded;
- (nullable id)compiledRuleList;
- (NSString *)applyContentBlockingToWebView:(nullable BrowserWebView *)webView enabled:(BOOL)enabled;
- (NSString *)diagnosticsReport;

@end

NS_ASSUME_NONNULL_END
```

---

