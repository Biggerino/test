#import <UIKit/UIKit.h>
#import "PAIntegrityBypass.h"
#import "PAStoreInterceptor.h"
#import "PAOverlayView.h"
#import "PAAdminPanel.h"
#import "PARuntimeBridge.h"

// Returns YES once the game has a live account (UserInfo initialized).
// The tweak stays completely invisible until then: no button, no panel,
// no overlay. Integrity/store hooks still install at boot (they must run
// before login to suppress the tamper popup).
static BOOL PAAccountReady(void) {
    @try {
        NSDictionary *summary = [PARuntimeBridge.shared playerSummary];
        return [summary[@"ready"] boolValue];
    } @catch (NSException *e) {
        return NO;
    }
}

// Feature flags (read from pool.app/PoolAdminConfig.plist, all default YES).
// Allows isolating a crashing subsystem without rebuilding: ship an IPA
// with a flag set to NO and that subsystem never loads.
static BOOL PAFlagEnabled(NSString *key) {
    @try {
        NSString *path = [NSBundle.mainBundle pathForResource:@"PoolAdminConfig" ofType:@"plist"];
        NSDictionary *cfg = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        id val = cfg[key];
        if (!val) return YES;
        if ([val respondsToSelector:@selector(boolValue)]) return [val boolValue];
        return YES;
    } @catch (NSException *e) {
        return YES;
    }
}

// Forward declarations
static void PAAttachViewsToWindow(int retryCount);
static UIWindow *PAFindBestWindow(void);

// Window lookup. keyWindow/windows only — no UIScene API references, so the
// binary has zero weak-linked data symbols and loads on any iOS our min
// deployment target supports. Never crashes: returns nil when UIKit isn't
// ready so the caller retries.
static UIWindow *PAFindBestWindow(void) {
    @try {
        UIApplication *app = nil;
        @try {
            app = UIApplication.sharedApplication;
        } @catch (NSException *e) {
            return nil;
        }
        if (!app) return nil;

        @try {
            UIWindow *key = app.keyWindow;
            if (key && !key.isHidden && key.bounds.size.width > 0) return key;
        } @catch (NSException *e) {}
        @try {
            for (UIWindow *w in app.windows) {
                if (!w.isHidden && w.bounds.size.width > 0) return w;
            }
        } @catch (NSException *e) {}
        @try {
            id delegate = app.delegate;
            if ([delegate respondsToSelector:@selector(window)]) {
                UIWindow *dw = [delegate valueForKey:@"window"];
                if ([dw isKindOfClass:UIWindow.class] && !dw.isHidden &&
                    ((UIWindow *)dw).bounds.size.width > 0) return dw;
            }
        } @catch (NSException *e) {}
    } @catch (NSException *e) {
        NSLog(@"[PoolAdmin] window lookup exception: %@", e);
    }
    return nil;
}

static void PAAttachViewsToWindow(int retryCount) {
    if (retryCount <= 0) {
        NSLog(@"[PoolAdmin] stage=attach result=no-window");
        return;
    }

    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PAAttachViewsToWindow(retryCount);
        });
        return;
    }

    UIWindow *window = PAFindBestWindow();
    if (!window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PAAttachViewsToWindow(retryCount - 1);
        });
        return;
    }

    // Stay invisible until the account is live. Keeps polling (up to the
    // retry budget) through login screens, loading, and menu.
    if (!PAAccountReady()) {
        NSLog(@"[PoolAdmin] stage=attach result=waiting-for-login");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PAAttachViewsToWindow(retryCount - 1);
        });
        return;
    }

    // Overlay and panel boot independently: if one throws, the other still loads.
    if (PAFlagEnabled(@"PAEnableOverlay")) {
        @try {
            [[PAOverlayView shared] attachToWindow:window];
            NSLog(@"[PoolAdmin] stage=overlay result=ok");
        } @catch (NSException *exception) {
            NSLog(@"[PoolAdmin] stage=overlay result=exception %@", exception);
        }
    } else {
        NSLog(@"[PoolAdmin] stage=overlay result=disabled");
    }

    if (PAFlagEnabled(@"PAEnablePanel")) {
        @try {
            [[PAAdminPanel shared] attachToWindow:window];
            NSLog(@"[PoolAdmin] stage=panel result=ok");
        } @catch (NSException *exception) {
            NSLog(@"[PoolAdmin] stage=panel result=exception %@", exception);
        }
    } else {
        NSLog(@"[PoolAdmin] stage=panel result=disabled");
    }
    NSLog(@"[PoolAdmin] stage=attach result=done");
}

// Re-attach when a new window becomes visible. Attach methods are idempotent.
static void PAInstallWindowObserver(void) {
    @try {
        [NSNotificationCenter.defaultCenter
            addObserverForName:@"UIWindowDidBecomeVisibleNotification"
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            @try {
                if (!PAAccountReady()) return;
                UIWindow *w = [note.object isKindOfClass:UIWindow.class]
                    ? (UIWindow *)note.object : PAFindBestWindow();
                if (w && !w.isHidden) {
                    if (PAFlagEnabled(@"PAEnableOverlay")) {
                        @try { [[PAOverlayView shared] attachToWindow:w]; }
                        @catch (NSException *e) {}
                    }
                    if (PAFlagEnabled(@"PAEnablePanel")) {
                        @try { [[PAAdminPanel shared] attachToWindow:w]; }
                        @catch (NSException *e) {}
                    }
                }
            } @catch (NSException *e) {}
        }];
    } @catch (NSException *e) {}
}

static void PABootFromNotification(void) {
    NSLog(@"[PoolAdmin] stage=boot begin");

    if (PAFlagEnabled(@"PAEnableIntegrityBypass")) {
        @try {
            [PAIntegrityBypass install];
            NSLog(@"[PoolAdmin] stage=bypass result=ok");
        } @catch (NSException *exception) {
            NSLog(@"[PoolAdmin] stage=bypass result=exception %@", exception);
        }
    } else {
        NSLog(@"[PoolAdmin] stage=bypass result=disabled");
    }

    if (PAFlagEnabled(@"PAEnableStoreHooks")) {
        @try {
            [PAStoreInterceptor install];
            NSLog(@"[PoolAdmin] stage=store result=ok");
        } @catch (NSException *exception) {
            NSLog(@"[PoolAdmin] stage=store result=exception %@", exception);
        }
    } else {
        NSLog(@"[PoolAdmin] stage=store result=disabled");
    }

    PAInstallWindowObserver();
    // Delay lets the game finish creating its window. Large retry budget:
    // the UI stays hidden until login completes, however long that takes.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PAAttachViewsToWindow(90);
    });
}

// NOTE: constructor intentionally does the bare minimum — registers ONE
// observer using only stringly-typed API names available since iOS 2.
// No UIScene symbols, no UIKit class references, no view code here.
static void __attribute__((constructor)) PAPoolAdminInit(void) {
    NSLog(@"[PoolAdmin] stage=init begin");
    @try {
        __block id finishObserver = nil;
        void (^bootOnce)(void) = ^{
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                @try {
                    if (finishObserver) {
                        [NSNotificationCenter.defaultCenter removeObserver:finishObserver];
                        finishObserver = nil;
                    }
                } @catch (NSException *e) {}
                if (NSThread.isMainThread) {
                    PABootFromNotification();
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        PABootFromNotification();
                    });
                }
            });
        };

        finishObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            (void)note;
            dispatch_async(dispatch_get_main_queue(), ^{
                bootOnce();
            });
        }];

        // Safety net if the notification never fires (late injection).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                bootOnce();
            });
        });
        NSLog(@"[PoolAdmin] stage=init result=ok");
    } @catch (NSException *exception) {
        NSLog(@"[PoolAdmin] stage=init result=exception %@", exception);
    }
}
