#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "PATrajectoryEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface PARuntimeSnapshot : NSObject {
    double _transformX[3];
    double _transformY[3];
}
@property(nonatomic, copy) NSArray<PABallState *> *balls;
@property(nonatomic) PARect tableBounds;
@property(nonatomic) double aimAngle;
@property(nonatomic) BOOL inGame;
@property(nonatomic) BOOL offlineGame;
@property(nonatomic, weak, nullable) UIView *gameView;
// C arrays can't be @properties — exposed via methods returning a mutable
// pointer to the internal buffer. Dot syntax (snapshot.transformX) still works.
- (double *)transformX;
- (double *)transformY;
@property(nonatomic) BOOL hasTransform;
- (CGPoint)overlayPointForPhysicsPoint:(PAVector)point overlayView:(UIView *)overlayView;
@end

@interface PARuntimeBridge : NSObject
+ (instancetype)shared;
- (PARuntimeSnapshot *)captureSnapshotForOverlayView:(UIView *)overlayView;
- (NSDictionary<NSString *, id> *)playerSummary;
- (id)userInfo;
- (id)gameManager;
- (void)forceSync;
- (BOOL)isInGame;
- (BOOL)isOfflineGame;
- (BOOL)isMyTurn;
- (void)setBallHighlightsEnabled:(BOOL)enabled;
- (void)setNativeGuidelinesHidden:(BOOL)hidden;
- (void)setGuidelineLength:(double)length;
- (void)setPower:(double)power;
- (double)currentPower;
- (void)setAimAngle:(double)angle;
- (double)currentAimAngle;
- (void)postUserInfoChanged;
- (BOOL)applyGrant:(NSDictionary<NSString *, id> *)grant
             error:(NSError * _Nullable * _Nullable)error;
- (BOOL)applyOfflineFixtureGrant:(NSDictionary<NSString *, id> *)grant
                           error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
