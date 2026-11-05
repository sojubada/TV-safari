//
//  BrowserFeedStore.m
//  Orbrisa
//

#import "BrowserFeedStore.h"
#import "BrowserLocalization.h"
#import "BrowserLog.h"

static NSString * const kFeedSubscriptionsKey = @"BrowserFeedSubscriptions";
static NSString * const kFeedReadLinksKey = @"BrowserFeedReadLinks";
static NSUInteger const kFeedMaxReadLinks = 3000;
static NSUInteger const kFeedMaxItemsPerFeed = 40;

@implementation BrowserFeedItem
@end

#pragma mark - Parser (RSS 2.0, RSS 1.0 and Atom)

@interface BrowserFeedParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *feedURL;
@property (nonatomic, copy) NSString *channelTitle;
@property (nonatomic) NSMutableArray<BrowserFeedItem *> *items;
@property (nonatomic) BrowserFeedItem *current;
@property (nonatomic) NSMutableString *buffer;
@property (nonatomic) NSInteger depthInItem;
@end

@implementation BrowserFeedParser

+ (NSDate *)dateFromString:(NSString *)string {
    NSString *trimmed = [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return nil;
    }
    static NSArray<NSDateFormatter *> *formatters;
    static NSISO8601DateFormatter *iso;
    static NSISO8601DateFormatter *isoFraction;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (NSString *format in @[@"EEE, dd MMM yyyy HH:mm:ss Z", @"EEE, dd MMM yyyy HH:mm:ss zzz", @"EEE, d MMM yyyy HH:mm:ss Z",
                                   @"EEE, d MMM yyyy HH:mm Z", @"dd MMM yyyy HH:mm:ss Z", @"yyyy-MM-dd HH:mm:ss"]) {
            NSDateFormatter *formatter = [NSDateFormatter new];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.dateFormat = format;
            [list addObject:formatter];
        }
        formatters = list;
        iso = [NSISO8601DateFormatter new];
        isoFraction = [NSISO8601DateFormatter new];
        isoFraction.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    NSDate *date = [iso dateFromString:trimmed] ?: [isoFraction dateFromString:trimmed];
    for (NSDateFormatter *formatter in formatters) {
        if (date != nil) {
            break;
        }
        date = [formatter dateFromString:trimmed];
    }
    return date;
}

+ (NSString *)plainTextFromHTML:(NSString *)html {
    if (html.length == 0) {
        return @"";
    }
    NSString *text = [html stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, html.length)];
    NSDictionary *entities = @{@"&amp;": @"&", @"&lt;": @"<", @"&gt;": @">", @"&quot;": @"\"", @"&#39;": @"'", @"&apos;": @"'", @"&nbsp;": @" ",
                               @"&#8217;": @"’", @"&#8216;": @"‘", @"&#8220;": @"“", @"&#8221;": @"”", @"&#8211;": @"–", @"&#8212;": @"—", @"&hellip;": @"…"};
    for (NSString *entity in entities) {
        text = [text stringByReplacingOccurrencesOfString:entity withString:entities[entity]];
    }
    text = [text stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

+ (NSString *)firstImageInHTML:(NSString *)html {
    if (html.length == 0) {
        return nil;
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<img[^>]+src=[\"']([^\"']+)[\"']" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    return match != nil ? [html substringWithRange:[match rangeAtIndex:1]] : nil;
}

- (void)parser:(__unused NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(__unused NSString *)namespaceURI
 qualifiedName:(__unused NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    NSString *name = elementName.lowercaseString;
    if ([name isEqualToString:@"item"] || [name isEqualToString:@"entry"]) {
        self.current = [BrowserFeedItem new];
        self.current.title = @"";
        self.current.link = @"";
        self.current.summary = @"";
        self.current.feedURL = self.feedURL;
        self.depthInItem = 1;
        self.buffer = [NSMutableString string];
        return;
    }
    if (self.current != nil) {
        self.depthInItem += 1;
        if ([name isEqualToString:@"link"] && attributes[@"href"] != nil) {
            NSString *rel = attributes[@"rel"] ?: @"alternate";
            if ([rel isEqualToString:@"alternate"] && self.current.link.length == 0) {
                self.current.link = attributes[@"href"];
            }
        }
        NSString *type = attributes[@"type"] ?: @"";
        NSString *URL = attributes[@"url"];
        if (URL.length > 0 && self.current.imageURL == nil &&
            ([name isEqualToString:@"media:thumbnail"] ||
             ([name isEqualToString:@"media:content"] && ([type hasPrefix:@"image"] || [attributes[@"medium"] isEqualToString:@"image"])) ||
             ([name isEqualToString:@"enclosure"] && [type hasPrefix:@"image"]))) {
            self.current.imageURL = URL;
        }
    }
    self.buffer = [NSMutableString string];
}

- (void)parser:(__unused NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.buffer appendString:string];
}

- (void)parser:(__unused NSXMLParser *)parser foundCDATA:(NSData *)CDATABlock {
    NSString *string = [[NSString alloc] initWithData:CDATABlock encoding:NSUTF8StringEncoding];
    if (string != nil) {
        [self.buffer appendString:string];
    }
}

- (void)parser:(__unused NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(__unused NSString *)namespaceURI
 qualifiedName:(__unused NSString *)qName {
    NSString *name = elementName.lowercaseString;
    NSString *value = [self.buffer stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (self.current == nil) {
        if ([name isEqualToString:@"title"] && self.channelTitle.length == 0) {
            self.channelTitle = [BrowserFeedParser plainTextFromHTML:value];
        }
        self.buffer = [NSMutableString string];
        return;
    }
    if ([name isEqualToString:@"item"] || [name isEqualToString:@"entry"]) {
        if (self.current.title.length > 0 && self.current.link.length > 0 && self.items.count < kFeedMaxItemsPerFeed) {
            [self.items addObject:self.current];
        }
        self.current = nil;
        self.buffer = [NSMutableString string];
        return;
    }
    self.depthInItem -= 1;
    if ([name isEqualToString:@"title"]) {
        self.current.title = [BrowserFeedParser plainTextFromHTML:value];
    } else if ([name isEqualToString:@"link"] && value.length > 0 && self.current.link.length == 0) {
        self.current.link = value;
    } else if ([name isEqualToString:@"guid"] && self.current.link.length == 0 && [value hasPrefix:@"http"]) {
        self.current.link = value;
    } else if ([@[@"description", @"summary", @"content", @"content:encoded"] containsObject:name] && value.length > 0) {
        if (self.current.imageURL == nil) {
            self.current.imageURL = [BrowserFeedParser firstImageInHTML:value];
        }
        if (self.current.summary.length == 0 || [name isEqualToString:@"description"] || [name isEqualToString:@"summary"]) {
            NSString *text = [BrowserFeedParser plainTextFromHTML:value];
            self.current.summary = text.length > 400 ? [[text substringToIndex:400] stringByAppendingString:@"…"] : text;
        }
    } else if ([@[@"pubdate", @"published", @"updated", @"dc:date"] containsObject:name] && self.current.date == nil) {
        self.current.date = [BrowserFeedParser dateFromString:value];
    }
    self.buffer = [NSMutableString string];
}

+ (NSString *)titleAndItems:(NSArray **)items fromData:(NSData *)data feedURL:(NSString *)feedURL {
    BrowserFeedParser *delegate = [BrowserFeedParser new];
    delegate.feedURL = feedURL;
    delegate.items = [NSMutableArray array];
    delegate.buffer = [NSMutableString string];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = delegate;
    parser.shouldProcessNamespaces = NO;
    [parser parse];
    NSURL *base = [NSURL URLWithString:feedURL];
    for (BrowserFeedItem *item in delegate.items) {
        item.feedTitle = delegate.channelTitle ?: @"";
        // Relative links and images become absolute.
        item.link = [NSURL URLWithString:item.link relativeToURL:base].absoluteString ?: item.link;
        if (item.imageURL != nil) {
            item.imageURL = [NSURL URLWithString:item.imageURL relativeToURL:base].absoluteString;
        }
    }
    if (items != NULL) {
        *items = [delegate.items copy];
    }
    return delegate.channelTitle;
}

@end

#pragma mark - Store

@interface BrowserFeedStore ()
@property (nonatomic) NSMutableDictionary<NSString *, NSArray<BrowserFeedItem *> *> *itemsByFeed;
@property (nonatomic) NSMutableOrderedSet<NSString *> *readLinks;
@property (nonatomic, readwrite, getter=isRefreshing) BOOL refreshing;
@end

@implementation BrowserFeedStore

+ (instancetype)sharedStore {
    static BrowserFeedStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [BrowserFeedStore new];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _itemsByFeed = [NSMutableDictionary dictionary];
        NSArray *read = [NSUserDefaults.standardUserDefaults arrayForKey:kFeedReadLinksKey] ?: @[];
        _readLinks = [NSMutableOrderedSet orderedSetWithArray:read];
    }
    return self;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)subscriptions {
    NSMutableArray *result = [NSMutableArray array];
    for (id entry in [NSUserDefaults.standardUserDefaults arrayForKey:kFeedSubscriptionsKey] ?: @[]) {
        if ([entry isKindOfClass:[NSDictionary class]] && [entry[@"url"] isKindOfClass:[NSString class]]) {
            [result addObject:entry];
        }
    }
    return result;
}

- (BOOL)isSubscribedToURL:(NSString *)URLString {
    for (NSDictionary *entry in self.subscriptions) {
        if ([entry[@"url"] isEqualToString:URLString]) {
            return YES;
        }
    }
    return NO;
}

- (void)subscribeToURL:(NSString *)URLString title:(NSString *)title {
    if (URLString.length == 0 || [self isSubscribedToURL:URLString]) {
        return;
    }
    NSMutableArray *list = [self.subscriptions mutableCopy];
    NSString *name = title.length > 0 ? title : ([NSURL URLWithString:URLString].host ?: URLString);
    [list addObject:@{@"url": URLString, @"title": name}];
    [NSUserDefaults.standardUserDefaults setObject:list forKey:kFeedSubscriptionsKey];
}

- (void)unsubscribeFromURL:(NSString *)URLString {
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *entry in self.subscriptions) {
        if (![entry[@"url"] isEqualToString:URLString]) {
            [list addObject:entry];
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:list forKey:kFeedSubscriptionsKey];
    [self.itemsByFeed removeObjectForKey:URLString];
}

- (NSArray<BrowserFeedItem *> *)itemsForFeedURL:(NSString *)URLString {
    NSMutableArray<BrowserFeedItem *> *items = [NSMutableArray array];
    for (NSDictionary *entry in self.subscriptions) {
        if (URLString == nil || [entry[@"url"] isEqualToString:URLString]) {
            NSArray *feedItems = self.itemsByFeed[entry[@"url"]] ?: @[];
            for (BrowserFeedItem *item in feedItems) {
                item.feedTitle = entry[@"title"] ?: item.feedTitle;
            }
            [items addObjectsFromArray:feedItems];
        }
    }
    [items sortUsingComparator:^NSComparisonResult(BrowserFeedItem *a, BrowserFeedItem *b) {
        NSDate *da = a.date ?: NSDate.distantPast;
        NSDate *db = b.date ?: NSDate.distantPast;
        return [db compare:da];
    }];
    return items;
}

- (NSUInteger)unreadCountForFeedURL:(NSString *)URLString {
    NSUInteger count = 0;
    for (BrowserFeedItem *item in [self itemsForFeedURL:URLString]) {
        if (![self isRead:item]) {
            count += 1;
        }
    }
    return count;
}

- (BOOL)isRead:(BrowserFeedItem *)item {
    return [self.readLinks containsObject:item.link];
}

- (void)markRead:(BrowserFeedItem *)item {
    if (item.link.length == 0 || [self isRead:item]) {
        return;
    }
    [self.readLinks addObject:item.link];
    while (self.readLinks.count > kFeedMaxReadLinks) {
        [self.readLinks removeObjectAtIndex:0];
    }
    [NSUserDefaults.standardUserDefaults setObject:self.readLinks.array forKey:kFeedReadLinksKey];
}

- (void)fetchFeedAtURL:(NSString *)URLString
            completion:(void (^)(NSString *, NSArray<BrowserFeedItem *> *, NSError *))completion {
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        completion(nil, @[], [NSError errorWithDomain:@"Orbrisa" code:1 userInfo:nil]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 Orbrisa"
   forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5" forHTTPHeaderField:@"Accept"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, __unused NSURLResponse *response, NSError *error) {
        NSArray *items = @[];
        NSString *title = data.length > 0 ? [BrowserFeedParser titleAndItems:&items fromData:data feedURL:URLString] : nil;
        if (error != nil) {
            BrowserLog(@"[Feeds] %@ failed: %@", URLString, error.localizedDescription);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(title, items, error);
        });
    }] resume];
}

- (void)refreshWithCompletion:(void (^)(void))completion {
    NSArray *subscriptions = self.subscriptions;
    if (subscriptions.count == 0) {
        if (completion != nil) {
            completion();
        }
        return;
    }
    self.refreshing = YES;
    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary *entry in subscriptions) {
        NSString *URLString = entry[@"url"];
        dispatch_group_enter(group);
        [self fetchFeedAtURL:URLString completion:^(__unused NSString *title, NSArray<BrowserFeedItem *> *items, __unused NSError *error) {
            if (items.count > 0) {
                self.itemsByFeed[URLString] = items;
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.refreshing = NO;
        if (completion != nil) {
            completion();
        }
    });
}

#pragma mark - Helpers

+ (UIColor *)colorForFeedURL:(NSString *)URLString {
    static NSArray<UIColor *> *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette = @[
            [UIColor colorWithRed:0.76 green:0.48 blue:0.17 alpha:1.0], [UIColor colorWithRed:0.04 green:0.52 blue:1.00 alpha:1.0],
            [UIColor colorWithRed:0.19 green:0.64 blue:0.42 alpha:1.0], [UIColor colorWithRed:0.90 green:0.28 blue:0.30 alpha:1.0],
            [UIColor colorWithRed:0.56 green:0.31 blue:0.78 alpha:1.0], [UIColor colorWithRed:0.85 green:0.51 blue:0.17 alpha:1.0],
            [UIColor colorWithRed:0.17 green:0.55 blue:0.62 alpha:1.0], [UIColor colorWithRed:0.82 green:0.25 blue:0.52 alpha:1.0],
        ];
    });
    NSUInteger hash = 5381;
    for (NSUInteger i = 0; i < URLString.length; i++) {
        hash = ((hash << 5) + hash) + [URLString characterAtIndex:i];
    }
    return palette[hash % palette.count];
}

+ (NSString *)relativeDateString:(NSDate *)date {
    if (date == nil) {
        return @"";
    }
    static NSRelativeDateTimeFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSRelativeDateTimeFormatter new];
        formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
        // Same language as the app's own texts (English, or German on a German Apple TV).
        NSString *language = NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:language];
    });
    NSDate *now = [NSDate date];
    return [formatter localizedStringForDate:([date compare:now] == NSOrderedDescending ? now : date) relativeToDate:now];
}

+ (NSString *)detectionScript {
    NSString *path = [NSBundle.mainBundle pathForResource:@"FeedDetect" ofType:@"js"];
    return path != nil ? ([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"") : @"";
}

@end
