/********* VirtualManagerBLE.m Cordova Plugin Implementation *******/

#import <Cordova/CDV.h>
#import <CoreBluetooth/CoreBluetooth.h>


NSMutableDictionary* getPeripheralInfo(CBPeripheral* peripheral, NSDictionary* advertisementData, NSNumber* rssi)
{
    NSMutableDictionary* info = [[NSMutableDictionary alloc] init];
    
    [info setObject: peripheral.identifier.UUIDString forKey:@"id"];
    if (peripheral.name != nil) {
        [info setObject: peripheral.name forKey: @"name"];
    }
    if (rssi != nil) {
        [info setObject: rssi forKey:@"rssi"];
    }
    if (advertisementData != nil) {
        NSMutableDictionary* advertisementInfo = [[NSMutableDictionary alloc] init];
        
        NSData* data = [advertisementData objectForKey:CBAdvertisementDataManufacturerDataKey];
        if (data != nil) {
            [advertisementInfo setObject: [data base64EncodedStringWithOptions:0] forKey:@"data"];
        }
        
        NSNumber* txPowerLevel = [advertisementData objectForKey:CBAdvertisementDataTxPowerLevelKey];
        if (txPowerLevel != nil) {
            [advertisementInfo setObject: txPowerLevel forKey:@"txPower"];
        }
        
        NSNumber* localName = [advertisementData objectForKey:CBAdvertisementDataLocalNameKey];
        if (localName != nil) {
            [advertisementInfo setObject: localName forKey:@"localName"];
        }
        
        NSNumber* isConnectable = [advertisementData objectForKey:CBAdvertisementDataIsConnectable];
        if (isConnectable != nil) {
            [advertisementInfo setObject: isConnectable forKey:@"connectable"];
        }
        
        NSArray* uuids = [advertisementData objectForKey:CBAdvertisementDataServiceUUIDsKey];
        if (uuids != nil) {
            NSMutableArray* uuidsInfo = [[NSMutableArray alloc] init];
            for(CBUUID* uuid in uuids) {
                [uuidsInfo addObject: uuid.UUIDString];
            }
            [advertisementInfo setObject: uuidsInfo forKey:@"UUIDS"];
        }
        
        NSArray* solicitedUuids = [advertisementData objectForKey:CBAdvertisementDataSolicitedServiceUUIDsKey];
        if (solicitedUuids != nil) {
            NSMutableArray* uuidsInfo = [[NSMutableArray alloc] init];
            for(CBUUID* uuid in solicitedUuids) {
                [uuidsInfo addObject: uuid.UUIDString];
            }
            [advertisementInfo setObject: uuidsInfo forKey:@"solicitedUUIDS"];
        }
        
        NSArray* overflowUuids = [advertisementData objectForKey:CBAdvertisementDataOverflowServiceUUIDsKey];
        if (overflowUuids != nil) {
            NSMutableArray* uuidsInfo = [[NSMutableArray alloc] init];
            for(CBUUID* uuid in overflowUuids) {
                [uuidsInfo addObject: uuid.UUIDString];
            }
            [advertisementInfo setObject: uuidsInfo forKey:@"overflowUUIDS"];
        }
        
        NSDictionary* serviceData = [advertisementData objectForKey:CBAdvertisementDataServiceDataKey];
        if (serviceData != nil) {
            NSMutableDictionary* serviceInfo = [[NSMutableDictionary alloc] init];
            for (CBUUID* uuid in serviceData) {
                NSData* data = [serviceData objectForKey:uuid];
                [serviceInfo setObject: [data base64EncodedStringWithOptions:0] forKey:uuid.UUIDString];
            }
            [advertisementInfo setObject: serviceInfo forKey:@"serviceData"];
        }
        
        [info setObject:advertisementInfo forKey:@"advertisement"];
    }
    
    if (peripheral.services != nil) {
        NSMutableArray* servicesInfo = [[NSMutableArray alloc] init];
        for(CBService* service in peripheral.services) {
            [servicesInfo addObject:service.UUID.UUIDString];
        }
        [info setObject:servicesInfo forKey:@"services"];
    }
    return info;
}

NSString* getCentralManagerStateName(CBCentralManagerState state)
{
    switch(state) {
        case CBCentralManagerStateUnknown:
            return @"Unknown";
            
        case CBCentralManagerStatePoweredOn:
            return @"PoweredOn";
            
        case CBCentralManagerStateResetting:
            return @"Resetting";
            
        case CBCentralManagerStatePoweredOff:
            return @"PoweredOff";
            
        case CBCentralManagerStateUnsupported:
            return @"Unsupported";
            
        case CBCentralManagerStateUnauthorized:
            return @"Unauthorized";
    }
    return @"Invalid State";
}

@interface VMPeripheral : NSObject {
}

-(id)initWithPeripheral:(CBPeripheral*)peripheral;
-(void)dispose;

@property (nonatomic, retain) CBPeripheral* peripheral;
@property (nonatomic, retain) NSString* discoverServicesCallbackId;

@end

@implementation VMPeripheral

@synthesize peripheral, discoverServicesCallbackId;

-(id)initWithPeripheral:(CBPeripheral *)initPeripheral
{
    if ((self = [super init])) {
        self.peripheral = initPeripheral;
    }
    return self;
}

-(void)dispose
{
    self.peripheral = nil;
}
@end


// VMScanClient allows multiple JS clients to call startScanning, we will merge their requests to make it look
// like
@interface VMScanClient : NSObject<CBCentralManagerDelegate, CBPeripheralDelegate> {
    // To make JS bridge more efficient, rather than returning every scan result to JS individually the following
    // 2 fields allow results to be gathered and sent as a group of maximum "groupSize" and waiting no more than
    // "groupTimeout" milliseconds once 1 scan has been gathered before delivering to JS
    NSInteger _groupSize;
    NSTimeInterval _groupTimeout;
    bool _groupTimeoutScheduled;
}

@property (nonatomic, retain) id<CDVCommandDelegate> commandDelegate;
@property (nonatomic, retain) NSMutableDictionary* peripherals;
@property (nonatomic, retain) NSString* scanResultCallbackId;
@property (nonatomic, retain) NSString* stateChangeCallbackId;
@property (nonatomic, retain) CBCentralManager* centralManager;
@property (nonatomic, retain) NSMutableArray* groupedScans;

@end


@implementation VMScanClient

@synthesize peripherals, scanResultCallbackId, stateChangeCallbackId, centralManager;

const int firstParameterOffset = 1;

-(id)initWithCommandDelegate:(id<CDVCommandDelegate>)commandDelegate
{
    NSLog(@"VMScanClient init");
    if ((self = [super init])) {
        self.commandDelegate = commandDelegate;
        self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        self.peripherals = [[NSMutableDictionary alloc] init];
        
        // Default send all results immediately
        self.groupedScans = nil;
        _groupTimeout = 0;
        _groupSize = 1;
        _groupTimeoutScheduled = false;
    }
    return self;
}

-(void)dispose
{
    NSLog(@"dispose");
    self.centralManager = nil;
    self.peripherals = nil;
    self.groupedScans = nil;
}

-(void)subscribeStateChange:(CDVInvokedUrlCommand*) command
{
    self.stateChangeCallbackId = command.callbackId;
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus: CDVCommandStatus_OK messageAsString: getCentralManagerStateName((CBCentralManagerState)centralManager.state)];
    [pluginResult setKeepCallbackAsBool:TRUE];
    [self.commandDelegate sendPluginResult: pluginResult callbackId: stateChangeCallbackId];
}

-(void)unsubscribeStateChange:(CDVInvokedUrlCommand*) command
{
    self.stateChangeCallbackId = nil;
}

-(NSArray*)getUUIDsFromStringArray:(NSArray*)uuidStrArray
{
    NSMutableArray* uuids = nil;
    if (uuidStrArray != nil && ![uuidStrArray isKindOfClass:[NSNull class]]) {
        uuids = [[NSMutableArray alloc] init];
        
        for(NSString* uuidStr in uuidStrArray) {
            CBUUID* uuid = [CBUUID UUIDWithString:uuidStr];
            [uuids addObject: uuid];
        }
    }
    return uuids;
}

-(void)startScanning:(CDVInvokedUrlCommand*) command
{
    NSLog(@"StartScanning %@", command);
    NSMutableDictionary* options = [[NSMutableDictionary alloc] init];
    NSArray* services = nil;
    
    if (command.arguments.count >= firstParameterOffset + 1) {
        services = [self getUUIDsFromStringArray:[command.arguments objectAtIndex: firstParameterOffset + 0]];
    }
    
    if (command.arguments.count >= firstParameterOffset + 2) {
        NSDictionary* optionArg = [command.arguments objectAtIndex: firstParameterOffset + 1];
        NSNumber* allowDuplicate = [optionArg objectForKey:@"allowDuplicate"];
        if (allowDuplicate && [allowDuplicate boolValue]) {
            [options setObject:allowDuplicate forKey:CBCentralManagerScanOptionAllowDuplicatesKey];
        }

        NSNumber* groupTimeout = [optionArg objectForKey:@"groupTimeout"];
        if (groupTimeout) {
            _groupTimeout = [groupTimeout integerValue] / 1000.0;
        }

        // To make JS bridge more efficient - Group scan results to no more than
        NSNumber* groupSize = [optionArg objectForKey:@"groupSize"];
        if (groupSize) {
            _groupSize = [groupSize integerValue];
        }
    }
    
    if (_groupTimeout < 0.0) {
        _groupTimeout = 0.0;
    }
    
    // GroupSize of 0 = ignore groupSize and just use groupTimeout
    if (_groupSize < 0) {
        _groupSize = 0;
    }
    
    [centralManager scanForPeripheralsWithServices:services options:options];
    
    self.scanResultCallbackId = command.callbackId;
    
    // Always callback
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus: CDVCommandStatus_OK messageAsArray: nil];
    [pluginResult setKeepCallbackAsBool:TRUE];
    [self.commandDelegate sendPluginResult: pluginResult callbackId: scanResultCallbackId];
}

-(void)stopScanning:(CDVInvokedUrlCommand*) command
{
    [centralManager stopScan];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus: CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult: pluginResult callbackId: command.callbackId];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    NSLog(@"Central Manager Update State %@", getCentralManagerStateName((CBCentralManagerState)central.state));
    
    if (stateChangeCallbackId != nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus: CDVCommandStatus_OK messageAsString: getCentralManagerStateName((CBCentralManagerState)central.state)];
        [pluginResult setKeepCallbackAsBool:TRUE];
        [self.commandDelegate sendPluginResult: pluginResult callbackId: stateChangeCallbackId];
    }
}

- (void)sendGroupScans
{
    if (_groupedScans != nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus: CDVCommandStatus_OK messageAsArray: _groupedScans];
        [pluginResult setKeepCallbackAsBool:TRUE];
        [self.commandDelegate sendPluginResult: pluginResult callbackId: scanResultCallbackId];
    }
    // release the group now it is sent
    self.groupedScans = nil;
    _groupTimeoutScheduled = false;
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI
{
    //    NSLog(@"Discovered Peripheral %@ - %@", peripheral.identifier.UUIDString, peripheral.name);
    
    VMPeripheral* vmp = [peripherals objectForKey:peripheral.identifier.UUIDString];
    if (vmp == nil) {
        vmp = [[VMPeripheral alloc] initWithPeripheral:peripheral];
    }
    [peripherals setObject:vmp forKey:peripheral.identifier.UUIDString];
    peripheral.delegate = self;
    
    NSMutableDictionary* info = getPeripheralInfo(peripheral, advertisementData, RSSI);
    if (_groupedScans == nil) {
        _groupedScans = [[NSMutableArray alloc] initWithObjects:info, nil];
    } else {
        [_groupedScans addObject:info];
    }

    // Note, groupSize of 0 means we ignore groupSize and send on groupTimeouts only
    if (_groupSize >= 1 && ([_groupedScans count] >= _groupSize)) {
        [self sendGroupScans];
    } else if (!_groupTimeoutScheduled) {
        _groupTimeoutScheduled = true;
        [self performSelector:@selector(sendGroupScans) withObject:nil afterDelay:_groupTimeout];
    } // else a timeout is already scheduled
}

-(void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    //    NSLog(@"Peripheral Discovered Services %@", peripheral.identifier.UUIDString);
    
    VMPeripheral* vmp = [peripherals objectForKey:peripheral.identifier.UUIDString];
    if (vmp != nil) {
        NSMutableDictionary* info = getPeripheralInfo(peripheral, nil, nil);
        
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus: CDVCommandStatus_OK messageAsDictionary: info];
        [pluginResult setKeepCallbackAsBool:TRUE];
        [self.commandDelegate sendPluginResult: pluginResult callbackId: scanResultCallbackId];
    }
}

-(void)peripheral_getServices:(CDVInvokedUrlCommand*) command
{
    CDVPluginResult* pluginResult;
    NSString* peripheralId = nil;
    NSArray* services = nil;
    
    if (command.arguments.count >= firstParameterOffset + 1) {
        peripheralId = [command.arguments objectAtIndex: firstParameterOffset + 0];
    }
    
    if (command.arguments.count >= firstParameterOffset + 2) {
        services = [self getUUIDsFromStringArray:[command.arguments objectAtIndex: firstParameterOffset + 1]];
    }
    
    if (peripheralId == nil) {
        pluginResult = [CDVPluginResult resultWithStatus: CDVCommandStatus_ERROR messageAsString: @"Missing argument 'peripheralId'"];
    } else {
        VMPeripheral* vmp = [peripherals objectForKey:peripheralId];
        if (vmp == nil) {
            pluginResult = [CDVPluginResult resultWithStatus: CDVCommandStatus_ERROR messageAsString: @"Peripheral not found"];
        } else {
            if (vmp.peripheral.services == nil) {
                [vmp.peripheral discoverServices: services];
            }
        }
    }
}

@end



@interface VirtualManagerBLE : CDVPlugin {
}

@property (nonatomic, retain) NSMutableDictionary* clients;

- (void)pluginInitialize;
- (void)dispose;

@end


@implementation VirtualManagerBLE

-(void)pluginInitialize
{
    NSLog(@"pluginInitialize");
    [super pluginInitialize];

    self.clients = [[NSMutableDictionary alloc] init];
}

-(void)dispose
{
    NSLog(@"dispose");
    self.clients = nil;
    [super dispose];
}

-(VMScanClient*)getClientFromCommand:(CDVInvokedUrlCommand*) command
{
    // 1st parameter will be the clientId
    NSString* clientId = nil;
    if (command.arguments.count >= 1) {
        clientId = [command.arguments objectAtIndex:0];
    }

    // Find or create a new client ..
    VMScanClient* client = [_clients objectForKey:clientId];
    if (client == nil) {
        client = [[VMScanClient alloc] initWithCommandDelegate: self.commandDelegate];
        [_clients setObject:client forKey:clientId];
    }
    return client;
}

-(void)clientSubscribeStateChange:(CDVInvokedUrlCommand*) command
{
    VMScanClient* client = [self getClientFromCommand:command];
    [client subscribeStateChange:command];
}

-(void)clientUnsubscribeStateChange:(CDVInvokedUrlCommand*) command
{
    VMScanClient* client = [self getClientFromCommand:command];
    [client unsubscribeStateChange:command];
}

-(void)clientStartScanning:(CDVInvokedUrlCommand*) command
{
    VMScanClient* client = [self getClientFromCommand:command];
    [client startScanning:command];
}

-(void)clientStopScanning:(CDVInvokedUrlCommand*) command
{
    VMScanClient* client = [self getClientFromCommand:command];
    [client stopScanning:command];
}

-(void)clientPeripheral_getServices:(CDVInvokedUrlCommand*) command
{
    VMScanClient* client = [self getClientFromCommand:command];
    [client peripheral_getServices:command];
}

@end

