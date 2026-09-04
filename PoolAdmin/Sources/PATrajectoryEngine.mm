#import "PATrajectoryEngine.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <vector>

@implementation PABallState
@end

@implementation PATrajectorySegment
@end

@implementation PATrajectoryResult
@end

@implementation PATrajectoryOptions

- (instancetype)init {
    self = [super init];
    if (self) {
        _cushionBounces = 2;
        _collisionDepth = 3;
        _lengthMultiplier = 3.0;
        _drawCueDeflection = YES;
        _drawPocketAssist = YES;
        _spinX = 0.0;
        _spinY = 0.0;
    }
    return self;
}

@end

NSValue *PAValueWithVector(PAVector vector) {
    return [NSValue valueWithBytes:&vector objCType:@encode(PAVector)];
}

PAVector PAVectorFromValue(NSValue *value) {
    PAVector vector = {0.0, 0.0};
    [value getValue:&vector size:sizeof(vector)];
    return vector;
}

namespace {

constexpr double kEpsilon = 1e-6;

struct Hit {
    bool found = false;
    bool ball = false;
    bool cushion = false;
    double distance = std::numeric_limits<double>::infinity();
    PAVector point = {0.0, 0.0};
    PAVector normal = {0.0, 0.0};
    __unsafe_unretained PABallState *target = nil;
};

static PAVector Add(PAVector a, PAVector b) {
    return {a.x + b.x, a.y + b.y};
}

static PAVector Sub(PAVector a, PAVector b) {
    return {a.x - b.x, a.y - b.y};
}

static PAVector Mul(PAVector a, double scale) {
    return {a.x * scale, a.y * scale};
}

static double Dot(PAVector a, PAVector b) {
    return a.x * b.x + a.y * b.y;
}

static double Length(PAVector value) {
    return std::sqrt(Dot(value, value));
}

static PAVector Normalize(PAVector value) {
    const double length = Length(value);
    return length <= kEpsilon ? PAVector{0.0, 0.0} : Mul(value, 1.0 / length);
}

static PAVector Reflect(PAVector direction, PAVector normal) {
    return Normalize(Sub(direction, Mul(normal, 2.0 * Dot(direction, normal))));
}

static double RayCircleDistance(PAVector origin,
                                PAVector direction,
                                PAVector center,
                                double combinedRadius) {
    const PAVector offset = Sub(origin, center);
    const double b = 2.0 * Dot(offset, direction);
    const double c = Dot(offset, offset) - combinedRadius * combinedRadius;
    const double discriminant = b * b - 4.0 * c;
    if (discriminant < 0.0) {
        return std::numeric_limits<double>::infinity();
    }

    const double root = std::sqrt(discriminant);
    const double nearDistance = (-b - root) * 0.5;
    const double farDistance = (-b + root) * 0.5;
    if (nearDistance > kEpsilon) {
        return nearDistance;
    }
    if (farDistance > kEpsilon) {
        return farDistance;
    }
    return std::numeric_limits<double>::infinity();
}

static Hit FindHit(PAVector origin,
                   PAVector direction,
                   double movingRadius,
                   PARect bounds,
                   NSArray<PABallState *> *balls,
                   PABallState *movingBall,
                   PABallState *lastBall,
                   double maxDistance) {
    Hit result;
    result.distance = maxDistance;

    for (PABallState *candidate in balls) {
        if (candidate == movingBall || candidate == lastBall) {
            continue;
        }
        const double distance = RayCircleDistance(origin,
                                                  direction,
                                                  candidate.position,
                                                  movingRadius + candidate.radius);
        if (distance < result.distance) {
            result.found = true;
            result.ball = true;
            result.cushion = false;
            result.distance = distance;
            result.point = Add(origin, Mul(direction, distance));
            result.normal = Normalize(Sub(candidate.position, result.point));
            result.target = candidate;
        }
    }

    const double minX = bounds.x + movingRadius;
    const double maxX = bounds.x + bounds.width - movingRadius;
    const double minY = bounds.y + movingRadius;
    const double maxY = bounds.y + bounds.height - movingRadius;

    struct CushionCandidate {
        double distance;
        PAVector normal;
    } candidates[4] = {
        {direction.x < -kEpsilon ? (minX - origin.x) / direction.x : std::numeric_limits<double>::infinity(), {1.0, 0.0}},
        {direction.x > kEpsilon ? (maxX - origin.x) / direction.x : std::numeric_limits<double>::infinity(), {-1.0, 0.0}},
        {direction.y < -kEpsilon ? (minY - origin.y) / direction.y : std::numeric_limits<double>::infinity(), {0.0, 1.0}},
        {direction.y > kEpsilon ? (maxY - origin.y) / direction.y : std::numeric_limits<double>::infinity(), {0.0, -1.0}},
    };

    for (const CushionCandidate &candidate : candidates) {
        if (candidate.distance > kEpsilon && candidate.distance < result.distance) {
            result.found = true;
            result.ball = false;
            result.cushion = true;
            result.distance = candidate.distance;
            result.point = Add(origin, Mul(direction, candidate.distance));
            result.normal = candidate.normal;
            result.target = nil;
        }
    }

    if (!result.found) {
        result.distance = maxDistance;
        result.point = Add(origin, Mul(direction, maxDistance));
    }
    return result;
}

static double NearestBallDistance(PAVector origin,
                                  PAVector direction,
                                  double radius,
                                  NSArray<PABallState *> *balls,
                                  PABallState *cueBall) {
    double nearest = std::numeric_limits<double>::infinity();
    for (PABallState *ball in balls) {
        if (ball == cueBall) {
            continue;
        }
        nearest = std::min(nearest,
                           RayCircleDistance(origin,
                                             direction,
                                             ball.position,
                                             radius + ball.radius));
    }
    return nearest;
}

static PAVector ResolveAimDirection(PABallState *cueBall,
                                    NSArray<PABallState *> *balls,
                                    double aimAngle) {
    PAVector forward = Normalize({std::cos(aimAngle), std::sin(aimAngle)});
    const PAVector backward = Mul(forward, -1.0);
    const double forwardHit = NearestBallDistance(cueBall.position,
                                                  forward,
                                                  cueBall.radius,
                                                  balls,
                                                  cueBall);
    const double backwardHit = NearestBallDistance(cueBall.position,
                                                   backward,
                                                   cueBall.radius,
                                                   balls,
                                                   cueBall);

    // Builds of the game have used both cue-facing and shot-facing angle
    // conventions. Prefer the direction that intersects the rack when only
    // one side does, while keeping the native mathematical convention for
    // bank shots where neither side has a direct collision.
    if (!std::isfinite(forwardHit) && std::isfinite(backwardHit)) {
        return backward;
    }
    if (std::isfinite(forwardHit) && std::isfinite(backwardHit) && backwardHit < forwardHit * 0.35) {
        return backward;
    }
    return forward;
}

static void AppendSegment(NSMutableArray<PATrajectorySegment *> *segments,
                          PAVector start,
                          PAVector end,
                          PATrajectorySegmentKind kind,
                          NSUInteger ballNumber,
                          bool cushionImpact,
                          bool ballImpact) {
    PATrajectorySegment *segment = [PATrajectorySegment new];
    segment.start = start;
    segment.end = end;
    segment.kind = kind;
    segment.ballNumber = ballNumber;
    segment.cushionImpact = cushionImpact;
    segment.ballImpact = ballImpact;
    [segments addObject:segment];
}

static PAVector PocketPosition(PARect bounds, NSInteger index) {
    switch (index) {
        case 0: return {bounds.x, bounds.y};
        case 1: return {bounds.x + bounds.width * 0.5, bounds.y};
        case 2: return {bounds.x + bounds.width, bounds.y};
        case 3: return {bounds.x, bounds.y + bounds.height};
        case 4: return {bounds.x + bounds.width * 0.5, bounds.y + bounds.height};
        default: return {bounds.x + bounds.width, bounds.y + bounds.height};
    }
}

static void AppendPocketAssist(NSMutableArray<PATrajectorySegment *> *segments,
                               PABallState *ball,
                               PAVector outgoingDirection,
                               PARect bounds,
                               NSArray<PABallState *> *balls) {
    PAVector bestPocket = {0.0, 0.0};
    bool found = false;
    double minTargetDistance = std::numeric_limits<double>::infinity();

    for (NSInteger index = 0; index < 6; index++) {
        const PAVector pocket = PocketPosition(bounds, index);
        const double catchRadius = (index == 1 || index == 4) ? (2.2 * ball.radius) : (1.8 * ball.radius);
        const double dist = RayCircleDistance(ball.position, outgoingDirection, pocket, catchRadius);
        
        if (std::isfinite(dist) && dist < minTargetDistance) {
            minTargetDistance = dist;
            bestPocket = pocket;
            found = true;
        }
    }
    
    if (found) {
        Hit hit = FindHit(ball.position, outgoingDirection, ball.radius, bounds, balls, ball, nil, minTargetDistance);
        if (!hit.ball) {
            AppendSegment(segments,
                          ball.position,
                          bestPocket,
                          PATrajectorySegmentKindPocket,
                          ball.number,
                          false,
                          false);
        }
    }
}

}  // namespace

@implementation PATrajectoryEngine

+ (PATrajectoryResult *)solveWithBalls:(NSArray<PABallState *> *)balls
                                bounds:(PARect)bounds
                              aimAngle:(double)aimAngle
                               options:(PATrajectoryOptions *)options {
    PATrajectoryResult *result = [PATrajectoryResult new];
    NSMutableArray<PATrajectorySegment *> *segments = [NSMutableArray array];
    NSMutableArray<NSValue *> *collisionPoints = [NSMutableArray array];
    NSMutableArray<NSValue *> *ghostCenters = [NSMutableArray array];
    NSMutableOrderedSet<NSNumber *> *impactedNumbers = [NSMutableOrderedSet orderedSet];

    NSMutableArray<NSValue *> *pockets = [NSMutableArray array];
    for (NSInteger i = 0; i < 6; i++) {
        [pockets addObject:PAValueWithVector(PocketPosition(bounds, i))];
    }
    result.pocketPositions = pockets;

    PABallState *cueBall = nil;
    for (PABallState *ball in balls) {
        if (ball.isCueBall || ball.number == 0) {
            cueBall = ball;
            break;
        }
    }
    if (!cueBall || bounds.width <= 0.0 || bounds.height <= 0.0) {
        result.segments = @[];
        result.collisionPoints = @[];
        result.ghostBallCenters = @[];
        result.impactedBallNumbers = @[];
        return result;
    }

    const double tableSpan = std::hypot(bounds.width, bounds.height);
    double remainingDistance = tableSpan * std::max(1.0, options.lengthMultiplier);
    PABallState *movingBall = cueBall;
    PABallState *lastBall = nil;
    PAVector origin = cueBall.position;
    PAVector direction = ResolveAimDirection(cueBall, balls, aimAngle);
    NSInteger bouncesRemaining = std::max<NSInteger>(0, options.cushionBounces);
    NSInteger collisionsRemaining = std::max<NSInteger>(1, options.collisionDepth);
    PATrajectorySegmentKind kind = PATrajectorySegmentKindCue;

    while (remainingDistance > kEpsilon && (bouncesRemaining >= 0 || collisionsRemaining > 0)) {
        const Hit hit = FindHit(origin,
                                direction,
                                movingBall.radius,
                                bounds,
                                balls,
                                movingBall,
                                lastBall,
                                remainingDistance);
        AppendSegment(segments,
                      origin,
                      hit.point,
                      kind,
                      movingBall.number,
                      hit.cushion,
                      hit.ball);
        remainingDistance -= hit.distance;
        result.finalPoint = hit.point;
        result.hasFinalPoint = YES;

        if (!hit.found) {
            break;
        }

        [collisionPoints addObject:PAValueWithVector(hit.point)];
        if (hit.cushion) {
            AppendSegment(segments,
                          hit.point,
                          Add(hit.point, Mul(Reflect(direction, hit.normal), movingBall.radius * 0.5)),
                          PATrajectorySegmentKindCushion,
                          movingBall.number,
                          YES,
                          NO);
            remainingDistance *= 0.92;
            if (bouncesRemaining <= 0) {
                break;
            }
            direction = Reflect(direction, hit.normal);
            origin = Add(hit.point, Mul(direction, movingBall.radius * 0.02 + kEpsilon));
            bouncesRemaining--;
            continue;
        }
        
        remainingDistance *= 0.85;

        if (!hit.target || collisionsRemaining <= 0) {
            break;
        }

        [ghostCenters addObject:PAValueWithVector(hit.point)];
        [impactedNumbers addObject:@(hit.target.number)];
        const PAVector targetDirection = Normalize(Sub(hit.target.position, hit.point));

        if (options.drawCueDeflection && movingBall == cueBall) {
            PAVector cueDeflection = Normalize(Sub(direction,
                                                   Mul(targetDirection,
                                                       Dot(direction, targetDirection))));
            if (options.spinX != 0.0 || options.spinY != 0.0) {
                const double spinAngle = std::atan2(options.spinY, options.spinX) * 0.15;
                const double cosA = std::cos(spinAngle);
                const double sinA = std::sin(spinAngle);
                cueDeflection = {
                    cueDeflection.x * cosA - cueDeflection.y * sinA,
                    cueDeflection.x * sinA + cueDeflection.y * cosA
                };
            }

            if (Length(cueDeflection) > 0.1) {
                const double deflectionLength = std::min(tableSpan * 0.28,
                                                         remainingDistance * 0.35);
                AppendSegment(segments,
                              hit.point,
                              Add(hit.point, Mul(cueDeflection, deflectionLength)),
                              PATrajectorySegmentKindDeflection,
                              cueBall.number,
                              false,
                              false);
            }
        }

        if (options.drawPocketAssist) {
            AppendPocketAssist(segments, hit.target, targetDirection, bounds, balls);
        }

        lastBall = movingBall;
        movingBall = hit.target;
        origin = Add(movingBall.position,
                     Mul(targetDirection, movingBall.radius * 0.02 + kEpsilon));
        direction = targetDirection;
        kind = PATrajectorySegmentKindObject;
        collisionsRemaining--;
        bouncesRemaining = std::max<NSInteger>(0, options.cushionBounces);
    }

    result.segments = segments;
    result.collisionPoints = collisionPoints;
    result.ghostBallCenters = ghostCenters;
    result.impactedBallNumbers = impactedNumbers.array;
    return result;
}

@end
