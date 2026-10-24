#import "BrowserFavoritesStore.h"

static NSString * const kFavoritesUserDefaultsKey = @"FAVORITES";
static NSString * const kFavoriteFoldersUserDefaultsKey = @"FAVORITE_FOLDERS";

@implementation BrowserFavoritesStore

- (NSString *)normalizedURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return @"";
    }

    NSURL *url = [NSURL URLWithString:URLString];
    if (url == nil) {
        return URLString;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (components == nil) {
        return URLString;
    }

    components.scheme = components.scheme.lowercaseString;
    components.host = components.host.lowercaseString;
    components.fragment = nil;

    NSString *path = components.path;
    if (path.length > 1 && [path hasSuffix:@"/"]) {
        components.path = [path substringToIndex:path.length - 1];
    } else if (path.length == 0 && components.host != nil) {
        components.path = @"";
    }

    NSString *normalized = components.URL.absoluteString;
    if (normalized == nil) {
        return URLString;
    }

    if ([normalized hasSuffix:@"/"] && normalized.length > components.scheme.length + 3) {
        normalized = [normalized substringToIndex:normalized.length - 1];
    }

    return normalized;
}

- (NSArray<NSArray<NSString *> *> *)favorites {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoritesUserDefaultsKey];
    if ([stored isKindOfClass:[NSArray class]]) {
        return stored;
    }
    return @[];
}

- (void)saveFavorites:(NSArray<NSArray<NSString *> *> *)favorites {
    [[NSUserDefaults standardUserDefaults] setObject:favorites forKey:kFavoritesUserDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)isFavoriteURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return NO;
    }

    NSString *target = [self normalizedURLString:URLString];
    if (target.length == 0) {
        return NO;
    }

    NSArray *currentFavorites = [self favorites];
    for (NSArray *entry in currentFavorites) {
        if (entry.count > 0) {
            NSString *existingURLString = entry[0];
            if ([existingURLString isKindOfClass:[NSString class]]) {
                NSString *existingTarget = [self normalizedURLString:existingURLString];
                if ([existingTarget isEqualToString:target]) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

- (void)addFavoriteWithURLString:(NSString *)URLString title:(NSString *)title {
    if (URLString.length == 0) {
        return;
    }

    if ([self isFavoriteURLString:URLString]) {
        return;
    }

    NSString *trimmedTitle = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *finalTitle = trimmedTitle.length > 0 ? trimmedTitle : URLString;

    NSMutableArray *currentFavorites = [[self favorites] mutableCopy];
    [currentFavorites addObject:@[URLString, finalTitle]];
    [self saveFavorites:currentFavorites];
}

- (void)removeFavoriteWithURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return;
    }

    NSString *target = [self normalizedURLString:URLString];
    if (target.length == 0) {
        return;
    }

    NSMutableArray *currentFavorites = [[self favorites] mutableCopy];
    NSMutableIndexSet *indexesToRemove = [NSMutableIndexSet indexSet];

    [currentFavorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger idx, BOOL *stop) {
        if (entry.count > 0) {
            NSString *existingURLString = entry[0];
            if ([existingURLString isKindOfClass:[NSString class]]) {
                NSString *existingTarget = [self normalizedURLString:existingURLString];
                if ([existingTarget isEqualToString:target]) {
                    [indexesToRemove addIndex:idx];
                }
            }
        }
    }];

    if (indexesToRemove.count > 0) {
        [currentFavorites removeObjectsAtIndexes:indexesToRemove];
        [self saveFavorites:currentFavorites];
    }
}

- (void)removeFavoriteAtIndex:(NSInteger)index {
    NSMutableArray *currentFavorites = [[self favorites] mutableCopy];
    if (index >= 0 && (NSUInteger)index < currentFavorites.count) {
        [currentFavorites removeObjectAtIndex:index];
        [self saveFavorites:currentFavorites];
    }
}

- (NSUInteger)count {
    return [self favorites].count;
}


#pragma mark - Folders

// A favorite is stored as [url, title] and now optionally [url, title, folder].
// Reading the third element defensively means nothing saved before folders
// existed has to be migrated.
- (NSString *)folderOfEntry:(NSArray<NSString *> *)entry {
    if (![entry isKindOfClass:[NSArray class]] || entry.count < 3) {
        return nil;
    }
    NSString *folder = entry[2];
    return [folder isKindOfClass:[NSString class]] && folder.length > 0 ? folder : nil;
}

- (NSArray<NSString *> *)folderNames {
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];

    NSArray *declared = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoriteFoldersUserDefaultsKey];
    for (id name in ([declared isKindOfClass:[NSArray class]] ? declared : @[])) {
        if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0) {
            [names addObject:name];
        }
    }
    for (NSArray<NSString *> *entry in [self favorites]) {
        NSString *folder = [self folderOfEntry:entry];
        if (folder != nil) {
            [names addObject:folder];
        }
    }
    return [names.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (NSArray<NSArray<NSString *> *> *)favoritesInFolder:(NSString *)folderName {
    NSMutableArray<NSArray<NSString *> *> *matches = [NSMutableArray array];
    for (NSArray<NSString *> *entry in [self favorites]) {
        NSString *folder = [self folderOfEntry:entry];
        BOOL belongs = folderName.length > 0 ? [folder isEqualToString:folderName] : (folder == nil);
        if (belongs) {
            [matches addObject:entry];
        }
    }
    return matches;
}

- (NSString *)folderForURLString:(NSString *)URLString {
    NSString *normalized = [self normalizedURLString:URLString ?: @""];
    for (NSArray<NSString *> *entry in [self favorites]) {
        if (entry.count >= 1 && [[self normalizedURLString:entry[0]] isEqualToString:normalized]) {
            return [self folderOfEntry:entry];
        }
    }
    return nil;
}

- (void)setFolder:(NSString *)folderName forURLString:(NSString *)URLString {
    NSString *normalized = [self normalizedURLString:URLString ?: @""];
    if (normalized.length == 0) {
        return;
    }
    NSMutableArray<NSArray<NSString *> *> *updated = [NSMutableArray array];
    for (NSArray<NSString *> *entry in [self favorites]) {
        if (entry.count >= 1 && [[self normalizedURLString:entry[0]] isEqualToString:normalized]) {
            NSString *title = entry.count >= 2 ? entry[1] : @"";
            [updated addObject:folderName.length > 0 ? @[entry[0], title, folderName]
                                                     : @[entry[0], title]];
        } else {
            [updated addObject:entry];
        }
    }
    [self saveFavorites:updated];
    if (folderName.length > 0) {
        [self createFolderNamed:folderName];
    }
}

- (void)createFolderNamed:(NSString *)folderName {
    if (folderName.length == 0) {
        return;
    }
    NSArray *declared = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoriteFoldersUserDefaultsKey];
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    for (id name in ([declared isKindOfClass:[NSArray class]] ? declared : @[])) {
        if ([name isKindOfClass:[NSString class]]) {
            [names addObject:name];
        }
    }
    [names addObject:folderName];
    [[NSUserDefaults standardUserDefaults] setObject:names.array forKey:kFavoriteFoldersUserDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Removing a folder keeps every favorite in it; they return to the top level.
- (void)removeFolderNamed:(NSString *)folderName {
    if (folderName.length == 0) {
        return;
    }
    NSMutableArray<NSArray<NSString *> *> *updated = [NSMutableArray array];
    for (NSArray<NSString *> *entry in [self favorites]) {
        if ([[self folderOfEntry:entry] isEqualToString:folderName]) {
            [updated addObject:@[entry[0], entry.count >= 2 ? entry[1] : @""]];
        } else {
            [updated addObject:entry];
        }
    }
    [self saveFavorites:updated];

    NSArray *declared = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoriteFoldersUserDefaultsKey];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id name in ([declared isKindOfClass:[NSArray class]] ? declared : @[])) {
        if ([name isKindOfClass:[NSString class]] && ![name isEqualToString:folderName]) {
            [names addObject:name];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:names forKey:kFavoriteFoldersUserDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
