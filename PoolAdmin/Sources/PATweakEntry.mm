#import <UIKit/UIKit.h>
#import "PAIntegrityBypass.h"
#import "PAStoreInterceptor.h"
#import "PAOverlayView.h"
#import "PAAdminPanel.h"

// Forward declarations
static void PAAttachViewsToWindow(int retryCount);
static UIWindow *PAFindBestWindow(void);

// Scene-aware window lookup. Works on iOS 11 (keyWindow) through iOS 13+
// (UIScene). Never returns a hidden window. Never crashes if UIKit isn't
// ready yet — returns nil so the caller can retry.
static UIWindow *PAFindBestWindow(void) {
    @try {
        UIApplication *app = UIApplication.sharedApplication;
        if (!app) return nil;

        // iOS 13+: walk connected scenes for the foreground active window.
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in app.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState != UISceneActivationStateForegroundActive &&
                    ws.activationState != UISceneActivationStateForegroundInactive) {
                    continue;
                }
                for (UIWindow *w in ws.windows) {
                    if (!w.isHidden && w.bounds.size.width > 0) return w;
                }
            }
            // Fallback: any visible window in any scene.
            for (UIScene *scene in app.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (!w.isHidden && w.bounds.size.width > 0) return w;
                }
            }
        }

        // iOS 11/12 path + final fallback.
        UIWindow *key = app.keyWindow;
        if (key && !key.isHidden) return key;
        for (UIWindow *w in app.windows) {
            if (!w.isHidden && w.bounds.size.width > 0) return w;
        }
        // Last resort: app delegate window (works before scenes attach).
        id delegate = app.delegate;
        if ([delegate respondsToSelector:@selector(window)]) {
            UIWindow *dw = [delegate valueForKey:@"window"];
            if ([dw isKindOfClass:UIWindow.class] && !dw.isHidden) return dw;
        }
    } @catch (NSException *e) {
        NSLog(@"[PoolAdmin] window lookup exception: %@", e);
    }
    return nil;
}

static void PAAttachViewsToWindow(int retryCount) {
    if (retryCount <= 0) {
        NSLog(@"[PoolAdmin] Failed to find window after retries.");
        return;
    }

    // All UIKit work must be on the main thread.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PAAttachViewsToWindow(retryCount);
        });
        return;
    }

    UIWindow *window = PAFindBestWindow();
    if (!window) {
        // Retry after 1 second
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PAAttachViewsToWindow(retryCount - 1);
        });
        return;
    }

    @try {
        // Avoid double-attach (e.g. scene reconnect fires twice).
        [[PAOverlayView shared] attachToWindow:window];
        [[PAAdminPanel shared] attachToWindow:window];
        NSLog(@"[PoolAdmin] Tweak loaded successfully.");
    } @catch (NSException *exception) {
        NSLog(@"[PoolAdmin] Exception attaching views: %@", exception);
    }
}

// Re-attach when a new window becomes visible (scene connect, rotation,
// external display, etc.). The attach methods are idempotent.
static void PAInstallWindowObserver(void) {
    @try {
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIWindowDidBecomeVisibleNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            @try {
                UIWindow *w = [note.object isKindOfClass:UIWindow.class]
                    ? (UIWindow *)note.object : PAFindBestWindow();
                if (w && !w.isHidden) {
                    [[PAOverlayView shared] attachToWindow:w];
                    [[PAAdminPanel shared] attachToWindow:w];
                }
            } @catch (NSException *e) {}
        }];
    } @catch (NSException *e) {}
}

static void PABootFromNotification(void) {
    @try {
        [PAIntegrityBypass install];
    } @catch (NSException *exception) {
        NSLog(@"[PoolAdmin] Integrity bypass exception: %@", exception);
    }

    @try {
        [PAStoreInterceptor install];
    } @catch (NSException *exception) {
        NSLog(@"[PoolAdmin] Store interceptor exception: %@", exception);
    }

    PAInstallWindowObserver();
    // Small delay lets the game finish creating its window/scene.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PAAttachViewsToWindow(15); // Try up to ~15 seconds
    });
}

static void __attribute__((constructor)) PAPoolAdminInit(void) {
    NSLog(@"[PoolAdmin] Initializing...");
    @try {
        // Do NOT touch UIApplication.sharedApplication here — at constructor
        // time UIKit may not be ready and keyWindow calls can deadlock/crash.
        // Defer everything until the app finishes launching.
        __block id finishObserver = nil;
        __block id sceneObserver = nil;
        void (^bootOnce)(void) = ^{
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                if (finishObserver) {
                    [NSNotificationCenter.defaultCenter removeObserver:finishObserver];
                    finishObserver = nil;
                }
                if (sceneObserver) {
                    [NSNotificationCenter.defaultCenter removeObserver:sceneObserver];
                    sceneObserver = nil;
                }
                // Always boot on main thread.
                if (NSThread.isMainThread) {
                    PABootFromNotification();
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        PABootFromNotification();
                    });
                }
            });
        };

        // Normal path: app posts this once UIKit is up.
        finishObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            // Push boot to the next runloop turn so the game window exists.
            dispatch_async(dispatch_get_main_queue(), ^{
                bootOnce();
            });
        }];

        // Scene-based apps (iOS 13+) may launch without the above posting
        // before our observer registers — also listen for scene connect.
        if (@available(iOS 13.0, *)) {
            sceneObserver = [NSNotificationCenter.defaultCenter
                addObserverForName:UISceneWillConnectNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    bootOnce();
                });
            }];
        }

        // Safety net: if neither notification ever fires (e.g. injected very
        // late), boot after 5s anyway. bootOnce's dispatch_once makes this
        // harmless if the normal path already ran.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                bootOnce();
            });
        });
    } @catch (NSException *exception) {
        NSLog(@"[PoolAdmin] Init exception: %@", exception);
    }
}
