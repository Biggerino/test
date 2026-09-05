#import "PAIntegrityBypass.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/syscall.h>
#import <pthread.h>
#import "PALogger.h"
#import "PAImageHider.h"

// ---------------------------------------------------------------------------
// DESIGN: Multi-layered verdict flip for 56.29.0.
//
// Layer 1 — Game-class swizzles (jailbreak/fraud/store booleans)
// Layer 2 — App Attest neutralisation (DCAppAttestService)
// Layer 3 — Receipt + provisioning profile fake-out
// Layer 4 — Direct-kill interception (syscall/pthread_exit)
// Layer 5 — Alert suppression (presentViewController:)
// Layer 6 — AppsFlyer V2 sanity flag cleanup
//
// All hooks are exception-guarded and logged via PALog. Missing classes
// or selectors are silently skipped.
// ---------------------------------------------------------------------------

#pragma mark - Safe per-class and per-metaclass swizzle

static void SwizzleMethod(const char *className, SEL selector, IMP replacement) {
    @try {
        Class cls = objc_getClass(className);
        if (!cls) return;

        // 1. Try instance method
        Method instMethod = class_getInstanceMethod(cls, selector);
        if (instMethod) {
            method_setImplementation(instMethod, replacement);
            PALog(@"swizzled -[%s %@] done", className, NSStringFromSelector(selector));
        }

        // 2. Try class method on metaclass
        Class meta = object_getClass((id)cls);
        if (meta && meta != cls) {
            Method classMethod = class_getInstanceMethod(meta, selector);
            if (classMethod) {
                method_setImplementation(classMethod, replacement);
                PALog(@"swizzled +[%s %@] done", className, NSStringFromSelector(selector));
            }
        }
    } @catch (NSException *e) {}
}

static void SwizzleOnNamedClass(const char *className, SEL selector, IMP replacement) {
    SwizzleMethod(className, selector, replacement);
}

static void SwizzleClassMethod(const char *className, SEL selector, IMP replacement) {
    SwizzleMethod(className, selector, replacement);
}

#pragma mark - Replacement stubs

static BOOL PA_returnNO(id self, SEL _cmd)            { return NO; }
static BOOL PA_returnNO_arg(id self, SEL _cmd, BOOL a){ return NO; }
static BOOL PA_returnYES(id self, SEL _cmd)            { return YES; }
static void PA_noop(id self, SEL _cmd)                 { /* no-op */ }
static void PA_noopBool(id self, SEL _cmd, BOOL a)     { /* no-op */ }
static void PA_noopIdBool(id self, SEL _cmd, id a, BOOL b) { /* no-op */ }

#pragma mark - Layer 2: DCAppAttestService neutralisation

// Make isSupported return NO — the game should fall back to a non-Attest
// code path, just as it would on a device running iOS < 14 or without
// Secure Enclave.
static BOOL PA_attestNotSupported(id self, SEL _cmd) {
    PALog(@"attest isSupported → NO (forced)");
    return NO;
}

// generateKeyWithCompletionHandler: — return DCErrorFeatureUnsupported (code 1)
static void PA_generateKeyNeutered(id self, SEL _cmd, id completionHandler) {
    PALog(@"attest generateKey: neutered → error callback");
    @try {
        if (completionHandler) {
            NSError *err = [NSError errorWithDomain:@"DCErrorDomain"
                                               code:1 // DCErrorFeatureUnsupported
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                       @"App Attest is not supported on this device"}];
            void (^block)(NSString *, NSError *) = (void (^)(NSString *, NSError *))completionHandler;
            block(nil, err);
        }
    } @catch (NSException *e) {
        PALog(@"attest generateKey: completion exception %@", e);
    }
}

// attestKey:clientDataHash:completionHandler: (takes 3 arguments)
static void PA_attestKeyNeutered(id self, SEL _cmd, NSString *keyId,
                                  NSData *clientDataHash,
                                  id completionHandler) {
    PALog(@"attest attestKey:clientDataHash: neutered → error callback keyId=%@", keyId ?: @"(nil)");
    @try {
        if (completionHandler) {
            NSError *err = [NSError errorWithDomain:@"DCErrorDomain"
                                               code:1 // DCErrorFeatureUnsupported
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                       @"App Attest is not supported on this device"}];
            void (^block)(NSData *, NSError *) = (void (^)(NSData *, NSError *))completionHandler;
            block(nil, err);
        }
    } @catch (NSException *e) {
        PALog(@"attest attestKey: completion exception %@", e);
    }
}

// generateAssertion:clientDataHash:completionHandler: (takes 3 arguments)
static void PA_generateAssertionNeutered(id self, SEL _cmd, NSString *keyId,
                                          NSData *clientDataHash,
                                          id completionHandler) {
    PALog(@"attest generateAssertion:clientDataHash: neutered → error callback");
    @try {
        if (completionHandler) {
            NSError *err = [NSError errorWithDomain:@"DCErrorDomain"
                                               code:1 // DCErrorFeatureUnsupported
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                       @"App Attest is not supported on this device"}];
            void (^block)(NSData *, NSError *) =
                (void (^)(NSData *, NSError *))completionHandler;
            block(nil, err);
        }
    } @catch (NSException *e) {
        PALog(@"attest generateAssertion: completion exception %@", e);
    }
}

static void PAInstallAppAttestHooks(void) {
    @try {
        Class attestClass = NSClassFromString(@"DCAppAttestService");
        if (!attestClass) {
            PALog(@"attest DCAppAttestService not found (iOS<14?) — skipping");
            return;
        }

        SwizzleMethod("DCAppAttestService", NSSelectorFromString(@"isSupported"), (IMP)PA_attestNotSupported);
        SwizzleMethod("DCAppAttestService", NSSelectorFromString(@"generateKeyWithCompletionHandler:"), (IMP)PA_generateKeyNeutered);
        SwizzleMethod("DCAppAttestService", NSSelectorFromString(@"attestKey:clientDataHash:completionHandler:"), (IMP)PA_attestKeyNeutered);
        SwizzleMethod("DCAppAttestService", NSSelectorFromString(@"generateAssertion:clientDataHash:completionHandler:"), (IMP)PA_generateAssertionNeutered);
    } @catch (NSException *e) {
        PALog(@"attest install exception: %@", e);
    }
}

#pragma mark - Layer 3: Receipt + mobileprovision fake-out

static NSData *sFakeReceiptData = nil;
static NSData *PAFakeReceiptData(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsigned char fakeReceipt[] = {
            0x30, 0x80, // SEQUENCE, indefinite length
            0x06, 0x09, // OID
            0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02, // pkcs7-signedData
            0xA0, 0x80, // [0] EXPLICIT, indefinite
            0x30, 0x80, // SEQUENCE, indefinite
            0x02, 0x01, 0x01, // INTEGER 1 (version)
            0x31, 0x00, // SET OF (empty digestAlgorithms)
            0x30, 0x80, // SEQUENCE, indefinite (contentInfo)
            0x06, 0x09, // OID
            0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01, // pkcs7-data
            0x00, 0x00, // end contentInfo
            0x00, 0x00, // end inner SEQUENCE
            0x00, 0x00, // end [0]
            0x00, 0x00, // end outer SEQUENCE
        };
        sFakeReceiptData = [NSData dataWithBytes:fakeReceipt length:sizeof(fakeReceipt)];
    });
    return sFakeReceiptData;
}

static NSString *PAFakeReceiptPath(void) {
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        return [docs stringByAppendingPathComponent:@"StoreKit_receipt"];
    } @catch (NSException *e) {
        return nil;
    }
}

static void PACreateFakeReceipt(void) {
    @try {
        NSString *receiptPath = PAFakeReceiptPath();
        if (!receiptPath) {
            PALog(@"receipt path is nil — skipping fake receipt");
            return;
        }

        NSData *data = PAFakeReceiptData();
        NSError *err = nil;
        BOOL written = [data writeToFile:receiptPath options:NSDataWritingAtomic error:&err];
        if (written) {
            PALog(@"receipt file created at %@", receiptPath);
        } else {
            PALog(@"receipt file create FAILED at %@: %@", receiptPath, err);
        }
    } @catch (NSException *e) {
        PALog(@"receipt creation exception: %@", e);
    }
}

static IMP sOriginal_appStoreReceiptURL = NULL;
static NSURL *PA_appStoreReceiptURL(id self, SEL _cmd) {
    @try {
        if (self != [NSBundle mainBundle]) {
            if (sOriginal_appStoreReceiptURL) {
                return ((NSURL *(*)(id, SEL))sOriginal_appStoreReceiptURL)(self, _cmd);
            }
            return nil;
        }
        return [NSURL fileURLWithPath:PAFakeReceiptPath()];
    } @catch (NSException *e) {
        return nil;
    }
}

// Intercept [NSData dataWithContentsOfURL:] for receipt URL requests
static IMP sOriginal_dataWithContentsOfURL = NULL;
static NSData *PA_dataWithContentsOfURL(id self, SEL _cmd, NSURL *url) {
    @try {
        if (url && [url isKindOfClass:NSURL.class]) {
            NSString *p = url.path;
            if ([p hasSuffix:@"StoreKit_receipt"] ||
                [p hasSuffix:@"sandboxReceipt"] ||
                [p hasSuffix:@"_MASReceipt/receipt"]) {
                PALog(@"receipt dataWithContentsOfURL intercepted: %@", p);
                return PAFakeReceiptData();
            }
        }
    } @catch (NSException *e) {}
    if (sOriginal_dataWithContentsOfURL) {
        return ((NSData *(*)(id, SEL, NSURL *))sOriginal_dataWithContentsOfURL)(self, _cmd, url);
    }
    return nil;
}

// Cloak embedded.mobileprovision — its presence signals a sideloaded app.
// App Store apps never have this file.
static IMP sOriginal_contentsAtPath = NULL;

static NSData *PA_contentsAtPath(id self, SEL _cmd, NSString *path) {
    @try {
        if ([path isKindOfClass:NSString.class]) {
            if ([path hasSuffix:@"embedded.mobileprovision"]) {
                PALog(@"mobileprovision read blocked: %@", path);
                return nil;
            }
            if ([path hasSuffix:@"StoreKit_receipt"] ||
                [path hasSuffix:@"sandboxReceipt"] ||
                [path hasSuffix:@"_MASReceipt/receipt"]) {
                return PAFakeReceiptData();
            }
        }
    } @catch (NSException *e) {}
    if (sOriginal_contentsAtPath) {
        return ((NSData *(*)(id, SEL, NSString *))sOriginal_contentsAtPath)(
            self, _cmd, path);
    }
    return nil;
}

static void PAInstallReceiptHooks(void) {
    @try {
        PACreateFakeReceipt();

        // Hook appStoreReceiptURL on NSBundle
        Method receiptURLMethod = class_getInstanceMethod(
            [NSBundle class], NSSelectorFromString(@"appStoreReceiptURL"));
        if (receiptURLMethod) {
            sOriginal_appStoreReceiptURL = method_getImplementation(receiptURLMethod);
            method_setImplementation(receiptURLMethod, (IMP)PA_appStoreReceiptURL);
            PALog(@"receipt hooked -[NSBundle appStoreReceiptURL]");
        }

        // Hook NSFileManager contentsAtPath:
        Method contentsMethod = class_getInstanceMethod(
            [NSFileManager class], @selector(contentsAtPath:));
        if (contentsMethod) {
            sOriginal_contentsAtPath = method_getImplementation(contentsMethod);
            method_setImplementation(contentsMethod, (IMP)PA_contentsAtPath);
            PALog(@"receipt hooked -[NSFileManager contentsAtPath:]");
        }

        // Hook +[NSData dataWithContentsOfURL:]
        Method dataURLMethod = class_getClassMethod(
            [NSData class], @selector(dataWithContentsOfURL:));
        if (dataURLMethod) {
            sOriginal_dataWithContentsOfURL = method_getImplementation(dataURLMethod);
            method_setImplementation(dataURLMethod, (IMP)PA_dataWithContentsOfURL);
            PALog(@"receipt hooked +[NSData dataWithContentsOfURL:]");
        }
    } @catch (NSException *e) {
        PALog(@"receipt hooks exception: %@", e);
    }
}

#pragma mark - Layer 4: Direct-kill interception (syscall/pthread)
static int (*sReal_syscall)(int, ...) = NULL;
static int PA_syscall(int number, ...) {
    // SYS_exit = 1, SYS_exit_group = 431 (ARM64 Linux; on iOS/XNU it's 1)
    if (number == 1 || number == 431) {
        PALog(@"guard syscall(%d) swallowed — staying alive", number);
        // Return 0 to pretend success but don't actually exit
        return 0;
    }
    // For other syscalls, we need to forward with the variadic args.
    // Since we can't perfectly forward variadic args, and the game
    // only uses syscall() for exit, just forward with up to 6 args.
    va_list ap;
    va_start(ap, number);
    long a1 = va_arg(ap, long);
    long a2 = va_arg(ap, long);
    long a3 = va_arg(ap, long);
    va_end(ap);
    if (sReal_syscall) {
        return sReal_syscall(number, a1, a2, a3);
    }
    return -1;
}

// pthread_exit hook — prevent main thread suicide
static void (*sReal_pthread_exit)(void *) = NULL;
static void PA_pthread_exit(void *value_ptr) {
    if (pthread_main_np()) {
        PALog(@"guard pthread_exit on main thread swallowed — staying alive");
        // Don't call the real one; just return (which is technically
        // undefined for pthread_exit, but keeps the thread alive)
        return;
    }
    if (sReal_pthread_exit) {
        sReal_pthread_exit(value_ptr);
    }
}

// __pthread_kill hook — prevent SIGKILL/SIGABRT sent to specific threads
static int (*sReal_pthread_kill)(pthread_t, int) = NULL;
static int PA_pthread_kill_hook(pthread_t thread, int sig) {
    if (sig == 9 /*SIGKILL*/ || sig == 6 /*SIGABRT*/ || sig == 15 /*SIGTERM*/) {
        // Check if targeting our own process threads
        if (pthread_equal(thread, pthread_self()) || pthread_main_np()) {
            PALog(@"guard __pthread_kill(sig=%d) on self swallowed", sig);
            return 0;
        }
    }
    if (sReal_pthread_kill) {
        return sReal_pthread_kill(thread, sig);
    }
    return -1;
}

// atexit handler — some code registers an atexit callback to terminate
// after cleanup. We can't unhook atexit entirely but we can log it.
static void (*sReal_atexit_fn)(void (*)(void)) = NULL;

static void PAInstallDirectKillHooks(void) {
    @try {
        // Save originals via dlsym before rebinding
        sReal_syscall = (int (*)(int, ...))dlsym(RTLD_DEFAULT, "syscall");
        sReal_pthread_exit = (void (*)(void *))dlsym(RTLD_DEFAULT, "pthread_exit");
        sReal_pthread_kill = (int (*)(pthread_t, int))dlsym(RTLD_DEFAULT, "pthread_kill");

        PARebindAll("_syscall", (void *)&PA_syscall);
        PARebindAll("syscall", (void *)&PA_syscall);
        PALog(@"guard hooked syscall()");

        PARebindAll("_pthread_exit", (void *)&PA_pthread_exit);
        PARebindAll("pthread_exit", (void *)&PA_pthread_exit);
        PALog(@"guard hooked pthread_exit()");

        PARebindAll("_pthread_kill", (void *)&PA_pthread_kill_hook);
        PARebindAll("pthread_kill", (void *)&PA_pthread_kill_hook);
        PALog(@"guard hooked pthread_kill()");
    } @catch (NSException *e) {
        PALog(@"guard direct-kill hooks exception: %@", e);
    }
}

#pragma mark - Alert suppression (presentViewController:)

static IMP sOriginal_present = NULL;

static BOOL IsIntegrityAlert(UIViewController *vc) {
    if (![vc isKindOfClass:[UIAlertController class]]) return NO;
    UIAlertController *alert = (UIAlertController *)vc;
    NSString *msg = [NSString stringWithFormat:@"%@ %@",
                     alert.title ?: @"", alert.message ?: @""].lowercaseString;

    NSArray *patterns = @[
        @"unofficial app", @"cannot be installed", @"app will close",
        @"protect you", @"support ref:", @"jailbroken", @"jailbreak",
        @"tampered", @"modified version", @"pirated", @"fraud detected",
        @"not available", @"integrity", @"security check",
    ];
    for (NSString *p in patterns) {
        if ([msg containsString:p]) return YES;
    }
    return NO;
}

static void PA_presentVC(id self, SEL _cmd, UIViewController *vc, BOOL anim, void(^comp)(void)) {
    if (IsIntegrityAlert(vc)) {
        UIAlertController *alert = (UIAlertController *)vc;
        PALog(@"blocked integrity alert title='%@' msg='%@'",
              alert.title ?: @"", alert.message ?: @"");
        if (comp) comp();
        return;
    }
    if (sOriginal_present) {
        ((void(*)(id,SEL,UIViewController*,BOOL,void(^)(void)))sOriginal_present)(self, _cmd, vc, anim, comp);
    }
}

#pragma mark - Jailbreak filesystem cloak

static BOOL PAIsJailbreakPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length) return NO;
    static NSArray<NSString *> *markers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = @[
            @"/Applications/Cydia.app",
            @"/Applications/Sileo.app",
            @"/Applications/Zebra.app",
            @"/bin/bash", @"/bin/sh", @"/usr/sbin/sshd",
            @"/etc/apt", @"/private/var/lib/apt",
            @"/Library/MobileSubstrate",
            @"/usr/lib/libsubstrate",
            @"/usr/lib/substitute",
            @"cydia", @"sileo", @"zebra",
        ];
    });
    NSString *lower = path.lowercaseString;
    for (NSString *m in markers) {
        if ([lower containsString:m.lowercaseString]) return YES;
    }
    return NO;
}

static IMP sOriginal_fileExists = NULL;
static IMP sOriginal_fileExistsDir = NULL;

static BOOL PA_fileExists(id self, SEL _cmd, NSString *path) {
    if (PAIsJailbreakPath(path)) return NO;
    // Also hide mobileprovision from file-exists checks
    @try {
        if ([path isKindOfClass:NSString.class]) {
            if ([path hasSuffix:@"embedded.mobileprovision"]) {
                PALog(@"mobileprovision fileExists blocked: %@", path);
                return NO;
            }
            if ([path hasSuffix:@"StoreKit_receipt"] ||
                [path hasSuffix:@"sandboxReceipt"] ||
                [path hasSuffix:@"_MASReceipt/receipt"]) {
                return YES;
            }
        }
    } @catch (NSException *e) {}
    if (sOriginal_fileExists) {
        return ((BOOL(*)(id, SEL, NSString *))sOriginal_fileExists)(self, _cmd, path);
    }
    return NO;
}

static BOOL PA_fileExistsDir(id self, SEL _cmd, NSString *path, BOOL *isDir) {
    if (PAIsJailbreakPath(path)) {
        if (isDir) *isDir = NO;
        return NO;
    }
    @try {
        if ([path isKindOfClass:NSString.class]) {
            if ([path hasSuffix:@"embedded.mobileprovision"]) {
                if (isDir) *isDir = NO;
                return NO;
            }
            if ([path hasSuffix:@"StoreKit_receipt"] ||
                [path hasSuffix:@"sandboxReceipt"] ||
                [path hasSuffix:@"_MASReceipt/receipt"]) {
                if (isDir) *isDir = NO;
                return YES;
            }
        }
    } @catch (NSException *e) {}
    if (sOriginal_fileExistsDir) {
        return ((BOOL(*)(id, SEL, NSString *, BOOL *))sOriginal_fileExistsDir)(
            self, _cmd, path, isDir);
    }
    return NO;
}

#pragma mark - Layer 6: AppsFlyer V2 Sanity Flags

static IMP sOriginal_v2Sanity = NULL;
static id PA_calculateV2Sanity(id self, SEL _cmd, BOOL isSim, BOOL isDev, BOOL isJB, BOOL isCounter, BOOL isDbg) {
    PALog(@"AppsFlyer calculateV2Sanity sanitized (all bad flags forced NO, counter YES)");
    if (sOriginal_v2Sanity) {
        return ((id(*)(id, SEL, BOOL, BOOL, BOOL, BOOL, BOOL))sOriginal_v2Sanity)(self, _cmd, NO, NO, NO, YES, NO);
    }
    return @"";
}

static IMP sOriginal_v2Value = NULL;
static id PA_calculateV2Value(id self, SEL _cmd, id ts, id uid, id sysVer, id firstLaunch, id sdkVer, BOOL isSim, BOOL isDev, BOOL isJB, BOOL isCounter, BOOL isDbg) {
    PALog(@"AppsFlyer calculateV2Value sanitized");
    if (sOriginal_v2Value) {
        return ((id(*)(id, SEL, id, id, id, id, id, BOOL, BOOL, BOOL, BOOL, BOOL))sOriginal_v2Value)(
            self, _cmd, ts, uid, sysVer, firstLaunch, sdkVer, NO, NO, NO, YES, NO);
    }
    return @"";
}

static void PAInstallAppsFlyerSanityHooks(void) {
    @try {
        Class afChecksum = objc_getClass("AFSDKChecksum");
        if (afChecksum) {
            Method mSanity = class_getInstanceMethod(afChecksum,
                NSSelectorFromString(@"calculateV2SanityFlagsWithIsSimulator:isDevBuild:isJailBroken:isCounterValid:isDebuggerAttached:"));
            if (mSanity && !sOriginal_v2Sanity) {
                sOriginal_v2Sanity = method_getImplementation(mSanity);
                method_setImplementation(mSanity, (IMP)PA_calculateV2Sanity);
                PALog(@"swizzled AFSDKChecksum calculateV2SanityFlags");
            }
            Method mVal = class_getInstanceMethod(afChecksum,
                NSSelectorFromString(@"calculateV2ValueWithTimestamp:uid:systemVersion:firstLaunchDate:AFSDKVersion:isSimulator:isDevBuild:isJailBroken:isCounterValid:isDebuggerAttached:"));
            if (mVal && !sOriginal_v2Value) {
                sOriginal_v2Value = method_getImplementation(mVal);
                method_setImplementation(mVal, (IMP)PA_calculateV2Value);
                PALog(@"swizzled AFSDKChecksum calculateV2Value");
            }
            SwizzleMethod("AFSDKChecksum", NSSelectorFromString(@"isCounterValid"), (IMP)PA_returnYES);
        }
    } @catch (NSException *e) {
        PALog(@"AppsFlyer sanity hooks exception: %@", e);
    }
}

#pragma mark - Install

static const char *kGameClasses[] = {
    "AppsFlyerLib",
    "AppsFlyerTracker",
    "AppsFlyerLinkGenerator",
    "AppsFlyerUtils",
    "AFSDKUtils",
    "AFSDKChecksum",
    "MCMenuStateManager",
    "GameManager",
    "MainManager",
    "UserInfo",
    "MenuStateContainer",
    "MenuTierSelector",
    "PurchaseConnector",
    "SKPaymentsReceiver",
    "MiniclipAntiCheat",
    "MCFraudDetector",
    "MCJailbreakDetector",
    "AppIntegrity",
    "IntegrityManager",
    "BUDeviceInfo",
    "MCDeviceInfo",
    // Discovered 56.29.0 device security & environment classes
    "STKDevice",
    "PAGDeviceHelper",
    "APMIdentity",
    "GULAppEnvironmentUtil",
    "MTGDeviceHandler",
};
static const int kGameClassCount = sizeof(kGameClasses) / sizeof(kGameClasses[0]);

@implementation PAIntegrityBypass

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        PALog(@"bypass stage=install begin");

        // ── Phase 0: App Attest neutralisation (MOST CRITICAL) ──
        @try {
            PAInstallAppAttestHooks();
        } @catch (NSException *e) {
            PALog(@"bypass phase0-attest exception: %@", e);
        }

        // ── Phase 0b: Direct-kill interception ──
        @try {
            PAInstallDirectKillHooks();
        } @catch (NSException *e) {
            PALog(@"bypass phase0b-directkill exception: %@", e);
        }

        // ── Phase 0c: Receipt + mobileprovision ──
        @try {
            PAInstallReceiptHooks();
        } @catch (NSException *e) {
            PALog(@"bypass phase0c-receipt exception: %@", e);
        }

        // ── Phase 1: Game-class swizzles (instance + metaclass) ──
        @try {
            for (int i = 0; i < kGameClassCount; i++) {
                const char *cls = kGameClasses[i];

                // Jailbreak detection
                SwizzleMethod(cls, @selector(isJailbroken),  (IMP)PA_returnNO);
                SwizzleMethod(cls, @selector(isJailBroken),  (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"bu_isJailBroken"), (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"jailbroken"),      (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"jailBroken"),      (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isJailbrokenWithSkipAdvancedJailbreakValidation:"),
                              (IMP)PA_returnNO_arg);
                SwizzleMethod(cls, NSSelectorFromString(@"containsJailbrokenFiles"),       (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"containsJailbrokenPermissions"),  (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isDeviceCompromised"), (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isDebuggerAttached"),  (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isRooted"),            (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isSimulator"),         (IMP)PA_returnNO);

                // Store / receipt
                SwizzleMethod(cls, NSSelectorFromString(@"isAppStoreReceiptSandbox"), (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isFromAppStore"),           (IMP)PA_returnYES);
                SwizzleMethod(cls, NSSelectorFromString(@"isAppStoreReceiptValid"),   (IMP)PA_returnYES);

                // Fraud detection
                SwizzleMethod(cls, NSSelectorFromString(@"setFraudDetectionEnabled:"),          (IMP)PA_noopBool);
                SwizzleMethod(cls, NSSelectorFromString(@"commandReceivedWithURL:fraudDetected:"), (IMP)PA_noopIdBool);
                SwizzleMethod(cls, NSSelectorFromString(@"setSkipAdvancedJailbreakValidation:"), (IMP)PA_noopBool);
            }
            PALog(@"bypass phase1-swizzle done (%d classes)", kGameClassCount);
        } @catch (NSException *e) {
            PALog(@"bypass phase1 exception: %@", e);
        }

        // ── Phase 1b: Jailbreak filesystem cloak ──
        @try {
            Method a = class_getInstanceMethod([NSFileManager class],
                                               @selector(fileExistsAtPath:));
            if (a) {
                sOriginal_fileExists = method_getImplementation(a);
                method_setImplementation(a, (IMP)PA_fileExists);
            }
            Method b = class_getInstanceMethod(
                [NSFileManager class],
                @selector(fileExistsAtPath:isDirectory:));
            if (b) {
                sOriginal_fileExistsDir = method_getImplementation(b);
                method_setImplementation(b, (IMP)PA_fileExistsDir);
            }
            PALog(@"bypass phase1b-fs done");
        } @catch (NSException *e) {
            PALog(@"bypass phase1b exception: %@", e);
        }

        // ── Phase 1c: Hardcoded Miniclip integrity class hooks ──
        // These classes exist in the 56.29.0 binary but aren't loaded until
        // after login. We hook them proactively so their methods return
        // "legit" the moment the game loads them.
        @try {
            // MCDeviceInfo / BUDeviceInfo — the primary device fingerprint
            SwizzleOnNamedClass("MCDeviceInfo", @selector(isJailbroken), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCDeviceInfo", @selector(isJailBroken), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCDeviceInfo", NSSelectorFromString(@"isDeviceCompromised"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCDeviceInfo", NSSelectorFromString(@"isDebuggerAttached"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCDeviceInfo", NSSelectorFromString(@"isRooted"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCDeviceInfo", NSSelectorFromString(@"isAppStoreReceiptValid"), (IMP)PA_returnYES);
            SwizzleOnNamedClass("MCDeviceInfo", NSSelectorFromString(@"isAppStoreReceiptSandbox"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCDeviceInfo", NSSelectorFromString(@"isFromAppStore"), (IMP)PA_returnYES);

            SwizzleOnNamedClass("BUDeviceInfo", @selector(isJailbroken), (IMP)PA_returnNO);
            SwizzleOnNamedClass("BUDeviceInfo", @selector(isJailBroken), (IMP)PA_returnNO);
            SwizzleOnNamedClass("BUDeviceInfo", NSSelectorFromString(@"isDeviceCompromised"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("BUDeviceInfo", NSSelectorFromString(@"isDebuggerAttached"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("BUDeviceInfo", NSSelectorFromString(@"isAppStoreReceiptValid"), (IMP)PA_returnYES);
            SwizzleOnNamedClass("BUDeviceInfo", NSSelectorFromString(@"isAppStoreReceiptSandbox"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("BUDeviceInfo", NSSelectorFromString(@"isFromAppStore"), (IMP)PA_returnYES);

            // MCFraudDetector / MCJailbreakDetector / AppIntegrity / IntegrityManager
            SwizzleOnNamedClass("MCFraudDetector", @selector(isFraudDetected), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCFraudDetector", NSSelectorFromString(@"isTampered"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCFraudDetector", NSSelectorFromString(@"detectFraud"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCFraudDetector", NSSelectorFromString(@"detectJailbreak"), (IMP)PA_returnNO);

            SwizzleOnNamedClass("MCJailbreakDetector", @selector(isJailbroken), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCJailbreakDetector", @selector(isJailBroken), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCJailbreakDetector", NSSelectorFromString(@"detectJailbreak"), (IMP)PA_returnNO);

            SwizzleOnNamedClass("AppIntegrity", @selector(isAppIntegrityValid), (IMP)PA_returnYES);
            SwizzleOnNamedClass("AppIntegrity", NSSelectorFromString(@"isTampered"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("AppIntegrity", NSSelectorFromString(@"verifyIntegrity"), (IMP)PA_returnYES);

            SwizzleOnNamedClass("IntegrityManager", @selector(isIntegrityValid), (IMP)PA_returnYES);
            SwizzleOnNamedClass("IntegrityManager", NSSelectorFromString(@"checkIntegrity"), (IMP)PA_returnYES);
            SwizzleOnNamedClass("IntegrityManager", NSSelectorFromString(@"verifyAppIntegrity"), (IMP)PA_returnYES);

            // PurchaseConnector / SKPaymentsReceiver — store validation
            SwizzleOnNamedClass("PurchaseConnector", NSSelectorFromString(@"isAppStoreReceiptValid"), (IMP)PA_returnYES);
            SwizzleOnNamedClass("PurchaseConnector", NSSelectorFromString(@"validateReceipt"), (IMP)PA_returnYES);
            SwizzleOnNamedClass("SKPaymentsReceiver", NSSelectorFromString(@"validateReceipt"), (IMP)PA_returnYES);

            // MCMenuStateManager — menu/terms integrity
            SwizzleOnNamedClass("MCMenuStateManager", NSSelectorFromString(@"isTermsAccepted"), (IMP)PA_returnYES);
            SwizzleOnNamedClass("MCMenuStateManager", NSSelectorFromString(@"shouldShowTerms"), (IMP)PA_returnNO);
            SwizzleOnNamedClass("MCMenuStateManager", NSSelectorFromString(@"shouldShowPrivacy"), (IMP)PA_returnNO);

            PALog(@"bypass phase1c-hardcoded done");
        } @catch (NSException *e) {
            PALog(@"bypass phase1c exception: %@", e);
        }

        // ── Phase 2: Alert suppression ──
        @try {
            Method m = class_getInstanceMethod([UIViewController class],
                                               @selector(presentViewController:animated:completion:));
            if (m) {
                sOriginal_present = method_getImplementation(m);
                method_setImplementation(m, (IMP)PA_presentVC);
            }
            PALog(@"bypass phase2-alert done");
        } @catch (NSException *e) {
            PALog(@"bypass phase2 exception: %@", e);
        }

        // ── Phase 3: AppsFlyer delayed force-skip & sanity hooks ──
        @try {
            PAInstallAppsFlyerSanityHooks();
        } @catch (NSException *e) {}

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                PAInstallAppsFlyerSanityHooks();
                Class afClass = NSClassFromString(@"AppsFlyerLib");
                if (afClass) {
                    SEL shared = NSSelectorFromString(@"shared");
                    if ([afClass respondsToSelector:shared]) {
                        id inst = ((id(*)(id,SEL))objc_msgSend)((id)afClass, shared);
                        SEL skip = NSSelectorFromString(@"setSkipAdvancedJailbreakValidation:");
                        if ([inst respondsToSelector:skip]) {
                            ((void(*)(id,SEL,BOOL))objc_msgSend)(inst, skip, YES);
                            PALog(@"bypass phase3-appsflyer skip=YES");
                        }
                    }
                }
            } @catch (NSException *e) {}
        });

        PALog(@"bypass stage=install done");
    });
}

// Early install: called from the constructor (before DidFinishLaunching).
// Only installs hooks that don't require UIKit (no alert suppression).
+ (void)installEarly {
    static dispatch_once_t earlyOnce;
    dispatch_once(&earlyOnce, ^{
        PALog(@"bypass stage=installEarly begin");

        // App Attest — must be neutered before any attestation flow starts
        @try {
            PAInstallAppAttestHooks();
        } @catch (NSException *e) {
            PALog(@"bypass early attest exception: %@", e);
        }

        // Direct-kill hooks
        @try {
            PAInstallDirectKillHooks();
        } @catch (NSException *e) {
            PALog(@"bypass early directkill exception: %@", e);
        }

        // Receipt + mobileprovision (Foundation only, no UIKit)
        @try {
            PAInstallReceiptHooks();
        } @catch (NSException *e) {
            PALog(@"bypass early receipt exception: %@", e);
        }

        // Game-class swizzles (these use objc_getClass, safe pre-main)
        @try {
            for (int i = 0; i < kGameClassCount; i++) {
                const char *cls = kGameClasses[i];

                SwizzleMethod(cls, @selector(isJailbroken),  (IMP)PA_returnNO);
                SwizzleMethod(cls, @selector(isJailBroken),  (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"bu_isJailBroken"), (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"jailbroken"),      (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"jailBroken"),      (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isJailbrokenWithSkipAdvancedJailbreakValidation:"),
                              (IMP)PA_returnNO_arg);
                SwizzleMethod(cls, NSSelectorFromString(@"containsJailbrokenFiles"),       (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"containsJailbrokenPermissions"),  (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isDeviceCompromised"), (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isDebuggerAttached"),  (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isRooted"),            (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isSimulator"),         (IMP)PA_returnNO);

                SwizzleMethod(cls, NSSelectorFromString(@"isAppStoreReceiptSandbox"), (IMP)PA_returnNO);
                SwizzleMethod(cls, NSSelectorFromString(@"isFromAppStore"),           (IMP)PA_returnYES);
                SwizzleMethod(cls, NSSelectorFromString(@"isAppStoreReceiptValid"),   (IMP)PA_returnYES);

                SwizzleMethod(cls, NSSelectorFromString(@"setFraudDetectionEnabled:"),          (IMP)PA_noopBool);
                SwizzleMethod(cls, NSSelectorFromString(@"commandReceivedWithURL:fraudDetected:"), (IMP)PA_noopIdBool);
                SwizzleMethod(cls, NSSelectorFromString(@"setSkipAdvancedJailbreakValidation:"), (IMP)PA_noopBool);
            }
        } @catch (NSException *e) {
            PALog(@"bypass early swizzle exception: %@", e);
        }

        // Filesystem cloak
        @try {
            Method a = class_getInstanceMethod([NSFileManager class],
                                               @selector(fileExistsAtPath:));
            if (a) {
                sOriginal_fileExists = method_getImplementation(a);
                method_setImplementation(a, (IMP)PA_fileExists);
            }
            Method b = class_getInstanceMethod(
                [NSFileManager class],
                @selector(fileExistsAtPath:isDirectory:));
            if (b) {
                sOriginal_fileExistsDir = method_getImplementation(b);
                method_setImplementation(b, (IMP)PA_fileExistsDir);
            }
        } @catch (NSException *e) {
            PALog(@"bypass early fs exception: %@", e);
        }

        // AppsFlyer sanity hooks
        @try {
            PAInstallAppsFlyerSanityHooks();
        } @catch (NSException *e) {}

        PALog(@"bypass stage=installEarly done");
    });
}

@end
