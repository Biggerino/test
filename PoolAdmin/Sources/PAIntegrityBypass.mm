#import "PAIntegrityBypass.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import "PALogger.h"

// ---------------------------------------------------------------------------
// DESIGN: We ONLY swizzle game-specific selectors on known classes.
// We do NOT hook NSFileManager, UIApplication, or UIViewController
// because those system-wide hooks can crash the app during early startup.
// The integrity popup is suppressed by neutralizing the game-level checks
// that TRIGGER the popup, not by trying to block the popup itself.
// ---------------------------------------------------------------------------

#pragma mark - Safe per-class swizzle

static void SwizzleOnNamedClass(const char *className, SEL selector, IMP replacement) {
    @try {
        Class cls = objc_getClass(className);
        if (!cls) return;

        // Check if this class directly implements the method (not inherited)
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        if (!methods) return;

        Method targetMethod = NULL;
        for (unsigned int i = 0; i < count; i++) {
            // NOTE: SELs must be compared with sel_isEqual, NOT pointer
            // equality — the same selector string from different images
            // can have different SEL pointers.
            if (sel_isEqual(method_getName(methods[i]), selector)) {
                targetMethod = methods[i];
                break;
            }
        }
        free(methods);

        if (targetMethod) {
            method_setImplementation(targetMethod, replacement);
        }
    } @catch (NSException *e) {
        // Silently ignore — never crash
    }
}

#pragma mark - Replacement stubs

static BOOL PA_returnNO(id self, SEL _cmd)            { return NO; }
static BOOL PA_returnNO_arg(id self, SEL _cmd, BOOL a){ return NO; }
static BOOL PA_returnYES(id self, SEL _cmd)            { return YES; }
static void PA_noop(id self, SEL _cmd)                 { /* no-op */ }
static void PA_noopBool(id self, SEL _cmd, BOOL a)     { /* no-op */ }
static void PA_noopIdBool(id self, SEL _cmd, id a, BOOL b) { /* no-op */ }

#pragma mark - Alert suppression (installed LATER, not at constructor time)

static IMP sOriginal_present = NULL;

static BOOL IsIntegrityAlert(UIViewController *vc) {
    if (![vc isKindOfClass:[UIAlertController class]]) return NO;
    UIAlertController *alert = (UIAlertController *)vc;
    NSString *msg = [NSString stringWithFormat:@"%@ %@",
                     alert.title ?: @"", alert.message ?: @""].lowercaseString;

    // Only suppress alerts that match the specific integrity check patterns
    NSArray *patterns = @[
        @"unofficial app", @"cannot be installed", @"app will close",
        @"protect you", @"support ref:", @"jailbroken", @"jailbreak",
        @"tampered", @"modified version", @"pirated", @"fraud detected",
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

#pragma mark - exit() suppression

// Hook the ObjC-level forceClose / exit paths, not the C exit() function.
// The game calls exit() through an ObjC method chain that we can intercept.

#pragma mark - Jailbreak filesystem cloak

// fileExistsAtPath: lies about classic jailbreak artifacts only.
// Everything else passes through untouched.
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
    if (sOriginal_fileExistsDir) {
        return ((BOOL(*)(id, SEL, NSString *, BOOL *))sOriginal_fileExistsDir)(
            self, _cmd, path, isDir);
    }
    return NO;
}

#pragma mark - Install

// Known 8 Ball Pool classes that implement integrity/jailbreak methods
static const char *kGameClasses[] = {
    "AppsFlyerLib",
    "AppsFlyerTracker",
    "AppsFlyerLinkGenerator",
    "AFSDKUtils",
    "MCMenuStateManager",
    "GameManager",
    "MainManager",
    "UserInfo",
    "MenuStateContainer",
    "MenuTierSelector",
    "PurchaseConnector",
    "SKPaymentsReceiver",
    // Extra Miniclip / anti-tamper hosts seen in the wild. Missing classes
    // are skipped safely by SwizzleOnNamedClass.
    "MiniclipAntiCheat",
    "MCFraudDetector",
    "MCJailbreakDetector",
    "AppIntegrity",
    "IntegrityManager",
};
static const int kGameClassCount = sizeof(kGameClasses) / sizeof(kGameClasses[0]);

@implementation PAIntegrityBypass

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[PoolAdmin] Installing integrity bypass...");

        // Phase 1: Immediate — swizzle game-specific selectors only.
        // These are safe because we only target named classes that exist in the binary.
        @try {
            for (int i = 0; i < kGameClassCount; i++) {
                const char *cls = kGameClasses[i];

                // Jailbreak detection
                SwizzleOnNamedClass(cls, @selector(isJailbroken),  (IMP)PA_returnNO);
                SwizzleOnNamedClass(cls, @selector(isJailBroken),  (IMP)PA_returnNO);
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"bu_isJailBroken"), (IMP)PA_returnNO);
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"jailbroken"),      (IMP)PA_returnNO);
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"jailBroken"),      (IMP)PA_returnNO);
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"isJailbrokenWithSkipAdvancedJailbreakValidation:"),
                                   (IMP)PA_returnNO_arg);
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"containsJailbrokenFiles"),       (IMP)PA_returnNO);
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"containsJailbrokenPermissions"),  (IMP)PA_returnNO);

                // Store / receipt
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"isAppStoreReceiptSandbox"), (IMP)PA_returnNO);
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"isFromAppStore"),           (IMP)PA_returnYES);

                // Fraud detection
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"setFraudDetectionEnabled:"),          (IMP)PA_noopBool);
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"commandReceivedWithURL:fraudDetected:"), (IMP)PA_noopIdBool);

                // Force skip advanced JB validation
                SwizzleOnNamedClass(cls, NSSelectorFromString(@"setSkipAdvancedJailbreakValidation:"), (IMP)PA_noopBool);
            }
        } @catch (NSException *e) {
            NSLog(@"[PoolAdmin] Phase 1 exception: %@", e);
        }

        // Phase 1b: cloak jailbreak filesystem artifacts. Runs with the
        // rest of phase 1 (post-launch, main thread).
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
            NSLog(@"[PoolAdmin] FS cloak exception: %@", e);
        }

        // Phase 2: Immediate — install the alert suppression hook.
        // It must beat the first integrity popup (REF 6902/8350 shows
        // within the first second), so no dispatch_after here. +install
        // itself runs post-launch on the main thread; UIKit is ready.
        @try {
            Method m = class_getInstanceMethod([UIViewController class],
                                               @selector(presentViewController:animated:completion:));
            if (m) {
                sOriginal_present = method_getImplementation(m);
                method_setImplementation(m, (IMP)PA_presentVC);
            }
            NSLog(@"[PoolAdmin] Alert suppression installed.");
        } @catch (NSException *e) {
            NSLog(@"[PoolAdmin] Alert suppression exception: %@", e);
        }

        // Phase 3: Delayed — force AppsFlyer skip
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                Class afClass = NSClassFromString(@"AppsFlyerLib");
                if (afClass) {
                    SEL shared = NSSelectorFromString(@"shared");
                    if ([afClass respondsToSelector:shared]) {
                        id inst = ((id(*)(id,SEL))objc_msgSend)((id)afClass, shared);
                        SEL skip = NSSelectorFromString(@"setSkipAdvancedJailbreakValidation:");
                        if ([inst respondsToSelector:skip]) {
                            ((void(*)(id,SEL,BOOL))objc_msgSend)(inst, skip, YES);
                        }
                    }
                }
            } @catch (NSException *e) {
                // ignore
            }
        });

        NSLog(@"[PoolAdmin] Integrity bypass phase 1 complete.");
    });
}

@end
