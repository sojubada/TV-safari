#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserHardwareKeyboardController;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserHardwareKeyboardControllerDelegate <NSObject>

/// The whole text the field should now show, caret text included.
- (void)hardwareKeyboardController:(BrowserHardwareKeyboardController *)controller
                     didChangeText:(NSString *)text;
/// Return was pressed: the text is final and the form should be sent.
- (void)hardwareKeyboardControllerDidSubmit:(BrowserHardwareKeyboardController *)controller;
/// Escape was pressed: typing is over and nothing more should be written.
- (void)hardwareKeyboardControllerDidCancel:(BrowserHardwareKeyboardController *)controller;
/// The language changed, so the caller can say so on screen.
- (void)hardwareKeyboardController:(BrowserHardwareKeyboardController *)controller
             didChangeKoreanInput:(BOOL)koreanInput;

@end

/// Types straight into the page from a Bluetooth keyboard.
///
/// tvOS has no in-place text entry: a text field takes focus and the system
/// throws up its own full-screen keyboard screen, which is what makes typing
/// a URL feel like leaving the page. A hardware keyboard, though, can be read
/// directly through the Game Controller framework, which reports key presses
/// to the app wherever they happen and owes nothing to that screen. The keys
/// are turned into text here and written into the focused element.
///
/// The framework is reached with dlopen, the way WebKit is, so the app links
/// nothing new and a device without it simply reports no keyboard.
@interface BrowserHardwareKeyboardController : NSObject

@property (nonatomic, weak, nullable) id<BrowserHardwareKeyboardControllerDelegate> delegate;

/// Whether a physical keyboard is connected right now. Checked afresh, since
/// one can be paired at any moment.
@property (nonatomic, readonly, getter=isKeyboardConnected) BOOL keyboardConnected;

@property (nonatomic, readonly, getter=isCapturing) BOOL capturing;
@property (nonatomic, readonly, getter=isKoreanInputActive) BOOL koreanInputActive;

/// Starts typing into a field that already holds `text`.
- (BOOL)beginCaptureWithExistingText:(nullable NSString *)text;
- (void)endCapture;

/// The second route in: UIKit delivers hardware keys through the press chain
/// on some systems, and this takes them when it does. Returns YES when the
/// key was used.
- (BOOL)handleKeyPress:(UIPress *)press;

/// Loaded at launch rather than at the first text field, in case the
/// framework has to be in place before a keyboard already paired is seen.
- (void)prepareForKeyboardDetection;

/// One short line naming how far keyboard detection got, shown in the fallback
/// dialog so a device that will not hand over its keyboard says why.
- (NSString *)detectionSummary;

@end

NS_ASSUME_NONNULL_END
