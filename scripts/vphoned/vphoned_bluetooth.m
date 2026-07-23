#import "vphoned_bluetooth.h"
#import "vphoned_protocol.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <dlfcn.h>

@interface VPBluetoothProbe : NSObject <CBCentralManagerDelegate>
@property(nonatomic, strong) CBCentralManager *central;
@property(nonatomic) dispatch_semaphore_t semaphore;
@property(nonatomic) NSInteger delegateState;
@end

@implementation VPBluetoothProbe

- (instancetype)init {
  self = [super init];
  if (self) {
    _delegateState = -1;
    _semaphore = dispatch_semaphore_create(0);
  }
  return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  self.delegateState = central.state;
  dispatch_semaphore_signal(self.semaphore);
}

@end

static NSString *cb_state_name(NSInteger state) {
  switch (state) {
  case CBManagerStateUnknown:
    return @"unknown";
  case CBManagerStateResetting:
    return @"resetting";
  case CBManagerStateUnsupported:
    return @"unsupported";
  case CBManagerStateUnauthorized:
    return @"unauthorized";
  case CBManagerStatePoweredOff:
    return @"poweredOff";
  case CBManagerStatePoweredOn:
    return @"poweredOn";
  default:
    return [NSString stringWithFormat:@"unknown(%ld)", (long)state];
  }
}

static NSString *cb_auth_name(NSInteger authorization) {
  switch (authorization) {
  case CBManagerAuthorizationNotDetermined:
    return @"notDetermined";
  case CBManagerAuthorizationRestricted:
    return @"restricted";
  case CBManagerAuthorizationDenied:
    return @"denied";
  case CBManagerAuthorizationAllowedAlways:
    return @"allowedAlways";
  default:
    return [NSString stringWithFormat:@"unknown(%ld)", (long)authorization];
  }
}

static id invoke_no_arg(id target, SEL selector) {
  if (!target || ![target respondsToSelector:selector])
    return nil;

  NSMethodSignature *sig = [target methodSignatureForSelector:selector];
  if (!sig || sig.numberOfArguments != 2)
    return nil;

  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  [inv setTarget:target];
  [inv setSelector:selector];
  [inv invoke];

  const char *ret = sig.methodReturnType;
  if (strcmp(ret, @encode(void)) == 0)
    return @"void";
  if (ret[0] == '@') {
    __unsafe_unretained id obj = nil;
    [inv getReturnValue:&obj];
    return obj ?: [NSNull null];
  }
  if (strcmp(ret, @encode(BOOL)) == 0) {
    BOOL value = NO;
    [inv getReturnValue:&value];
    return @(value);
  }
  if (strcmp(ret, @encode(int)) == 0) {
    int value = 0;
    [inv getReturnValue:&value];
    return @(value);
  }
  if (strcmp(ret, @encode(long)) == 0) {
    long value = 0;
    [inv getReturnValue:&value];
    return @(value);
  }
  if (strcmp(ret, @encode(long long)) == 0) {
    long long value = 0;
    [inv getReturnValue:&value];
    return @(value);
  }
  if (strcmp(ret, @encode(float)) == 0) {
    float value = 0;
    [inv getReturnValue:&value];
    return @(value);
  }
  if (strcmp(ret, @encode(double)) == 0) {
    double value = 0;
    [inv getReturnValue:&value];
    return @(value);
  }

  return [NSString stringWithFormat:@"unsupported return type: %s", ret];
}

static NSDictionary *query_corebluetooth(void) {
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  result[@"authorization"] = @([CBManager authorization]);
  result[@"authorization_name"] = cb_auth_name([CBManager authorization]);

  VPBluetoothProbe *probe = [[VPBluetoothProbe alloc] init];
  dispatch_queue_t queue =
      dispatch_queue_create("vphoned.bluetooth.probe", DISPATCH_QUEUE_SERIAL);
  probe.central = [[CBCentralManager alloc]
      initWithDelegate:probe
                 queue:queue
               options:@{CBCentralManagerOptionShowPowerAlertKey : @NO}];

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC));
  dispatch_semaphore_wait(probe.semaphore, deadline);

  NSInteger state = probe.central.state;
  result[@"state"] = @(state);
  result[@"state_name"] = cb_state_name(state);
  result[@"delegate_state"] = @(probe.delegateState);
  if (probe.delegateState >= 0)
    result[@"delegate_state_name"] = cb_state_name(probe.delegateState);
  else
    result[@"delegate_state_name"] = @"notReported";
  return result;
}

static NSDictionary *query_bluetooth_manager(void) {
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  void *handle = dlopen(
      "/System/Library/PrivateFrameworks/BluetoothManager.framework/"
      "BluetoothManager",
      RTLD_NOW);
  result[@"framework_loaded"] = @(handle != NULL);
  if (!handle) {
    const char *err = dlerror();
    result[@"error"] = err ? [NSString stringWithUTF8String:err] : @"dlopen failed";
    return result;
  }

  Class cls = NSClassFromString(@"BluetoothManager");
  result[@"class_found"] = @(cls != Nil);
  if (!cls)
    return result;

  id manager = invoke_no_arg(cls, @selector(currentInstance));
  if (!manager || manager == [NSNull null])
    manager = invoke_no_arg(cls, @selector(sharedInstance));
  if (!manager || manager == [NSNull null])
    manager = invoke_no_arg(cls, @selector(defaultManager));

  result[@"instance_found"] = @(manager && manager != [NSNull null]);
  if (!manager || manager == [NSNull null])
    return result;

  NSArray<NSString *> *selectors = @[
    @"available", @"enabled", @"powered", @"isPowered", @"powerState",
    @"state"
  ];
  for (NSString *name in selectors) {
    id value = invoke_no_arg(manager, NSSelectorFromString(name));
    if (value)
      result[name] = value;
  }
  return result;
}

NSDictionary *vp_handle_bluetooth_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  if (![type isEqualToString:@"bluetooth_status"]) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"unknown Bluetooth command: %@", type];
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"bluetooth_status", reqId);
  r[@"ok"] = @YES;
  r[@"corebluetooth"] = query_corebluetooth();
  r[@"bluetooth_manager"] = query_bluetooth_manager();
  return r;
}
