//
//  AppDelegate.m
//  Orbrisa
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "AppDelegate.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"
#import "BrowserDiagnosticsLog.h"

@interface AppDelegate ()

- (void)restoreCookiesFromDefaults;
- (void)saveCookiesToDefaults;

@end

#pragma mark - Scene delegate

// Builds made with the current tvOS SDK must use the UIScene life cycle, otherwise UIKit stops at launch.
// With a scene manifest UIKit no longer calls the app-level foreground/background callbacks,
// so the scene forwards them to the app delegate.
@interface BrowserSceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (strong, nonatomic) UIWindow *window;

@end

@implementation BrowserSceneDelegate

- (AppDelegate *)browserAppDelegate {
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    return [delegate isKindOfClass:[AppDelegate class]] ? (AppDelegate *)delegate : nil;
}

/// Links from the Top Shelf (orbrisa://…): kept until the browser is ready, then opened.
- (void)rememberAppURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    NSURL *URL = contexts.anyObject.URL;
    if (URL == nil) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:URL.absoluteString forKey:@"BrowserPendingAppURL"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BrowserOpenAppURLNotification" object:nil];
    });
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    [self rememberAppURLContexts:connectionOptions.URLContexts];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    [self rememberAppURLContexts:URLContexts];
}

- (void)sceneWillResignActive:(UIScene *)scene {
    [[self browserAppDelegate] saveCookiesToDefaults];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    [[self browserAppDelegate] saveCookiesToDefaults];
}

@end

#pragma mark - App delegate

@implementation AppDelegate

- (void)restoreCookiesFromDefaults {
    // WebKit keeps its own cookie store on disk, so restoring once per launch is enough.
    static BOOL restoredThisLaunch = NO;
    if (restoredThisLaunch) {
        return;
    }
    restoredThisLaunch = YES;

    NSData *cookieData = [[NSUserDefaults standardUserDefaults] objectForKey:@"ApplicationCookie"];
    if (cookieData.length == 0) {
        return;
    }

    [BrowserWebView restoreCookiesFromData:cookieData];
}

- (void)saveCookiesToDefaults {
    NSData *cookieData = [BrowserWebView cookieDataRepresentation];
    if (cookieData == nil) {
        return;
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:cookieData forKey:@"ApplicationCookie"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}


// A crash kills the app before anything else can write, so the reason is
// recorded here, first thing, while the exception is still in hand.
static void BrowserLogUncaughtException(NSException *exception) {
    NSString *frames = [exception.callStackSymbols componentsJoinedByString:@" | "];
    if (frames.length > 1200) {
        frames = [frames substringToIndex:1200];
    }
    [[BrowserDiagnosticsLog sharedLog]
        logEventSynchronously:@"UNCAUGHT"
                       detail:[NSString stringWithFormat:@"%@: %@  ::  %@",
                               exception.name ?: @"?", exception.reason ?: @"?", frames ?: @""]];
}

// Housekeeping: everything below lives in the app's own Caches and tmp folders,
// which tvOS may delete at any time, so removing it is safe. It runs at launch,
// before any web content process exists. Login data (Library/WebKit, cookies)
// is never touched.
static unsigned long long BrowserDirectorySize(NSString *path, NSFileManager *fm) {
    unsigned long long total = 0;
    NSDirectoryEnumerator *walker = [fm enumeratorAtPath:path];
    for (NSString *item in walker) {
        NSDictionary *attrs = [walker fileAttributes];
        if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) {
            total += [attrs fileSize];
        }
    }
    return total;
}

static void BrowserPruneCaches(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches.length == 0) {
        return;
    }
    // WebKit's network cache (Caches/WebKit/NetworkCache/Version N/...): over 40 MB it goes.
    // Other cache folders: over 20 MB. Diagnostics (the logs) are kept.
    NSArray<NSArray *> *rules = @[
        @[[caches stringByAppendingPathComponent:@"WebKit/NetworkCache"], @(40)],
        @[[caches stringByAppendingPathComponent:@"WebKit/CacheStorage"], @(20)],
        @[[caches stringByAppendingPathComponent:@"com.sojubada.orbrisa"], @(20)],
        @[NSTemporaryDirectory(), @(20)],
    ];
    for (NSArray *rule in rules) {
        NSString *path = rule[0];
        unsigned long long limit = [rule[1] unsignedLongLongValue] * 1024ULL * 1024ULL;
        if (![fm fileExistsAtPath:path] || BrowserDirectorySize(path, fm) <= limit) {
            continue;
        }
        for (NSString *child in [fm contentsOfDirectoryAtPath:path error:NULL]) {
            [fm removeItemAtPath:[path stringByAppendingPathComponent:child] error:NULL];
        }
        BrowserDiagInfo(BrowserDiagCategoryStorage, @"cleanup", nil, [NSString stringWithFormat:@"emptied %@", path.lastPathComponent]);
    }
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSSetUncaughtExceptionHandler(&BrowserLogUncaughtException);
    // B1: a ceiling on the URL cache. A few tens of megabytes is plenty for
    // revisiting pages and leaves the small, shared disk alone.
    NSURLCache *cache = [[NSURLCache alloc] initWithMemoryCapacity:(8 * 1024 * 1024)
                                                      diskCapacity:(48 * 1024 * 1024)
                                                          diskPath:nil];
    [NSURLCache setSharedURLCache:cache];
    // C1: crashes below Objective-C and a main thread that stops answering
    // leave no trace otherwise.
    [[BrowserDiagnosticsLog sharedLog] installCrashAndStallWatch];
    BrowserPruneCaches();
	// Override point for customization after application launch.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"MobileMode"]) {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.mobileUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    else {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.desktopUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    [self restoreCookiesFromDefaults];
	return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
	// Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
	// Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    [self saveCookiesToDefaults];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	// Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
	// If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    [self saveCookiesToDefaults];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	// Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    [self restoreCookiesFromDefaults];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	// Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    [self restoreCookiesFromDefaults];
}

- (void)applicationWillTerminate:(UIApplication *)application {
	// Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [self saveCookiesToDefaults];
}

@end
