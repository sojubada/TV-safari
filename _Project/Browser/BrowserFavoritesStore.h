#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserFavoritesStore : NSObject

- (NSArray<NSArray<NSString *> *> *)favorites;
- (BOOL)isFavoriteURLString:(nullable NSString *)URLString;
- (void)addFavoriteWithURLString:(nullable NSString *)URLString title:(nullable NSString *)title;
- (void)removeFavoriteWithURLString:(nullable NSString *)URLString;
- (void)removeFavoriteAtIndex:(NSInteger)index;
- (NSUInteger)count;

@end

NS_ASSUME_NONNULL_END
