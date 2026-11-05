#import "BrowserWebView.h"
#import "BrowserLog.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kBrowserWebViewClassName = @"WKWebView";
static NSString * const kBrowserWebViewConfigurationClassName = @"WKWebViewConfiguration";
static NSString * const kBrowserWebsiteDataStoreClassName = @"WKWebsiteDataStore";
static NSString * const kBrowserUserContentControllerClassName = @"WKUserContentController";
static NSString * const kBrowserUserScriptClassName = @"WKUserScript";

extern void BrowserInstallPrivacyStanceShim(void);

static void BrowserEnsureWebKitRuntimeLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(kBrowserWebViewClassName) != Nil) {
            BrowserInstallPrivacyStanceShim();
            return;
        }

        NSArray<NSString *> *candidatePaths = @[
            @"/System/Library/Frameworks/WebKit.framework/WebKit",
            @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
        ];

        for (NSString *candidatePath in candidatePaths) {
            if (dlopen(candidatePath.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(kBrowserWebViewClassName) != Nil) {
                break;
            }
        }
        // tvOS 16's AVFoundation asks WebCore's metrics object for
        // _privacyStance, which that WebCore does not have; without this the
        // web content process dies as soon as a page plays media.
        BrowserInstallPrivacyStanceShim();
    });
}

// Synchronous script calls spin the run loop until WebKit answers. While it spins, UIKit can deliver the
// next remote touch, whose handler starts another script call, and so on. Newer tvOS versions stop the app
// once events nest more than four levels deep, so a script call made while another one is waiting is skipped.
static NSInteger sBrowserJavaScriptEvaluationDepth = 0;

static void BrowserPumpRunLoopUntil(BOOL *done) {
    while (!*done) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
}

static NSString *BrowserStringFromJavaScriptResult(id result) {
    if (result == nil || result == [NSNull null]) {
        return nil;
    }
    if ([result isKindOfClass:[NSString class]]) {
        return result;
    }
    if ([result respondsToSelector:@selector(stringValue)]) {
        return [result stringValue];
    }
    return [result description];
}

static BOOL BrowserSelectorNameMatchesMediaFilter(NSString *selectorName) {
    static NSArray<NSString *> *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"mediasource",
            @"managedmediasource",
            @"sourcebuffer",
            @"media",
            @"video",
            @"inline",
            @"autoplay",
            @"fullscreen",
            @"pictureinpicture",
            @"airplay",
            @"webm",
            @"vp9",
            @"av1",
            @"hls",
            @"mse",
            @"codec",
        ];
    });

    NSString *lowercaseSelectorName = selectorName.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lowercaseSelectorName containsString:keyword]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *BrowserFilteredSelectorNamesForClass(Class klass) {
    if (klass == Nil) {
        return @[];
    }

    NSMutableOrderedSet<NSString *> *selectorNames = [NSMutableOrderedSet orderedSet];
    for (Class currentClass = klass; currentClass != Nil && currentClass != [NSObject class]; currentClass = class_getSuperclass(currentClass)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(currentClass, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex += 1) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *selectorName = NSStringFromSelector(selector);
            if (selectorName.length > 0 && BrowserSelectorNameMatchesMediaFilter(selectorName)) {
                [selectorNames addObject:selectorName];
            }
        }
        free(methods);
    }

    return [selectorNames.array sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSString *BrowserGetterNameFromSetterName(NSString *setterName) {
    if (![setterName hasPrefix:@"set"] || ![setterName hasSuffix:@":"] || setterName.length <= 4) {
        return nil;
    }

    NSString *propertyStem = [setterName substringWithRange:NSMakeRange(3, setterName.length - 4)];
    if (propertyStem.length == 0) {
        return nil;
    }

    NSString *firstCharacter = [[propertyStem substringToIndex:1] lowercaseString];
    if (propertyStem.length == 1) {
        return firstCharacter;
    }

    return [firstCharacter stringByAppendingString:[propertyStem substringFromIndex:1]];
}

static NSString *BrowserBooleanValueDescriptionForObjectAndSelector(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL) {
        return nil;
    }

    if (returnType[0] != 'B' && returnType[0] != 'c') {
        return nil;
    }

    BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    return value ? @"YES" : @"NO";
}

static id BrowserObjectResultForGetter(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL || returnType[0] != '@') {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *BrowserPreviewString(NSString *string, NSUInteger maxLength) {
    if (string.length <= maxLength) {
        return string;
    }
    return [[string substringToIndex:maxLength] stringByAppendingString:@"\n…"];
}

static NSString *BrowserStringValueForKnownSelectors(id object, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        id result = BrowserObjectResultForGetter(object, selectorName);
        if (result == nil || result == [NSNull null]) {
            continue;
        }
        NSString *stringResult = nil;
        if ([result isKindOfClass:[NSString class]]) {
            stringResult = result;
        } else if ([result respondsToSelector:@selector(stringValue)]) {
            stringResult = [result stringValue];
        } else {
            stringResult = [result description];
        }

        if (stringResult.length > 0) {
            return stringResult;
        }
    }
    return nil;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *BrowserFeatureEntriesForPreferences(id preferences) {
    if (preferences == nil) {
        return @[];
    }

    NSArray<NSString *> *collectionSelectors = @[
        @"_experimentalFeatures",
        @"_internalDebugFeatures",
        @"_features",
    ];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries = [NSMutableArray array];
    for (NSString *collectionSelectorName in collectionSelectors) {
        id collection = BrowserObjectResultForGetter(preferences, collectionSelectorName);
        if (![collection conformsToProtocol:@protocol(NSFastEnumeration)]) {
            continue;
        }

        for (id feature in collection) {
            NSString *name = BrowserStringValueForKnownSelectors(feature, @[@"name", @"key", @"identifier", @"title", @"details"]);
            if (name.length == 0) {
                continue;
            }

            NSString *lowercaseName = name.lowercaseString;
            if (![lowercaseName containsString:@"media"] &&
                ![lowercaseName containsString:@"source"] &&
                ![lowercaseName containsString:@"vp9"] &&
                ![lowercaseName containsString:@"av1"] &&
                ![lowercaseName containsString:@"webm"] &&
                ![lowercaseName containsString:@"video"] &&
                ![lowercaseName containsString:@"mse"] &&
                ![lowercaseName containsString:@"managed"]) {
                continue;
            }

            NSString *enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"enabled");
            if (enabledValue == nil) {
                enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"isEnabled");
            }
            if (enabledValue == nil) {
                enabledValue = @"unknown";
            }

            NSString *key = BrowserStringValueForKnownSelectors(feature, @[@"key", @"identifier"]);
            NSString *source = [collectionSelectorName stringByReplacingOccurrencesOfString:@"_" withString:@""];
            [entries addObject:@{
                @"source": source ?: @"features",
                @"name": name,
                @"enabled": enabledValue,
                @"key": key ?: @"",
            }];
        }
    }

    return entries;
}

static void BrowserSetBooleanSelectorIfAvailable(id object, NSString *selectorName, BOOL value) {
    if (object == nil || selectorName.length == 0) {
        return;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

static void BrowserConfigurePrivateMediaPreferences(id configuration) {
    if (configuration == nil) {
        return;
    }

    SEL preferencesSelector = NSSelectorFromString(@"preferences");
    if (![configuration respondsToSelector:preferencesSelector]) {
        return;
    }

    id preferences = ((id (*)(id, SEL))objc_msgSend)(configuration, preferencesSelector);
    if (preferences == nil) {
        return;
    }

    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaSourceEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setManagedMediaSourceEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaCapabilityGrantsEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setVideoQualityIncludesDisplayCompositingEnabled:", YES);
}

static NSString *BrowserYouTubeRequestCaptureScript(void) {
    return
    @"(function(){"
        "if (window.__browserYouTubeHookInstalled) { return; }"
        "window.__browserYouTubeHookInstalled = true;"
        "window.__browserYouTubeIntegrity = window.__browserYouTubeIntegrity || {};"
        "function assignIfPresent(key, value) {"
            "if (value === undefined || value === null) { return; }"
            "var stringValue = String(value || '');"
            "if (!stringValue) { return; }"
            "window.__browserYouTubeIntegrity[key] = stringValue;"
        "}"
        "function capturePayload(payload) {"
            "try {"
                "if (!payload || typeof payload !== 'object') { return; }"
                "if (payload.serviceIntegrityDimensions) {"
                    "assignIfPresent('poToken', payload.serviceIntegrityDimensions.poToken || payload.serviceIntegrityDimensions.po_token);"
                "}"
                "if (payload.context && payload.context.serviceIntegrityDimensions) {"
                    "assignIfPresent('poToken', payload.context.serviceIntegrityDimensions.poToken || payload.context.serviceIntegrityDimensions.po_token);"
                "}"
                "if (payload.context && payload.context.client) {"
                    "assignIfPresent('requestClientName', payload.context.client.clientName);"
                    "assignIfPresent('requestClientVersion', payload.context.client.clientVersion);"
                "}"
            "} catch (error) {}"
        "}"
        "function toHeaderObject(headers) {"
            "var result = {};"
            "try {"
                "if (!headers) { return result; }"
                "if (typeof Headers !== 'undefined' && headers instanceof Headers) {"
                    "headers.forEach(function(value, key) { result[String(key)] = String(value); });"
                    "return result;"
                "}"
                "if (Array.isArray(headers)) {"
                    "headers.forEach(function(entry) {"
                        "if (Array.isArray(entry) && entry.length >= 2) { result[String(entry[0])] = String(entry[1]); }"
                    "});"
                    "return result;"
                "}"
                "if (typeof headers === 'object') {"
                    "Object.keys(headers).forEach(function(key) { result[String(key)] = String(headers[key]); });"
                "}"
            "} catch (error) {}"
            "return result;"
        "}"
        "function rememberRequest(url, body, headers, transport) {"
            "try {"
                "var integrity = window.__browserYouTubeIntegrity;"
                "integrity.lastPlayerRequestURL = String(url || '');"
                "integrity.lastPlayerRequestBody = String(body || '');"
                "integrity.lastPlayerRequestHeaders = JSON.stringify(headers || {});"
                "integrity.lastPlayerRequestTransport = String(transport || '');"
                "if (!integrity.firstPlayerRequestURL) {"
                    "integrity.firstPlayerRequestURL = integrity.lastPlayerRequestURL;"
                    "integrity.firstPlayerRequestBody = integrity.lastPlayerRequestBody;"
                    "integrity.firstPlayerRequestHeaders = integrity.lastPlayerRequestHeaders;"
                    "integrity.firstPlayerRequestTransport = integrity.lastPlayerRequestTransport;"
                "}"
            "} catch (error) {}"
        "}"
        "function captureBodyStringAsync(source, bodyString, headers, transport) {"
            "try {"
                "if (bodyString && bodyString !== '[object ReadableStream]') {"
                    "rememberRequest(source.url || '', bodyString, headers || {}, transport || '');"
                    "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
                    "return;"
                "}"
                "if (source && typeof source.clone === 'function' && typeof source.text === 'function') {"
                    "source.clone().text().then(function(text) {"
                        "rememberRequest(source.url || '', text || '', headers || {}, transport || '');"
                        "try { capturePayload(JSON.parse(text || '')); } catch (error) {}"
                    "}).catch(function(){});"
                "}"
            "} catch (error) {}"
        "}"
        "function captureRequest(input, init) {"
            "try {"
                "var url = '';"
                "if (typeof input === 'string') { url = input; }"
                "else if (input && typeof input.url === 'string') { url = input.url; }"
                "if (url.indexOf('/youtubei/v1/player') === -1) { return; }"
                "var body = (init && init.body) || (input && input.body) || null;"
                "var bodyString = '';"
                "if (typeof body === 'string') { bodyString = body; }"
                "else if (body && typeof body === 'object' && typeof body.toString === 'function') { bodyString = String(body); }"
                "var headers = toHeaderObject((init && init.headers) || (input && input.headers) || null);"
                "rememberRequest(url, bodyString, headers, 'fetch');"
                "captureBodyStringAsync((input && typeof input.clone === 'function') ? input : null, bodyString, headers, 'fetch');"
                "if (typeof bodyString !== 'string' || !bodyString || bodyString === '[object ReadableStream]') { return; }"
                "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
            "} catch (error) {}"
        "}"
        "function captureXHRRequest(xhr, body) {"
            "try {"
                "var url = String((xhr && xhr.__browserYouTubeURL) || '');"
                "if (url.indexOf('/youtubei/v1/player') === -1) { return; }"
                "var bodyString = '';"
                "if (typeof body === 'string') { bodyString = body; }"
                "else if (body && typeof body === 'object' && typeof body.toString === 'function') { bodyString = String(body); }"
                "var headers = xhr && xhr.__browserYouTubeHeaders ? xhr.__browserYouTubeHeaders : {};"
                "rememberRequest(url, bodyString, headers, 'xhr');"
                "if (typeof bodyString !== 'string' || !bodyString) { return; }"
                "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
            "try { capturePayload(JSON.parse(body)); } catch (error) {}"
            "} catch (error) {}"
        "}"
        "var cfg = (window.ytcfg && window.ytcfg.data_) || {};"
        "assignIfPresent('poToken', cfg.PO_TOKEN || cfg.po_token || cfg.POTOKEN);"
        "if (cfg.SERVICE_INTEGRITY_DIMENSIONS) {"
            "assignIfPresent('poToken', cfg.SERVICE_INTEGRITY_DIMENSIONS.poToken || cfg.SERVICE_INTEGRITY_DIMENSIONS.po_token);"
        "}"
        "if (cfg.WEB_PLAYER_CONTEXT_CONFIGS) {"
            "var watchConfig = cfg.WEB_PLAYER_CONTEXT_CONFIGS.WEB_PLAYER_CONTEXT_CONFIG_ID_KEVLAR_WATCH || {};"
            "if (watchConfig.serviceIntegrityDimensions) {"
                "assignIfPresent('poToken', watchConfig.serviceIntegrityDimensions.poToken || watchConfig.serviceIntegrityDimensions.po_token);"
            "}"
        "}"
        "if (window.fetch) {"
            "var originalFetch = window.fetch;"
            "window.fetch = function(input, init) {"
                "captureRequest(input, init);"
                "return originalFetch.apply(this, arguments);"
            "};"
        "}"
        "if (window.XMLHttpRequest && window.XMLHttpRequest.prototype) {"
            "var originalOpen = window.XMLHttpRequest.prototype.open;"
            "var originalSend = window.XMLHttpRequest.prototype.send;"
            "var originalSetRequestHeader = window.XMLHttpRequest.prototype.setRequestHeader;"
            "window.XMLHttpRequest.prototype.open = function(method, url) {"
                "this.__browserYouTubeURL = String(url || '');"
                "this.__browserYouTubeHeaders = {};"
                "return originalOpen.apply(this, arguments);"
            "};"
            "window.XMLHttpRequest.prototype.setRequestHeader = function(key, value) {"
                "try {"
                    "if (!this.__browserYouTubeHeaders) { this.__browserYouTubeHeaders = {}; }"
                    "this.__browserYouTubeHeaders[String(key)] = String(value);"
                "} catch (error) {}"
                "return originalSetRequestHeader.apply(this, arguments);"
            "};"
            "window.XMLHttpRequest.prototype.send = function(body) {"
                "captureXHRRequest(this, body);"
                "return originalSend.apply(this, arguments);"
            "};"
        "}"
    "})();";
}

#pragma mark - Dark mode for websites

NSString * const BrowserForceDarkPagesDidChangeNotification = @"BrowserForceDarkPagesDidChangeNotification";
static NSString * const kBrowserForceDarkPagesDefaultsKey = @"BrowserForceDarkPages";

// Turns light pages dark by inverting them (pictures and videos are inverted back).
// Pages that are already dark are left alone.
static NSString *BrowserForceDarkScriptFunction(void) {
    static NSString *script = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        script =
        @"(function(on){\n"
        @"var ID = '__tvForceDarkStyle', BG = '__tvForceDarkBg';\n"
        @"function style(id, css){ var st = document.getElementById(id); if (st) { return st; } st = document.createElement('style'); st.id = id; st.textContent = css; (document.head || document.documentElement).appendChild(st); return st; }\n"
        @"function drop(id){ var st = document.getElementById(id); if (st) { st.remove(); } }\n"
        @"function lum(e){ if (!e) { return null; } var c = getComputedStyle(e).backgroundColor; var m = c && c.match(/[\\d.]+/g); if (!m || m.length < 3) { return null; } if (m.length > 3 && parseFloat(m[3]) < 0.05) { return null; } return (0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]) / 255; }\n"
        @"if (!on) { drop(ID); drop(BG); return; }\n"
        @"style(ID, 'html{filter:invert(0.9) hue-rotate(180deg) !important;}img,video,picture,canvas,iframe,embed,object,svg image,[style*=\"background-image\"]{filter:invert(1) hue-rotate(180deg) !important;}');\n"
        @"style(BG, 'html{background-color:#fff !important;}');\n"
        @"function check(){\n"
        @"  drop(BG);\n"
        @"  var l = lum(document.body);\n"
        @"  if (l === null) { l = lum(document.documentElement); }\n"
        @"  if (l === null) { style(BG, 'html{background-color:#fff !important;}'); return; }\n"
        @"  if (l < 0.4) { drop(ID); }\n"
        @"}\n"
        @"if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', check); } else { check(); }\n"
        @"})\n";
    });
    return script;
}

#pragma mark - Cookie banners

static NSString * const kBrowserAutoAcceptCookiesDisabledKey = @"BrowserAutoAcceptCookiesDisabled";

// Looks for a cookie/consent banner for a few seconds and presses its "accept all" button.
// Known consent tools first (Google, OneTrust, Didomi, Cookiebot, Usercentrics, ...), then buttons
// whose whole label is a typical "accept" wording in German, English, French or Italian.
static NSString *BrowserMediaCaptureScript(void) {
    // Reports every video stream address the page (or any of its frames) loads, so the Apple TV
    // player can play it even when the page itself only shows a "blob:" video.
    return
        @"(function(){\n"
        @"if (window.__browserMediaCapture) { return; } window.__browserMediaCapture = true;\n"
        @"var seen = {};\n"
        @"function kindOf(l){\n"
        @"  if (/\\.m3u8(\\?|#|$)/.test(l) || /[?&](format|type)=m3u8/.test(l) || /\\/hls\\/.*playlist/.test(l)) { return 'hls'; }\n"
        @"  if (/\\.mpd(\\?|#|$)/.test(l)) { return 'dash'; }\n"
        @"  if (/\\.(mp4|m4v|mov|webm|mkv|flv|ogv|avi)(\\?|#|$)/.test(l)) { return 'file'; }\n"
        @"  return '';\n"
        @"}\n"
        @"function report(u, source){\n"
        @"  try {\n"
        @"    if (!u) { return; } u = String(u);\n"
        @"    if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) { return; }\n"
        @"    var abs = new URL(u, location.href).href;\n"
        @"    var type = kindOf(abs.toLowerCase());\n"
        @"    if (!type && source === 'media') { type = 'file'; }\n"
        @"    if (!type || seen[abs]) { return; } seen[abs] = 1;\n"
        @"    var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserMedia;\n"
        @"    if (h) { h.postMessage({url: abs, type: type, source: source || 'network', page: location.href}); }\n"
        @"  } catch (e) {}\n"
        @"}\n"
        @"try { var xo = XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open = function(m, u){ report(u, 'network'); noteRequest(u); return xo.apply(this, arguments); }; } catch (e) {}\n"
        @"function noteRequest(u){ try { u = String(u || ''); if (/get_media|m3u8|master|\\/hls\\/|mediaDefinition/i.test(u) && !AD_SRC.test(u)) { dlog('Anfrage: ' + u.replace(/^https?:\\/\\//, '').slice(0, 70)); } } catch (e) {} }\n"
        @"try { var of = window.fetch; if (of) { window.__browserOrigFetch = of; window.fetch = function(i){ try { report(typeof i === 'string' ? i : (i && i.url), 'network'); noteRequest(typeof i === 'string' ? i : (i && i.url)); } catch (e) {} return of.apply(this, arguments); }; } } catch (e) {}\n"
        @"try { var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src'); if (d && d.set) { Object.defineProperty(HTMLMediaElement.prototype, 'src', {get: d.get, set: function(v){ report(v, 'media'); return d.set.call(this, v); }, configurable: true}); } } catch (e) {}\n"
        @"try { var sa = Element.prototype.setAttribute; Element.prototype.setAttribute = function(n, v){ try { var t = (this.tagName || '').toLowerCase(); if ((t === 'video' || t === 'source' || t === 'audio') && String(n).toLowerCase() === 'src') { report(v, t === 'audio' ? 'network' : 'media'); } } catch (e) {} return sa.apply(this, arguments); }; } catch (e) {}\n"
        @"function scan(){\n"
        @"  try { document.querySelectorAll('video, video source').forEach(function(e){ report(e.currentSrc || e.src || e.getAttribute('src'), 'media'); }); } catch (e) {}\n"
        @"  try { performance.getEntriesByType('resource').forEach(function(r){ report(r.name, 'network'); }); } catch (e) {}\n"
        @"}\n"
        @"// The player's configuration in the page often lists the real stream addresses (before any advert has played).\n"
        @"var pageStreams = [], pageScans = 0;\n"
        @"function addPageStream(u, fromConfig){ try { u = String(u).replace(/\\\\\\//g, '/').replace(/\\\\u0026/g, '&').replace(/&amp;/g, '&'); if (!/^https?:\\/\\//.test(u) || AD_SRC.test(u)) { return; } var hls = /\\.m3u8(\\?|$)/i.test(u); var mp4 = /\\.mp4(\\?|$)/i.test(u); if (!hls && !(fromConfig && mp4)) { return; } if (pageStreams.indexOf(u) < 0) { pageStreams.push(u); dlog('Stream in Seite gefunden: ' + u.replace(/^https?:\\/\\//, '').slice(0, 70)); } report(u, 'page'); } catch (e) {} }\n"
        @"var fetchedMedia = {}, configLogged = {};\n"
        @"function takeDefinitions(defs, where){\n"
        @"  if (!defs || !defs.forEach) { return; }\n"
        @"  if (!configLogged[where]) { configLogged[where] = 1; var f = []; defs.forEach(function(d){ if (d) { f.push((d.format || '?') + ':' + (d.quality || '?') + ':' + String(d.videoUrl || '').replace(/^https?:\\/\\//, '').slice(0, 28)); } }); dlog('Player-Config ' + where + ' (' + defs.length + '): ' + f.join(' ; ')); }\n"
        @"  defs.forEach(function(d){\n"
        @"    if (!d || !d.videoUrl) { return; }\n"
        @"    var u = String(d.videoUrl);\n"
        @"    if (/get_media|\\/media\\//i.test(u) || d.remote) {\n"
        @"      if (fetchedMedia[u]) { return; } fetchedMedia[u] = 1;\n"
        @"      dlog('lade Video-Liste: ' + u.replace(/^https?:\\/\\//, '').slice(0, 50));\n"
        @"      try { (window.__browserOrigFetch || fetch)(u, {credentials: 'include'}).then(function(r){ return r.json(); }).then(function(list){ if (list && !list.forEach && list.mediaDefinitions) { list = list.mediaDefinitions; } if (list && list.forEach) { dlog('Video-Liste: ' + list.length + ' Eintraege'); list.forEach(function(x){ if (x && x.videoUrl) { addPageStream(x.videoUrl, true); } }); } }).catch(function(er){ dlog('Video-Liste Fehler: ' + (er && er.message)); }); } catch (e) {}\n"
        @"      return;\n"
        @"    }\n"
        @"    addPageStream(u, true);\n"
        @"  });\n"
        @"}\n"
        @"function scanPageConfig(){\n"
        @"  if (pageScans++ > 12) { return; }\n"
        @"  try { Object.keys(window).forEach(function(k){ if (!/flash|player|video|media|config/i.test(k)) { return; } var o; try { o = window[k]; } catch (x) { return; } if (!o || typeof o !== 'object') { return; } var defs = o.mediaDefinitions || o.mediaDefinition || (o.video && o.video.mediaDefinitions); if (!defs && Array.isArray(o) && o.length && o[0] && o[0].videoUrl) { defs = o; } if (defs) { takeDefinitions(defs, k); } }); } catch (e) {}\n"
        @"  try { var html = document.documentElement.innerHTML; var re = /https?:(?:\\\\?\\/){2}[^\"'\\s<>]+?\\.m3u8[^\"'\\s<>]*/g; var mm; var n = 0; while ((mm = re.exec(html)) && n++ < 40) { addPageStream(mm[0]); } } catch (e) {}\n"
        @"  pageStreams.sort(function(a, b){ function q(u){ var m = /(2160|1440|1080|720|480|360|240)[pP]/.exec(u); var v = m ? +m[1] : 500; return v > 1080 ? 1080 - v / 10 : v; } return q(b) - q(a); });\n"
        @"  window.__browserPageStreams = pageStreams;\n"
        @"}\n"
        @"document.addEventListener('DOMContentLoaded', function(){ scan(); scanPageConfig(); }); setInterval(function(){ scan(); scanPageConfig(); }, 2500);\n"
        @"// Pre-roll adverts: skip or fast-forward them, then make sure the real video starts (and goes full screen again if wanted).\n"
        @"var AD_SRC = /adtng|trafficjunky|doubleclick|googlesyndication|imasdk|exoclick|exosrv|juicyads|adnxs|adsystem|adserver|magsrv|tsyndicate|realsrv|trafficstars|vast|preroll|pre-roll|pre_videos|evtubescms|\\/ads?\\//i;\n"
        @"var AD_BOX = '[class*=\"adroll\" i],[class*=\"preroll\" i],[class*=\"pre-roll\" i],[class*=\"vast\" i],[class*=\"ima-ad\" i],[id*=\"adroll\" i],[id*=\"preroll\" i],.vjs-ad-playing,.jw-flag-ads,.fp-ad,.ad-container,.ad-playing,.ad-showing';\n"
        @"var SKIP_SEL = '[class*=\"skip\" i],[id*=\"skip\" i],[aria-label*=\"skip\" i],[aria-label*=\"überspringen\" i],[title*=\"skip\" i]';\n"
        @"var SKIP_TEXT = /skip|überspringen|ueberspringen|passer|salta|saltar|weiter zum video|close ad|werbung schlie/i;\n"
        @"var PLAY_SEL = '.mgp_playIcon,.mgp_bigPlay,.vjs-big-play-button,.jw-icon-display,.fp-play,.plyr__control--overlaid,.play-button,.big-play-button,[class*=\"bigPlay\" i],[aria-label=\"Play\"],[aria-label=\"Abspielen\"]';\n"
        @"function isAdVideo(v){\n"
        @"  try {\n"
        @"    var s = v.currentSrc || v.src || '';\n"
        @"    if (s && AD_SRC.test(s)) { return true; }\n"
        @"    var d = v.duration;\n"
        @"    if (isFinite(d) && d > 0 && d <= 65 && v.closest && v.closest(AD_BOX)) { return true; }\n"
        @"  } catch (e) {}\n"
        @"  return false;\n"
        @"}\n"
        @"window.__browserIsAdVideo = isAdVideo;\n"
        @"var FR = (window === window.top) ? 'top' : ('frm:' + location.hostname);\n"
        @"function dlog(m){ try { var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserMedia; if (h) { h.postMessage({type: 'adlog', msg: FR + ' ' + m}); } } catch (e) {} }\n"
        @"function vdesc(v, i){ var s = v.currentSrc || v.src || ''; s = s.indexOf('blob:') === 0 ? 'blob' : s.replace(/^https?:\\/\\//, '').slice(0, 38); var r = v.getBoundingClientRect(); return '#' + i + ' ' + s + ' d=' + (isFinite(v.duration) ? Math.round(v.duration) : '-') + ' t=' + Math.round(v.currentTime) + (v.paused ? ' P' : ' >') + (v.ended ? 'E' : '') + ' w=' + Math.round(r.width) + (isAdVideo(v) ? ' AD' : '') + (v.muted ? ' m' : '') + ' rs=' + v.readyState; }\n"
        @"var lastSig = '';\n"
        @"function logState(){ try { var parts = []; var vs = document.querySelectorAll('video'); for (var i = 0; i < vs.length; i++) { parts.push(vdesc(vs[i], i).replace(/ t=\\d+/, '')); } var sig = parts.join(' | '); if (sig !== lastSig) { lastSig = sig; var full = []; for (var j = 0; j < vs.length; j++) { full.push(vdesc(vs[j], j)); } dlog('VIDEOS ' + (full.join(' | ') || 'keine')); } } catch (e) {} }\n"
        @"['ended', 'pause', 'error', 'emptied', 'stalled', 'abort'].forEach(function(n){ document.addEventListener(n, function(ev){ try { var vs = Array.prototype.indexOf.call(document.querySelectorAll('video'), ev.target); dlog('EVENT ' + n + ' #' + vs + (ev.target && ev.target.error ? ' err=' + ev.target.error.code : '')); } catch (e) {} }, true); });\n"
        @"function shown(el){ try { var r = el.getBoundingClientRect(); var st = getComputedStyle(el); return r.width > 4 && r.height > 4 && st.visibility !== 'hidden' && st.display !== 'none' && st.opacity !== '0'; } catch (e) { return false; } }\n"
        @"function clickSkip(){\n"
        @"  try {\n"
        @"    var list = document.querySelectorAll(SKIP_SEL + ',button,[role=\"button\"]');\n"
        @"    for (var i = 0; i < list.length; i++) {\n"
        @"      var b = list[i]; var t = (b.innerText || b.getAttribute('aria-label') || b.title || '').trim();\n"
        @"      if (t.length > 40 || !shown(b) || b.disabled) { continue; }\n"
        @"      if (/\\d/.test(t) && /in|sek|sec|s$/i.test(t) && !/^skip/i.test(t)) { continue; }\n"
        @"      if (SKIP_TEXT.test(t) || (b.matches && b.matches(SKIP_SEL) && t.length > 0)) { b.click(); dlog('Skip geklickt: ' + t); return true; }\n"
        @"    }\n"
        @"  } catch (e) {}\n"
        @"  return false;\n"
        @"}\n"
        @"function mainVideo(){\n"
        @"  var best = null, area = 0;\n"
        @"  document.querySelectorAll('video').forEach(function(v){ if (isAdVideo(v)) { return; } var r = v.getBoundingClientRect(); var a = r.width * r.height; if (v.webkitDisplayingFullscreen) { a += 1e9; } if (a > area) { area = a; best = v; } });\n"
        @"  return (best && (best.webkitDisplayingFullscreen || best.getBoundingClientRect().width >= window.innerWidth * 0.2)) ? best : null;\n"
        @"}\n"
        @"var adActive = false, resumeUntil = 0, playClicked = false;\n"
        @"function adTick(){\n"
        @"  var now = Date.now(), adNow = false;\n"
        @"  document.querySelectorAll('video').forEach(function(v){\n"
        @"    if (v.paused || v.ended || !isAdVideo(v)) { return; }\n"
        @"    adNow = true;\n"
        @"    try { v.muted = true; } catch (e) {}\n"
        @"    try { var d = v.duration; if (isFinite(d) && d > 0.5 && v.currentTime < d - 0.6) { v.currentTime = d - 0.25; } } catch (e) {}\n"
        @"    try { if (v.playbackRate < 8) { v.playbackRate = 16; } } catch (e) {}\n"
        @"  });\n"
        @"  // A pre-roll that sits paused at the start blocks the player (it waits for the advert to finish): finish it.\n"
        @"  var stuckMain = false;\n"
        @"  document.querySelectorAll('video').forEach(function(v){ if (!isAdVideo(v) && v.currentTime < 1 && !v.ended && (v.readyState < 2 || v.paused)) { stuckMain = true; } });\n"
        @"  if (stuckMain) {\n"
        @"    document.querySelectorAll('video').forEach(function(v){\n"
        @"      if (!v.paused || v.ended || !isAdVideo(v)) { return; }\n"
        @"      if (v.__browserKickAt && now - v.__browserKickAt < 1500) { return; }\n"
        @"      v.__browserKickAt = now; v.__browserKicks = (v.__browserKicks || 0) + 1;\n"
        @"      adNow = true;\n"
        @"      try { v.muted = true; var d = v.duration; if (isFinite(d) && d > 0.5) { v.currentTime = d - 0.25; } } catch (e) {}\n"
        @"      dlog('pausierte Werbung #' + Array.prototype.indexOf.call(document.querySelectorAll('video'), v) + ' wird beendet (Versuch ' + v.__browserKicks + ')');\n"
        @"      var fire = function(){ try { v.dispatchEvent(new Event('ended')); dlog('ended-Signal an Player gesendet'); } catch (x) {} };\n"
        @"      try { var p = v.play(); if (p && p.catch) { p.catch(function(er){ dlog('Werbung play() abgelehnt: ' + (er && er.name)); fire(); }); } } catch (e) { fire(); }\n"
        @"      if (v.__browserKicks >= 3) { fire(); }\n"
        @"    });\n"
        @"  }\n"
        @"  if (adNow) { clickSkip(); }\n"
        @"  logState();\n"
        @"  if (adNow) { if (!adActive) { dlog('WERBUNG erkannt'); } adActive = true; window.__browserAdSeenAt = now; return; }\n"
        @"  if (adActive) { adActive = false; resumeUntil = now + 15000; playClicked = false; dlog('WERBUNG vorbei, starte Hauptvideo'); }\n"
        @"  if (now > resumeUntil) { return; }\n"
        @"  var m = mainVideo();\n"
        @"  if (!m) {\n"
        @"    if (!playClicked) { try { var pb = document.querySelector(PLAY_SEL); if (pb && shown(pb)) { pb.click(); playClicked = true; dlog('kein Hauptvideo, Play-Knopf geklickt: ' + (pb.className || pb.tagName)); } else if (!pb) { dlog('kein Hauptvideo und kein Play-Knopf'); playClicked = true; } } catch (e) {} }\n"
        @"    return;\n"
        @"  }\n"
        @"  try { m.muted = false; if (m.playbackRate > 2) { m.playbackRate = 1; } } catch (e) {}\n"
        @"  // The player never gave its video a source after the advert: give it the stream from the page (WebKit plays HLS itself).\n"
        @"  if (!(m.currentSrc || m.src) && m.readyState === 0 && pageStreams.length > 0 && now > resumeUntil - 11000 && !m.__browserFedSrc) {\n"
        @"    m.__browserFedSrc = true; dlog('Hauptvideo ohne Quelle, setze Stream aus der Seite');\n"
        @"    try { m.src = pageStreams[0]; m.load(); var pp = m.play(); if (pp && pp.catch) { pp.catch(function(er){ dlog('play() abgelehnt: ' + (er && er.name)); }); } } catch (e) { dlog('Quelle setzen fehlgeschlagen'); }\n"
        @"    return;\n"
        @"  }\n"
        @"  if (m.paused && !m.ended) {\n"
        @"    dlog('Hauptvideo pausiert, play()');\n"
        @"    try { var p = m.play(); if (p && p.catch) { p.catch(function(er){ dlog('play() abgelehnt: ' + (er && er.name)); if (!playClicked) { try { var pb2 = document.querySelector(PLAY_SEL); if (pb2) { pb2.click(); playClicked = true; } } catch (x) {} } }); } } catch (e) {}\n"
        @"    return;\n"
        @"  }\n"
        @"  var want = window.__browserWantFullscreen || 0;\n"
        @"  if (want && now - want < 120000 && !m.webkitDisplayingFullscreen && m.readyState >= 1) {\n"
        @"    window.__browserWantFullscreen = 0;\n"
        @"    dlog('Hauptvideo wieder Vollbild');\n"
        @"    try { if (m.webkitEnterFullscreen) { m.webkitEnterFullscreen(); } else if (m.requestFullscreen) { m.requestFullscreen(); } } catch (e) {}\n"
        @"  }\n"
        @"  if (!m.paused && (!want || m.webkitDisplayingFullscreen)) { resumeUntil = 0; }\n"
        @"}\n"
        @"setInterval(adTick, 400);\n"
        @"window.addEventListener('message', function(e){\n"
        @"  if (e.data === '__browserSkipAdverts') { document.querySelectorAll('video').forEach(function(v){ var d = v.duration; if (isAdVideo(v) || (isFinite(d) && d > 0 && d <= 120)) { try { v.muted = true; v.currentTime = Math.max(0, d - 0.2); v.play(); } catch (x) {} } }); adActive = true; return; }\n"
        @"  if (e.data === '__browserWantFullscreen') { window.__browserWantFullscreen = Date.now(); for (var k = 0; k < window.frames.length; k++) { try { window.frames[k].postMessage('__browserWantFullscreen', '*'); } catch (x) {} } return; }\n"
        @"  if (e.data !== '__browserEnterFullscreen') { return; }\n"
        @"  var best = null, area = 0;\n"
        @"  window.__browserWantFullscreen = Date.now();\n"
        @"  document.querySelectorAll('video').forEach(function(v){ var r = v.getBoundingClientRect(); var a = r.width * r.height; if (!v.paused) { a += 1e9; } if (a > area) { area = a; best = v; } });\n"
        @"  if (best && isAdVideo(best)) { return; }\n"
        @"  if (best && best.getBoundingClientRect().width >= 50) {\n"
        @"    if (best.webkitDisplayingFullscreen) { return; }\n"
        @"    if (best.paused) { try { var p = best.play(); if (p && p.catch) { p.catch(function(){}); } } catch (x) {} }\n"
        @"    try { if (best.webkitEnterFullscreen) { best.webkitEnterFullscreen(); } else if (best.requestFullscreen) { best.requestFullscreen(); } } catch (x) {}\n"
        @"    return;\n"
        @"  }\n"
        @"  for (var i = 0; i < window.frames.length; i++) { try { window.frames[i].postMessage('__browserEnterFullscreen', '*'); } catch (x) {} }\n"
        @"});\n"
        @"})();\n";
}

/// Receives the stream addresses from the page script (WebKit is loaded at runtime, so the protocol is added at runtime too).
@interface BrowserMediaMessageHandler : NSObject
@property (nonatomic, weak) id owner;
@end

@implementation BrowserMediaMessageHandler
- (void)userContentController:(id)userContentController didReceiveScriptMessage:(id)message {
    (void)userContentController;
    id body = [message respondsToSelector:NSSelectorFromString(@"body")] ? ((id (*)(id, SEL))objc_msgSend)(message, NSSelectorFromString(@"body")) : nil;
    if (![body isKindOfClass:[NSDictionary class]]) {
        return;
    }
    id owner = self.owner;
    if ([body[@"type"] isEqual:@"adlog"]) {
        NSString *line = [body[@"msg"] isKindOfClass:[NSString class]] ? body[@"msg"] : @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL logSelector = NSSelectorFromString(@"appendAdDebugLine:");
            if ([owner respondsToSelector:logSelector]) {
                ((void (*)(id, SEL, id))objc_msgSend)(owner, logSelector, line);
            }
        });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL addSelector = NSSelectorFromString(@"addCapturedMediaStream:");
        if ([owner respondsToSelector:addSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(owner, addSelector, body);
        }
    });
}
@end

static NSString *BrowserCookieAutoAcceptScript(void) {
    static NSString *script = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        script =
        @"(function(){\n"
        @"if (window.__tvCookieAutoAccept) { return; }\n"
        @"window.__tvCookieAutoAccept = true;\n"
        @"var SELECTORS = ['#L2AGLb', '#onetrust-accept-btn-handler', '#didomi-notice-agree-button', '.fc-cta-consent', '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll', '#CybotCookiebotDialogBodyButtonAccept', '.cky-btn-accept', '#cookiescript_accept', '[data-testid=\"uc-accept-all-button\"]', 'button[data-cookiefirst-action=\"accept\"]', '.qc-cmp2-summary-buttons button[mode=\"primary\"]', '#truste-consent-button', '.cmpboxbtnyes', '.sp_choice_type_11', 'button[aria-label=\"Accept all\"]', 'button[aria-label=\"Alle akzeptieren\"]'];\n"
        @"var WORDS = ['alle akzeptieren', 'alles akzeptieren', 'alle annehmen', 'alle cookies akzeptieren', 'alle zulassen', 'alle cookies zulassen', 'akzeptieren und schliessen', 'akzeptieren und schließen', 'zustimmen und weiter', 'einverstanden', 'akzeptieren', 'zustimmen', 'accept all', 'accept all cookies', 'allow all', 'allow all cookies', 'i agree', 'agree', 'accept', 'accept cookies', 'got it', 'tout accepter', 'accepter', \"j'accepte\", 'accetta tutto', 'accetta', 'accetto'];\n"
        @"function visible(el){ var r = el.getBoundingClientRect(); var s = getComputedStyle(el); return r.width > 2 && r.height > 2 && s.visibility !== 'hidden' && s.display !== 'none'; }\n"
        @"function roots(){ var list = [document]; var uc = document.querySelector('#usercentrics-root, #usercentrics-cmp-ui'); if (uc && uc.shadowRoot) { list.push(uc.shadowRoot); } return list; }\n"
        @"function tryClick(){\n"
        @"  var all = roots();\n"
        @"  for (var r = 0; r < all.length; r++) {\n"
        @"    for (var i = 0; i < SELECTORS.length; i++) {\n"
        @"      var el = all[r].querySelector(SELECTORS[i]);\n"
        @"      if (el && visible(el)) { el.click(); return true; }\n"
        @"    }\n"
        @"  }\n"
        @"  for (var r2 = 0; r2 < all.length; r2++) {\n"
        @"    var buttons = all[r2].querySelectorAll('button, [role=\"button\"], a.button, input[type=\"button\"], input[type=\"submit\"]');\n"
        @"    for (var j = 0; j < buttons.length; j++) {\n"
        @"      var b = buttons[j];\n"
        @"      var t = (b.innerText || b.value || b.getAttribute('aria-label') || '').trim().toLowerCase().replace(/\\s+/g, ' ');\n"
        @"      if (t.length > 0 && t.length < 40 && WORDS.indexOf(t) >= 0 && visible(b)) { b.click(); return true; }\n"
        @"    }\n"
        @"  }\n"
        @"  return false;\n"
        @"}\n"
        @"var tries = 0;\n"
        @"var timer = setInterval(function(){ tries += 1; if (tryClick() || tries > 30) { clearInterval(timer); } }, 500);\n"
        @"tryClick();\n"
        @"})();\n";
    });
    return script;
}

static NSString *BrowserForceDarkScript(BOOL enabled) {
    return [NSString stringWithFormat:@"%@(%@);", BrowserForceDarkScriptFunction(), enabled ? @"true" : @"false"];
}

static void BrowserInstallYouTubeCaptureUserScript(id configuration) {
    if (configuration == nil) {
        return;
    }

    Class userContentControllerClass = NSClassFromString(kBrowserUserContentControllerClassName);
    Class userScriptClass = NSClassFromString(kBrowserUserScriptClassName);
    if (userContentControllerClass == Nil || userScriptClass == Nil) {
        return;
    }

    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    SEL setUserContentControllerSelector = NSSelectorFromString(@"setUserContentController:");
    id userContentController = nil;
    if ([configuration respondsToSelector:userContentControllerGetter]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    }

    if (userContentController == nil && [configuration respondsToSelector:setUserContentControllerSelector]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)((id)userContentControllerClass, @selector(new));
        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setUserContentControllerSelector, userContentController);
    }

    SEL addUserScriptSelector = NSSelectorFromString(@"addUserScript:");
    SEL userScriptInitializer = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (userContentController == nil ||
        ![userContentController respondsToSelector:addUserScriptSelector] ||
        ![userScriptClass instancesRespondToSelector:userScriptInitializer]) {
        return;
    }

    id userScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, userScriptInitializer, BrowserYouTubeRequestCaptureScript(), 0, NO);
    if (userScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addUserScriptSelector, userScript);
    }

    // Video stream capture: at document start (0), in every frame, so players in iframes are seen too.
    id mediaScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
    mediaScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(mediaScript, userScriptInitializer, BrowserMediaCaptureScript(), 0, NO);
    if (mediaScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addUserScriptSelector, mediaScript);
    }

    // Cookie banners: at document end (1), in every frame, because many banners live in an iframe.
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kBrowserAutoAcceptCookiesDisabledKey]) {
        id cookieScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
        cookieScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(cookieScript, userScriptInitializer, BrowserCookieAutoAcceptScript(), 1, NO);
        if (cookieScript != nil) {
            ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addUserScriptSelector, cookieScript);
        }
    }

    // Dark mode for websites, injected at document start (0) into the main frame only.
    if ([BrowserWebView websitesShouldBeDark]) {
        id darkScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
        darkScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(darkScript, userScriptInitializer, BrowserForceDarkScript(YES), 0, YES);
        if (darkScript != nil) {
            ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addUserScriptSelector, darkScript);
        }
    }
}

@interface BrowserWebView ()

@property (nullable, nonatomic, strong) id runtimeWebView;
@property (nullable, nonatomic, strong) NSURLRequest *lastRequest;
@property (nullable, nonatomic, copy) NSString *lastTitle;
@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL loading;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSString *> *> *mediaStreams;
@property (nonatomic, strong) BrowserMediaMessageHandler *mediaMessageHandler;
@property (nonatomic, weak) id mediaUserContentController;
@property (nonatomic, strong) NSMutableSet<NSString *> *advertStreamURLs;

@end

@implementation BrowserWebView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [self initWithUserAgent:nil allowsInlineMediaPlayback:YES];
    if (self) {
        self.frame = frame;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInitWithUserAgent:nil allowsInlineMediaPlayback:YES];
    }
    return self;
}

- (instancetype)initWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        [self commonInitWithUserAgent:userAgent allowsInlineMediaPlayback:allowsInlineMediaPlayback];
    }
    return self;
}

- (void)commonInitWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    BrowserEnsureWebKitRuntimeLoaded();

    self.backgroundColor = UIColor.clearColor; // the container behind shows the remembered page colour
    self.userAgent = userAgent;
    self.scalesPageToFit = NO;

    Class configurationClass = NSClassFromString(kBrowserWebViewConfigurationClassName);
    Class webViewClass = NSClassFromString(kBrowserWebViewClassName);
    if (configurationClass == Nil || webViewClass == Nil) {
        return;
    }

    id configuration = ((id (*)(id, SEL))objc_msgSend)((id)configurationClass, @selector(new));
    SEL allowsInlineMediaPlaybackSelector = NSSelectorFromString(@"setAllowsInlineMediaPlayback:");
    if (configuration != nil && [configuration respondsToSelector:allowsInlineMediaPlaybackSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(configuration, allowsInlineMediaPlaybackSelector, allowsInlineMediaPlayback);
    }
    BrowserConfigurePrivateMediaPreferences(configuration);
    BrowserInstallYouTubeCaptureUserScript(configuration);
    [self installMediaMessageHandlerInConfiguration:configuration];

    id webViewObject = ((id (*)(id, SEL))objc_msgSend)((id)webViewClass, @selector(alloc));
    SEL initializer = NSSelectorFromString(@"initWithFrame:configuration:");
    webViewObject = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webViewObject, initializer, self.bounds, configuration);
    if (webViewObject == nil) {
        return;
    }

    self.runtimeWebView = webViewObject;
    UIView *runtimeView = (UIView *)webViewObject;
    runtimeView.frame = self.bounds;
    runtimeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    runtimeView.backgroundColor = UIColor.clearColor;

    SEL navigationDelegateSelector = NSSelectorFromString(@"setNavigationDelegate:");
    if ([webViewObject respondsToSelector:navigationDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, navigationDelegateSelector, self);
    }

    SEL UIDelegateSelector = NSSelectorFromString(@"setUIDelegate:");
    if ([webViewObject respondsToSelector:UIDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, UIDelegateSelector, self);
    }

    [self addSubview:runtimeView];
    [self setUserAgent:userAgent];
    [self applyPreferredInterfaceStyle];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleForceDarkPagesDidChange:)
                                                 name:BrowserForceDarkPagesDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    SEL removeSelector = NSSelectorFromString(@"removeScriptMessageHandlerForName:");
    id controller = self.mediaUserContentController;
    if ([controller respondsToSelector:removeSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, removeSelector, @"browserMedia");
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Video stream capture

- (void)installMediaMessageHandlerInConfiguration:(id)configuration {
    self.mediaStreams = [NSMutableArray array];
    SEL getter = NSSelectorFromString(@"userContentController");
    id controller = [configuration respondsToSelector:getter] ? ((id (*)(id, SEL))objc_msgSend)(configuration, getter) : nil;
    SEL addSelector = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if (![controller respondsToSelector:addSelector]) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Protocol *handlerProtocol = objc_getProtocol("WKScriptMessageHandler");
        if (handlerProtocol != NULL) {
            class_addProtocol([BrowserMediaMessageHandler class], handlerProtocol);
        }
    });
    self.mediaMessageHandler = [BrowserMediaMessageHandler new];
    self.mediaMessageHandler.owner = self;
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addSelector, self.mediaMessageHandler, @"browserMedia");
        self.mediaUserContentController = controller;
    } @catch (__unused NSException *exception) {}
}

- (void)addCapturedMediaStream:(NSDictionary *)body {
    NSString *url = [body[@"url"] isKindOfClass:[NSString class]] ? body[@"url"] : nil;
    NSString *type = [body[@"type"] isKindOfClass:[NSString class]] ? body[@"type"] : @"";
    if (url.length == 0 || type.length == 0) {
        return;
    }
    for (NSDictionary *existing in self.mediaStreams) {
        if ([existing[@"url"] isEqualToString:url]) {
            return;
        }
    }
    if (self.mediaStreams.count > 200) {
        [self.mediaStreams removeObjectAtIndex:0];
    }
    [self.mediaStreams addObject:@{
        @"url": url,
        @"type": type,
        @"source": [body[@"source"] isKindOfClass:[NSString class]] ? body[@"source"] : @"network",
        @"page": [body[@"page"] isKindOfClass:[NSString class]] ? body[@"page"] : @"",
    }];
    BrowserLog(@"[MediaCapture] %@ (%@) %@", type, body[@"source"] ?: @"", url);
}

#pragma mark - Advert diagnostics

/// Lines from the page script about adverts and video elements; only in debug builds, in the Xcode console.
- (void)appendAdDebugLine:(NSString *)line {
#if DEBUG
    BrowserLog(@"[AdDbg] %@", line);
#else
    (void)line;
#endif
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)capturedMediaStreams {
    return [self.mediaStreams copy] ?: @[];
}

- (NSString *)browserUserAgent {
    return self.userAgent ?: @"";
}

static BOOL BrowserMediaURLIsAdvert(NSString *URLString) {
    NSString *lower = URLString.lowercaseString;
    NSArray<NSString *> *advertHints = @[
        @"adtng.com", @"trafficjunky", @"doubleclick.net", @"googlesyndication", @"googleads", @"imasdk",
        @"exoclick", @"exosrv", @"juicyads", @"adnxs", @"adsystem", @"adserver", @"magsrv", @"tsyndicate",
        @"realsrv", @"trafficstars", @"pre_videos", @"evtubescms", @"/vast", @"vast.xml", @"preroll", @"pre-roll", @"/ads/", @"/ad/", @"advert",
    ];
    for (NSString *hint in advertHints) {
        if ([lower containsString:hint]) {
            return YES;
        }
    }
    return NO;
}

static NSInteger BrowserMediaQualityInURL(NSString *URLString) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[^0-9])(2160|1440|1080|720|480|360|240)[pP]?(?:[^0-9]|$)" options:0 error:nil];
    NSInteger best = 0;
    for (NSTextCheckingResult *match in [expression matchesInString:URLString options:0 range:NSMakeRange(0, URLString.length)]) {
        best = MAX(best, [[URLString substringWithRange:[match rangeAtIndex:1]] integerValue]);
    }
    return best;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)playableCapturedMediaStreams {
    NSArray<NSString *> *pieceHints = @[@"seg-", @"seg_", @"/seg", @"frag", @"chunk", @"init.", @"/range/", @".m4s"];
    NSArray<NSString *> *previewHints = @[@"preview", @"thumb", @"teaser", @"trailer", @"sprite", @"hover"];
    NSMutableArray<NSDictionary *> *scored = [NSMutableArray array];
    NSUInteger order = 0;
    for (NSDictionary<NSString *, NSString *> *stream in self.mediaStreams) {
        order += 1;
        NSString *url = stream[@"url"] ?: @"";
        NSString *type = stream[@"type"] ?: @"";
        NSString *lower = url.lowercaseString;
        if ([self.advertStreamURLs containsObject:url]) {
            continue;
        }
        if (BrowserMediaURLIsAdvert(url) || !([type isEqualToString:@"hls"] || [type isEqualToString:@"file"] || [type isEqualToString:@"dash"])) {
            continue;
        }
        if ([type isEqualToString:@"file"] && ![stream[@"source"] isEqualToString:@"media"]) {
            BOOL piece = NO;
            for (NSString *hint in pieceHints) {
                if ([lower containsString:hint]) { piece = YES; break; }
            }
            if (piece) {
                continue;
            }
        }
        // HLS first, then plain files; DASH only the VLC player can play, so it comes after them.
        NSInteger score = [type isEqualToString:@"hls"] ? 1000 : ([type isEqualToString:@"dash"] ? -200 : 0);
        if ([type isEqualToString:@"hls"] && [lower containsString:@"master"]) {
            score += 100;
        }
        if ([stream[@"source"] isEqualToString:@"media"]) {
            score += 50;
        }
        if ([stream[@"source"] isEqualToString:@"page"]) {
            score += 200; // from the player's own configuration: the real video, not an advert
        }
        score += BrowserMediaQualityInURL(url) / 10;
        for (NSString *hint in previewHints) {
            if ([lower containsString:hint]) { score -= 600; break; }
        }
        [scored addObject:@{@"stream": stream, @"score": @(score), @"order": @(order)}];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        NSComparisonResult byScore = [y[@"score"] compare:x[@"score"]];
        return byScore != NSOrderedSame ? byScore : [x[@"order"] compare:y[@"order"]];
    }];
    return [scored valueForKey:@"stream"];
}

- (NSDictionary<NSString *, NSString *> *)pageConfigMediaStream {
    for (NSDictionary<NSString *, NSString *> *stream in [self playableCapturedMediaStreams]) {
        if ([stream[@"source"] isEqualToString:@"page"]) {
            return stream;
        }
    }
    return nil;
}

- (void)markCapturedStreamAsAdvert:(NSString *)URLString {
    if (URLString.length == 0) {
        return;
    }
    if (self.advertStreamURLs == nil) {
        self.advertStreamURLs = [NSMutableSet set];
    }
    [self.advertStreamURLs addObject:URLString];
    BrowserLog(@"[MediaCapture] marked as advert: %@", URLString);
}

- (void)skipPageAdvertsAndPlayMainVideo {
    // Short clips (adverts) jump to their end; the longest real video gets started.
    [self stringByEvaluatingJavaScriptFromString:
     @"(function(){"
      "var isAd = window.__browserIsAdVideo || function(){ return false; };"
      "var main = null, area = 0;"
      "document.querySelectorAll('video').forEach(function(v){"
      "  var d = v.duration;"
      "  if (isAd(v) || (isFinite(d) && d > 0 && d <= 120)) { try { v.muted = true; v.currentTime = Math.max(0, d - 0.2); v.play(); } catch (e) {} return; }"
      "  var r = v.getBoundingClientRect(); var a = r.width * r.height; if (a > area) { area = a; main = v; }"
      "});"
      "if (main && main.paused) { try { var p = main.play(); if (p && p.catch) { p.catch(function(){}); } } catch (e) {} }"
      "if (!main) { try { var b = document.querySelector('.mgp_playIcon,.mgp_bigPlay,.vjs-big-play-button,.jw-icon-display,.fp-play,.play-button,.big-play-button'); if (b) { b.click(); } } catch (e) {} }"
      "try { for (var i = 0; i < window.frames.length; i++) { window.frames[i].postMessage('__browserSkipAdverts', '*'); } } catch (e) {}"
      "return main ? 'main' : 'none'; })()"];
}

- (NSDictionary<NSString *, NSString *> *)bestCapturedMediaStream {
    return [self playableCapturedMediaStreams].firstObject;
}


+ (BOOL)forceDarkPages {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kBrowserForceDarkPagesDefaultsKey];
}

+ (void)setForceDarkPages:(BOOL)forceDarkPages {
    [[NSUserDefaults standardUserDefaults] setBool:forceDarkPages forKey:kBrowserForceDarkPagesDefaultsKey];
    [self applyAppearanceToWindows];
    [[NSNotificationCenter defaultCenter] postNotificationName:BrowserForceDarkPagesDidChangeNotification object:nil];
}

+ (NSInteger)appearanceMode {
    return MIN(MAX([[NSUserDefaults standardUserDefaults] integerForKey:@"BrowserAppearanceMode"], 0), 2);
}

+ (void)setAppearanceMode:(NSInteger)appearanceMode {
    [[NSUserDefaults standardUserDefaults] setInteger:MIN(MAX(appearanceMode, 0), 2) forKey:@"BrowserAppearanceMode"];
    [self applyAppearanceToWindows];
    [[NSNotificationCenter defaultCenter] postNotificationName:BrowserForceDarkPagesDidChangeNotification object:nil];
}

/// The Apple TV's own light/dark setting (read from the scene, which our window override doesn't change).
+ (BOOL)systemIsDark {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIUserInterfaceStyle style = ((UIWindowScene *)scene).traitCollection.userInterfaceStyle;
            if (style != UIUserInterfaceStyleUnspecified) {
                return style == UIUserInterfaceStyleDark;
            }
        }
    }
    return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
}

+ (BOOL)websitesShouldBeDark {
    if (!self.forceDarkPages) {
        return NO;
    }
    switch (self.appearanceMode) {
        case 1:
            return NO;
        case 2:
            return YES;
        default:
            return [self systemIsDark];
    }
}

+ (void)applyAppearanceToWindows {
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    if (self.forceDarkPages) {
        NSInteger mode = self.appearanceMode;
        style = mode == 1 ? UIUserInterfaceStyleLight : (mode == 2 ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified);
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            window.overrideUserInterfaceStyle = style;
        }
    }
}

+ (BOOL)autoAcceptCookies {
    return ![[NSUserDefaults standardUserDefaults] boolForKey:kBrowserAutoAcceptCookiesDisabledKey];
}

+ (void)setAutoAcceptCookies:(BOOL)autoAcceptCookies {
    [[NSUserDefaults standardUserDefaults] setBool:!autoAcceptCookies forKey:kBrowserAutoAcceptCookiesDisabledKey];
    // Same path as the dark-mode switch: re-installs the start-of-page scripts in every web view.
    [[NSNotificationCenter defaultCenter] postNotificationName:BrowserForceDarkPagesDidChangeNotification object:nil];
}

- (void)applyPreferredInterfaceStyle {
    // Sites that have their own dark design pick it up through prefers-color-scheme.
    UIView *runtimeView = (UIView *)self.runtimeWebView;
    // Dark mode off: pages follow the Apple TV as before. On: the chosen look (automatic / light / dark).
    if (!BrowserWebView.forceDarkPages) {
        runtimeView.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    } else {
        runtimeView.overrideUserInterfaceStyle = [BrowserWebView websitesShouldBeDark] ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    }
}

- (void)handleForceDarkPagesDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyPreferredInterfaceStyle];

    // Re-install the start-of-page scripts so the next pages follow the new setting.
    SEL configurationSelector = NSSelectorFromString(@"configuration");
    SEL userContentControllerSelector = NSSelectorFromString(@"userContentController");
    SEL removeAllSelector = NSSelectorFromString(@"removeAllUserScripts");
    if ([self.runtimeWebView respondsToSelector:configurationSelector]) {
        id configuration = ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, configurationSelector);
        id userContentController = [configuration respondsToSelector:userContentControllerSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerSelector)
            : nil;
        if ([userContentController respondsToSelector:removeAllSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(userContentController, removeAllSelector);
            BrowserInstallYouTubeCaptureUserScript(configuration);
        }
    }

    // And switch the page that is open right now.
    [self stringByEvaluatingJavaScriptFromString:BrowserForceDarkScript([BrowserWebView websitesShouldBeDark])];
    if ([BrowserWebView autoAcceptCookies]) {
        [self stringByEvaluatingJavaScriptFromString:BrowserCookieAutoAcceptScript()];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    ((UIView *)self.runtimeWebView).frame = self.bounds;
    [self applyPageScalingIfNeeded];
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled {
    [super setUserInteractionEnabled:userInteractionEnabled];

    UIView *runtimeView = (UIView *)self.runtimeWebView;
    runtimeView.userInteractionEnabled = userInteractionEnabled;

    UIScrollView *scrollView = [self scrollView];
    scrollView.userInteractionEnabled = userInteractionEnabled;
}

+ (BOOL)isWaitingForPage {
    return sBrowserJavaScriptEvaluationDepth > 0;
}

+ (void)waitBrieflyForPage:(NSTimeInterval)interval {
    sBrowserJavaScriptEvaluationDepth += 1;
    @autoreleasepool {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:interval]];
    }
    sBrowserJavaScriptEvaluationDepth -= 1;
}

- (void)setPageEdgeColor:(UIColor *)color {
    if (color == nil) {
        return;
    }
    self.backgroundColor = color;
    UIView *runtimeView = (UIView *)self.runtimeWebView;
    runtimeView.backgroundColor = color;
    [self scrollView].backgroundColor = color;

    SEL underPageSelector = NSSelectorFromString(@"setUnderPageBackgroundColor:");
    if ([self.runtimeWebView respondsToSelector:underPageSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, underPageSelector, color);
    }
}

- (UIScrollView *)scrollView {
    SEL selector = NSSelectorFromString(@"scrollView");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURL *)currentURL {
    SEL selector = NSSelectorFromString(@"URL");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURLRequest *)request {
    NSURL *currentURL = [self currentURL];
    if (currentURL != nil) {
        return [NSURLRequest requestWithURL:currentURL];
    }
    return self.lastRequest;
}

- (NSString *)title {
    SEL selector = NSSelectorFromString(@"title");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return self.lastTitle;
    }
    NSString *title = ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    return title ?: self.lastTitle;
}

- (BOOL)canGoBack {
    SEL selector = NSSelectorFromString(@"canGoBack");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (BOOL)canGoForward {
    SEL selector = NSSelectorFromString(@"canGoForward");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (void)loadRequest:(NSURLRequest *)request {
    if (request == nil || self.runtimeWebView == nil) {
        return;
    }
    self.lastRequest = request;
    SEL selector = NSSelectorFromString(@"loadRequest:");
    if ([self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, request);
    }
}

- (void)reload {
    SEL selector = NSSelectorFromString(@"reload");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goBack {
    SEL selector = NSSelectorFromString(@"goBack");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goForward {
    SEL selector = NSSelectorFromString(@"goForward");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script {
    if (script.length == 0 || self.runtimeWebView == nil) {
        return nil;
    }

    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }

    if (sBrowserJavaScriptEvaluationDepth > 0) {
        return nil;
    }

    __block id evaluationResult = nil;
    __block NSError *evaluationError = nil;
    __block BOOL finished = NO;
    sBrowserJavaScriptEvaluationDepth += 1;
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.runtimeWebView, selector, script, ^(id result, NSError *error) {
        evaluationResult = result;
        evaluationError = error;
        finished = YES;
    });
    BrowserPumpRunLoopUntil(&finished);
    sBrowserJavaScriptEvaluationDepth -= 1;

    if (evaluationError != nil) {
        return nil;
    }
    return BrowserStringFromJavaScriptResult(evaluationResult);
}

- (void)pauseAllMediaPlayback {
    if (self.runtimeWebView == nil) {
        return;
    }

    // Prefer WebKit's internal media pause APIs when available.
    SEL pauseWithCompletionHandlerSelector = NSSelectorFromString(@"pauseAllMediaPlaybackWithCompletionHandler:");
    if ([self.runtimeWebView respondsToSelector:pauseWithCompletionHandlerSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseWithCompletionHandlerSelector, nil);
    } else {
        SEL pauseSelector = NSSelectorFromString(@"pauseAllMediaPlayback:");
        if ([self.runtimeWebView respondsToSelector:pauseSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseSelector, nil);
        } else {
            SEL privatePauseSelector = NSSelectorFromString(@"_pauseAllMediaPlayback");
            if ([self.runtimeWebView respondsToSelector:privatePauseSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, privatePauseSelector);
            }
        }
    }

    // JS fallback for page media elements and common iframe-based players.
    NSString *pauseScript =
        @"(function(){"
            "function safe(fn){ try { fn(); } catch (error) {} }"
            "var media = document.querySelectorAll('video,audio');"
            "for (var i = 0; i < media.length; i++) {"
                "var element = media[i];"
                "safe(function(){ element.pause(); });"
                "safe(function(){ element.autoplay = false; });"
                "safe(function(){ element.removeAttribute('autoplay'); });"
            "}"
            "var iframePlayers = document.querySelectorAll('iframe');"
            "for (var j = 0; j < iframePlayers.length; j++) {"
                "var frame = iframePlayers[j];"
                "var src = String(frame.src || '').toLowerCase();"
                "if (!src) { continue; }"
                "safe(function(){"
                    "if (src.indexOf('youtube.com') !== -1 || src.indexOf('youtube-nocookie.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({event:'command',func:'pauseVideo',args:''}), '*');"
                    "}"
                "});"
                "safe(function(){"
                    "if (src.indexOf('vimeo.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({method:'pause'}), '*');"
                    "}"
                "});"
            "}"
        "})();";
    [self stringByEvaluatingJavaScriptFromString:pauseScript];
}

- (NSString *)runtimeMediaPreferenceReport {
    if (self.runtimeWebView == nil) {
        return @"Runtime web view unavailable.";
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *objectSelectors = @[
        @{@"label": @"WKWebView", @"selector": @""},
        @{@"label": @"Configuration", @"selector": @"configuration"},
        @{@"label": @"Configuration._preferences", @"selector": @"configuration._preferences"},
        @{@"label": @"Configuration.preferences", @"selector": @"configuration.preferences"},
        @{@"label": @"Configuration.defaultWebpagePreferences", @"selector": @"configuration.defaultWebpagePreferences"},
        @{@"label": @"Configuration.websiteDataStore", @"selector": @"configuration.websiteDataStore"},
        @{@"label": @"WKWebView._configuration", @"selector": @"_configuration"},
        @{@"label": @"WKWebView._page", @"selector": @"_page"},
    ];

    NSMutableDictionary<NSValue *, NSString *> *seenObjects = [NSMutableDictionary dictionary];
    NSMutableString *report = [NSMutableString string];

    for (NSDictionary<NSString *, NSString *> *entry in objectSelectors) {
        NSString *label = entry[@"label"] ?: @"Object";
        NSString *selectorPath = entry[@"selector"] ?: @"";
        id currentObject = self.runtimeWebView;

        if (selectorPath.length > 0) {
            NSArray<NSString *> *components = [selectorPath componentsSeparatedByString:@"."];
            for (NSString *component in components) {
                currentObject = BrowserObjectResultForGetter(currentObject, component);
                if (currentObject == nil) {
                    break;
                }
            }
        }

        if (currentObject == nil) {
            [report appendFormat:@"[%@] unavailable\n\n", label];
            continue;
        }

        NSValue *objectKey = [NSValue valueWithNonretainedObject:currentObject];
        NSString *previousLabel = seenObjects[objectKey];
        if (previousLabel != nil) {
            [report appendFormat:@"[%@] same object as %@ (%@)\n\n", label, previousLabel, NSStringFromClass([currentObject class])];
            continue;
        }
        seenObjects[objectKey] = label;

        NSArray<NSString *> *selectorNames = BrowserFilteredSelectorNamesForClass([currentObject class]);
        NSMutableArray<NSString *> *booleanLines = [NSMutableArray array];
        for (NSString *selectorName in selectorNames) {
            NSString *getterName = nil;
            if ([selectorName hasPrefix:@"set"] && [selectorName hasSuffix:@":"]) {
                getterName = BrowserGetterNameFromSetterName(selectorName);
            } else {
                getterName = selectorName;
            }

            NSString *valueDescription = BrowserBooleanValueDescriptionForObjectAndSelector(currentObject, getterName);
            if (valueDescription != nil) {
                [booleanLines addObject:[NSString stringWithFormat:@"%@ = %@", getterName, valueDescription]];
            }
        }

        [report appendFormat:@"[%@] %@\n", label, NSStringFromClass([currentObject class])];
        if (booleanLines.count > 0) {
            [report appendString:@"Boolean getters:\n"];
            for (NSString *line in booleanLines) {
                [report appendFormat:@"- %@\n", line];
            }
        } else {
            [report appendString:@"Boolean getters:\n- none resolved\n"];
        }

        [report appendString:@"Matching selectors:\n"];
        if (selectorNames.count == 0) {
            [report appendString:@"- none\n\n"];
            continue;
        }

        for (NSString *selectorName in selectorNames) {
            [report appendFormat:@"- %@\n", selectorName];
        }

        if ([label isEqualToString:@"Configuration.preferences"]) {
            NSArray<NSDictionary<NSString *, NSString *> *> *featureEntries = BrowserFeatureEntriesForPreferences(currentObject);
            [report appendString:@"Feature entries:\n"];
            if (featureEntries.count == 0) {
                [report appendString:@"- none\n"];
            } else {
                for (NSDictionary<NSString *, NSString *> *featureEntry in featureEntries) {
                    NSString *featureSource = featureEntry[@"source"] ?: @"features";
                    NSString *featureName = featureEntry[@"name"] ?: @"Unknown";
                    NSString *featureEnabled = featureEntry[@"enabled"] ?: @"unknown";
                    NSString *featureKey = featureEntry[@"key"];
                    if (featureKey.length > 0) {
                        [report appendFormat:@"- [%@] %@ (%@) = %@\n", featureSource, featureName, featureKey, featureEnabled];
                    } else {
                        [report appendFormat:@"- [%@] %@ = %@\n", featureSource, featureName, featureEnabled];
                    }
                }
            }
        }
        [report appendString:@"\n"];
    }

    return BrowserPreviewString(report, 24000);
}

- (void)installYouTubeRequestCaptureHook {
    [self stringByEvaluatingJavaScriptFromString:BrowserYouTubeRequestCaptureScript()];
}

- (void)setUserAgent:(NSString *)userAgent {
    _userAgent = [userAgent copy];
    SEL selector = NSSelectorFromString(@"setCustomUserAgent:");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, _userAgent);
    }
}

- (void)setScalesPageToFit:(BOOL)scalesPageToFit {
    _scalesPageToFit = scalesPageToFit;
    [self applyPageScalingIfNeeded];
}

- (void)applyPageScalingIfNeeded {
    if (self.runtimeWebView == nil) {
        return;
    }

    UIScrollView *scrollView = [self scrollView];
    if (scrollView == nil || CGRectIsEmpty(scrollView.bounds)) {
        return;
    }

    CGFloat zoomValue = 1.0;
    if (self.scalesPageToFit) {
        CGFloat contentWidth = scrollView.contentSize.width;
        CGFloat boundsWidth = CGRectGetWidth(scrollView.bounds);
        if (contentWidth > 1.0 && boundsWidth > 1.0) {
            zoomValue = MIN(1.0, MAX(0.25, boundsWidth / contentWidth));
        }
    }

    SEL pageZoomSelector = NSSelectorFromString(@"setPageZoom:");
    if ([self.runtimeWebView respondsToSelector:pageZoomSelector]) {
        ((void (*)(id, SEL, double))objc_msgSend)(self.runtimeWebView, pageZoomSelector, zoomValue);
        return;
    }

    NSString *script = zoomValue == 1.0
        ? @"document.documentElement.style.zoom=''; document.body.style.zoom='';"
        : [NSString stringWithFormat:@"document.documentElement.style.zoom='%0.4f'; document.body.style.zoom='%0.4f';", zoomValue, zoomValue];
    [self stringByEvaluatingJavaScriptFromString:script];
}

- (void)webView:(id)webView didStartProvisionalNavigation:(id)navigation {
    self.loading = YES;
    if ([self.delegate respondsToSelector:@selector(webViewDidStartLoad:)]) {
        [self.delegate webViewDidStartLoad:self];
    }
}

- (void)webView:(id)webView didCommitNavigation:(id)navigation {
    (void)webView;
    (void)navigation;
    // A new page: forget the streams of the previous one.
    [self.mediaStreams removeAllObjects];
    if ([self.delegate respondsToSelector:@selector(webViewDidCommitNavigation:)]) {
        [self.delegate webViewDidCommitNavigation:self];
    }
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    self.loading = NO;
    self.lastTitle = [self title];
    self.lastRequest = [self request];
    [self installYouTubeRequestCaptureHook];
    [self applyPageScalingIfNeeded];
    if ([self.delegate respondsToSelector:@selector(webViewDidFinishLoad:)]) {
        [self.delegate webViewDidFinishLoad:self];
    }
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    self.loading = NO;
}

- (NSURLRequest *)requestFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return nil;
    }
    SEL requestSelector = NSSelectorFromString(@"request");
    if (![navigationAction respondsToSelector:requestSelector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(navigationAction, requestSelector);
}

- (NSInteger)navigationTypeFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return 0;
    }
    SEL navigationTypeSelector = NSSelectorFromString(@"navigationType");
    if (![navigationAction respondsToSelector:navigationTypeSelector]) {
        return 0;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(navigationAction, navigationTypeSelector);
}

- (void)webView:(id)webView decidePolicyForNavigationAction:(id)navigationAction decisionHandler:(void (^)(NSInteger policy))decisionHandler {
    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];
    BOOL isMainFrameRequest = YES;

    SEL targetFrameSelector = NSSelectorFromString(@"targetFrame");
    if ([navigationAction respondsToSelector:targetFrameSelector]) {
        id targetFrame = ((id (*)(id, SEL))objc_msgSend)(navigationAction, targetFrameSelector);
        SEL mainFrameSelector = NSSelectorFromString(@"isMainFrame");
        if (targetFrame != nil && [targetFrame respondsToSelector:mainFrameSelector]) {
            isMainFrameRequest = ((BOOL (*)(id, SEL))objc_msgSend)(targetFrame, mainFrameSelector);
        }
    }

    BOOL shouldAllow = YES;
    if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
        shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
    }

    if (shouldAllow && isMainFrameRequest && request != nil) {
        self.lastRequest = request;
    }

    if (decisionHandler != nil) {
        decisionHandler(shouldAllow ? 1 : 0);
    }
}

- (id)webView:(id)webView
createWebViewWithConfiguration:(id)configuration
forNavigationAction:(id)navigationAction
windowFeatures:(id)windowFeatures {
    (void)webView;
    (void)configuration;
    (void)windowFeatures;

    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];

    BOOL delegateHandlesNewTabRequests = [self.delegate respondsToSelector:@selector(webView:shouldCreateNewTabWithRequest:navigationType:)];
    BOOL handledInTab = NO;
    if (delegateHandlesNewTabRequests) {
        handledInTab = [self.delegate webView:self shouldCreateNewTabWithRequest:request navigationType:navigationType];
    }

    if (!delegateHandlesNewTabRequests && !handledInTab && request != nil) {
        BOOL shouldAllow = YES;
        if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
            shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
        }
        if (shouldAllow) {
            [self loadRequest:request];
        }
    }

    return nil;
}

+ (id)defaultWebsiteDataStore {
    BrowserEnsureWebKitRuntimeLoaded();
    Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
    SEL selector = NSSelectorFromString(@"defaultDataStore");
    if (dataStoreClass == Nil || ![dataStoreClass respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, selector);
}

+ (id)defaultCookieStore {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"httpCookieStore");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(dataStore, selector);
}

+ (NSArray<NSHTTPCookie *> *)allCookies {
    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"getAllCookies:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        return NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies ?: @[];
    }

    __block NSArray<NSHTTPCookie *> *cookies = nil;
    __block BOOL finished = NO;
    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, selector, ^(NSArray<NSHTTPCookie *> *fetchedCookies) {
        cookies = fetchedCookies;
        finished = YES;
    });
    BrowserPumpRunLoopUntil(&finished);
    return cookies ?: @[];
}

+ (NSData *)cookieDataRepresentation {
    NSArray<NSHTTPCookie *> *cookies = [self allCookies];
    NSError *error = nil;
    NSData *cookieData = [NSKeyedArchiver archivedDataWithRootObject:cookies requiringSecureCoding:NO error:&error];
    return error == nil ? cookieData : nil;
}

+ (void)restoreCookiesFromData:(NSData *)cookieData {
    if (cookieData.length == 0) {
        return;
    }

    NSError *error = nil;
    NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [NSHTTPCookie class], nil];
    NSArray<NSHTTPCookie *> *cookies = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses fromData:cookieData error:&error];
    if (![cookies isKindOfClass:[NSArray class]]) {
        return;
    }

    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"setCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        for (NSHTTPCookie *cookie in cookies) {
            [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];
        }
        return;
    }

    // Hand the cookies to WebKit without waiting for each one to be confirmed: waiting here held up
    // every app launch. WebKit applies them in order, ahead of the first page request.
    for (NSHTTPCookie *cookie in cookies) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, selector, cookie, ^{});
    }
}

+ (NSSet<NSString *> *)allWebsiteDataTypes {
    Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
    SEL selector = NSSelectorFromString(@"allWebsiteDataTypes");
    if (dataStoreClass == Nil || ![dataStoreClass respondsToSelector:selector]) {
        return [NSSet set];
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, selector);
}

+ (void)removeWebsiteDataTypes:(NSSet<NSString *> *)websiteDataTypes completion:(void (^)(void))completion {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        if (completion != nil) {
            completion();
        }
        return;
    }

    NSDate *beginningOfTime = [NSDate dateWithTimeIntervalSince1970:0];
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(dataStore, selector, websiteDataTypes, beginningOfTime, ^{
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

+ (void)clearCachedDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    NSMutableSet<NSString *> *websiteDataTypes = [[self allWebsiteDataTypes] mutableCopy];
    for (NSString *dataType in websiteDataTypes.allObjects) {
        if ([dataType.lowercaseString containsString:@"cookie"]) {
            [websiteDataTypes removeObject:dataType];
        }
    }

    [self removeWebsiteDataTypes:websiteDataTypes completion:completion];
}

+ (void)clearCookiesWithCompletion:(void (^)(void))completion {
    id cookieStore = [self defaultCookieStore];
    SEL getAllCookiesSelector = NSSelectorFromString(@"getAllCookies:");
    SEL deleteCookieSelector = NSSelectorFromString(@"deleteCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:getAllCookiesSelector] || ![cookieStore respondsToSelector:deleteCookieSelector]) {
        NSHTTPCookieStorage *storage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
        for (NSHTTPCookie *cookie in storage.cookies) {
            [storage deleteCookie:cookie];
        }
        if (completion != nil) {
            completion();
        }
        return;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, getAllCookiesSelector, ^(NSArray<NSHTTPCookie *> *cookies) {
        if (cookies.count == 0) {
            if (completion != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
            return;
        }

        __block NSInteger remainingCount = cookies.count;
        for (NSHTTPCookie *cookie in cookies) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, deleteCookieSelector, cookie, ^{
                remainingCount -= 1;
                if (remainingCount == 0 && completion != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion();
                    });
                }
            });
        }
    });
}

+ (void)resetWebsiteDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    [self removeWebsiteDataTypes:[self allWebsiteDataTypes] completion:completion];
}

@end
