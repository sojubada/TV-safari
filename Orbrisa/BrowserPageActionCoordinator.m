#import "BrowserPageActionCoordinator.h"
#import "BrowserLocalization.h"
#import "BrowserLog.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserWebView.h"

static UIColor *BrowserPageActionTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

@interface BrowserPageActionCoordinator ()

@property (nonatomic, weak) id<BrowserPageActionCoordinatorHost> host;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
/// YES while a click is replayed after the "Vollbild / Auf der Seite" choice, so the choice isn't asked again.
@property (nonatomic) BOOL bypassVideoChoice;
/// When the video question was answered: the same press must not also click the page (e.g. YouTube's double-click = full screen).
@property (nonatomic) CFTimeInterval videoChoiceAnsweredAt;

@end

@implementation BrowserPageActionCoordinator

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
    videoPlaybackCoordinator:(BrowserVideoPlaybackCoordinator *)videoPlaybackCoordinator {
    self = [super init];
    if (self) {
        _host = host;
        _domInteractionService = domInteractionService;
        _navigationService = navigationService;
        _videoPlaybackCoordinator = videoPlaybackCoordinator;
    }
    return self;
}

- (NSString *)hoverStateAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    return [self.domInteractionService evaluateHoverStateJavaScriptAtPoint:point webView:webView];
}

- (BOOL)handleTargetBlankLinkAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    NSDictionary *linkInfo = [self.domInteractionService linkInfoAtDOMPoint:point webView:webView];
    NSString *href = [linkInfo[@"href"] isKindOfClass:[NSString class]] ? linkInfo[@"href"] : @"";
    NSString *target = [linkInfo[@"target"] isKindOfClass:[NSString class]] ? linkInfo[@"target"] : @"";

    if (href.length == 0 || ![target isEqualToString:@"_blank"]) {
        return NO;
    }

    NSURLRequest *request = [self.navigationService requestForURLString:href];
    if (request == nil) {
        return NO;
    }

    return [self.host browserPageActionCoordinatorCreateNewTabWithRequest:request];
}

- (void)presentEditableFieldPromptForFieldType:(NSString *)fieldType
                                         point:(CGPoint)point
                                       webView:(BrowserWebView *)webView {
    NSString *fieldTitle = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                         webView:webView
                                                                                            body:@"var target = browserEditableTarget();"
                                                                                                 "if (!target) { return ''; }"
                                                                                                 "return target.title || target.getAttribute('aria-label') || target.name || target.placeholder || '';"];
    if ([fieldTitle isEqualToString:@""]) {
        fieldTitle = fieldType;
    }
    NSString *placeholder = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                          webView:webView
                                                                                             body:@"var target = browserEditableTarget();"
                                                                                                  "if (!target) { return ''; }"
                                                                                                  "return target.placeholder || target.getAttribute('aria-label') || '';"];
    if ([placeholder isEqualToString:@""]) {
        placeholder = [fieldTitle isEqualToString:fieldType] ? BrowserLocalized(@"Text Input") : [NSString stringWithFormat:BrowserLocalized(@"%@ Input"), fieldTitle];
    }
    // Go straight to the Apple TV keyboard, without the "Input Text" window in between.
    if ([self presentDirectKeyboardForFieldType:fieldType point:point webView:webView placeholder:placeholder]) {
        return;
    }

    NSString *testedFormResponse = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                                 webView:webView
                                                                                                    body:@"var target = browserEditableTarget();"
                                                                                                         "return (target && target.form && target.form.hasAttribute('onsubmit')) ? 'true' : 'false';"];
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Input Text")
                                                                             message:[fieldTitle capitalizedString]
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alertController;
    BOOL multiLine = [fieldType isEqualToString:@"textarea"];
    BOOL isPassword = [fieldType isEqualToString:@"password"];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        if ([fieldType isEqualToString:@"url"]) {
            textField.keyboardType = UIKeyboardTypeURL;
        } else if ([fieldType isEqualToString:@"email"]) {
            textField.keyboardType = UIKeyboardTypeEmailAddress;
        } else if ([fieldType isEqualToString:@"tel"] ||
                   [fieldType isEqualToString:@"number"] ||
                   [fieldType isEqualToString:@"date"] ||
                   [fieldType isEqualToString:@"datetime"] ||
                   [fieldType isEqualToString:@"datetime-local"]) {
            textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        } else {
            textField.keyboardType = UIKeyboardTypeDefault;
        }
        textField.placeholder = [placeholder capitalizedString];
        if ([fieldType isEqualToString:@"password"]) {
            textField.secureTextEntry = YES;
        }
        textField.text = [weakSelf.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                           webView:webView
                                                                                              body:@"var target = browserEditableTarget();"
                                                                                                   "if (!target) { return ''; }"
                                                                                                   "if (typeof target.value !== 'undefined') { return target.value; }"
                                                                                                   "return target.textContent || '';"];
        textField.textColor = BrowserPageActionTextColor();
        if (multiLine || isPassword) {
            [textField setReturnKeyType:UIReturnKeyDone];
            return;
        }
        // The keyboard's main key reads "Search": it fills the page's field and sends it right away,
        // like pressing Enter in a search box on a computer.
        [textField setReturnKeyType:UIReturnKeySearch];
        [textField addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            UIAlertController *alert = weakAlert;
            NSString *text = alert.textFields.firstObject.text ?: @"";
            if (alert == nil || text.length == 0) {
                return;
            }
            [alert dismissViewControllerAnimated:YES completion:^{
                [weakSelf fillAndSendEditableElementAtPoint:point webView:webView text:text];
            }];
        }] forControlEvents:UIControlEventEditingDidEndOnExit];
    }];

    UIAlertAction *submitAction = [UIAlertAction actionWithTitle:BrowserLocalized(@"Submit")
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(__unused UIAlertAction *action) {
        UITextField *inputTextField = alertController.textFields.firstObject;
        NSString *escapedText = [weakSelf.domInteractionService javaScriptEscapedString:inputTextField.text];
        [weakSelf.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                         webView:webView
                                                                            body:[NSString stringWithFormat:@"var target = browserEditableTarget();"
                                                                                  "if (!target) { return 'false'; }"
                                                                                  "if (typeof target.value !== 'undefined') { target.value = '%@'; }"
                                                                                  "else { target.textContent = '%@'; }"
                                                                                  "if (target.dispatchEvent) {"
                                                                                      "target.dispatchEvent(new Event('input', { bubbles: true }));"
                                                                                      "target.dispatchEvent(new Event('change', { bubbles: true }));"
                                                                                  "}"
                                                                                  "if (target.form) { target.form.submit(); }"
                                                                                  "return 'true';", escapedText, escapedText]];
    }];
    UIAlertAction *doneAction = [UIAlertAction actionWithTitle:BrowserLocalized(@"Done")
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *action) {
        UITextField *inputTextField = alertController.textFields.firstObject;
        NSString *escapedText = [weakSelf.domInteractionService javaScriptEscapedString:inputTextField.text];
        [weakSelf.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                         webView:webView
                                                                            body:[NSString stringWithFormat:@"var target = browserEditableTarget();"
                                                                                  "if (!target) { return 'false'; }"
                                                                                  "if (typeof target.value !== 'undefined') { target.value = '%@'; }"
                                                                                  "else { target.textContent = '%@'; }"
                                                                                  "if (target.dispatchEvent) {"
                                                                                      "target.dispatchEvent(new Event('input', { bubbles: true }));"
                                                                                      "target.dispatchEvent(new Event('change', { bubbles: true }));"
                                                                                  "}"
                                                                                  "return 'true';", escapedText, escapedText]];
    }];
    [alertController addAction:doneAction];
    if ([testedFormResponse isEqualToString:@"true"]) {
        [alertController addAction:submitAction];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPageActionCoordinatorPresentViewController:alertController];

    UITextField *inputTextField = alertController.textFields.firstObject;
    if ([[inputTextField.text stringByReplacingOccurrencesOfString:@" " withString:@""] isEqualToString:@""]) {
        [inputTextField becomeFirstResponder];
    }
}

- (BOOL)presentDirectKeyboardForFieldType:(NSString *)fieldType
                                    point:(CGPoint)point
                                  webView:(BrowserWebView *)webView
                              placeholder:(NSString *)placeholder {
    UIView *hostView = webView.superview;
    if (hostView == nil || webView.window == nil) {
        return NO;
    }

    BOOL multiLine = [fieldType isEqualToString:@"textarea"];
    BOOL isPassword = [fieldType isEqualToString:@"password"];

    // An almost invisible text field: becoming first responder brings up the full-screen tvOS keyboard.
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0.0, 0.0, 2.0, 2.0)];
    textField.alpha = 0.02;
    textField.placeholder = placeholder.length > 0 ? [placeholder capitalizedString] : nil;
    textField.secureTextEntry = isPassword;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    if ([fieldType isEqualToString:@"url"]) {
        textField.keyboardType = UIKeyboardTypeURL;
    } else if ([fieldType isEqualToString:@"email"]) {
        textField.keyboardType = UIKeyboardTypeEmailAddress;
    } else if ([fieldType isEqualToString:@"tel"] || [fieldType isEqualToString:@"number"]) {
        textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    } else {
        textField.keyboardType = UIKeyboardTypeDefault;
    }
    textField.returnKeyType = (multiLine || isPassword) ? UIReturnKeyDone : UIReturnKeySearch;
    textField.text = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point
                                                                                   webView:webView
                                                                                      body:@"var target = browserEditableTarget();"
                                                                                           "if (!target) { return ''; }"
                                                                                           "if (typeof target.value !== 'undefined') { return target.value; }"
                                                                                           "return target.textContent || '';"];

    __weak typeof(self) weakSelf = self;
    __weak UITextField *weakField = textField;
    __block BOOL sent = NO;
    // "Search" key: fill the page's field and send it right away.
    [textField addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        UITextField *field = weakField;
        if (field == nil || sent) {
            return;
        }
        sent = YES;
        NSString *text = field.text ?: @"";
        [field removeFromSuperview];
        if (multiLine || isPassword) {
            [weakSelf fillEditableElementAtPoint:point webView:webView text:text];
        } else {
            [weakSelf fillAndSendEditableElementAtPoint:point webView:webView text:text];
        }
    }] forControlEvents:UIControlEventEditingDidEndOnExit];
    // Leaving the keyboard with the Menu button: keep what was typed, but don't send it.
    [textField addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        UITextField *field = weakField;
        if (field == nil || sent) {
            return;
        }
        sent = YES;
        NSString *text = field.text ?: @"";
        [field removeFromSuperview];
        [weakSelf fillEditableElementAtPoint:point webView:webView text:text];
    }] forControlEvents:UIControlEventEditingDidEnd];

    [hostView addSubview:textField];
    if (![textField becomeFirstResponder]) {
        [textField removeFromSuperview];
        return NO;
    }
    return YES;
}

- (void)fillEditableElementAtPoint:(CGPoint)point webView:(BrowserWebView *)webView text:(NSString *)text {
    NSString *escapedText = [self.domInteractionService javaScriptEscapedString:text];
    NSString *body = [NSString stringWithFormat:@"var target = browserEditableTarget();"
                      "if (!target) { return 'false'; }"
                      "if (typeof target.value !== 'undefined') { target.value = '%@'; }"
                      "else { target.textContent = '%@'; }"
                      "target.dispatchEvent(new Event('input', { bubbles: true }));"
                      "target.dispatchEvent(new Event('change', { bubbles: true }));"
                      "return 'true';", escapedText, escapedText];
    [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point webView:webView body:body];
}

- (void)fillAndSendEditableElementAtPoint:(CGPoint)point webView:(BrowserWebView *)webView text:(NSString *)text {
    NSString *escapedText = [self.domInteractionService javaScriptEscapedString:text];
    NSString *body = [NSString stringWithFormat:@"var target = browserEditableTarget();"
                      "if (!target) { return 'false'; }"
                      "if (target.focus) { target.focus(); }"
                      "if (typeof target.value !== 'undefined') { target.value = '%@'; }"
                      "else { target.textContent = '%@'; }"
                      "target.dispatchEvent(new Event('input', { bubbles: true }));"
                      "target.dispatchEvent(new Event('change', { bubbles: true }));"
                      "var keyInit = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };"
                      "var notHandled = target.dispatchEvent(new KeyboardEvent('keydown', keyInit));"
                      "target.dispatchEvent(new KeyboardEvent('keypress', keyInit));"
                      "target.dispatchEvent(new KeyboardEvent('keyup', keyInit));"
                      "if (notHandled && target.form) {"
                          "if (typeof target.form.requestSubmit === 'function') { target.form.requestSubmit(); }"
                          "else { target.form.submit(); }"
                      "}"
                      "return 'true';", escapedText, escapedText];
    [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point webView:webView body:body];
}

#pragma mark - Video: full screen or on the page

- (NSString *)enterVideoFullscreenInWebView:(BrowserWebView *)webView {
    // Main page first; players inside embedded frames get the same request through a message
    // (the page script in every frame listens for it).
    return [webView stringByEvaluatingJavaScriptFromString:
            @"(function(){"
             "function tellFrames(){ try { for (var i = 0; i < window.frames.length; i++) { try { window.frames[i].postMessage('__browserEnterFullscreen', '*'); } catch (e) {} } } catch (e) {} }"
             "window.__browserWantFullscreen = Date.now();"
             "try { for (var f = 0; f < window.frames.length; f++) { try { window.frames[f].postMessage('__browserWantFullscreen', '*'); } catch (e) {} } } catch (e) {}"
             "var isAd = window.__browserIsAdVideo || function(){ return false; };"
             "var videos = Array.prototype.slice.call(document.querySelectorAll('video'));"
             "var adPlaying = videos.some(function(v){ return !v.paused && !v.ended && isAd(v); });"
             "if (adPlaying) { return 'loading'; }"   // wait until the advert is over; the page script skips it
             "videos = videos.filter(function(v){ return !isAd(v); });"
             "var video = null;"
             "for (var i = 0; i < videos.length; i++) { if (!videos[i].paused && !videos[i].ended) { video = videos[i]; break; } }"
             "if (!video) {"
             "  var bestArea = 0;"
             "  videos.forEach(function(v){ var r = v.getBoundingClientRect(); var a = Math.max(0, r.width) * Math.max(0, r.height); if (a > bestArea) { bestArea = a; video = v; } });"
             "}"
             "if (!video || video.getBoundingClientRect().width < 50) { tellFrames(); return 'frames'; }"
             "if (video.webkitDisplayingFullscreen || document.fullscreenElement || document.webkitFullscreenElement) { return 'fullscreen'; }"
             "if (video.paused && !video.__browserPlayTried) { video.__browserPlayTried = true; try { var p = video.play(); if (p && p.catch) { p.catch(function(){}); } } catch (e) {} }"
             "if (video.readyState < 1) { return 'loading'; }"
             "try {"
             "  if (video.webkitEnterFullscreen) { video.webkitEnterFullscreen(); return 'requested'; }"
             "  if (video.requestFullscreen) { video.requestFullscreen(); return 'requested'; }"
             "  if (video.webkitRequestFullscreen) { video.webkitRequestFullscreen(); return 'requested'; }"
             "} catch (error) { return 'error'; }"
             "return 'unsupported';"
             "})()"] ?: @"";
}

/// Keeps trying for a while (the video may still be loading) until it is really full screen; never again once it was,
/// so leaving full screen is not undone. If the page's video refuses, the page's stream goes to the Apple TV player instead.
- (void)continueFullscreenAttempt:(NSUInteger)attempt requests:(NSUInteger)requests webView:(BrowserWebView *)webView {
    // Long enough to sit out a pre-roll advert (the page script skips or fast-forwards it).
    NSArray<NSNumber *> *delays = @[@0.4, @0.8, @1.0, @1.0, @1.2, @1.5, @1.5, @2.0, @2.0, @2.0, @2.5, @2.5, @3.0, @3.0, @3.0];
    if (attempt >= delays.count) {
        [self fullscreenFailedInWebView:webView];
        return;
    }
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[attempt].doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BrowserWebView *webViewNow = weakWebView;
        if (webViewNow == nil || webViewNow.window == nil) {
            return;
        }
        if (webViewNow.window.rootViewController.presentedViewController != nil) {
            return; // something opened on top (e.g. the full-screen player itself)
        }
        NSString *result = [weakSelf enterVideoFullscreenInWebView:webViewNow];
        BrowserLog(@"[VideoChoice] fullscreen attempt %lu: %@", (unsigned long)attempt, result);
        if ([result isEqualToString:@"fullscreen"]) {
            return;
        }
        NSUInteger newRequests = requests + (([result isEqualToString:@"requested"] || [result isEqualToString:@"frames"]) ? 1 : 0);
        if (newRequests >= 4) {
            // Asked several times without success: the page doesn't allow it.
            [weakSelf fullscreenFailedInWebView:webViewNow];
            return;
        }
        [weakSelf continueFullscreenAttempt:attempt + 1 requests:newRequests webView:webViewNow];
    });
}

- (void)fullscreenFailedInWebView:(BrowserWebView *)webView {
    // Already full screen somewhere (a player opened on top, or the video's own full-screen window took over).
    if (webView.window == nil || !webView.window.isKeyWindow || webView.window.rootViewController.presentedViewController != nil) {
        return;
    }
    NSString *state = [webView stringByEvaluatingJavaScriptFromString:
                       @"(function(){ var v = document.querySelector('video'); return (v && (v.webkitDisplayingFullscreen || document.fullscreenElement)) ? 'fullscreen' : 'no'; })()"];
    if ([state isEqualToString:@"fullscreen"]) {
        return;
    }
    BrowserLog(@"[VideoChoice] page video did not go full screen, trying the Apple TV player");
    NSString *time = [webView stringByEvaluatingJavaScriptFromString:
                      @"(function(){ var t = 0; document.querySelectorAll('video').forEach(function(v){ if (v.currentTime > t) { t = v.currentTime; } }); return String(t); })()"];
    if ([self.videoPlaybackCoordinator hasCapturedStream]) {
        [self presentStreamPickerStartingAt:time.doubleValue];
    }
}

/// Before a click: remember which videos are already playing, so only a video that starts because of this click is asked about.
- (void)rememberPlayingVideosInWebView:(BrowserWebView *)webView {
    [webView stringByEvaluatingJavaScriptFromString:
     @"(function(){ document.querySelectorAll('video').forEach(function(v){"
      "v.__browserPlayingBefore = (!v.paused && !v.ended) ? (v.currentSrc || v.src || 'playing') : '';"
      "}); return 'ok'; })()"];
}

/// After a click: is there now a big video playing that wasn't playing before (and wasn't asked about yet)?
- (BOOL)newlyPlayingVideoInWebView:(BrowserWebView *)webView {
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:
                        @"(function(){"
                         "var found = 'no';"
                         "document.querySelectorAll('video').forEach(function(v){"
                         "  if (found === 'yes' || v.paused || v.ended) { return; }"
                         "  if (window.__browserIsAdVideo && window.__browserIsAdVideo(v)) { return; }"   // adverts are not asked about
                         "  var src = v.currentSrc || v.src || 'playing';"
                         "  if (v.__browserPlayingBefore === src || v.__browserAskedFor === src) { return; }"
                         "  var r = v.getBoundingClientRect();"
                         "  if (r.width < window.innerWidth * 0.4) { return; }"   // small hover previews don't count
                         "  if (v.webkitDisplayingFullscreen) { return; }"
                         "  v.__browserAskedFor = src; found = 'yes';"
                         "});"
                         "return found; })()"];
    return [result isEqualToString:@"yes"];
}

- (void)watchForVideoStartInWebView:(BrowserWebView *)webView {
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    __block BOOL asked = NO;
    // Keeps looking a while longer, so the real video after a pre-roll advert is still asked about.
    for (NSNumber *delay in @[@0.8, @1.6, @2.6, @4.0, @6.0, @8.0, @10.0, @13.0, @16.0, @20.0, @25.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BrowserWebView *webViewNow = weakWebView;
            if (asked || webViewNow == nil || webViewNow.window == nil) {
                return;
            }
            if (webViewNow.window.rootViewController.presentedViewController != nil) {
                return;
            }
            if ([weakSelf newlyPlayingVideoInWebView:webViewNow]) {
                asked = YES;
                [weakSelf presentVideoChoiceForWebView:webViewNow];
            }
        });
    }
}

/// Several videos found (the real one, adverts, previews …): the viewer picks; the most likely one is first.
- (void)presentStreamPickerStartingAt:(NSTimeInterval)startTime {
    NSArray<NSDictionary<NSString *, NSString *> *> *choices = [self.videoPlaybackCoordinator capturedStreamChoices];
    if (choices.count <= 1) {
        [self.videoPlaybackCoordinator playCapturedStreamAtTime:startTime];
        return;
    }
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Which Video?")
                                                                    message:BrowserLocalized(@"The page loaded several videos. The most likely one is at the top.")
                                                             preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    NSUInteger shown = 0;
    for (NSDictionary<NSString *, NSString *> *stream in choices) {
        if (shown >= 6) {
            break;
        }
        shown += 1;
        NSString *title = [NSString stringWithFormat:@"%lu. %@", (unsigned long)shown, [self.videoPlaybackCoordinator labelForCapturedStream:stream]];
        [picker addAction:[UIAlertAction actionWithTitle:title
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(__unused UIAlertAction *action) {
            weakSelf.videoChoiceAnsweredAt = CACurrentMediaTime();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf.videoPlaybackCoordinator playCapturedStream:stream atTime:startTime];
            });
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Cancel")
                                               style:UIAlertActionStyleCancel
                                             handler:^(__unused UIAlertAction *action) {
        weakSelf.videoChoiceAnsweredAt = CACurrentMediaTime();
    }]];
    [self.host browserPageActionCoordinatorPresentViewController:picker];
}

/// Asked once, as soon as the video runs: switch to full screen, or keep watching on the page.
- (void)presentVideoChoiceForWebView:(BrowserWebView *)webView {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BrowserLocalized(@"Video Playing")
                                                                             message:BrowserLocalized(@"How would you like to watch it?")
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Full Screen")
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        weakSelf.videoChoiceAnsweredAt = CACurrentMediaTime();
        BrowserWebView *webViewNow = weakWebView;
        if (webViewNow == nil) {
            return;
        }
        // The page's player told us the real stream: play that in the Apple TV player – reliable, no advert, no page player in between.
        NSDictionary<NSString *, NSString *> *pageStream = [webViewNow pageConfigMediaStream];
        if (pageStream == nil) {
            // No list from the player's configuration: take the address the page's own video plays (e.g. beeg),
            // then the best stream the page loaded. WebKit's own full screen doesn't work on the Apple TV.
            NSString *ownSource = [webViewNow stringByEvaluatingJavaScriptFromString:
                                   @"(function(){ var isAd = window.__browserIsAdVideo || function(){ return false; }; var best = null, area = 0;"
                                    "document.querySelectorAll('video').forEach(function(v){ if (isAd(v)) { return; } var s = v.currentSrc || v.src || ''; if (!/^https?:/i.test(s)) { return; } var d = v.duration; if (isFinite(d) && d > 0 && d <= 65) { return; } var r = v.getBoundingClientRect(); var a = r.width * r.height + (v.paused ? 0 : 1e9); if (a > area) { area = a; best = s; } });"
                                    "return best || ''; })()"];
            if (ownSource.length > 0) {
                BOOL isPlaylist = [ownSource.lowercaseString containsString:@"m3u8"];
                pageStream = @{@"url": ownSource,
                               @"type": isPlaylist ? @"hls" : @"file",
                               @"source": @"media",
                               @"page": webViewNow.request.URL.absoluteString ?: @""};
            } else {
                NSDictionary<NSString *, NSString *> *best = [webViewNow bestCapturedMediaStream];
                if ([best[@"type"] isEqualToString:@"hls"]) {
                    pageStream = best;
                }
            }
        }
        if (pageStream != nil) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BrowserWebView *webViewLater = weakWebView;
                NSString *time = [webViewLater stringByEvaluatingJavaScriptFromString:
                                  @"(function(){ var t = 0; var isAd = window.__browserIsAdVideo || function(){ return false; }; document.querySelectorAll('video').forEach(function(v){ if (!isAd(v) && v.currentTime > t) { t = v.currentTime; } }); return String(t); })()"];
                BrowserLog(@"[VideoChoice] full screen with the page's own stream %@", pageStream[@"url"]);
                [weakSelf.videoPlaybackCoordinator playCapturedStream:pageStream atTime:time.doubleValue];
            });
            return;
        }
        // Otherwise the page's video goes full screen, a moment later, outside the remote press, so the page really gets the command.
        [weakSelf continueFullscreenAttempt:0 requests:0 webView:webViewNow];
    }]];
    if ([self.videoPlaybackCoordinator hasCapturedStream]) {
        // The page's own stream in the real Apple TV player (own controls, smoother playback).
        [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Choose Video …")
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.videoChoiceAnsweredAt = CACurrentMediaTime();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BrowserWebView *webViewNow = weakWebView;
                if (webViewNow == nil) {
                    return;
                }
                NSString *time = [webViewNow stringByEvaluatingJavaScriptFromString:
                                  @"(function(){ var t = 0; document.querySelectorAll('video').forEach(function(v){ if (!v.paused && v.currentTime > t) { t = v.currentTime; } }); return String(t); })()"];
                [weakSelf presentStreamPickerStartingAt:time.doubleValue];
            });
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:BrowserLocalized(@"Stay on Page")
                                                        style:UIAlertActionStyleCancel
                                                      handler:^(__unused UIAlertAction *action) {
        weakSelf.videoChoiceAnsweredAt = CACurrentMediaTime();
    }]];
    [self.host browserPageActionCoordinatorPresentViewController:alertController];
}

- (BOOL)handlePageSelectionAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    if (CACurrentMediaTime() - self.videoChoiceAnsweredAt < 1.0) {
        return YES;
    }
    if (!self.bypassVideoChoice) {
        // No question before the click any more: if this click starts a video, it is asked once while it plays.
        [self rememberPlayingVideosInWebView:webView];
        [self watchForVideoStartInWebView:webView];
    }
    if (!self.bypassVideoChoice && [self.videoPlaybackCoordinator handleSelectPressForVideoAtCursor]) {
        return YES;
    }
    if ([self handleTargetBlankLinkAtDOMPoint:point webView:webView]) {
        return YES;
    }

    NSString *fieldType = [self.domInteractionService evaluateResolvedElementJavaScriptAtPoint:point
                                                                                        webView:webView
                                                                                           body:@"function browserEditableTargetAtPoint() {"
                                                                                                "var candidate = editableElement;"
                                                                                                "if (!candidate && resolvedElement && resolvedElement.matches) {"
                                                                                                    "if (resolvedElement.matches(editableSelector) || resolvedElement.matches('textarea, select')) {"
                                                                                                        "candidate = resolvedElement;"
                                                                                                    "}"
                                                                                                "}"
                                                                                                "if (!candidate) { return null; }"
                                                                                                "window.__browserLastEditableElement = candidate;"
                                                                                                "return candidate;"
                                                                                                "}"
                                                                                                "var target = browserEditableTargetAtPoint();"
                                                                                                "if (!target) { return ''; }"
                                                                                                "var tagName = target.tagName ? target.tagName.toLowerCase() : '';"
                                                                                                "var type = (target.type || '').toLowerCase();"
                                                                                                "if (tagName === 'textarea' || target.isContentEditable) { return 'text'; }"
                                                                                                "if (tagName === 'input' && !type) { return 'text'; }"
                                                                                                "return type;"];
    [self.domInteractionService evaluateResolvedElementJavaScriptAtPoint:point
                                                                 webView:webView
                                                                    body:@"var target = editableElement || interactiveElement || resolvedElement;"
                                                                         "if (!target) { return 'false'; }"
                                                                         "try { if (target.focus) { target.focus(); } } catch (error) {}"
                                                                         "function dispatchPointerLikeEvent(type, constructorName) {"
                                                                             "try {"
                                                                                 "var Constructor = window[constructorName];"
                                                                                 "if (Constructor) {"
                                                                                     "var event = new Constructor(type, { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: 1, pointerType: 'mouse' });"
                                                                                     "return target.dispatchEvent(event);"
                                                                                 "}"
                                                                             "} catch (error) {}"
                                                                             "var mouseEvent = document.createEvent('MouseEvents');"
                                                                             "mouseEvent.initMouseEvent(type, true, true, window, 1, x, y, x, y, false, false, false, false, 0, null);"
                                                                             "return target.dispatchEvent(mouseEvent);"
                                                                         "}"
                                                                         "dispatchPointerLikeEvent('pointerdown', 'PointerEvent');"
                                                                         "dispatchPointerLikeEvent('mousedown', 'MouseEvent');"
                                                                         "dispatchPointerLikeEvent('pointerup', 'PointerEvent');"
                                                                         "dispatchPointerLikeEvent('mouseup', 'MouseEvent');"
                                                                         "if (typeof target.click === 'function') { target.click(); }"
                                                                         "else { dispatchPointerLikeEvent('click', 'MouseEvent'); }"
                                                                         "return 'true';"];
    fieldType = fieldType.lowercaseString;
    if ([fieldType isEqualToString:@"date"] ||
        [fieldType isEqualToString:@"datetime"] ||
        [fieldType isEqualToString:@"datetime-local"] ||
        [fieldType isEqualToString:@"email"] ||
        [fieldType isEqualToString:@"month"] ||
        [fieldType isEqualToString:@"number"] ||
        [fieldType isEqualToString:@"password"] ||
        [fieldType isEqualToString:@"search"] ||
        [fieldType isEqualToString:@"tel"] ||
        [fieldType isEqualToString:@"text"] ||
        [fieldType isEqualToString:@"time"] ||
        [fieldType isEqualToString:@"url"] ||
        [fieldType isEqualToString:@"week"]) {
        [self presentEditableFieldPromptForFieldType:fieldType point:point webView:webView];
    }
    return YES;
}

@end
