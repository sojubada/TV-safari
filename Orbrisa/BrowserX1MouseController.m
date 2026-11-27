#import "BrowserX1MouseController.h"
#import "BrowserDiagnosticsLog.h"
#import <CoreBluetooth/CoreBluetooth.h>

// Profile as the relay firmware publishes it (rd4tvos firmware/x1bridge/main/x1_profile.h) and as
// Moonlight / X1Kit (fizzyade/X1Kit, MIT) read it.
static NSString * const kX1ServiceUUID = @"2B080000-BDB5-F6EB-24AE-9D6AB282AB63";
static NSString * const kX1ProtocolModeUUID = @"2A4E";
static NSString * const kX1ReportUUID = @"2A4D";
static NSString * const kX1ReportReferenceUUID = @"2908";
static NSString * const kX1EnabledKey = @"BrowserX1MouseEnabled";
static NSString * const kX1SpeedKey = @"BrowserX1MouseSpeed";
static const NSTimeInterval kX1RescanDelay = 2.0;
static const NSTimeInterval kX1StatsInterval = 30.0;

typedef NS_ENUM(NSInteger, BrowserX1ReportKind) {
    BrowserX1ReportKindUnknown = 0,
    BrowserX1ReportKindButtons = 1,  // report id 1
    BrowserX1ReportKindXY = 2,       // report id 2
};

static NSString *BrowserX1Hex(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < MIN(data.length, (NSUInteger)16); i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

static NSString *BrowserX1StateName(CBManagerState state) {
    switch (state) {
        case CBManagerStatePoweredOn: return @"poweredOn";
        case CBManagerStatePoweredOff: return @"poweredOff";
        case CBManagerStateUnauthorized: return @"unauthorized";
        case CBManagerStateUnsupported: return @"unsupported";
        case CBManagerStateResetting: return @"resetting";
        case CBManagerStateUnknown: return @"unknown";
    }
    return @"?";
}

/// 12-bit two's complement.
static NSInteger BrowserX1Signed12(NSUInteger value) {
    value &= 0x0FFF;
    return (value & 0x0800) ? (NSInteger)value - 0x1000 : (NSInteger)value;
}

@interface BrowserX1MouseController () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong, nullable) CBCentralManager *central;
@property (nonatomic, strong, nullable) CBPeripheral *peripheral;
@property (nonatomic, strong) NSMapTable<CBCharacteristic *, NSNumber *> *reportKinds;
@property (nonatomic, readwrite, getter=isConnected) BOOL connected;
@property (nonatomic) BOOL running;
@property (nonatomic, copy) NSString *trace;
@property (nonatomic) BrowserX1MouseButtons buttons;
@property (nonatomic) NSUInteger reportCountXY;
@property (nonatomic) NSUInteger reportCountButtons;
@property (nonatomic) NSUInteger clicks;
@property (nonatomic) NSInteger travelX;
@property (nonatomic) NSInteger travelY;
@property (nonatomic) BOOL loggedFirstXY;
@property (nonatomic) BOOL loggedFirstButtons;
@property (nonatomic, nullable) NSTimer *statsTimer;
@end

@implementation BrowserX1MouseController

+ (BOOL)isEnabledInSettings {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kX1EnabledKey];
    return value == nil ? YES : [value boolValue];
}

+ (CGFloat)speed {
    double speed = [NSUserDefaults.standardUserDefaults doubleForKey:kX1SpeedKey];
    if (speed <= 0.0) {
        return 1.0;
    }
    return (CGFloat)MIN(MAX(speed, 0.2), 5.0);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reportKinds = [NSMapTable strongToStrongObjectsMapTable];
        _trace = @"-";
    }
    return self;
}

- (void)dealloc {
    [_statsTimer invalidate];
}

#pragma mark - Start / stop

- (void)start {
    if (self.running) {
        return;
    }
    if (![BrowserX1MouseController isEnabledInSettings]) {
        BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 off", nil, @"BrowserX1MouseEnabled = NO; Bluetooth not used");
        return;
    }
    if (NSBundle.mainBundle.infoDictionary[@"NSBluetoothAlwaysUsageDescription"] == nil) {
        // Without this key the system kills the app on first CoreBluetooth use.
        BrowserDiagWarn(BrowserDiagCategoryInput, @"x1 not started", nil, @"NSBluetoothAlwaysUsageDescription missing in Info.plist");
        return;
    }
    self.running = YES;
    self.trace = BrowserDiagBeginTrace(@"mouse");
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 start", self.trace,
                    [NSString stringWithFormat:@"service=%@ speed=%.2f", kX1ServiceUUID, [BrowserX1MouseController speed]]);
    self.central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:@{
        CBCentralManagerOptionShowPowerAlertKey: @NO,
    }];
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:kX1StatsInterval target:self selector:@selector(logStats) userInfo:nil repeats:YES];
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    [self.statsTimer invalidate];
    self.statsTimer = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(scan) object:nil];
    if (self.central.state == CBManagerStatePoweredOn) {
        [self.central stopScan];
        if (self.peripheral != nil) {
            [self.central cancelPeripheralConnection:self.peripheral];
        }
    }
    [self releaseAllButtons];
    self.peripheral = nil;
    self.central.delegate = nil;
    self.central = nil;
    self.connected = NO;
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 stop", self.trace, nil);
}

- (void)logStats {
    if (self.reportCountXY == 0 && self.reportCountButtons == 0 && !self.connected) {
        return;
    }
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 stats", self.trace,
                    [NSString stringWithFormat:@"connected=%@ xyReports=%lu buttonReports=%lu clicks=%lu travel=(%ld,%ld) counts",
                     self.connected ? @"yes" : @"no", (unsigned long)self.reportCountXY, (unsigned long)self.reportCountButtons,
                     (unsigned long)self.clicks, (long)self.travelX, (long)self.travelY]);
}

#pragma mark - Scanning and connecting

- (void)scan {
    if (!self.running || self.central.state != CBManagerStatePoweredOn || self.peripheral != nil) {
        return;
    }
    CBUUID *service = [CBUUID UUIDWithString:kX1ServiceUUID];
    // A relay still connected from an earlier launch does not advertise; take it back directly.
    NSArray<CBPeripheral *> *already = [self.central retrieveConnectedPeripheralsWithServices:@[service]];
    if (already.count > 0) {
        BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 reuse", self.trace,
                        [NSString stringWithFormat:@"already connected: %@", already.firstObject.name ?: @"?"]);
        [self connectTo:already.firstObject];
        return;
    }
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 scan", self.trace, @"looking for the X1 service");
    [self.central scanForPeripheralsWithServices:@[service] options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
}

- (void)scheduleRescan {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(scan) object:nil];
    [self performSelector:@selector(scan) withObject:nil afterDelay:kX1RescanDelay];
}

- (void)connectTo:(CBPeripheral *)peripheral {
    self.peripheral = peripheral;
    peripheral.delegate = self;
    [self.reportKinds removeAllObjects];
    [self.central connectPeripheral:peripheral options:nil];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 bluetooth", self.trace, BrowserX1StateName(central.state));
    if (central.state == CBManagerStatePoweredOn) {
        [self scan];
        return;
    }
    if (central.state == CBManagerStateUnauthorized) {
        BrowserDiagWarn(BrowserDiagCategoryInput, @"x1 bluetooth denied", self.trace, @"Bluetooth permission refused for this app");
    }
    [self releaseAllButtons];
    self.peripheral = nil;
    [self setConnectedState:NO name:nil];
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *, id> *)advertisementData RSSI:(NSNumber *)RSSI {
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 found", self.trace,
                    [NSString stringWithFormat:@"name=%@ rssi=%@ id=%@", peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey] ?: @"?",
                     RSSI, [peripheral.identifier.UUIDString substringToIndex:8]]);
    [central stopScan];
    [self connectTo:peripheral];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 connected", self.trace, peripheral.name ?: @"?");
    [peripheral discoverServices:@[[CBUUID UUIDWithString:kX1ServiceUUID]]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    BrowserDiagError(BrowserDiagCategoryInput, @"x1 connect failed", self.trace, error, peripheral.name);
    self.peripheral = nil;
    [self scheduleRescan];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (error != nil) {
        BrowserDiagError(BrowserDiagCategoryInput, @"x1 disconnected", self.trace, error, peripheral.name);
    } else {
        BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 disconnected", self.trace, peripheral.name ?: @"?");
    }
    [self releaseAllButtons];
    self.peripheral = nil;
    [self setConnectedState:NO name:peripheral.name];
    [self scheduleRescan];
}

#pragma mark - GATT setup

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error != nil) {
        BrowserDiagError(BrowserDiagCategoryInput, @"x1 services", self.trace, error, nil);
        return;
    }
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:kX1ServiceUUID]]) {
            [peripheral discoverCharacteristics:nil forService:service];
            return;
        }
    }
    BrowserDiagWarn(BrowserDiagCategoryInput, @"x1 services", self.trace,
                    [NSString stringWithFormat:@"X1 service missing; found %lu service(s)", (unsigned long)peripheral.services.count]);
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error != nil) {
        BrowserDiagError(BrowserDiagCategoryInput, @"x1 characteristics", self.trace, error, nil);
        return;
    }
    NSUInteger reportIndex = 0;
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:kX1ProtocolModeUUID]]) {
            // Boot protocol, as X1Kit asks for it.
            uint8_t mode = 0x00;
            CBCharacteristicWriteType type = (characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse)
                ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
            [peripheral writeValue:[NSData dataWithBytes:&mode length:1] forCharacteristic:characteristic type:type];
        } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:kX1ReportUUID]]) {
            // Firmware order is XY first, buttons second; the 0x2908 descriptor, when read, overrides this guess.
            [self.reportKinds setObject:@(reportIndex == 0 ? BrowserX1ReportKindXY : BrowserX1ReportKindButtons) forKey:characteristic];
            reportIndex++;
            [peripheral discoverDescriptorsForCharacteristic:characteristic];
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
    }
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 characteristics", self.trace,
                    [NSString stringWithFormat:@"total=%lu reports=%lu", (unsigned long)service.characteristics.count, (unsigned long)reportIndex]);
    if (reportIndex == 0) {
        BrowserDiagWarn(BrowserDiagCategoryInput, @"x1 characteristics", self.trace, @"no 0x2A4D report characteristic");
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error != nil) {
        BrowserDiagError(BrowserDiagCategoryInput, @"x1 descriptors", self.trace, error, nil);
        return;
    }
    for (CBDescriptor *descriptor in characteristic.descriptors) {
        if ([descriptor.UUID isEqual:[CBUUID UUIDWithString:kX1ReportReferenceUUID]]) {
            [peripheral readValueForDescriptor:descriptor];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForDescriptor:(CBDescriptor *)descriptor error:(NSError *)error {
    if (error != nil) {
        BrowserDiagError(BrowserDiagCategoryInput, @"x1 report reference", self.trace, error, nil);
        return;
    }
    NSData *value = [descriptor.value isKindOfClass:[NSData class]] ? descriptor.value : nil;
    if (value.length < 1) {
        BrowserDiagWarn(BrowserDiagCategoryInput, @"x1 report reference", self.trace, @"empty 0x2908 value; keeping order guess");
        return;
    }
    uint8_t reportID = ((const uint8_t *)value.bytes)[0];
    BrowserX1ReportKind kind = reportID == 2 ? BrowserX1ReportKindXY : (reportID == 1 ? BrowserX1ReportKindButtons : BrowserX1ReportKindUnknown);
    [self.reportKinds setObject:@(kind) forKey:descriptor.characteristic];
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 report reference", self.trace,
                    [NSString stringWithFormat:@"raw=%@ id=%u kind=%@", BrowserX1Hex(value), reportID,
                     kind == BrowserX1ReportKindXY ? @"xy" : (kind == BrowserX1ReportKindButtons ? @"buttons" : @"unknown")]);
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error != nil) {
        BrowserDiagError(BrowserDiagCategoryInput, @"x1 subscribe", self.trace, error, nil);
        return;
    }
    BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 subscribe", self.trace,
                    [NSString stringWithFormat:@"notifying=%@ kind=%@", characteristic.isNotifying ? @"yes" : @"no",
                     [self.reportKinds objectForKey:characteristic] ?: @0]);
    if (characteristic.isNotifying && !self.connected) {
        [self setConnectedState:YES name:peripheral.name];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error != nil) {
        BrowserDiagError(BrowserDiagCategoryInput, @"x1 protocol mode", self.trace, error, nil);
    } else {
        BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 protocol mode", self.trace, @"boot (0x00) written");
    }
}

#pragma mark - Reports

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error != nil) {
        BrowserDiagError(BrowserDiagCategoryInput, @"x1 report", self.trace, error, nil);
        return;
    }
    NSData *data = characteristic.value;
    const uint8_t *b = data.bytes;
    BrowserX1ReportKind kind = (BrowserX1ReportKind)[[self.reportKinds objectForKey:characteristic] integerValue];

    if (kind == BrowserX1ReportKindXY && data.length >= 3) {
        self.reportCountXY++;
        if (!self.loggedFirstXY) {
            self.loggedFirstXY = YES;
            BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 first xy", self.trace, [NSString stringWithFormat:@"raw=%@", BrowserX1Hex(data)]);
        }
        [self handleDeltaX:BrowserX1Signed12(b[0] | ((NSUInteger)(b[1] & 0x0F) << 8))
                    deltaY:BrowserX1Signed12((b[1] >> 4) | ((NSUInteger)b[2] << 4))];
        return;
    }

    if (kind == BrowserX1ReportKindButtons && data.length >= 2) {
        self.reportCountButtons++;
        if (!self.loggedFirstButtons) {
            self.loggedFirstButtons = YES;
            BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 first buttons", self.trace, [NSString stringWithFormat:@"raw=%@ len=%lu", BrowserX1Hex(data), (unsigned long)data.length]);
        }
        NSInteger wheel = 0;
        if (data.length >= 5) {
            // Newer firmware: buttons, XY in b1..b3, wheel in b4.
            [self handleDeltaX:BrowserX1Signed12(b[1] | ((NSUInteger)(b[2] & 0x0F) << 8))
                        deltaY:BrowserX1Signed12((b[2] >> 4) | ((NSUInteger)b[3] << 4))];
            wheel = (int8_t)b[4];
        } else {
            wheel = (int8_t)b[1];
        }
        [self handleButtons:(BrowserX1MouseButtons)(b[0] & 0x07)];
        if (wheel != 0) {
            [self.delegate x1Mouse:self didScrollWheel:wheel];
        }
        return;
    }

    BrowserDiagWarn(BrowserDiagCategoryInput, @"x1 report ignored", self.trace,
                    [NSString stringWithFormat:@"kind=%ld len=%lu raw=%@", (long)kind, (unsigned long)data.length, BrowserX1Hex(data)]);
}

- (void)handleDeltaX:(NSInteger)dx deltaY:(NSInteger)dy {
    if (dx == 0 && dy == 0) {
        return;
    }
    self.travelX += labs(dx);
    self.travelY += labs(dy);
    CGFloat speed = [BrowserX1MouseController speed];
    [self.delegate x1Mouse:self didMoveByDelta:CGPointMake(dx * speed, dy * speed)];
}

- (void)handleButtons:(BrowserX1MouseButtons)buttons {
    BrowserX1MouseButtons changed = buttons ^ self.buttons;
    self.buttons = buttons;
    for (BrowserX1MouseButtons button = BrowserX1MouseButtonLeft; button <= BrowserX1MouseButtonMiddle; button <<= 1) {
        if (changed & button) {
            BOOL pressed = (buttons & button) != 0;
            if (!pressed) {
                self.clicks++;
            }
            BrowserDiagInfo(BrowserDiagCategoryInput, @"x1 button", self.trace,
                            [NSString stringWithFormat:@"%@ %@", button == BrowserX1MouseButtonLeft ? @"left" : (button == BrowserX1MouseButtonRight ? @"right" : @"middle"),
                             pressed ? @"down" : @"up"]);
            [self.delegate x1Mouse:self button:button pressed:pressed];
        }
    }
}

/// A button held when the link drops would otherwise stay down for ever.
- (void)releaseAllButtons {
    if (self.buttons != 0) {
        [self handleButtons:0];
    }
}

- (void)setConnectedState:(BOOL)connected name:(NSString *)name {
    if (self.connected == connected) {
        return;
    }
    self.connected = connected;
    if ([self.delegate respondsToSelector:@selector(x1Mouse:connectionDidChange:name:)]) {
        [self.delegate x1Mouse:self connectionDidChange:connected name:name];
    }
}

@end
