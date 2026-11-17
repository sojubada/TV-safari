#import "BrowserNavigationService.h"

#import "BrowserPreferencesStore.h"
#import "BrowserTabViewModel.h"

static NSString * const kHistoryDefaultsKey = @"HISTORY";
static NSUInteger const kMaximumHistoryCount = 100;

@interface BrowserNavigationService ()

@property (nonatomic) BrowserPreferencesStore *preferencesStore;

@end

@implementation BrowserNavigationService

- (instancetype)init {
    return [self initWithPreferencesStore:[BrowserPreferencesStore new]];
}

- (instancetype)initWithPreferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
    }
    return self;
}

- (NSURLRequest *)homePageRequest {
    NSString *homePageURLString = self.preferencesStore.homePageURLString;
    if (homePageURLString.length == 0) {
        homePageURLString = @"http://www.google.com";
    }
    return [self requestForURLString:homePageURLString];
}

- (NSURLRequest *)requestForEnteredAddressString:(NSString *)addressString {
    NSString *trimmedAddress = [self trimmedString:addressString];
    if (trimmedAddress.length == 0) {
        return nil;
    }
    
    self.httpsFirstAddress = nil;
    if (![trimmedAddress hasPrefix:@"http://"] && ![trimmedAddress hasPrefix:@"https://"]) {
        // HTTPS first. An address typed without a scheme is retried once over
        // http:// only if the secure connection cannot be made (see
        // httpFallbackRequestForFailedURL:).
        self.httpsFirstAddress = trimmedAddress;
        trimmedAddress = [@"https://" stringByAppendingString:trimmedAddress];
    }
    return [self requestForURLString:trimmedAddress];
}

- (NSURLRequest *)httpFallbackRequestForFailedURL:(NSURL *)failedURL {
    NSString *address = self.httpsFirstAddress;
    if (address.length == 0 || failedURL == nil || ![failedURL.scheme isEqualToString:@"https"]) {
        return nil;
    }
    NSString *expected = [@"https://" stringByAppendingString:address];
    if (![failedURL.absoluteString isEqualToString:expected] &&
        ![failedURL.absoluteString isEqualToString:[expected stringByAppendingString:@"/"]]) {
        return nil;
    }
    self.httpsFirstAddress = nil; // one retry per typed address
    return [self requestForURLString:[@"http://" stringByAppendingString:address]];
}

- (NSURLRequest *)googleSearchRequestForQuery:(NSString *)query {
    NSString *sanitizedQuery = [self sanitizedSearchQuery:query];
    if (sanitizedQuery.length == 0) {
        return nil;
    }
    
    NSString *searchURLString = [NSString stringWithFormat:@"https://www.google.com/search?q=%@", sanitizedQuery];
    return [self requestForURLString:searchURLString];
}

- (NSURLRequest *)googleSearchRequestForFailedRequestURLString:(NSString *)requestURLString {
    NSString *searchQuery = [self trimmedString:requestURLString];
    if (searchQuery.length == 0) {
        return nil;
    }
    
    if ([searchQuery hasSuffix:@"/"]) {
        searchQuery = [searchQuery substringToIndex:searchQuery.length - 1];
    }
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"http://" withString:@""];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"https://" withString:@""];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"www." withString:@""];
    
    return [self googleSearchRequestForQuery:searchQuery];
}

- (void)updateTab:(BrowserTabViewModel *)tab
    withPageTitle:(NSString *)pageTitle
  currentURLString:(NSString *)currentURLString {
    if (tab == nil) {
        return;
    }
    
    NSString *safeTitle = pageTitle ?: @"";
    NSString *safeURLString = currentURLString ?: @"";
    tab.title = safeTitle.length > 0 ? safeTitle : @"New Tab";
    tab.URLString = safeURLString;
    
    [self persistHistoryItemWithURLString:safeURLString title:safeTitle];
}

- (BOOL)shouldIgnoreLoadError:(NSError *)error {
    NSInteger errorCode = error.code;
    return errorCode == 999 || errorCode == 204;
}

- (NSURLRequest *)requestForURLString:(NSString *)URLString {
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    NSString *userAgent = self.preferencesStore.userAgent;
    if (userAgent.length > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
    return request;
}

- (NSString *)trimmedString:(NSString *)string {
    if (string == nil) {
        return @"";
    }
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)sanitizedSearchQuery:(NSString *)query {
    NSString *trimmedQuery = [self trimmedString:query];
    if (trimmedQuery.length == 0) {
        return @"";
    }
    
    NSString *searchQuery = [trimmedQuery stringByReplacingOccurrencesOfString:@" " withString:@"+"];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"." withString:@"+"];
    while ([searchQuery containsString:@"++"]) {
        searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"++" withString:@"+"];
    }
    
    return [searchQuery stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

- (void)persistHistoryItemWithURLString:(NSString *)URLString title:(NSString *)title {
    if (URLString.length == 0) {
        return;
    }
    
    NSArray *historyItem = @[URLString, title ?: @""];
    NSMutableArray *historyItems = [NSMutableArray arrayWithObject:historyItem];
    NSArray *storedHistory = [[NSUserDefaults standardUserDefaults] arrayForKey:kHistoryDefaultsKey];
    if (storedHistory.count > 0) {
        NSArray *latestItem = storedHistory.firstObject;
        if ([latestItem isKindOfClass:[NSArray class]] && latestItem.count > 0 && [latestItem[0] isEqualToString:URLString]) {
            [historyItems removeObjectAtIndex:0];
        }
        [historyItems addObjectsFromArray:storedHistory];
    }
    
    while (historyItems.count > kMaximumHistoryCount) {
        [historyItems removeLastObject];
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:historyItems forKey:kHistoryDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
