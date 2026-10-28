#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Composes 두벌식 keystrokes into Hangul syllables.
///
/// tvOS gives a hardware keyboard no Korean input method of its own: its
/// Korean keyboard lives inside the system's own full-screen text entry
/// screen, and outside it a Bluetooth keyboard produces nothing but the Latin
/// letters printed on the keys. Typing Korean in place therefore means doing
/// the composition here — collecting 초성/중성/종성 and folding them into a
/// syllable as the keys arrive.
///
/// Nothing here touches the system: it is string arithmetic over the Unicode
/// Hangul block.
@interface BrowserHangulComposer : NSObject

/// The syllable being built right now, which the caller shows at the caret.
/// Empty when nothing is in progress.
@property (nonatomic, readonly, copy) NSString *composingText;

/// Feeds one compatibility jamo (U+3131–U+3163). Returns the text that has
/// settled and should be appended to the field, which is usually empty while
/// a syllable is still growing.
- (NSString *)inputJamo:(unichar)jamo;

/// Takes one jamo back out of the syllable in progress. NO when there was
/// nothing in progress, in which case the caller deletes a character from the
/// settled text instead.
- (BOOL)deleteBackward;

/// Ends composition and returns whatever was still in progress.
- (NSString *)flush;

- (void)reset;

/// Maps a US-layout letter to its 두벌식 jamo, or 0 when the key carries none.
+ (unichar)jamoForLatinCharacter:(unichar)character;

@end

NS_ASSUME_NONNULL_END
