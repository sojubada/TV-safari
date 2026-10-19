#import "BrowserFavoritesStore.h"

static NSString * const kFavoritesUserDefaultsKey = @"FAVORITES";

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

@end
