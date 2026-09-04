// Minimal load-test dylib: proves whether ANY custom binary loads in this
// slot, independent of all PoolAdmin subsystems. Constructor only logs.
// If an IPA with this file STILL dies with CODESIGNING/Invalid Page, the
// cause is packaging/signing/toolchain — not PoolAdmin code.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static void __attribute__((constructor)) PAMinimalInit(void) {
    NSLog(@"[PoolAdmin-min] stage=init alive");
    @try {
        [NSNotificationCenter.defaultCenter
            addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            (void)note;
            NSLog(@"[PoolAdmin-min] stage=launched ok");
        }];
    } @catch (NSException *e) {
        NSLog(@"[PoolAdmin-min] stage=init exception %@", e);
    }
}
