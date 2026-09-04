#import "PARuntimeBridge.h"

#import <objc/message.h>
#import <objc/runtime.h>

namespace {

typedef id (*PAIdSend0)(id, SEL);
typedef BOOL (*PABoolSend0)(id, SEL);
typedef uint64_t (*PAUInt64Send0)(id, SEL);
typedef int32_t (*PAIntSend0)(id, SEL);
typedef void (*PAVoidSend0)(id, SEL);
typedef void (*PAVoidBoolSend)(id, SEL, BOOL);
typedef void (*PAVoidIntSend)(id, SEL, int32_t);
typedef void (*PAVoidUIntSend)(id, SEL, uint32_t);
typedef void (*PAVoidUInt64Send)(id, SEL, uint64_t);
typedef void (*PAVoidIdUInt64Send)(id, SEL, id, uint64_t);
typedef void (*PAVoidIdUInt64IntSend)(id, SEL, id, uint64_t, int32_t);
typedef id (*PAIdUIntSend)(id, SEL, uint32_t);
typedef id (*PAIdIdSend)(id, SEL, id);
typedef uint64_t (*PAUInt64IdSend)(id, SEL, id);
typedef uint32_t (*PAUInt32IdSend)(id, SEL, id);
typedef PAVector (*PAVectorSend0)(id, SEL);
typedef PARect (*PARectSend0)(id, SEL);
typedef double (*PADoubleSend0)(id, SEL);
typedef CGPoint (*PAPointSend0)(id, SEL);
typedef CGPoint (*PAPointPointSend)(id, SEL, CGPoint);

static id SendId(id object, NSString *selectorName) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((PAIdSend0)objc_msgSend)(object, selector);
}

static BOOL SendBool(id object, NSString *selectorName, BOOL fallback) {
    if (!object) return fallback;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return fallback;
    return ((PABoolSend0)objc_msgSend)(object, selector);
}

static id SharedObject(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    return SendId((id)cls, selectorName);
}

static Ivar FindIvar(id object, const char *name) {
    if (!object) return nullptr;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return ivar;
        cls = class_getSuperclass(cls);
    }
    return nullptr;
}

static id ObjectIvar(id object, const char *name) {
    Ivar ivar = FindIvar(object, name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

template <typename T>
static T ScalarIvar(id object, const char *name, T fallback) {
    Ivar ivar = FindIvar(object, name);
    if (!ivar) return fallback;
    const ptrdiff_t offset = ivar_getOffset(ivar);
    const uint8_t *bytes = reinterpret_cast<const uint8_t *>((__bridge const void *)object);
    return *reinterpret_cast<const T *>(bytes + offset);
}

static BOOL Solve3x3(const double matrix[3][3], const double vector[3], double result[3]) {
    double augmented[3][4] = {
        {matrix[0][0], matrix[0][1], matrix[0][2], vector[0]},
        {matrix[1][0], matrix[1][1], matrix[1][2], vector[1]},
        {matrix[2][0], matrix[2][1], matrix[2][2], vector[2]},
    };

    for (NSInteger column = 0; column < 3; column++) {
        NSInteger pivot = column;
        for (NSInteger row = column + 1; row < 3; row++) {
            if (fabs(augmented[row][column]) > fabs(augmented[pivot][column])) {
                pivot = row;
            }
        }
        if (fabs(augmented[pivot][column]) < 1e-9) return NO;
        if (pivot != column) {
            for (NSInteger k = column; k < 4; k++) {
                std::swap(augmented[pivot][k], augmented[column][k]);
            }
        }
        const double divisor = augmented[column][column];
        for (NSInteger k = column; k < 4; k++) augmented[column][k] /= divisor;
        for (NSInteger row = 0; row < 3; row++) {
            if (row == column) continue;
            const double factor = augmented[row][column];
            for (NSInteger k = column; k < 4; k++) {
                augmented[row][k] -= factor * augmented[column][k];
            }
        }
    }
    for (NSInteger row = 0; row < 3; row++) result[row] = augmented[row][3];
    return YES;
}

static BOOL FitAffine(NSArray<PABallState *> *balls, double xResult[3], double yResult[3]) {
    if (balls.count < 3) return NO;
    double normal[3][3] = {};
    double xVector[3] = {};
    double yVector[3] = {};
    for (PABallState *ball in balls) {
        const double row[3] = {ball.position.x, ball.position.y, 1.0};
        for (NSInteger i = 0; i < 3; i++) {
            for (NSInteger j = 0; j < 3; j++) normal[i][j] += row[i] * row[j];
            xVector[i] += row[i] * ball.visualPoint.x;
            yVector[i] += row[i] * ball.visualPoint.y;
        }
    }
    return Solve3x3(normal, xVector, xResult) && Solve3x3(normal, yVector, yResult);
}

static UIView *CocosView(void) {
    id director = SharedObject(@"CCDirector", @"sharedDirector");
    id view = SendId(director, @"view");
    return [view isKindOfClass:UIView.class] ? view : nil;
}

static NSError *RuntimeError(NSString *message) {
    return [NSError errorWithDomain:@"PoolAdmin.Runtime"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

}  // namespace

@implementation PARuntimeSnapshot

- (CGPoint)overlayPointForPhysicsPoint:(PAVector)point overlayView:(UIView *)overlayView {
    if (!self.hasTransform) return CGPointZero;
    const CGPoint cocosPoint = CGPointMake(self.transformX[0] * point.x +
                                           self.transformX[1] * point.y +
                                           self.transformX[2],
                                           self.transformY[0] * point.x +
                                           self.transformY[1] * point.y +
                                           self.transformY[2]);
    UIView *gameView = self.gameView;
    if (gameView) {
        const CGPoint viewPoint = CGPointMake(cocosPoint.x,
                                              CGRectGetHeight(gameView.bounds) - cocosPoint.y);
        return [gameView convertPoint:viewPoint toView:overlayView];
    }
    return CGPointMake(cocosPoint.x, CGRectGetHeight(overlayView.bounds) - cocosPoint.y);
}

@end

@implementation PARuntimeBridge

+ (instancetype)shared {
    static PARuntimeBridge *bridge;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ bridge = [PARuntimeBridge new]; });
    return bridge;
}

- (id)gameManager {
    Class cls = NSClassFromString(@"GameManager");
    if (!cls || !SendBool((id)cls, @"isGameManagerInitialized", NO)) return nil;
    return SharedObject(@"GameManager", @"sharedGameManager");
}

- (id)userInfo {
    Class cls = NSClassFromString(@"UserInfo");
    if (!cls || !SendBool((id)cls, @"isUserInfoInitialized", NO)) return nil;
    return SharedObject(@"UserInfo", @"sharedUserInfo");
}

- (BOOL)isInGame {
    id manager = SharedObject(@"MainManager", @"sharedMainManager");
    return SendBool(manager, @"isInGame", NO);
}

- (BOOL)isOfflineGame {
    id manager = [self gameManager];
    return SendBool(manager, @"isOnOfflineGame", NO);
}

- (PARuntimeSnapshot *)captureSnapshotForOverlayView:(UIView *)overlayView {
    PARuntimeSnapshot *snapshot = [PARuntimeSnapshot new];
    snapshot.balls = @[];
    @try {
        snapshot.inGame = [self isInGame];
        snapshot.offlineGame = [self isOfflineGame];
        if (!snapshot.inGame) return snapshot;

        id gameManager = [self gameManager];
        id table = SendId(gameManager, @"table") ?: SendId(gameManager, @"getTable");
        id visualCue = SendId(gameManager, @"visualCue");
        if (!table || !visualCue) return snapshot;

        // Cache selectors — NSSelectorFromString every frame at 60-120Hz
        // is measurable overhead.
        static SEL boundsSelector = nil;
        static SEL aimSelector = nil;
        static SEL ballsSelector = nil;
        static SEL cueBallSelector = nil;
        static SEL positionSelector = nil;
        static SEL radiusSelector = nil;
        static SEL onTableSelector = nil;
        static SEL convertSelector = nil;
        static dispatch_once_t selOnce;
        dispatch_once(&selOnce, ^{
            boundsSelector = NSSelectorFromString(@"tableBounds");
            aimSelector = NSSelectorFromString(@"aimAngle");
            ballsSelector = NSSelectorFromString(@"balls");
            cueBallSelector = NSSelectorFromString(@"getCueBall");
            positionSelector = NSSelectorFromString(@"position");
            radiusSelector = NSSelectorFromString(@"radius");
            onTableSelector = NSSelectorFromString(@"onTable");
            convertSelector = NSSelectorFromString(@"convertToWorldSpace:");
        });

        if ([table respondsToSelector:boundsSelector]) {
            @try {
                snapshot.tableBounds = ((PARectSend0)objc_msgSend)(table, boundsSelector);
            } @catch (NSException *e) { return snapshot; }
        }
        if ([visualCue respondsToSelector:aimSelector]) {
            @try {
                snapshot.aimAngle = ((PADoubleSend0)objc_msgSend)(visualCue, aimSelector);
            } @catch (NSException *e) {}
        }

        // balls may be NSArray or a Cocos CCArray (count/objectAtIndex:).
        id ballsContainer = SendId(table, @"balls");
        NSArray *runtimeBalls = nil;
        if ([ballsContainer isKindOfClass:NSArray.class]) {
            runtimeBalls = ballsContainer;
        } else if (ballsContainer &&
                   [ballsContainer respondsToSelector:@selector(count)] &&
                   [ballsContainer respondsToSelector:@selector(objectAtIndex:)]) {
            @try {
                NSUInteger n = (NSUInteger)[ballsContainer count];
                NSMutableArray *tmp = [NSMutableArray arrayWithCapacity:MIN(n, (NSUInteger)32)];
                for (NSUInteger i = 0; i < n; i++) {
                    id obj = [ballsContainer objectAtIndex:i];
                    if (obj) [tmp addObject:obj];
                }
                runtimeBalls = tmp;
            } @catch (NSException *e) { return snapshot; }
        } else {
            return snapshot;
        }
        id cueBallObject = SendId(table, @"getCueBall");

        NSMutableArray<PABallState *> *balls = [NSMutableArray array];
        for (id runtimeBall in runtimeBalls) {
            if (!runtimeBall) continue;
            // onTable defaults to YES when the selector is absent.
            if ([runtimeBall respondsToSelector:onTableSelector] &&
                !((PABoolSend0)objc_msgSend)(runtimeBall, onTableSelector)) continue;
            if (![runtimeBall respondsToSelector:positionSelector] ||
                ![runtimeBall respondsToSelector:radiusSelector]) continue;

            id visualBall = ObjectIvar(runtimeBall, "visualBall");
            // Fallbacks: some builds name it _visualBall / m_visualBall.
            if (!visualBall) visualBall = ObjectIvar(runtimeBall, "_visualBall");
            if (!visualBall) visualBall = ObjectIvar(runtimeBall, "m_visualBall");
            CGPoint visualPoint = CGPointZero;
            SEL visualPositionSelector = positionSelector;
            if ([visualBall respondsToSelector:convertSelector]) {
                @try {
                    visualPoint = ((PAPointPointSend)objc_msgSend)(visualBall, convertSelector, CGPointZero);
                } @catch (NSException *e) { continue; }
            } else if ([visualBall respondsToSelector:visualPositionSelector]) {
                @try {
                    visualPoint = ((PAPointSend0)objc_msgSend)(visualBall, visualPositionSelector);
                } @catch (NSException *e) { continue; }
            } else {
                continue;
            }

            PABallState *ball = [PABallState new];
            @try {
                ball.position = ((PAVectorSend0)objc_msgSend)(runtimeBall, positionSelector);
                ball.radius = ((PADoubleSend0)objc_msgSend)(runtimeBall, radiusSelector);
            } @catch (NSException *e) { continue; }
            // number may be int32, uint32, or NSInteger — try each width.
            uint32_t num = ScalarIvar<uint32_t>(runtimeBall, "number", UINT32_MAX);
            if (num == UINT32_MAX) {
                int32_t s = ScalarIvar<int32_t>(runtimeBall, "number", -1);
                int64_t l = ScalarIvar<int64_t>(runtimeBall, "number", -1);
                num = (s >= 0) ? (uint32_t)s : ((l >= 0) ? (uint32_t)l : 0);
            }
            // Alternate ivar names seen across builds.
            if (num == 0) {
                uint32_t alt = ScalarIvar<uint32_t>(runtimeBall, "_number", UINT32_MAX);
                if (alt != UINT32_MAX) num = alt;
            }
            ball.number = num;
            ball.cueBall = runtimeBall == cueBallObject || ball.number == 0;
            ball.visualPoint = visualPoint;
            [balls addObject:ball];
        }

        snapshot.balls = balls;
        snapshot.gameView = CocosView();
        snapshot.hasTransform = FitAffine(balls, snapshot.transformX, snapshot.transformY);
    } @catch (NSException *e) {
        // Never let a per-frame reflection failure crash the game.
        snapshot.balls = @[];
        snapshot.hasTransform = NO;
    }
    return snapshot;
}

- (NSDictionary<NSString *, id> *)playerSummary {
    id userInfo = [self userInfo];
    if (!userInfo) {
        return @{ @"ready": @NO,
                  @"online": @NO,
                  @"offlineGame": @([self isOfflineGame]) };
    }

    id userId = SendId(userInfo, @"userId");
    BOOL isOnline = (![self isOfflineGame] && userId != nil) || [self isInGame];

    NSMutableDictionary *summary = [@{
        @"ready": @YES,
        @"online": @(isOnline),
        @"offlineGame": @([self isOfflineGame]),
    } mutableCopy];
    if (userId) summary[@"userId"] = [userId description];

    SEL coinsSelector = NSSelectorFromString(@"coins");
    SEL cashSelector = NSSelectorFromString(@"cash");
    SEL xpSelector = NSSelectorFromString(@"xp");
    SEL levelSelector = NSSelectorFromString(@"level");
    if ([userInfo respondsToSelector:coinsSelector]) summary[@"coins"] = @(((PAUInt64Send0)objc_msgSend)(userInfo, coinsSelector));
    if ([userInfo respondsToSelector:cashSelector]) summary[@"cash"] = @(((PAUInt64Send0)objc_msgSend)(userInfo, cashSelector));
    if ([userInfo respondsToSelector:xpSelector]) summary[@"xp"] = @(((PAUInt64Send0)objc_msgSend)(userInfo, xpSelector));
    if ([userInfo respondsToSelector:levelSelector]) summary[@"level"] = @(((PAIntSend0)objc_msgSend)(userInfo, levelSelector));
    return summary;
}

- (void)setBallHighlightsEnabled:(BOOL)enabled {
    id table = SendId([self gameManager], @"table");
    NSString *selectorName = enabled ? @"activateContinuousHighlightOnAllBalls" : @"deactivateHighlightOnAllBalls";
    SEL selector = NSSelectorFromString(selectorName);
    if ([table respondsToSelector:selector]) ((PAVoidSend0)objc_msgSend)(table, selector);
}

- (void)setNativeGuidelinesHidden:(BOOL)hidden {
    id visualCue = SendId([self gameManager], @"visualCue");
    SEL selector = NSSelectorFromString(@"setHideGuidelinesMode:");
    if ([visualCue respondsToSelector:selector]) {
        ((PAVoidBoolSend)objc_msgSend)(visualCue, selector, hidden);
    }
}

- (BOOL)isMyTurn {
    id gameManager = [self gameManager];
    if (!gameManager) return NO;
    // Try multiple selectors for turn detection
    if (SendBool(gameManager, @"isMyTurn", NO)) return YES;
    if (SendBool(gameManager, @"isTurnActive", NO)) return YES;
    id turnState = SendId(gameManager, @"turnState");
    if (turnState) {
        return SendBool(turnState, @"isMyTurn", NO);
    }
    return NO;
}

- (void)setGuidelineLength:(double)length {
    id gameManager = [self gameManager];
    id visualCue = SendId(gameManager, @"visualCue");
    // Try setting guideline length directly
    SEL sel1 = NSSelectorFromString(@"setGuidelineLength:");
    SEL sel2 = NSSelectorFromString(@"setGuideLength:");
    typedef void (*PAVoidDoubleSend)(id, SEL, double);
    if ([visualCue respondsToSelector:sel1]) {
        ((PAVoidDoubleSend)objc_msgSend)(visualCue, sel1, length);
    } else if ([visualCue respondsToSelector:sel2]) {
        ((PAVoidDoubleSend)objc_msgSend)(visualCue, sel2, length);
    }
    // Also try on the game rules
    id gameRules = SendId(gameManager, @"gameRules") ?: SendId(gameManager, @"rules");
    if (gameRules) {
        SEL sel3 = NSSelectorFromString(@"setGuidelineLength:");
        if ([gameRules respondsToSelector:sel3]) {
            ((PAVoidDoubleSend)objc_msgSend)(gameRules, sel3, length);
        }
    }
}

- (void)setPower:(double)power {
    id gameManager = [self gameManager];
    id visualCue = SendId(gameManager, @"visualCue");
    typedef void (*PAVoidDoubleSend)(id, SEL, double);
    typedef void (*PAVoidFloatSend)(id, SEL, float);
    SEL setPower = NSSelectorFromString(@"setPower:");
    SEL setForce = NSSelectorFromString(@"setForce:");
    SEL setShotPower = NSSelectorFromString(@"setShotPower:");
    if ([visualCue respondsToSelector:setPower]) {
        ((PAVoidDoubleSend)objc_msgSend)(visualCue, setPower, power);
    } else if ([visualCue respondsToSelector:setForce]) {
        ((PAVoidFloatSend)objc_msgSend)(visualCue, setForce, (float)power);
    } else if ([gameManager respondsToSelector:setShotPower]) {
        ((PAVoidDoubleSend)objc_msgSend)(gameManager, setShotPower, power);
    }
}

- (double)currentPower {
    id gameManager = [self gameManager];
    id visualCue = SendId(gameManager, @"visualCue");
    SEL powerSel = NSSelectorFromString(@"power");
    SEL forceSel = NSSelectorFromString(@"force");
    if ([visualCue respondsToSelector:powerSel]) {
        return ((PADoubleSend0)objc_msgSend)(visualCue, powerSel);
    }
    if ([visualCue respondsToSelector:forceSel]) {
        return ((PADoubleSend0)objc_msgSend)(visualCue, forceSel);
    }
    return 0.5;
}

- (void)setAimAngle:(double)angle {
    id gameManager = [self gameManager];
    id visualCue = SendId(gameManager, @"visualCue");
    typedef void (*PAVoidDoubleSend)(id, SEL, double);
    SEL sel = NSSelectorFromString(@"setAimAngle:");
    if ([visualCue respondsToSelector:sel]) {
        ((PAVoidDoubleSend)objc_msgSend)(visualCue, sel, angle);
    }
}

- (double)currentAimAngle {
    id gameManager = [self gameManager];
    id visualCue = SendId(gameManager, @"visualCue");
    SEL sel = NSSelectorFromString(@"aimAngle");
    if ([visualCue respondsToSelector:sel]) {
        return ((PADoubleSend0)objc_msgSend)(visualCue, sel);
    }
    return 0.0;
}

- (void)postUserInfoChanged {
    id userInfo = [self userInfo];
    if (userInfo) {
        SEL onUserInfoChanged = NSSelectorFromString(@"onUserInfoChanged");
        if ([userInfo respondsToSelector:onUserInfoChanged]) {
            ((PAVoidSend0)objc_msgSend)(userInfo, onUserInfoChanged);
        }
        SEL updateCues = NSSelectorFromString(@"updateNumberOfUpgradableCues");
        if ([userInfo respondsToSelector:updateCues]) {
            ((PAVoidSend0)objc_msgSend)(userInfo, updateCues);
        }
        SEL notifyCues = NSSelectorFromString(@"notifyNumberOfUpgradableCuesChanged");
        if ([userInfo respondsToSelector:notifyCues]) {
            ((PAVoidSend0)objc_msgSend)(userInfo, notifyCues);
        }
    }

    id mainManager = SharedObject(@"MainManager", @"sharedMainManager");
    if (mainManager) {
        SEL refreshStates = NSSelectorFromString(@"refreshStates");
        if ([mainManager respondsToSelector:refreshStates]) {
            ((PAVoidSend0)objc_msgSend)(mainManager, refreshStates);
        }
    }

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center postNotificationName:@"NotificationUserInfoChanged" object:nil];
    [center postNotificationName:@"NotificationUserInfoCueInfoChanged" object:nil];
    [center postNotificationName:@"NotificationUserInfoVipTierChanged" object:nil];
    [center postNotificationName:@"NotificationUserInfoCollectionCueChanged" object:nil];
    [center postNotificationName:@"NotificationUserInfoUpgradableCuesChanged" object:nil];
}

- (void)forceSync {
    id userInfo = [self userInfo];
    if (!userInfo) return;
    
    NSArray *selectors = @[@"saveToLocalStorage", @"saveData", @"persistUserInfo", @"saveToDefaults"];
    for (NSString *selName in selectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([userInfo respondsToSelector:sel]) {
            ((PAVoidSend0)objc_msgSend)(userInfo, sel);
            break;
        }
    }
}

- (BOOL)applyGrant:(NSDictionary<NSString *, id> *)grant
             error:(NSError **)error {
    id userInfo = [self userInfo];
    if (!userInfo) {
        if (error) *error = RuntimeError(@"UserInfo is not initialized yet. Please log in or wait for game data.");
        return NO;
    }

    NSString *kind = [grant[@"kind"] isKindOfClass:NSString.class] ? grant[@"kind"] : @"";
    uint64_t amount = [grant[@"amount"] respondsToSelector:@selector(unsignedLongLongValue)] ? [grant[@"amount"] unsignedLongLongValue] : 1;
    NSString *productId = [grant[@"productId"] description];
    BOOL applied = NO;

    if ([kind isEqualToString:@"coins"] || [kind isEqualToString:@"cash"] || [kind isEqualToString:@"xp"]) {
        SEL getter = NSSelectorFromString(kind);
        NSString *setterName = [NSString stringWithFormat:@"set%@%@:",
                                [[kind substringToIndex:1] uppercaseString],
                                [kind substringFromIndex:1]];
        SEL setter = NSSelectorFromString(setterName);
        
        NSString *adderName = [NSString stringWithFormat:@"add%@%@:",
                                [[kind substringToIndex:1] uppercaseString],
                                [kind substringFromIndex:1]];
        SEL adder = NSSelectorFromString(adderName);

        if ([userInfo respondsToSelector:adder]) {
            ((PAVoidUInt64Send)objc_msgSend)(userInfo, adder, amount);
            applied = YES;
        } else if ([userInfo respondsToSelector:getter] && [userInfo respondsToSelector:setter]) {
            uint64_t current = ((PAUInt64Send0)objc_msgSend)(userInfo, getter);
            ((PAVoidUInt64Send)objc_msgSend)(userInfo, setter, current + amount);
            applied = YES;
        }
    } else if ([kind isEqualToString:@"vip_points"]) {
        // Different builds name this differently — try each.
        NSArray *vipSetters = @[@"setVIPPoints:", @"setVipPoints:",
                                @"setVIPPoint:", @"setVipPoint:"];
        for (NSString *name in vipSetters) {
            SEL vipSetter = NSSelectorFromString(name);
            if ([userInfo respondsToSelector:vipSetter]) {
                ((PAVoidUIntSend)objc_msgSend)(userInfo, vipSetter, (uint32_t)amount);
                SEL vipChanged = NSSelectorFromString(@"onUserInfoVIPTierChanged");
                if ([userInfo respondsToSelector:vipChanged]) {
                    ((PAVoidSend0)objc_msgSend)(userInfo, vipChanged);
                }
                applied = YES;
                break;
            }
        }
    } else if ([kind isEqualToString:@"pool_points"]) {
        NSArray *poolSetters = @[@"setSeasonPassPointsAmount:",
                                 @"setSeasonPassPoints:",
                                 @"setPoolPoints:", @"setPoolPassPoints:"];
        for (NSString *name in poolSetters) {
            SEL s = NSSelectorFromString(name);
            if ([userInfo respondsToSelector:s]) {
                ((PAVoidUIntSend)objc_msgSend)(userInfo, s, (uint32_t)amount);
                applied = YES;
                break;
            }
        }
        NSString *pid = (productId.length > 0) ? productId : @"38156";
        SEL getter = NSSelectorFromString(@"getOwnedProductAmount:");
        SEL setter = NSSelectorFromString(@"setOwnedProduct:amount:totalDelta:");
        SEL adder = NSSelectorFromString(@"addOwnedProduct:amount:");
        if ([userInfo respondsToSelector:adder]) {
            ((PAVoidIdUInt64Send)objc_msgSend)(userInfo, adder, pid, amount);
            applied = YES;
        } else if ([userInfo respondsToSelector:getter] && [userInfo respondsToSelector:setter]) {
            uint64_t current = ((PAUInt64IdSend)objc_msgSend)(userInfo, getter, pid);
            ((PAVoidIdUInt64IntSend)objc_msgSend)(userInfo,
                                                  setter,
                                                  pid,
                                                  current + amount,
                                                  (int32_t)MIN(amount, (uint64_t)INT32_MAX));
            applied = YES;
        }
    } else if ([kind isEqualToString:@"cue"] && productId.length > 0) {
        SEL selector = NSSelectorFromString(@"addOwnedCue:shouldStoreLocally:");
        SEL addCue = NSSelectorFromString(@"addOwnedCue:");
        if ([userInfo respondsToSelector:selector]) {
            typedef void (*AddCueSend)(id, SEL, int32_t, BOOL);
            ((AddCueSend)objc_msgSend)(userInfo, selector, productId.intValue, YES);
            applied = YES;
        } else if ([userInfo respondsToSelector:addCue]) {
            typedef void (*AddCueSimple)(id, SEL, int32_t);
            ((AddCueSimple)objc_msgSend)(userInfo, addCue, productId.intValue);
            applied = YES;
        }
        SEL refresh = NSSelectorFromString(@"refreshOwnedCues");
        if ([userInfo respondsToSelector:refresh]) {
            ((PAVoidSend0)objc_msgSend)(userInfo, refresh);
        }
    } else if ([kind isEqualToString:@"cue_pieces"] && productId.length > 0) {
        SEL getter = NSSelectorFromString(@"getAmountOfProductPiecesForProductId:");
        SEL setter = NSSelectorFromString(@"setOwnedProductPiece:amount:");
        SEL adder = NSSelectorFromString(@"addOwnedProductPiece:amount:");
        if ([userInfo respondsToSelector:adder]) {
            ((PAVoidIdUInt64Send)objc_msgSend)(userInfo, adder, productId, amount);
            applied = YES;
        } else if ([userInfo respondsToSelector:getter] && [userInfo respondsToSelector:setter]) {
            uint32_t current = ((PAUInt32IdSend)objc_msgSend)(userInfo, getter, productId);
            ((PAVoidIdUInt64Send)objc_msgSend)(userInfo, setter, productId, current + amount);
            applied = YES;
        }
    } else if (productId.length > 0) {
        SEL getter = NSSelectorFromString(@"getOwnedProductAmount:");
        SEL setter = NSSelectorFromString(@"setOwnedProduct:amount:totalDelta:");
        SEL adder = NSSelectorFromString(@"addOwnedProduct:amount:");
        if ([userInfo respondsToSelector:adder]) {
            ((PAVoidIdUInt64Send)objc_msgSend)(userInfo, adder, productId, amount);
            applied = YES;
        } else if ([userInfo respondsToSelector:getter] && [userInfo respondsToSelector:setter]) {
            uint64_t current = ((PAUInt64IdSend)objc_msgSend)(userInfo, getter, productId);
            ((PAVoidIdUInt64IntSend)objc_msgSend)(userInfo,
                                                  setter,
                                                  productId,
                                                  current + amount,
                                                  (int32_t)MIN(amount, (uint64_t)INT32_MAX));
            applied = YES;
        }
    }

    if (!applied) {
        NSString *msg = [NSString stringWithFormat:
            @"No matching setter for kind '%@' on this build — grant skipped.", kind];
        NSLog(@"[PoolAdmin] %@", msg);
        if (error) *error = RuntimeError(msg);
        return NO;
    }

    [self postUserInfoChanged];
    [self forceSync];
    return YES;
}

- (BOOL)applyOfflineFixtureGrant:(NSDictionary<NSString *, id> *)grant
                           error:(NSError **)error {
    return [self applyGrant:grant error:error];
}

@end
