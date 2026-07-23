/*
 * vphoned_apps — App lifecycle management via private APIs.
 *
 * Uses LSApplicationWorkspace (CoreServices) and FBSSystemService
 * (FrontBoardServices).
 */

#import "vphoned_apps.h"
#import "vphoned_protocol.h"
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <signal.h>
#include <unistd.h>

// MARK: - Private API Declarations

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property(readonly) NSString *bundleIdentifier;
@property(readonly) NSString *localizedName;
@property(readonly) NSString *shortVersionString;
@property(readonly) NSString *applicationType;
@property(readonly) NSURL *bundleURL;
@property(readonly) NSURL *dataContainerURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dictionary;
@end

// FBSSystemService loaded via dlsym
static Class gFBSSystemServiceClass = Nil;

static BOOL gAppsLoaded = NO;

BOOL vp_apps_load(void) {
  // FrontBoardServices
  void *fbs = dlopen("/System/Library/PrivateFrameworks/"
                     "FrontBoardServices.framework/FrontBoardServices",
                     RTLD_LAZY);
  if (fbs) {
    gFBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
    if (!gFBSSystemServiceClass) {
      NSLog(@"vphoned: FBSSystemService class not found");
    }
  } else {
    NSLog(@"vphoned: dlopen FrontBoardServices failed: %s", dlerror());
  }

  // LSApplicationWorkspace is in CoreServices (already linked)
  Class lsClass = NSClassFromString(@"LSApplicationWorkspace");
  if (!lsClass) {
    NSLog(@"vphoned: LSApplicationWorkspace class not found");
    return NO;
  }

  gAppsLoaded = YES;
  NSLog(@"vphoned: apps loaded (FBS=%s)",
        gFBSSystemServiceClass ? "yes" : "no");
  return YES;
}

// MARK: - Helpers

static pid_t pid_for_app(NSString *bundleID) {
  if (!gFBSSystemServiceClass)
    return 0;
  id service = ((id (*)(Class, SEL))objc_msgSend)(
      gFBSSystemServiceClass, sel_registerName("sharedService"));
  if (!service)
    return 0;
  return ((pid_t (*)(id, SEL, id))objc_msgSend)(
      service, sel_registerName("pidForApplication:"), bundleID);
}

static NSString *state_for_pid(pid_t pid) {
  if (pid > 0)
    return @"running";
  return @"not_running";
}

static void terminate_application(NSString *bundleID) {
  if (gFBSSystemServiceClass) {
    id service = ((id (*)(Class, SEL))objc_msgSend)(
        gFBSSystemServiceClass, sel_registerName("sharedService"));
    if (service) {
      ((void (*)(id, SEL, id, int, BOOL, id))objc_msgSend)(
          service,
          sel_registerName(
              "terminateApplication:forReason:andReport:withDescription:"),
          bundleID, 5, NO, @"vphoned dyld-insert relaunch");
    }
  }
  pid_t pid = pid_for_app(bundleID);
  if (pid > 0)
    kill(pid, SIGKILL);
}

/// Wait until FrontBoard no longer reports a live pid for bundleID.
static BOOL wait_until_terminated(NSString *bundleID, int timeoutMs) {
  int waited = 0;
  while (waited < timeoutMs) {
    if (pid_for_app(bundleID) <= 0)
      return YES;
    usleep(100000);
    waited += 100;
  }
  return pid_for_app(bundleID) <= 0;
}

// Launch after LS EnvironmentVariables registration. Tries several open paths;
// records which one succeeded via *methodOut (caller-owned NSString*).
static BOOL open_application_with_environment(NSString *bundleID,
                                              NSDictionary *environment,
                                              NSString **methodOut) {
  NSDictionary *env = environment ?: @{};
  // Multiple keys because option names differ across iOS / FrontBoard revisions.
  NSDictionary *options = @{
    @"__Environment" : env,
    @"Environment" : env,
    @"environment" : env,
    @"EnvironmentVariables" : env,
  };

  LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];

  // 1) Plain LS open — relies on the EnvironmentVariables we just registered.
  //    On regular (get-task-allow forced + dyld policy patched) this is often
  //    enough once the process is truly dead first.
  {
    BOOL ok = [ws openApplicationWithBundleID:bundleID];
    if (ok) {
      if (methodOut)
        *methodOut = @"ls_open";
      return YES;
    }
  }

  // 2) LS open with options dict (if available)
  SEL lsOpenOpts = sel_registerName("openApplicationWithBundleID:options:");
  if ([ws respondsToSelector:lsOpenOpts]) {
    BOOL ok = ((BOOL(*)(id, SEL, id, id))objc_msgSend)(ws, lsOpenOpts,
                                                       bundleID, options);
    if (ok) {
      if (methodOut)
        *methodOut = @"ls_open_options";
      return YES;
    }
  }

  if (!gFBSSystemServiceClass) {
    if (methodOut)
      *methodOut = @"no_fbs";
    return NO;
  }
  id service = ((id (*)(Class, SEL))objc_msgSend)(
      gFBSSystemServiceClass, sel_registerName("sharedService"));
  if (!service) {
    if (methodOut)
      *methodOut = @"no_fbs_service";
    return NO;
  }

  // 3) FBS openApplication:options:withResult: (no client port)
  SEL openNoPort = sel_registerName("openApplication:options:withResult:");
  if ([service respondsToSelector:openNoPort]) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL launched = NO;
    __block NSString *errDesc = nil;
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(
        service, openNoPort, bundleID, options, ^(NSError *error) {
          launched = (error == nil);
          errDesc = error.localizedDescription;
          dispatch_semaphore_signal(sem);
        });
    long timedOut = dispatch_semaphore_wait(
        sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)8 * NSEC_PER_SEC));
    if (timedOut == 0 && launched) {
      if (methodOut)
        *methodOut = @"fbs_open";
      return YES;
    }
    if (methodOut)
      *methodOut = [NSString
          stringWithFormat:@"fbs_open_fail:%@", errDesc ?: @"timeout"];
  }

  // 4) FBS openApplication:options:clientPort:withResult: with a real port
  SEL openPort =
      sel_registerName("openApplication:options:clientPort:withResult:");
  SEL createPort = sel_registerName("createClientPort");
  SEL cleanupPort = sel_registerName("cleanupClientPort:");
  if ([service respondsToSelector:openPort] &&
      [service respondsToSelector:createPort]) {
    mach_port_t port =
        ((mach_port_t(*)(id, SEL))objc_msgSend)(service, createPort);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL launched = NO;
    __block NSString *errDesc = nil;
    ((void (*)(id, SEL, id, id, mach_port_t, id))objc_msgSend)(
        service, openPort, bundleID, options, port, ^(NSError *error) {
          launched = (error == nil);
          errDesc = error.localizedDescription;
          dispatch_semaphore_signal(sem);
        });
    long timedOut = dispatch_semaphore_wait(
        sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)8 * NSEC_PER_SEC));
    if ([service respondsToSelector:cleanupPort]) {
      ((void (*)(id, SEL, mach_port_t))objc_msgSend)(service, cleanupPort,
                                                     port);
    }
    if (timedOut == 0 && launched) {
      if (methodOut)
        *methodOut = @"fbs_open_port";
      return YES;
    }
    if (methodOut)
      *methodOut = [NSString
          stringWithFormat:@"fbs_port_fail:%@", errDesc ?: @"timeout"];
  }

  if (methodOut && *methodOut == nil)
    *methodOut = @"all_open_failed";
  return NO;
}

static NSDictionary *environment_for_proxy(LSApplicationProxy *proxy,
                                           NSDictionary *extraEnvironment) {
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  NSString *containerPath = proxy.dataContainerURL.path;
  if (containerPath.length > 0) {
    env[@"CFFIXED_USER_HOME"] = containerPath;
    env[@"HOME"] = containerPath;
    env[@"TMPDIR"] = [containerPath stringByAppendingPathComponent:@"tmp"];
  } else {
    env[@"CFFIXED_USER_HOME"] = @"/var/mobile";
    env[@"HOME"] = @"/var/mobile";
    env[@"TMPDIR"] = @"/var/tmp";
  }

  for (NSString *key in extraEnvironment) {
    id value = extraEnvironment[key];
    if ([key isKindOfClass:[NSString class]] &&
        [value isKindOfClass:[NSString class]] && key.length > 0) {
      env[key] = value;
    }
  }
  return env;
}

static NSDictionary *registration_dictionary_for_proxy(
    LSApplicationProxy *proxy, NSDictionary *extraEnvironment) {
  NSString *bundlePath = proxy.bundleURL.path;
  NSDictionary *info =
      [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
  NSString *bundleID = proxy.bundleIdentifier ?: info[@"CFBundleIdentifier"];
  if (bundleID.length == 0 || bundlePath.length == 0)
    return nil;

  NSMutableDictionary *dict = [NSMutableDictionary dictionary];
  dict[@"ApplicationType"] = proxy.applicationType ?: @"User";
  dict[@"CFBundleIdentifier"] = bundleID;
  dict[@"CodeInfoIdentifier"] = bundleID;
  dict[@"CompatibilityState"] = @0;
  dict[@"IsContainerized"] = @YES;
  dict[@"Path"] = bundlePath;
  dict[@"IsDeletable"] = @YES;
  dict[@"LSInstallType"] = @1;
  dict[@"HasMIDBasedSINF"] = @0;
  dict[@"MissingSINF"] = @0;
  dict[@"FamilyID"] = @0;
  dict[@"IsOnDemandInstallCapable"] = @0;

  NSString *containerPath = proxy.dataContainerURL.path;
  if (containerPath.length > 0)
    dict[@"Container"] = containerPath;
  dict[@"EnvironmentVariables"] =
      environment_for_proxy(proxy, extraEnvironment ?: @{});

  return dict;
}

// MARK: - Command Handler

NSDictionary *vp_handle_apps_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  if (!gAppsLoaded) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"apps not available";
    return r;
  }

  // -- app_list --
  if ([type isEqualToString:@"app_list"]) {
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSArray *allApps = [ws allInstalledApplications];
    NSString *filter = msg[@"filter"] ?: @"all";

    NSMutableArray *result = [NSMutableArray array];
    for (LSApplicationProxy *proxy in allApps) {
      NSString *appType = proxy.applicationType;
      BOOL isSystem = [appType isEqualToString:@"System"];

      if ([filter isEqualToString:@"user"] && isSystem)
        continue;
      if ([filter isEqualToString:@"system"] && !isSystem)
        continue;

      pid_t pid = pid_for_app(proxy.bundleIdentifier);

      if ([filter isEqualToString:@"running"] && pid <= 0)
        continue;

      [result addObject:@{
        @"bundle_id" : proxy.bundleIdentifier ?: @"",
        @"name" : proxy.localizedName ?: @"",
        @"version" : proxy.shortVersionString ?: @"",
        @"type" : isSystem ? @"system" : @"user",
        @"state" : state_for_pid(pid),
        @"pid" : @(pid > 0 ? pid : 0),
        @"path" : proxy.bundleURL.path ?: @"",
        @"data_container" : proxy.dataContainerURL.path ?: @"",
      }];
    }

    NSMutableDictionary *r = vp_make_response(@"app_list", reqId);
    r[@"apps"] = result;
    return r;
  }

  // -- app_set_environment --
  if ([type isEqualToString:@"app_set_environment"]) {
    NSString *bundleID = msg[@"bundle_id"];
    NSDictionary *environment = msg[@"environment"];
    if (bundleID.length == 0 || ![environment isKindOfClass:[NSDictionary class]]) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id or environment";
      return r;
    }

    LSApplicationProxy *proxy =
        [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    if (!proxy || proxy.bundleURL.path.length == 0) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = [NSString stringWithFormat:@"app not found: %@", bundleID];
      return r;
    }

    NSDictionary *registration =
        registration_dictionary_for_proxy(proxy, environment);
    if (!registration) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"failed to build registration dictionary";
      return r;
    }

    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    BOOL ok = [ws registerApplicationDictionary:registration];
    if (!ok) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"ok"] = @NO;
      r[@"msg"] = @"LaunchServices registration update failed";
      return r;
    }

    // Persist env via LS, then force a cold start so DYLD_* is applied.
    terminate_application(bundleID);
    BOOL died = wait_until_terminated(bundleID, 3000);
    if (!died) {
      // Last-ditch hard kill by pid if FrontBoard still reports it alive.
      pid_t stuck = pid_for_app(bundleID);
      if (stuck > 0)
        kill(stuck, SIGKILL);
      died = wait_until_terminated(bundleID, 2000);
    }

    NSString *method = nil;
    BOOL launched =
        open_application_with_environment(bundleID, environment, &method);
    usleep(800000);
    pid_t pid = pid_for_app(bundleID);

    // Host/guest-visible breadcrumb: proves vphoned applied the path even if
    // the target app ctor never runs.
    {
      NSString *dylib = environment[@"DYLD_INSERT_LIBRARIES"];
      NSString *crumb = [NSString
          stringWithFormat:
              @"bundle=%@\ndyld=%@\ndied=%d\nlaunched=%d\nmethod=%@\npid=%d\n",
              bundleID, dylib ?: @"(nil)", died ? 1 : 0, launched ? 1 : 0,
              method ?: @"(none)", pid];
      [crumb writeToFile:@"/var/mobile/Library/Caches/vphone-dyld-insert-set.txt"
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
    }

    NSMutableDictionary *r = vp_make_response(@"app_set_environment", reqId);
    r[@"ok"] = @YES;
    r[@"launched"] = @(launched);
    r[@"died"] = @(died);
    r[@"method"] = method ?: @"";
    r[@"pid"] = @(pid > 0 ? pid : 0);
    r[@"environment"] = registration[@"EnvironmentVariables"] ?: @{};
    r[@"msg"] = [NSString
        stringWithFormat:
            @"registered + relaunch (died=%@ launched=%@ method=%@ pid=%d). "
            @"Check app Caches for vphone-noop-inject-loaded.txt",
            died ? @"yes" : @"no", launched ? @"yes" : @"no",
            method ?: @"(none)", pid];
    return r;
  }

  // -- app_launch --
  if ([type isEqualToString:@"app_launch"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSString *url = msg[@"url"];

    BOOL ok;
    if (url) {
      // Open URL (which will launch the handling app)
      NSURL *nsurl = [NSURL URLWithString:url];
      // Try openURL:withOptions: if available
      SEL openURLSel = sel_registerName("openURL:withOptions:");
      if ([ws respondsToSelector:openURLSel]) {
        ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, openURLSel, nsurl,
                                                       nil);
      } else {
        ok = [ws openApplicationWithBundleID:bundleID];
      }
    } else {
      ok = [ws openApplicationWithBundleID:bundleID];
    }

    if (!ok) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = [NSString stringWithFormat:@"failed to launch %@", bundleID];
      return r;
    }

    // Brief wait for app to start
    usleep(500000); // 500ms

    pid_t pid = pid_for_app(bundleID);
    NSMutableDictionary *r = vp_make_response(@"app_launch", reqId);
    r[@"ok"] = @YES;
    r[@"pid"] = @(pid > 0 ? pid : 0);
    return r;
  }

  // -- app_terminate --
  if ([type isEqualToString:@"app_terminate"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    if (gFBSSystemServiceClass) {
      id service = ((id (*)(Class, SEL))objc_msgSend)(
          gFBSSystemServiceClass, sel_registerName("sharedService"));
      if (service) {
        // terminateApplication:forReason:andReport:withDescription:
        // reason 5 = user requested, report NO
        ((void (*)(id, SEL, id, int, BOOL, id))objc_msgSend)(
            service,
            sel_registerName(
                "terminateApplication:forReason:andReport:withDescription:"),
            bundleID, 5, NO, @"vphoned terminate request");
      }
    } else {
      // Fallback: kill by PID
      pid_t pid = pid_for_app(bundleID);
      if (pid > 0)
        kill(pid, SIGTERM);
    }

    NSMutableDictionary *r = vp_make_response(@"app_terminate", reqId);
    r[@"ok"] = @YES;
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown apps command: %@", type];
  return r;
}
