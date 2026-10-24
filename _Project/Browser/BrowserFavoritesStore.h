#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserFavoritesStore : NSObject

- (NSArray<NSArray<NSString *> *> *)favorites;
- (BOOL)isFavoriteURLString:(nullable NSString *)URLString;
- (void)addFavoriteWithURLString:(nullable NSString *)URLString title:(nullable NSString *)title;
- (void)removeFavoriteWithURLString:(nullable NSString *)URLString;
- (void)removeFavoriteAtIndex:(NSInteger)index;
- (NSUInteger)count;

// Folders. A favorite stores its folder as a third element, so entries saved
// before folders existed stay readable and simply belong to no folder.
- (NSArray<NSString *> *)folderNames;
- (NSArray<NSArray<NSString *> *> *)favoritesInFolder:(nullable NSString *)folderName;
- (nullable NSString *)folderForURLString:(nullable NSString *)URLString;
- (void)setFolder:(nullable NSString *)folderName forURLString:(nullable NSString *)URLString;
- (void)createFolderNamed:(NSString *)folderName;
- (void)removeFolderNamed:(NSString *)folderName;

@end

NS_ASSUME_NONNULL_END
