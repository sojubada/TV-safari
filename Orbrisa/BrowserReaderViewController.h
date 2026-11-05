//
//  BrowserReaderViewController.h
//  Orbrisa
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Reader mode: shows only the article of a page – large, calm text with its own size, background and font.
/// Swipe scrolls, Play/Pause opens the appearance panel, Back closes the reader.
@interface BrowserReaderViewController : UIViewController

/// The JSON the page script ReaderExtract.js returns, already parsed (title, site, byline, image, words, blocks).
- (instancetype)initWithArticle:(NSDictionary *)article NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Runs ReaderExtract.js in the page; returns the article, or nil when the page has no readable article.
+ (nullable NSDictionary *)articleFromJavaScriptResult:(nullable NSString *)result;
/// YES when the user chose "Always Open in Reader" for this site.
+ (BOOL)opensAutomaticallyForURL:(nullable NSURL *)URL;
/// The page script that finds the article (from the app bundle).
+ (NSString *)extractionScript;

@end

NS_ASSUME_NONNULL_END
