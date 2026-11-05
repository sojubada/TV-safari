//
//  BrowserFeedStore.h
//  Orbrisa
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One article from an RSS or Atom feed.
@interface BrowserFeedItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *link;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy, nullable) NSString *imageURL;
@property (nonatomic, copy, nullable) NSDate *date;
@property (nonatomic, copy) NSString *feedURL;
@property (nonatomic, copy) NSString *feedTitle;
@end

/// The feeds the user subscribed to, their articles and which ones were read. Stored in the user defaults.
@interface BrowserFeedStore : NSObject

+ (instancetype)sharedStore;

/// Subscribed feeds, each @{@"url": …, @"title": …}, in the order they were added.
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *subscriptions;
@property (nonatomic, readonly, getter=isRefreshing) BOOL refreshing;

- (BOOL)isSubscribedToURL:(NSString *)URLString;
- (void)subscribeToURL:(NSString *)URLString title:(NSString *)title;
- (void)unsubscribeFromURL:(NSString *)URLString;

/// Articles of one feed, or of all feeds when nil – newest first.
- (NSArray<BrowserFeedItem *> *)itemsForFeedURL:(nullable NSString *)URLString;
- (NSUInteger)unreadCountForFeedURL:(nullable NSString *)URLString;
- (BOOL)isRead:(BrowserFeedItem *)item;
- (void)markRead:(BrowserFeedItem *)item;

/// Loads every subscribed feed again. The completion runs on the main queue.
- (void)refreshWithCompletion:(nullable void (^)(void))completion;
/// Loads one feed (to show it before subscribing). The completion runs on the main queue.
- (void)fetchFeedAtURL:(NSString *)URLString
            completion:(void (^)(NSString * _Nullable title, NSArray<BrowserFeedItem *> *items, NSError * _Nullable error))completion;

/// A stable colour for a feed (for its letter badge and cards).
+ (UIColor *)colorForFeedURL:(NSString *)URLString;
/// "5 min ago", "yesterday", … in the app's language.
+ (NSString *)relativeDateString:(nullable NSDate *)date;
/// The page script that lists the feeds a page announces (from the app bundle).
+ (NSString *)detectionScript;

@end

NS_ASSUME_NONNULL_END
