#import "BrowserHardwareKeyboardController.h"

#import <dlfcn.h>
#import <objc/message.h>

#import "BrowserHangulComposer.h"

// USB HID usage ids, which are exactly the values GCKeyCode carries.
static const NSInteger kKeyCodeA = 0x04;
static const NSInteger kKeyCodeZ = 0x1D;
static const NSInteger kKeyCodeOne = 0x1E;
static const NSInteger kKeyCodeZero = 0x27;
static const NSInteger kKeyCodeReturn = 0x28;
static const NSInteger kKeyCodeEscape = 0x29;
static const NSInteger kKeyCodeDeleteBackward = 0x2A;
static const NSInteger kKeyCodeTab = 0x2B;
static const NSInteger kKeyCodeSpacebar = 0x2C;
static const NSInteger kKeyCodeKeypadEnter = 0x58;
static const NSInteger kKeyCodeLang1 = 0x90;
static const NSInteger kKeyCodeLeftShift = 0xE1;
static const NSInteger kKeyCodeRightShift = 0xE5;
static const NSInteger kKeyCodeLeftControl = 0xE0;
static const NSInteger kKeyCodeRightControl = 0xE4;
static const NSInteger kKeyCodeRightAlt = 0xE6;

static NSString *const kGameControllerPath =
    @"/System/Library/Frameworks/GameController.framework/GameController";

// The punctuation keys, in key-code order from 0x2D, unshifted then shifted.
static NSString *const kPunctuationUnshifted = @"-=[]\\#;'`,./";
static NSString *const kPunctuationShifted = @"_+{}|~:\"~<>?";

@interface BrowserHardwareKeyboardController ()
@property (nonatomic, readwrite, getter=isCapturing) BOOL capturing;
@property (nonatomic, readwrite, getter=isKoreanInputActive) BOOL koreanInputActive;
@property (nonatomic) BrowserHangulComposer *composer;
@property (nonatomic, copy) NSString *settledText;
@property (nonatomic, nullable) id keyboardInput;
// Set the first time UIKit hands over a real key. Some systems report a
// keyboard through the Game Controller framework and some only through the
// press chain, and this is how the app finds out which it has without
// guessing: once a key has arrived that way, direct typing is on.
@property (nonatomic) BOOL sawUIKitKeyEvent;
@end

@implementation BrowserHardwareKeyboardController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _composer = [[BrowserHangulComposer alloc] init];
        _settledText = @"";
    }
    return self;
}

- (void)dealloc {
    [self clearKeyChangedHandler];
}

#pragma mark - Game Controller

+ (void)loadGameControllerFrameworkIfNeeded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(@"GCKeyboard") == Nil) {
            dlopen(kGameControllerPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        }
    });
}

// The connected keyboard, or nil. Looked up each time rather than cached: a
// keyboard can be paired or go to sleep between one field and the next.
- (nullable id)currentKeyboardInput {
    [[self class] loadGameControllerFrameworkIfNeeded];
    Class keyboardClass = NSClassFromString(@"GCKeyboard");
    if (keyboardClass == Nil || ![keyboardClass respondsToSelector:@selector(coalesced)]) {
        return nil;
    }
    id keyboard = ((id (*)(id, SEL))objc_msgSend)((id)keyboardClass, @selector(coalesced));
    if (keyboard == nil || ![keyboard respondsToSelector:@selector(keyboardInput)]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(keyboard, @selector(keyboardInput));
}

- (BOOL)isKeyboardConnected {
    return self.sawUIKitKeyEvent || [self currentKeyboardInput] != nil;
}

- (void)prepareForKeyboardDetection {
    [[self class] loadGameControllerFrameworkIfNeeded];
    (void)[self currentKeyboardInput];
}

- (NSString *)detectionSummary {
    [[self class] loadGameControllerFrameworkIfNeeded];
    if (self.sawUIKitKeyEvent) {
        return @"키보드: UIKit";
    }
    Class keyboardClass = NSClassFromString(@"GCKeyboard");
    if (keyboardClass == Nil) {
        return @"키보드: GC 없음";
    }
    if (![keyboardClass respondsToSelector:@selector(coalesced)]) {
        return @"키보드: GC 구형";
    }
    id keyboard = ((id (*)(id, SEL))objc_msgSend)((id)keyboardClass, @selector(coalesced));
    if (keyboard == nil) {
        return @"키보드: 미연결";
    }
    if (![keyboard respondsToSelector:@selector(keyboardInput)]) {
        return @"키보드: 입력 없음";
    }
    id input = ((id (*)(id, SEL))objc_msgSend)(keyboard, @selector(keyboardInput));
    if (input == nil) {
        return @"키보드: 프로필 없음";
    }
    if (![input respondsToSelector:@selector(setKeyChangedHandler:)]) {
        return @"키보드: 수신 불가";
    }
    return @"키보드: GC 연결됨";
}

- (BOOL)isKeyCodePressed:(NSInteger)keyCode onInput:(id)keyboardInput {
    if (keyboardInput == nil || ![keyboardInput respondsToSelector:@selector(buttonForKeyCode:)]) {
        return NO;
    }
    id button = ((id (*)(id, SEL, NSInteger))objc_msgSend)(keyboardInput,
                                                           @selector(buttonForKeyCode:),
                                                           keyCode);
    if (button == nil || ![button respondsToSelector:@selector(isPressed)]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(button, @selector(isPressed));
}

- (void)clearKeyChangedHandler {
    id keyboardInput = self.keyboardInput;
    self.keyboardInput = nil;
    if (keyboardInput == nil || ![keyboardInput respondsToSelector:@selector(setKeyChangedHandler:)]) {
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(keyboardInput, @selector(setKeyChangedHandler:), nil);
}

#pragma mark - Capture

- (BOOL)beginCaptureWithExistingText:(NSString *)text {
    id keyboardInput = [self currentKeyboardInput];
    if (keyboardInput != nil && ![keyboardInput respondsToSelector:@selector(setKeyChangedHandler:)]) {
        keyboardInput = nil;
    }
    // With no Game Controller keyboard, typing can still go through the press
    // chain — but only once a key has actually arrived that way. Starting
    // without either would leave the field with no way to type into it at all.
    if (keyboardInput == nil && !self.sawUIKitKeyEvent) {
        return NO;
    }

    [self clearKeyChangedHandler];
    [self.composer reset];
    self.settledText = text.length > 0 ? text : @"";
    self.keyboardInput = keyboardInput;
    self.capturing = YES;
    if (keyboardInput == nil) {
        return YES;
    }

    __weak typeof(self) weakSelf = self;
    void (^handler)(id, id, NSInteger, BOOL) = ^(id input, id button, NSInteger keyCode, BOOL pressed) {
        (void)button;
        if (!pressed) {
            return;
        }
        // The handler arrives on the Game Controller queue, and everything it
        // leads to touches the web view.
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleKeyCode:keyCode onInput:input];
        });
    };
    ((void (*)(id, SEL, id))objc_msgSend)(keyboardInput, @selector(setKeyChangedHandler:), handler);
    return YES;
}

- (void)endCapture {
    if (!self.capturing) {
        return;
    }
    self.capturing = NO;
    [self clearKeyChangedHandler];
    [self.composer reset];
    self.settledText = @"";
}

#pragma mark - Keys

- (NSString *)currentFieldText {
    return [self.settledText stringByAppendingString:self.composer.composingText];
}

- (void)notifyTextChanged {
    [self.delegate hardwareKeyboardController:self didChangeText:[self currentFieldText]];
}

- (void)setKoreanInput:(BOOL)korean {
    if (self.koreanInputActive == korean) {
        return;
    }
    self.settledText = [self.settledText stringByAppendingString:[self.composer flush]];
    self.koreanInputActive = korean;
    [self.delegate hardwareKeyboardController:self didChangeKoreanInput:korean];
    [self notifyTextChanged];
}

- (void)handleKeyCode:(NSInteger)keyCode onInput:(id)keyboardInput {
    if (!self.capturing) {
        return;
    }

    BOOL shift = [self isKeyCodePressed:kKeyCodeLeftShift onInput:keyboardInput] ||
        [self isKeyCodePressed:kKeyCodeRightShift onInput:keyboardInput];
    BOOL control = [self isKeyCodePressed:kKeyCodeLeftControl onInput:keyboardInput] ||
        [self isKeyCodePressed:kKeyCodeRightControl onInput:keyboardInput];

    // Control-space is the switch most people already use for this, and the
    // 한/영 key reports as Lang1 on the keyboards that have one.
    if (keyCode == kKeyCodeLang1 || keyCode == kKeyCodeRightAlt ||
        (control && keyCode == kKeyCodeSpacebar)) {
        [self setKoreanInput:!self.koreanInputActive];
        return;
    }
    if (control) {
        return;
    }

    [self handleResolvedKeyCode:keyCode shift:shift];
}

- (void)handleResolvedKeyCode:(NSInteger)keyCode shift:(BOOL)shift {
    if (keyCode == kKeyCodeReturn || keyCode == kKeyCodeKeypadEnter) {
        self.settledText = [self.settledText stringByAppendingString:[self.composer flush]];
        [self notifyTextChanged];
        [self.delegate hardwareKeyboardControllerDidSubmit:self];
        return;
    }

    if (keyCode == kKeyCodeEscape) {
        [self.delegate hardwareKeyboardControllerDidCancel:self];
        return;
    }

    if (keyCode == kKeyCodeDeleteBackward) {
        if (![self.composer deleteBackward]) {
            if (self.settledText.length > 0) {
                // By composed character, so one press removes one letter the
                // person can see rather than half a syllable.
                NSRange lastRange = [self.settledText
                                     rangeOfComposedCharacterSequenceAtIndex:self.settledText.length - 1];
                self.settledText = [self.settledText stringByReplacingCharactersInRange:lastRange
                                                                             withString:@""];
            }
        }
        [self notifyTextChanged];
        return;
    }

    NSString *character = [self characterForKeyCode:keyCode shift:shift];
    if (character.length == 0) {
        return;
    }

    [self appendTypedCharacter:character];
}

- (void)appendTypedCharacter:(NSString *)character {
    unichar scalar = [character characterAtIndex:0];

    if (self.koreanInputActive) {
        unichar jamo = [BrowserHangulComposer jamoForLatinCharacter:scalar];
        if (jamo != 0) {
            NSString *settled = [self.composer inputJamo:jamo];
            if (settled.length > 0) {
                self.settledText = [self.settledText stringByAppendingString:settled];
            }
            [self notifyTextChanged];
            return;
        }
        // Spaces and punctuation end the syllable in progress.
        self.settledText = [self.settledText stringByAppendingString:[self.composer flush]];
    }

    self.settledText = [self.settledText stringByAppendingString:character];
    [self notifyTextChanged];
}

- (NSString *)characterForKeyCode:(NSInteger)keyCode shift:(BOOL)shift {
    if (keyCode >= kKeyCodeA && keyCode <= kKeyCodeZ) {
        unichar letter = (unichar)((shift ? 'A' : 'a') + (keyCode - kKeyCodeA));
        return [NSString stringWithCharacters:&letter length:1];
    }

    if (keyCode >= kKeyCodeOne && keyCode <= kKeyCodeZero) {
        NSString *unshifted = @"1234567890";
        NSString *shifted = @"!@#$%^&*()";
        NSUInteger index = (NSUInteger)(keyCode - kKeyCodeOne);
        NSString *source = shift ? shifted : unshifted;
        return [source substringWithRange:NSMakeRange(index, 1)];
    }

    if (keyCode == kKeyCodeSpacebar) {
        return @" ";
    }
    if (keyCode == kKeyCodeTab) {
        return @" ";
    }

    if (keyCode >= 0x2D && keyCode <= 0x38) {
        NSUInteger index = (NSUInteger)(keyCode - 0x2D);
        NSString *source = shift ? kPunctuationShifted : kPunctuationUnshifted;
        if (index < source.length) {
            return [source substringWithRange:NSMakeRange(index, 1)];
        }
    }

    return @"";
}

#pragma mark - UIKit route

- (BOOL)handleKeyPress:(UIPress *)press {
    if (![press respondsToSelector:@selector(key)]) {
        return NO;
    }
    UIKey *key = press.key;
    if (key == nil) {
        return NO;
    }
    // Noted whether or not a field is being typed into: this is the app
    // learning that keys reach it this way, so the next field can skip the
    // system text entry screen.
    if (key.charactersIgnoringModifiers.length > 0) {
        self.sawUIKitKeyEvent = YES;
    }
    if (!self.capturing) {
        return NO;
    }
    // When the Game Controller route is live it already reported this key, and
    // taking it twice would double every letter.
    if (self.keyboardInput != nil) {
        return NO;
    }

    NSString *characters = key.charactersIgnoringModifiers;
    BOOL shift = (key.modifierFlags & UIKeyModifierShift) != 0;
    BOOL control = (key.modifierFlags & (UIKeyModifierControl | UIKeyModifierAlternate)) != 0;

    if ([characters isEqualToString:@" "] && control) {
        [self setKoreanInput:!self.koreanInputActive];
        return YES;
    }
    if (control) {
        return NO;
    }

    if ([characters isEqualToString:UIKeyInputEscape]) {
        [self.delegate hardwareKeyboardControllerDidCancel:self];
        return YES;
    }
    if ([characters isEqualToString:@"\r"] || [characters isEqualToString:@"\n"]) {
        self.settledText = [self.settledText stringByAppendingString:[self.composer flush]];
        [self notifyTextChanged];
        [self.delegate hardwareKeyboardControllerDidSubmit:self];
        return YES;
    }
    if ([characters isEqualToString:@"\b"]) {
        [self handleResolvedKeyCode:kKeyCodeDeleteBackward shift:NO];
        return YES;
    }

    if (characters.length != 1) {
        return NO;
    }

    unichar scalar = [characters characterAtIndex:0];
    if (scalar < 0x20 || scalar == 0x7F) {
        return NO;
    }
    if (shift && scalar >= 'a' && scalar <= 'z') {
        scalar = (unichar)(scalar - 'a' + 'A');
        characters = [NSString stringWithCharacters:&scalar length:1];
    } else if (key.characters.length == 1) {
        characters = key.characters;
    }

    [self appendTypedCharacter:characters];
    return YES;
}

@end
