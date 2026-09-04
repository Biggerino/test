#import "PADiscovery.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "PALogger.h"

namespace {

const NSUInteger kMaxLines = 400;

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
    });
}

@end
