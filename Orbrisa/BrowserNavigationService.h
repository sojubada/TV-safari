#import <Foundation/Foundation.h>

@class BrowserTabViewModel;
@class BrowserPreferencesStore;

@interface BrowserNavigationService : NSObject

@property (nonatomic, copy) NSString *httpsFirstAddress;

- (instancetype)initWithPreferencesStore:(BrowserPreferencesStore *)preferencesStore;
- (NSURLRequest *)homePageRequest;
- (NSURLRequest *)requestForURLString:(NSString *)URLString;
- (NSURLRequest *)requestForEnteredAddressString:(NSString *)addressString;
- (NSURLRequest *)httpFallbackRequestForFailedURL:(NSURL *)failedURL;
- (NSURLRequest *)googleSearchRequestForQuery:(NSString *)query;
- (NSURLRequest *)googleSearchRequestForFailedRequestURLString:(NSString *)requestURLString;
- (void)updateTab:(BrowserTabViewModel *)tab
    withPageTitle:(NSString *)pageTitle
  currentURLString:(NSString *)currentURLString;
- (BOOL)shouldIgnoreLoadError:(NSError *)error;

@end
