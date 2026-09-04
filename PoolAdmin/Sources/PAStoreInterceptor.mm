#import "PAStoreInterceptor.h"

#import <StoreKit/StoreKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "PARuntimeBridge.h"
#import "PAGrantService.h"

// ---------------------------------------------------------------------------
#pragma mark - Product → Grant Mapping
// ---------------------------------------------------------------------------

static NSArray<NSDictionary *> *GrantsForProductIdentifier(NSString *productId) {
    NSString *pid = productId.lowercaseString;

    // Currency packs
    if ([pid containsString:@"coin"] || [pid containsString:@"gold"]) {
        NSScanner *scanner = [NSScanner scannerWithString:pid];
        long long amount = 0;
        while (!scanner.isAtEnd) {
            if ([scanner scanLongLong:&amount] && amount > 0) break;
            [scanner setScanLocation:scanner.scanLocation + 1];
        }
        if (amount <= 0) amount = 100000;
        return @[@{@"kind": @"coins", @"amount": @(amount)}];
    }
    if ([pid containsString:@"cash"] || [pid containsString:@"gem"] || [pid containsString:@"diamond"]) {
        NSScanner *scanner = [NSScanner scannerWithString:pid];
        long long amount = 0;
        while (!scanner.isAtEnd) {
            if ([scanner scanLongLong:&amount] && amount > 0) break;
            [scanner setScanLocation:scanner.scanLocation + 1];
        }
        if (amount <= 0) amount = 500;
        return @[@{@"kind": @"cash", @"amount": @(amount)}];
    }

    // Cues
    if ([pid containsString:@"cue"]) {
        return @[@{@"kind": @"cue", @"productId": productId, @"amount": @1}];
    }

    // Passes
    if ([pid containsString:@"pass"] || [pid containsString:@"season"] || [pid containsString:@"elite"]) {
        return @[
            @{@"kind": @"season_pass", @"amount": @1},
            @{@"kind": @"elite_pass", @"amount": @1},
            @{@"kind": @"pool_points", @"productId": @"38156", @"amount": @5000},
        ];
    }

    // VIP
    if ([pid containsString:@"vip"]) {
        return @[@{@"kind": @"vip_points", @"amount": @5000}];
    }

    // Minigames
    if ([pid containsString:@"spin"] || [pid containsString:@"wheel"]) {
        return @[@{@"kind": @"spin", @"productId": productId, @"amount": @10}];
    }
    if ([pid containsString:@"scratch"]) {
        return @[@{@"kind": @"scratcher", @"productId": productId, @"amount": @10}];
    }
    if ([pid containsString:@"golden_shot"] || [pid containsString:@"goldenshot"]) {
        return @[@{@"kind": @"golden_shot", @"productId": productId, @"amount": @5}];
    }
    if ([pid containsString:@"lucky"]) {
        return @[@{@"kind": @"lucky_shot", @"productId": productId, @"amount": @5}];
    }

    // Boxes / chests
    if ([pid containsString:@"box"] || [pid containsString:@"victory"] || [pid containsString:@"chest"]) {
        return @[@{@"kind": @"victory_box", @"productId": productId, @"amount": @3}];
    }

    // Cosmetics
    if ([pid containsString:@"avatar"]) {
        return @[@{@"kind": @"avatar", @"productId": productId, @"amount": @1}];
    }
    if ([pid containsString:@"decal"]) {
        return @[@{@"kind": @"decal", @"productId": productId, @"amount": @1}];
    }

    // Bundles / offers
    if ([pid containsString:@"bundle"] || [pid containsString:@"offer"] ||
        [pid containsString:@"pack"] || [pid containsString:@"starter"] ||
        [pid containsString:@"deal"]) {
        return @[
            @{@"kind": @"coins", @"amount": @500000},
            @{@"kind": @"cash", @"amount": @2000},
            @{@"kind": @"xp", @"amount": @50000},
        ];
    }

    // Default fallback
    return @[
        @{@"kind": @"coins", @"amount": @100000},
        @{@"kind": @"cash", @"amount": @500},
    ];
}

// ---------------------------------------------------------------------------
#pragma mark - Toast Notification
// ---------------------------------------------------------------------------

static void ShowToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *window = nil;
            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if (![scene isKindOfClass:UIWindowScene.class]) continue;
                    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                        if (!w.isHidden) { window = w; break; }
                    }
                    if (window) break;
                }
            }
            if (!window) window = UIApplication.sharedApplication.keyWindow;
            if (!window) {
                for (UIWindow *w in UIApplication.sharedApplication.windows) {
                    if (!w.isHidden) { window = w; break; }
                }
            }
            if (!window) return;

            UILabel *toast = [UILabel new];
            toast.text = message;
            toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            toast.textColor = UIColor.whiteColor;
            toast.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
            toast.textAlignment = NSTextAlignmentCenter;
            toast.layer.cornerRadius = 10;
            toast.clipsToBounds = YES;
            toast.alpha = 0;
            toast.translatesAutoresizingMaskIntoConstraints = NO;

            [window addSubview:toast];
            [NSLayoutConstraint activateConstraints:@[
                [toast.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
                [toast.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-20],
                [toast.widthAnchor constraintLessThanOrEqualToAnchor:window.widthAnchor multiplier:0.85],
                [toast.heightAnchor constraintGreaterThanOrEqualToConstant:38],
            ]];

            [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                toast.alpha = 1;
                toast.transform = CGAffineTransformIdentity;
            } completion:^(BOOL finished) {
                [UIView animateWithDuration:0.3 delay:2.0 options:UIViewAnimationOptionCurveEaseIn animations:^{
                    toast.alpha = 0;
                    toast.transform = CGAffineTransformMakeTranslation(0, 20);
                } completion:^(BOOL done) {
                    [toast removeFromSuperview];
                }];
            }];
        } @catch (NSException *e) {
            // Safe catch
        }
    });
}

// ---------------------------------------------------------------------------
#pragma mark - Swizzle Storage
// ---------------------------------------------------------------------------

static IMP sOriginal_addPayment = NULL;
static IMP sOriginal_canMakePayments = NULL;

// ---------------------------------------------------------------------------
#pragma mark - Replacement Implementations
// ---------------------------------------------------------------------------

static void PA_addPayment(id self, SEL _cmd, id payment) {
    @try {
        NSString *productId = nil;
        SEL productIdentifierSel = NSSelectorFromString(@"productIdentifier");
        if ([payment respondsToSelector:productIdentifierSel]) {
            productId = ((id(*)(id, SEL))objc_msgSend)(payment, productIdentifierSel);
        }
        if (!productId.length) {
            if (sOriginal_addPayment) {
                ((void(*)(id, SEL, id))sOriginal_addPayment)(self, _cmd, payment);
            }
            return;
        }

        NSLog(@"[PoolAdmin] Intercepted purchase: %@", productId);

        // Grant the items directly
        NSArray *grants = GrantsForProductIdentifier(productId);
        [[PAGrantService shared] grantItems:grants completion:^(BOOL success, NSString *message, NSDictionary *response) {
            if (success) {
                ShowToast([NSString stringWithFormat:@"\u2705 %@ — Free!", productId]);
            } else {
                ShowToast([NSString stringWithFormat:@"\u26A0\uFE0F %@ — %@", productId, message ?: @"Grant failed"]);
            }
        }];

        // Notify the payment queue observers and game flow.
        // We swallow the real purchase (never call the original, so the user
        // is never charged) but must still wake up any game code waiting on
        // paymentQueue:updatedTransactions: or purchaseCompleted, otherwise
        // the shop UI can hang on a spinner forever.
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"SKPaymentTransactionPurchased"
                                                                    object:nil
                                                                  userInfo:@{@"productIdentifier": productId}];

                // Best-effort: poke SKPaymentQueue observers with a fake
                // purchased transaction so stock game code completes.
                @try {
                    Class queueClass = NSClassFromString(@"SKPaymentQueue");
                    SEL defaultQueueSel = NSSelectorFromString(@"defaultQueue");
                    id queue = nil;
                    if (queueClass && [queueClass respondsToSelector:defaultQueueSel]) {
                        queue = ((id(*)(id, SEL))objc_msgSend)((id)queueClass, defaultQueueSel);
                    }
                    SEL observersSel = NSSelectorFromString(@"transactionObservers");
                    NSArray *observers = nil;
                    if (queue && [queue respondsToSelector:observersSel]) {
                        observers = ((id(*)(id, SEL))objc_msgSend)(queue, observersSel);
                    }
                    SEL updatedSel = NSSelectorFromString(@"paymentQueue:updatedTransactions:");
                    for (id obs in observers) {
                        if ([obs respondsToSelector:updatedSel]) {
                            // Pass an empty array — observers that strictly
                            // require SKPaymentTransaction objects ignore it,
                            // while our own notification above carries the
                            // product id for grant auditing.
                            ((void(*)(id, SEL, id, id))objc_msgSend)(obs, updatedSel, queue, @[]);
                        }
                    }
                } @catch (NSException *e) {}

                SEL completedSel = NSSelectorFromString(@"purchaseCompleted");
                Class mainClass = NSClassFromString(@"MainManager");
                if (mainClass) {
                    SEL sharedSel = NSSelectorFromString(@"sharedMainManager");
                    if ([mainClass respondsToSelector:sharedSel]) {
                        id mainManager = ((id(*)(id, SEL))objc_msgSend)((id)mainClass, sharedSel);
                        if ([mainManager respondsToSelector:completedSel]) {
                            ((void(*)(id, SEL))objc_msgSend)(mainManager, completedSel);
                        }
                    }
                }
            } @catch (NSException *e) {
                // Safe catch
            }
        });
    } @catch (NSException *e) {
        if (sOriginal_addPayment) {
            ((void(*)(id, SEL, id))sOriginal_addPayment)(self, _cmd, payment);
        }
    }
}

static BOOL PA_canMakePayments(id self, SEL _cmd) {
    return YES;
}

// ---------------------------------------------------------------------------
#pragma mark - Install
// ---------------------------------------------------------------------------

@implementation PAStoreInterceptor

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            Class paymentQueueClass = NSClassFromString(@"SKPaymentQueue");
            if (!paymentQueueClass) {
                NSLog(@"[PoolAdmin] SKPaymentQueue not found — Store interceptor skipped.");
                return;
            }

            Method addPaymentMethod = class_getInstanceMethod(paymentQueueClass, @selector(addPayment:));
            if (addPaymentMethod) {
                sOriginal_addPayment = method_getImplementation(addPaymentMethod);
                method_setImplementation(addPaymentMethod, (IMP)PA_addPayment);
            }

            // +canMakePayments is a CLASS method — fetch it with
            // class_getClassMethod, not via the metaclass instance table.
            Method canMakeMethod = class_getClassMethod(paymentQueueClass, @selector(canMakePayments));
            if (canMakeMethod) {
                sOriginal_canMakePayments = method_getImplementation(canMakeMethod);
                method_setImplementation(canMakeMethod, (IMP)PA_canMakePayments);
            }

            NSLog(@"[PoolAdmin] Store interceptor installed.");
        } @catch (NSException *e) {
            NSLog(@"[PoolAdmin] Store interceptor install exception: %@", e);
        }
    });
}

@end
