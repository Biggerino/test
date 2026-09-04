#import "PADiscovery.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "PALogger.h"

namespace {

const NSUInteger kMaxLines = 200;

// Ad-network / system prefixes: enumerated last (or never) so the
// 400-line budget isn't eaten by IronSource/Mintegral/etc. Thousands of
// their methods match generic keywords like "storekit" or "forKey".
BOOL PADiscoveryExcluded(NSString *className) {
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefixes = @[
            @"IS", @"MTG", @"GADM", @"GAD", @"IAS", @"ALAd", @"FB",
            @"FIR", @"MP", @"MoPub", @"Vungle", @"Unity", @"IronSource",
            @"Supersonic", @"Mintegral", @"AppLovin", @"InMobi",
            @"Moloco", @"AdSurge", @"AppsFlyer", @"AF", @"Google",
            @"OMID", @"LevelPlay", @"LPM", @"SSE", @"SSA", @"FBL",
            @"FBSDK", @"GMS", @"GTM", @"Chartboost", @"Tapjoy",
            @"AdColony", @"VAST", @"IMA", @"Pangle", @"AMZN",
            @"Amazon", @"SK", @"SKAd", @"NS", @"UI", @"_", @"AV",
            @"CA", @"CG", @"CF", @"MK", @"CL", @"PH", @"CN", @"EK",
            @"HK", @"NE", @"NW", @"WK", @"SC", @"SF", @"IN",
        ];
    });
    for (NSString *prefix in prefixes) {
        if ([className hasPrefix:prefix]) return YES;
    }
    return NO;
}

// Game-side priority: Miniclip's own classes live here. Phase 1 scans
// only these; phase 2 scans the rest (minus excluded prefixes).
BOOL PADiscoveryPriority(NSString *className) {
    static NSArray<NSString *> *markers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = @[
            @"game", @"manager", @"menu", @"user", @"pool", @"table",
            @"match", @"cue", @"miniclip", @"payment", @"purchase",
            @"receipt", @"attest", @"fraud", @"integrity", @"tamper",
            @"jailbreak", @"verify", @"licens", @"drm", @"protect",
            @"threat", @"alert", @"dialog", @"popup", @"account",
            @"login", @"session", @"auth", @"menustate", @"unofficial",
        ];
    });
    NSString *lower = className.lowercaseString;
    for (NSString *marker in markers) {
        if ([lower containsString:marker]) return YES;
    }
    return NO;
}

BOOL PADiscoveryMatch(NSString *name) {
    static NSArray<NSString *> *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"receipt", @"attest", @"devicecheck", @"jailbreak",
            @"jailbroken", @"fraud", @"tamper", @"integrity",
            @"unofficial", @"validat", @"verify", @"appstore",
            @"app_store", @"storekit", @"exitapp", @"forceclose",
            @"terminate", @"killapp", @"closeself", @"shutdown",
            @"untrusted", @"pirat", @"crack", @"cheat", @"hack",
            @"debugger", @"ptrace", @"sysctl", @"fork", @"cydia",
            @"substrate", @"dylib", @"imagecount", @"loadedimage",
            @"bundleid", @"provision", @"entitle", @"sandbox",
            @"fairplay", @"drm", @"menustate", @"popup", @"dialog",
            @"threat", @"protect", @"licens", @"payment", @"purchase",
            @"ref", @"close", @"account", @"session",
        ];
    });
    NSString *lower = name.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lower containsString:keyword]) return YES;
    }
    return NO;
}

// Auto-hook: for high-confidence verdict selectors (no-arg, BOOL/void
// return, hostile keyword in the name), neutralize immediately and log.
// Type encoding is checked first, so only provably compatible methods
// are touched.
BOOL PAAutoHookVerdict(Class target, NSString *className,
                       NSString *selName, Method method) {
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding) return NO;
    if (strlen(encoding) < 3 || encoding[1] != '@' || encoding[2] != ':') {
        return NO;
    }
    if (strlen(encoding) > 4) return NO;
    const char ret = encoding[0];
    const BOOL isBool = (ret == 'B' || ret == 'c');
    const BOOL isVoid = (ret == 'v');
    if (!isBool && !isVoid) return NO;

    NSString *lower = selName.lowercaseString;
    NSArray<NSString *> *badWords = @[
        @"jailbreak", @"jailbroken", @"tamper", @"fraud", @"cheat",
        @"hack", @"debugger", @"cydia", @"substrate", @"pirat",
        @"crack", @"untrust", @"unofficial",
    ];
    NSArray<NSString *> *goodWords = @[
        @"appstore", @"app_store", @"genuine", @"legit", @"official",
    ];
    BOOL hostile = NO;
    for (NSString *w in badWords) {
        if ([lower containsString:w]) { hostile = YES; break; }
    }
    BOOL benign = NO;
    for (NSString *w in goodWords) {
        if ([lower containsString:w]) { benign = YES; break; }
    }

    @try {
        if (isBool && hostile &&
            ([lower hasPrefix:@"is"] || [lower hasPrefix:@"can"] ||
             [lower hasPrefix:@"has"] || [lower hasPrefix:@"should"] ||
             [lower containsString:@"detect"])) {
            IMP stub = imp_implementationWithBlock(^BOOL(id _self) {
                (void)_self;
                return NO;
            });
            method_setImplementation(method, stub);
            PALog(@"autohook -[%@ %@] -> NO", className, selName);
            return YES;
        }
        if (isBool && benign &&
            ([lower hasPrefix:@"is"] || [lower hasPrefix:@"can"] ||
             [lower hasPrefix:@"has"])) {
            IMP stub = imp_implementationWithBlock(^BOOL(id _self) {
                (void)_self;
                return YES;
            });
            method_setImplementation(method, stub);
            PALog(@"autohook -[%@ %@] -> YES", className, selName);
            return YES;
        }
        if (isVoid && hostile &&
            ([lower hasPrefix:@"set"] || [lower hasPrefix:@"enable"] ||
             [lower hasPrefix:@"disable"] || [lower hasPrefix:@"check"] ||
             [lower hasPrefix:@"verify"] || [lower hasPrefix:@"report"] ||
             [lower hasPrefix:@"perform"])) {
            IMP stub = imp_implementationWithBlock(^(id _self) {
                (void)_self;
            });
            method_setImplementation(method, stub);
            PALog(@"autohook -[%@ %@] -> noop", className, selName);
            return YES;
        }
    } @catch (NSException *e) {
        PALog(@"autohook -[%@ %@] exception %@", className, selName, e);
    }
    return NO;
}

void PADiscoveryScan(Class *classes, int classCount, BOOL priorityOnly,
                     NSUInteger *lines) {
    for (int ci = 0; ci < classCount && *lines < kMaxLines; ci++) {
        Class cls = classes[ci];
        if (!cls) continue;
        const char *imageName = class_getImageName(cls);
        if (!imageName) continue;
        NSString *imagePath =
            [NSString stringWithUTF8String:imageName];
        if (![imagePath hasSuffix:@"/pool.app/pool"]) continue;

        NSString *className = NSStringFromClass(cls);
        // Priority game classes are never excluded (e.g. SKPaymentsReceiver
        // matches the SK* system-looking prefix but is Miniclip's own).
        const BOOL priority = PADiscoveryPriority(className);
        if (!priority && PADiscoveryExcluded(className)) continue;
        if (priorityOnly != priority) continue;

        const BOOL classHit = PADiscoveryMatch(className);
        for (int pass = 0; pass < 2 && *lines < kMaxLines; pass++) {
            Class target =
                (pass == 0) ? cls : object_getClass(cls);
            if (!target) continue;
            unsigned int methodCount = 0;
            Method *methods =
                class_copyMethodList(target, &methodCount);
            if (!methods) continue;
            for (unsigned int mi = 0;
                 mi < methodCount && *lines < kMaxLines; mi++) {
                NSString *selName =
                    NSStringFromSelector(method_getName(methods[mi]));
                if (classHit || PADiscoveryMatch(selName)) {
                    PALog(@"discover %@[%@ %@]", pass == 0 ? @"-" : @"+",
                          className, selName);
                    (*lines)++;
                    if (pass == 0) {
                        PAAutoHookVerdict(target, className, selName,
                                          methods[mi]);
                    }
                }
            }
            free(methods);
        }
    }
}

}  // namespace

@implementation PADiscovery

+ (void)run {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Off the main thread: full runtime enumeration blocks ~2s.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self runInBackground];
        });
    });
}

+ (void)runInBackground {
    @try {
        PALog(@"stage=discovery begin");
        int poolIndex = -1;
        const uint32_t total = _dyld_image_count();
        for (uint32_t i = 0; i < total; i++) {
            const char *name = _dyld_get_image_name(i);
            if (name) {
                NSString *path =
                    [NSString stringWithUTF8String:name];
                if ([path hasSuffix:@"/pool.app/pool"]) {
                    poolIndex = (int)i;
                    break;
                }
            }
        }
        if (poolIndex < 0) {
            PALog(@"stage=discovery result=no-pool-image");
            return;
        }

        int classCount = objc_getClassList(NULL, 0);
        // iOS 26 processes host 100k+ classes with the shared cache;
        // only the old absurd cap was wrong, not the count.
        if (classCount <= 0 || classCount > 500000) {
            PALog(@"stage=discovery result=bad-count %d", classCount);
            return;
        }
        Class *classes =
            (Class *)calloc((size_t)classCount, sizeof(Class));
        if (!classes) return;
        classCount = objc_getClassList(classes, classCount);

        // Phase 1: game classes first (Miniclip's verdict lives here).
        NSUInteger lines = 0;
        PADiscoveryScan(classes, classCount, YES, &lines);
        // Phase 2: everything else still matching.
        PADiscoveryScan(classes, classCount, NO, &lines);
        free(classes);
        PALog(@"stage=discovery result=done lines=%lu", (unsigned long)lines);
    } @catch (NSException *e) {
        PALog(@"stage=discovery result=exception %@", e);
    }
}

@end
