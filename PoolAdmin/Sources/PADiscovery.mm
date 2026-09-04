#import "PADiscovery.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "PALogger.h"

namespace {

const NSUInteger kMaxLines = 400;

BOOL PADiscoveryMatch(NSString *name) {    static NSArray<NSString *> *keywords;
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
            @"fairplay", @"drm",
        ];
    });
    NSString *lower = name.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lower containsString:keyword]) return YES;
    }
    return NO;
}

}  // namespace

// Auto-hook: for high-confidence verdict selectors (no-arg, BOOL/void
// return, hostile keyword in the name), neutralize immediately and log.
// Type encoding is checked first, so only provably compatible methods
// are touched. Runs on the background queue; method_setImplementation
// is thread-safe for distinct methods.
static BOOL PAAutoHookVerdict(Class target, NSString *className,
                              NSString *selName, Method method) {
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding) return NO;
    // No-arg methods only: encodings look like "B@:" / "c@:" / "v@:".
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
        @"crack", @"untrust", @" unofficial",
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

        NSUInteger lines = 0;
        for (int ci = 0; ci < classCount && lines < kMaxLines; ci++) {
            Class cls = classes[ci];
            if (!cls) continue;
            const char *imageName = class_getImageName(cls);
            if (!imageName) continue;
            NSString *imagePath =
                [NSString stringWithUTF8String:imageName];
            if (![imagePath hasSuffix:@"/pool.app/pool"]) continue;

            NSString *className = NSStringFromClass(cls);
            const BOOL classHit = PADiscoveryMatch(className);

            // Instance + class methods.
            for (int pass = 0; pass < 2 && lines < kMaxLines; pass++) {
                Class target =
                    (pass == 0) ? cls : object_getClass(cls);
                if (!target) continue;
                unsigned int methodCount = 0;
                Method *methods =
                    class_copyMethodList(target, &methodCount);
                if (!methods) continue;
                for (unsigned int mi = 0;
                     mi < methodCount && lines < kMaxLines; mi++) {
                    NSString *selName =
                        NSStringFromSelector(method_getName(methods[mi]));
                    if (classHit || PADiscoveryMatch(selName)) {
                        PALog(@"discover %@[%@ %@]", pass == 0 ? @"-" : @"+",
                              className, selName);
                        lines++;
                        // Instance methods only (pass 0): try immediate
                        // neutralization; class methods are logged for
                        // the next targeted build.
                        if (pass == 0) {
                            PAAutoHookVerdict(target, className, selName,
                                              methods[mi]);
                        }
                    }
                }
                free(methods);
            }
        }
        free(classes);
        PALog(@"stage=discovery result=done lines=%lu", (unsigned long)lines);
    } @catch (NSException *e) {
        PALog(@"stage=discovery result=exception %@", e);
    }
}

@end
