#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSInteger BrowserPrivacyStanceUnknown(__unused id self, __unused SEL _cmd) {
    return 0;
}

void BrowserInstallPrivacyStanceShim(void);

@interface BrowserPrivacyStanceShim : NSObject
@end

@implementation BrowserPrivacyStanceShim

// WebKit is dlopen'ed when the first web view is made, after +load has run,
// so at +load the class is usually not there yet. The same install is called
// again right after WebKit is loaded (BrowserWebView.m); whichever finds the
// class first adds the methods, and adding is skipped once they exist.
void BrowserInstallPrivacyStanceShim(void) {
    Class metricsClass = objc_getClass("WebCoreNSURLSessionTaskTransactionMetrics");
    if (metricsClass == Nil) {
        return;
    }
    SEL privateSelector = NSSelectorFromString(@"_privacyStance");
    SEL publicSelector = NSSelectorFromString(@"privacyStance");
    const char *typeEncoding = "q@:";
    if (class_getInstanceMethod(metricsClass, privateSelector) == NULL) {
        class_addMethod(metricsClass, privateSelector, (IMP)BrowserPrivacyStanceUnknown, typeEncoding);
    }
    if (class_getInstanceMethod(metricsClass, publicSelector) == NULL) {
        class_addMethod(metricsClass, publicSelector, (IMP)BrowserPrivacyStanceUnknown, typeEncoding);
    }
}

+ (void)load {
    BrowserInstallPrivacyStanceShim();
}

@end
