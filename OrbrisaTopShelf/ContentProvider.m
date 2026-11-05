#import "ContentProvider.h"

/// The shared App Group (group.<bundle id of the app>), written into Info.plist at build time.
#define kOrbrisaAppGroup ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"OrbrisaAppGroup"] ?: @"")
static NSString * const kOrbrisaTopShelfKey = @"TopShelf";

@implementation ContentProvider

- (NSURL *)deepLinkWithHost:(NSString *)host index:(NSUInteger)index URLString:(NSString *)URLString {
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"orbrisa";
    components.host = host;
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"index" value:[NSString stringWithFormat:@"%lu", (unsigned long)index]],
        [NSURLQueryItem queryItemWithName:@"url" value:URLString ?: @""],
    ];
    return components.URL;
}

- (NSArray<TVTopShelfSectionedItem *> *)itemsFromEntries:(NSArray *)entries
                                                    kind:(NSString *)kind
                                               container:(NSURL *)container {
    NSMutableArray<TVTopShelfSectionedItem *> *items = [NSMutableArray array];
    NSUInteger index = 0;
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            index += 1;
            continue;
        }
        NSString *URLString = [entry[@"url"] isKindOfClass:[NSString class]] ? entry[@"url"] : @"";
        NSString *title = [entry[@"title"] isKindOfClass:[NSString class]] ? entry[@"title"] : @"";
        NSString *image = [entry[@"image"] isKindOfClass:[NSString class]] ? entry[@"image"] : @"";
        if (URLString.length == 0) {
            index += 1;
            continue;
        }
        NSString *identifier = [NSString stringWithFormat:@"%@-%lu", kind, (unsigned long)index];
        TVTopShelfSectionedItem *item = [[TVTopShelfSectionedItem alloc] initWithIdentifier:identifier];
        NSString *host = [NSURL URLWithString:URLString].host;
        item.title = title.length > 0 ? title : (host.length > 0 ? host : URLString);
        item.imageShape = TVTopShelfSectionedItemImageShapeHDTV;
        if (image.length > 0 && container != nil) {
            NSURL *imageURL = [[container URLByAppendingPathComponent:@"TopShelf" isDirectory:YES] URLByAppendingPathComponent:image];
            [item setImageURL:imageURL forTraits:TVTopShelfItemImageTraitScreenScale1x];
            [item setImageURL:imageURL forTraits:TVTopShelfItemImageTraitScreenScale2x];
        }
        NSURL *link = [self deepLinkWithHost:kind index:index URLString:URLString];
        if (link != nil) {
            item.displayAction = [[TVTopShelfAction alloc] initWithURL:link];
            item.playAction = [[TVTopShelfAction alloc] initWithURL:link];
        }
        [items addObject:item];
        index += 1;
    }
    return items;
}

- (void)loadTopShelfContentWithCompletionHandler:(void (^)(id<TVTopShelfContent> _Nullable))completionHandler {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kOrbrisaAppGroup];
    NSDictionary *shelf = [defaults dictionaryForKey:kOrbrisaTopShelfKey];
    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:kOrbrisaAppGroup];

    NSMutableArray<TVTopShelfItemCollection<TVTopShelfSectionedItem *> *> *sections = [NSMutableArray array];
    NSArray *tabs = [shelf[@"tabs"] isKindOfClass:[NSArray class]] ? shelf[@"tabs"] : @[];
    NSArray *favorites = [shelf[@"favorites"] isKindOfClass:[NSArray class]] ? shelf[@"favorites"] : @[];

    NSArray<TVTopShelfSectionedItem *> *tabItems = [self itemsFromEntries:tabs kind:@"tab" container:container];
    if (tabItems.count > 0) {
        TVTopShelfItemCollection<TVTopShelfSectionedItem *> *section = [[TVTopShelfItemCollection alloc] initWithItems:tabItems];
        section.title = NSLocalizedString(@"Open Tabs", nil);
        [sections addObject:section];
    }
    NSArray<TVTopShelfSectionedItem *> *favoriteItems = [self itemsFromEntries:favorites kind:@"favorite" container:container];
    if (favoriteItems.count > 0) {
        TVTopShelfItemCollection<TVTopShelfSectionedItem *> *section = [[TVTopShelfItemCollection alloc] initWithItems:favoriteItems];
        section.title = NSLocalizedString(@"Favorites", nil);
        [sections addObject:section];
    }

    // Nothing shared yet (e.g. right after install): nil keeps the app's static Top Shelf image.
    completionHandler(sections.count > 0 ? [[TVTopShelfSectionedContent alloc] initWithSections:sections] : nil);
}

@end
