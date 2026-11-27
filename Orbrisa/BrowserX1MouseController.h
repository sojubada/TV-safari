#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Mouse buttons as the X1 button report carries them (bit 0 left, bit 1 right, bit 2 middle).
typedef NS_OPTIONS(uint8_t, BrowserX1MouseButtons) {
    BrowserX1MouseButtonLeft = 1 << 0,
    BrowserX1MouseButtonRight = 1 << 1,
    BrowserX1MouseButtonMiddle = 1 << 2,
};

@class BrowserX1MouseController;

@protocol BrowserX1MouseControllerDelegate <NSObject>
/// Relative movement in screen points (already scaled by the speed setting).
- (void)x1Mouse:(BrowserX1MouseController *)mouse didMoveByDelta:(CGPoint)delta;
/// A button went down (pressed = YES) or came back up (pressed = NO).
- (void)x1Mouse:(BrowserX1MouseController *)mouse button:(BrowserX1MouseButtons)button pressed:(BOOL)pressed;
/// Wheel notches, positive = away from the user (scroll up).
- (void)x1Mouse:(BrowserX1MouseController *)mouse didScrollWheel:(NSInteger)notches;
@optional
- (void)x1Mouse:(BrowserX1MouseController *)mouse connectionDidChange:(BOOL)connected name:(nullable NSString *)name;
@end

/// tvOS has no system mouse. A Bluetooth mouse reaches the app through the ESP32-C3 relay
/// (sojubada/rd4tvos, firmware/x1bridge), which re-sends it as a Citrix X1 mouse:
///   Service 2B080000-BDB5-F6EB-24AE-9D6AB282AB63
///     0x2A4E Protocol Mode  write 0x00
///     0x2A4D Report + 0x2908 {0x02,0x01}  XY: 12-bit signed dx, dy packed in 3 bytes
///     0x2A4D Report + 0x2908 {0x01,0x01}  buttons (b0) + wheel (b1, Int8); 5-byte form: b1..b3 XY, b4 wheel
/// The app is the central (the only role tvOS allows); nothing is paired in tvOS Settings.
/// Every step is written to the diagnostics log (category Input) so a failure can be read without a new build.
@interface BrowserX1MouseController : NSObject

@property (nonatomic, weak, nullable) id<BrowserX1MouseControllerDelegate> delegate;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;

/// NSUserDefaults "BrowserX1MouseEnabled" (default YES). Off: no Bluetooth use at all, so no permission prompt.
+ (BOOL)isEnabledInSettings;
/// NSUserDefaults "BrowserX1MouseSpeed" (default 1.0, 0.2…5.0): points per mouse count.
+ (CGFloat)speed;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
