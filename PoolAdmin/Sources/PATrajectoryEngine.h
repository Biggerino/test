#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    double x;
    double y;
} PAVector;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} PARect;

typedef NS_ENUM(NSInteger, PATrajectorySegmentKind) {
    PATrajectorySegmentKindCue = 0,
    PATrajectorySegmentKindObject = 1,
    PATrajectorySegmentKindDeflection = 2,
    PATrajectorySegmentKindPocket = 3,
    PATrajectorySegmentKindCushion = 4,
    PATrajectorySegmentKindGhostBall = 5,
};

@interface PABallState : NSObject
@property(nonatomic) NSUInteger number;
@property(nonatomic) PAVector position;
@property(nonatomic) double radius;
@property(nonatomic, getter=isCueBall) BOOL cueBall;
@property(nonatomic) CGPoint visualPoint;
@end

@interface PATrajectorySegment : NSObject
@property(nonatomic) PAVector start;
@property(nonatomic) PAVector end;
@property(nonatomic) PATrajectorySegmentKind kind;
@property(nonatomic) NSUInteger ballNumber;
@property(nonatomic) BOOL cushionImpact;
@property(nonatomic) BOOL ballImpact;
@end

@interface PATrajectoryResult : NSObject
@property(nonatomic, copy) NSArray<PATrajectorySegment *> *segments;
@property(nonatomic, copy) NSArray<NSValue *> *collisionPoints;
@property(nonatomic, copy) NSArray<NSValue *> *ghostBallCenters;
@property(nonatomic, copy) NSArray<NSNumber *> *impactedBallNumbers;
@property(nonatomic, copy) NSArray<NSValue *> *pocketPositions;
@property(nonatomic) PAVector finalPoint;
@property(nonatomic) BOOL hasFinalPoint;
@end

@interface PATrajectoryOptions : NSObject
@property(nonatomic) NSInteger cushionBounces;
@property(nonatomic) NSInteger collisionDepth;
@property(nonatomic) double lengthMultiplier;
@property(nonatomic) BOOL drawCueDeflection;
@property(nonatomic) BOOL drawPocketAssist;
@property(nonatomic) double spinX;
@property(nonatomic) double spinY;
@end

@interface PATrajectoryEngine : NSObject
+ (PATrajectoryResult *)solveWithBalls:(NSArray<PABallState *> *)balls
                                bounds:(PARect)bounds
                              aimAngle:(double)aimAngle
                               options:(PATrajectoryOptions *)options;
@end

FOUNDATION_EXPORT NSValue *PAValueWithVector(PAVector vector);
FOUNDATION_EXPORT PAVector PAVectorFromValue(NSValue *value);

NS_ASSUME_NONNULL_END
