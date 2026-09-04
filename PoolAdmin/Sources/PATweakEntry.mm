#import <UIKit/UIKit.h>
#import "PAImageHider.h"
#import "PADiscovery.h"
#import "PAIntegrityBypass.h"
#import "PAStoreInterceptor.h"
#import "PAOverlayView.h"
#import "PAAdminPanel.h"
#import "PARuntimeBridge.h"
#import "PALogger.h"

// Returns YES once the game has a LIVE account (a real user id).
// NOTE: the UserInfo singleton exists from launch with no user, so `ready`
// alone is true on the Terms screen — gate on an actual user id instead.
// The tweak stays completely invisible until then: no button, no panel,
// no overlay. Integrity/store hooks still install at boot (they must run
// before login to suppress the tamper popup).
static BOOL PAAccountReady(void) {
    @try {
        NSDictionary *summary = [PARuntimeBridge.shared playerSummary];
        id userId = summary[@"userId"];
        return [userId isKindOfClass:NSString.class] &&
               [(NSString *)userId length] > 0;
    } @catch (NSException *e) {
        return NO;
    }
}

// Feature flags (read from pool.app/PoolAdminConfig.plist, all default YES
// except store hooks, which are opt-in: set PAEnableStoreHooks to true to
// enable free-StoreKit interception).
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

// Opt-in flags: missing key means NO. Used for invasive hooks.
static BOOL PAFlagOptIn(NSString *key) {
    @try {
        NSString *path = [NSBundle.mainBundle pathForResource:@"PoolAdminConfig" ofType:@"plist"];
        NSDictionary *cfg = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        id val = cfg[key];
        if (!val) return NO;
        if ([val respondsToSelector:@selector(boolValue)]) return [val boolValue];
        return NO;
    } @catch (NSException *e) {
        return NO;
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
        PALog(@"window lookup exception: %@", e);
    }
    return nil;
}

// Auto-pilot: before login, poll for the onboarding buttons (Terms
// "Accept", "Play as Guest") and tap the first visible one. Beats the
// freeze window without the user racing it. Pure UIKit search — if the
// game draws these in Cocos it finds nothing and stays idle (logged).
static UIButton *PAFindButton(UIView *view, NSArray<NSString *> *titles) {
    @try {
        if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)view;
            NSString *title = button.currentTitle ?: @"";
            NSString *label = button.accessibilityLabel ?: @"";
            NSString *both = [NSString stringWithFormat:@"%@ %@", title, label];
            for (NSString *want in titles) {
                if ([both localizedCaseInsensitiveContainsString:want]) {
                    return button;
                }
            }
        }
        for (UIView *sub in view.subviews) {
            UIButton *found = PAFindButton(sub, titles);
            if (found) return found;
        }
    } @catch (NSException *e) {}
    return nil;
}

static void PAAutoPilotTick(int remaining) {
    if (remaining <= 0) return;
    if (PAAccountReady()) {
        PALog(@"autopilot stop: logged in");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            UIWindow *window = PAFindBestWindow();
            UIButton *button = window ? PAFindButton(
                window, @[@"Accept", @"Play as Guest"]) : nil;
            if (button && button.enabled && !button.hidden &&
                button.alpha > 0.01 && button.window) {
                PALog(@"autopilot tapping '%@'",
                      button.currentTitle ?: @"?");
                [button sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        } @catch (NSException *e) {
            PALog(@"autopilot exception %@", e);
        }
        PAAutoPilotTick(remaining - 1);
    });
}

static void PAAttachViewsToWindow(int retryCount) {
    if (retryCount <= 0) {
        PALog(@"stage=attach result=no-window");
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
        PALog(@"stage=attach result=waiting-for-login");
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
            PALog(@"stage=overlay result=ok");
        } @catch (NSException *exception) {
            PALog(@"stage=overlay result=exception %@", exception);
        }
    } else {
        PALog(@"stage=overlay result=disabled");
    }

    if (PAFlagEnabled(@"PAEnablePanel")) {
        @try {
            [[PAAdminPanel shared] attachToWindow:window];
            PALog(@"stage=panel result=ok");
        } @catch (NSException *exception) {
            PALog(@"stage=panel result=exception %@", exception);
        }
    } else {
        PALog(@"stage=panel result=disabled");
    }
    PALog(@"stage=attach result=done");
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
    PALog(@"stage=boot begin");
    PAStartHeartbeat();

    // Hide our image from dyld/NSBundle enumeration FIRST, before any
    // other hook runs — the game's local checks scan for foreign images.
    @try {
        [PAImageHider install];
    } @catch (NSException *exception) {
        PALog(@"stage=hider result=exception %@", exception);
    }

    // Swallow the delayed-kill suicide calls (exit/_exit/abort/kill-self).
    @try {
        [PAExitGuard install];
    } @catch (NSException *exception) {
        PALog(@"stage=exitguard result=exception %@", exception);
    }

    // Read-only recon: dump the game's own integrity selector names so
    // the bypass can target them precisely instead of guessing.
    @try {
        [PADiscovery run];
    } @catch (NSException *exception) {
        PALog(@"stage=discovery result=exception %@", exception);
    }

    if (PAFlagEnabled(@"PAEnableIntegrityBypass")) {
        @try {
            [PAIntegrityBypass install];
            PALog(@"stage=bypass result=ok");
        } @catch (NSException *exception) {
            PALog(@"stage=bypass result=exception %@", exception);
        }
    } else {
        PALog(@"stage=bypass result=disabled");
    }

    if (PAFlagOptIn(@"PAEnableStoreHooks")) {
        @try {
            [PAStoreInterceptor install];
            PALog(@"stage=store result=ok");
        } @catch (NSException *exception) {
            PALog(@"stage=store result=exception %@", exception);
        }
    } else {
        PALog(@"stage=store result=skipped-opt-in");
    }

    PAInstallWindowObserver();
    // Auto-pilot covers onboarding for ~60s or until login.
    PAAutoPilotTick(120);
    // Lifecycle markers: distinguish user/OS backgrounding and orderly
    // termination from sudden silent death (direct-syscall exit leaves
    // no crash log, but it also never posts WillTerminate).
    @try {
        [NSNotificationCenter.defaultCenter
            addObserverForName:@"UIApplicationDidEnterBackgroundNotification"
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            (void)note;
            PALog(@"lifecycle did-enter-background");
        }];
        [NSNotificationCenter.defaultCenter
            addObserverForName:@"UIApplicationWillTerminateNotification"
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            (void)note;
            PALog(@"lifecycle will-terminate");
        }];
    } @catch (NSException *e) {}
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
    PALog(@"stage=init begin");
    // Install hiding + exit guard IMMEDIATELY here, not at boot: the
    // game's pre-main integrity scan runs before DidFinishLaunching, so
    // boot-time installation is too late to blind it. Our image is a
    // dependency of the main executable, so this constructor runs before
    // the main image's own initializers.
    @try {
        [PAImageHider install];
    } @catch (NSException *e) {}
    @try {
        [PAExitGuard install];
    } @catch (NSException *e) {}
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
        PALog(@"stage=init result=ok");
    } @catch (NSException *exception) {
        PALog(@"stage=init result=exception %@", exception);
    }
}
