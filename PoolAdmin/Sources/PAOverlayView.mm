#import "PAOverlayView.h"
#import "PAAdminPanel.h"
#import <QuartzCore/QuartzCore.h>
#import <cmath>

@interface PAOverlayView ()

@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) PATrajectoryResult *currentTrajectoryResult;
@property (nonatomic, strong) PARuntimeSnapshot *currentSnapshot;

@end

@implementation PAOverlayView

+ (instancetype)shared {
    static PAOverlayView *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initWithFrame:CGRectZero];
    });
    return sharedInstance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        
        _trajectoryEnabled = YES;
        _espEnabled = YES;
        _pocketGuidesEnabled = YES;
        _ghostBallEnabled = YES;
        
        _options = [[PATrajectoryOptions alloc] init];
        _options.cushionBounces = 3;
        _options.collisionDepth = 4;
        _options.lengthMultiplier = 4.0;
        _options.drawCueDeflection = YES;
        _options.drawPocketAssist = YES;
        _lineWidth = 2.5;
        _lineOpacity = 0.95;
        
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(optionsChanged:) name:PAAdminPanelTrajectoryOptionsChangedNotification object:nil];
        [center addObserver:self selector:@selector(enabledChanged:) name:PAAdminPanelTrajectoryEnabledChangedNotification object:nil];
        [center addObserver:self selector:@selector(highlightsChanged:) name:PAAdminPanelBallHighlightsChangedNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self detach];
}

- (void)optionsChanged:(NSNotification *)notification {
    PAAdminPanel *panel = [PAAdminPanel shared];
    if (panel.trajectoryOptions) {
        self.options = panel.trajectoryOptions;
    }
    [self setNeedsTrajectoryUpdate];
}

- (void)enabledChanged:(NSNotification *)notification {
    PAAdminPanel *panel = [PAAdminPanel shared];
    self.trajectoryEnabled = panel.trajectoryEnabled;
    [self setNeedsTrajectoryUpdate];
}

- (void)highlightsChanged:(NSNotification *)notification {
    PAAdminPanel *panel = [PAAdminPanel shared];
    self.espEnabled = panel.ballHighlightsEnabled;
    [self setNeedsTrajectoryUpdate];
}

- (void)attachToWindow:(UIWindow *)window {
    // Idempotent: if we're already in this window, just fix the frame.
    if (self.superview == window) {
        self.frame = window.bounds;
        return;
    }
    [self detach];
    self.frame = window.bounds;
    // Insert at the back of the overlay stack so the admin toggle button
    // (added later / on top) stays tappable. Still above the game view
    // because the game view was added first.
    window.autoresizesSubviews = YES;
    [window addSubview:self];
    [window sendSubviewToBack:self];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateDisplay:)];
    // 30fps is plenty for trajectory lines and halves per-frame reflection
    // cost vs the original 120Hz. This is the single biggest perf/crash
    // win: captureSnapshot does ObjC reflection every tick.
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(15, 30, 30);
    } else {
        self.displayLink.preferredFramesPerSecond = 30;
    }
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)detach {
    [self.displayLink invalidate];
    self.displayLink = nil;
    [self removeFromSuperview];
}

- (void)setNeedsTrajectoryUpdate {
    [self setNeedsDisplay];
}

- (void)updateDisplay:(CADisplayLink *)link {
    @try {
        // Skip work entirely when overlay is off and no ESP — avoids the
        // per-frame reflection cost in menus.
        if (!self.trajectoryEnabled && !self.espEnabled && !self.pocketGuidesEnabled) {
            if (self.currentTrajectoryResult || self.currentSnapshot) {
                self.currentTrajectoryResult = nil;
                self.currentSnapshot = nil;
                [self setNeedsDisplay];
            }
            return;
        }
        PARuntimeSnapshot *snapshot = [[PARuntimeBridge shared] captureSnapshotForOverlayView:self];
        self.currentSnapshot = snapshot;

        if (snapshot && snapshot.inGame && snapshot.hasTransform && self.trajectoryEnabled &&
            snapshot.balls.count >= 2) {
            self.currentTrajectoryResult = [PATrajectoryEngine solveWithBalls:snapshot.balls
                                                                       bounds:snapshot.tableBounds
                                                                     aimAngle:snapshot.aimAngle
                                                                      options:self.options];
        } else {
            self.currentTrajectoryResult = nil;
        }

        [self setNeedsDisplay];
    } @catch (NSException *e) {
        // Suppress any frame calculation exceptions
    }
}

- (void)drawRect:(CGRect)rect {
    @try {
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) return;
        CGContextClearRect(context, rect);
        
        PARuntimeSnapshot *snapshot = self.currentSnapshot;
        if (!snapshot || !snapshot.inGame || !snapshot.hasTransform) {
            return;
        }
        
        // 1. Pocket Guides & Catch Zones
        if (self.pocketGuidesEnabled) {
            [self drawPocketGuidesInContext:context snapshot:snapshot];
        }
        
        // 2. Trajectory Lines & Indicators
        if (self.trajectoryEnabled && self.currentTrajectoryResult) {
            [self drawTrajectoryInContext:context result:self.currentTrajectoryResult snapshot:snapshot];
        }
        
        // 3. Ball ESP Overlays
        if (self.espEnabled) {
            [self drawESPInContext:context snapshot:snapshot];
        }
    } @catch (NSException *e) {
        // Suppress any frame drawing exceptions
    }
}

- (void)drawPocketGuidesInContext:(CGContextRef)context snapshot:(PARuntimeSnapshot *)snapshot {
    NSArray<NSValue *> *pockets = self.currentTrajectoryResult.pocketPositions;
    if (!pockets.count) return;
    
    for (NSValue *val in pockets) {
        PAVector physPocket = PAVectorFromValue(val);
        CGPoint p = [snapshot overlayPointForPhysicsPoint:physPocket overlayView:self];
        if (p.x == 0 && p.y == 0) continue;
        
        CGFloat catchRadius = 22.0;
        CGRect catchRect = CGRectMake(p.x - catchRadius, p.y - catchRadius, catchRadius * 2, catchRadius * 2);
        
        // Catch zone glow
        CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.0 green:1.0 blue:0.4 alpha:0.12].CGColor);
        CGContextFillEllipseInRect(context, catchRect);
        
        // Catch zone dashed ring
        CGContextSetStrokeColorWithColor(context, [UIColor colorWithRed:0.0 green:1.0 blue:0.4 alpha:0.5].CGColor);
        CGContextSetLineWidth(context, 1.2);
        CGFloat dash[] = {4.0, 3.0};
        CGContextSetLineDash(context, 0, dash, 2);
        CGContextStrokeEllipseInRect(context, catchRect);
        CGContextSetLineDash(context, 0, NULL, 0);
        
        // Pocket center bullseye
        CGFloat centerR = 5.0;
        CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.0 green:1.0 blue:0.4 alpha:0.8].CGColor);
        CGContextFillEllipseInRect(context, CGRectMake(p.x - centerR, p.y - centerR, centerR * 2, centerR * 2));
    }
}

- (void)drawTrajectoryInContext:(CGContextRef)context result:(PATrajectoryResult *)result snapshot:(PARuntimeSnapshot *)snapshot {
    // 1. Draw trajectory segments
    for (PATrajectorySegment *segment in result.segments) {
        CGPoint start = [snapshot overlayPointForPhysicsPoint:segment.start overlayView:self];
        CGPoint end = [snapshot overlayPointForPhysicsPoint:segment.end overlayView:self];
        
        if (start.x == 0 && start.y == 0 && end.x == 0 && end.y == 0) continue;
        
        UIColor *lineColor = [UIColor whiteColor];
        BOOL isDashed = NO;
        BOOL hasGlow = YES;
        CGFloat w = self.lineWidth;
        
        switch (segment.kind) {
            case PATrajectorySegmentKindCue:
                lineColor = [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:1.0];
                hasGlow = YES;
                w = self.lineWidth;
                break;
            case PATrajectorySegmentKindObject:
                lineColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.15 alpha:1.0];
                hasGlow = YES;
                w = self.lineWidth * 0.9;
                break;
            case PATrajectorySegmentKindDeflection:
                lineColor = [UIColor colorWithRed:0.0 green:0.85 blue:1.0 alpha:0.9];
                isDashed = YES;
                hasGlow = NO;
                w = self.lineWidth * 0.8;
                break;
            case PATrajectorySegmentKindPocket:
                lineColor = [UIColor colorWithRed:0.15 green:1.0 blue:0.35 alpha:1.0];
                hasGlow = YES;
                w = self.lineWidth * 1.1;
                break;
            case PATrajectorySegmentKindCushion:
                lineColor = [UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0];
                hasGlow = NO;
                w = self.lineWidth * 0.7;
                break;
            case PATrajectorySegmentKindGhostBall:
                lineColor = [UIColor colorWithWhite:1.0 alpha:0.6];
                isDashed = YES;
                break;
        }
        
        // Glow effect
        if (hasGlow) {
            CGContextSetStrokeColorWithColor(context, [lineColor colorWithAlphaComponent:0.25].CGColor);
            CGContextSetLineWidth(context, w * 3.2);
            CGContextMoveToPoint(context, start.x, start.y);
            CGContextAddLineToPoint(context, end.x, end.y);
            CGContextStrokePath(context);
        }
        
        // Core line
        CGContextSetStrokeColorWithColor(context, [lineColor colorWithAlphaComponent:self.lineOpacity].CGColor);
        CGContextSetLineWidth(context, w);
        if (isDashed) {
            CGFloat dashPattern[] = {6.0, 4.0};
            CGContextSetLineDash(context, 0, dashPattern, 2);
        } else {
            CGContextSetLineDash(context, 0, NULL, 0);
        }
        CGContextMoveToPoint(context, start.x, start.y);
        CGContextAddLineToPoint(context, end.x, end.y);
        CGContextStrokePath(context);
        CGContextSetLineDash(context, 0, NULL, 0);
        
        // Cushion bounce marker
        if (segment.cushionImpact) {
            CGFloat dotR = 4.0;
            CGContextSetFillColorWithColor(context, [UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0].CGColor);
            CGContextFillEllipseInRect(context, CGRectMake(end.x - dotR, end.y - dotR, dotR * 2, dotR * 2));
            CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(context, 1.0);
            CGContextStrokeEllipseInRect(context, CGRectMake(end.x - dotR, end.y - dotR, dotR * 2, dotR * 2));
        }
    }
    
    // 2. Ghost Ball Circles (exact position at impact)
    if (self.ghostBallEnabled) {
        for (NSValue *val in result.ghostBallCenters) {
            PAVector physCenter = PAVectorFromValue(val);
            CGPoint screenCenter = [snapshot overlayPointForPhysicsPoint:physCenter overlayView:self];
            if (screenCenter.x == 0 && screenCenter.y == 0) continue;
            
            CGFloat gbRadius = 14.0;
            CGRect gbRect = CGRectMake(screenCenter.x - gbRadius, screenCenter.y - gbRadius, gbRadius * 2, gbRadius * 2);
            
            // Translucent fill
            CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:1.0 alpha:0.22].CGColor);
            CGContextFillEllipseInRect(context, gbRect);
            
            // Crisp white dashed border
            CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1.0 alpha:0.95].CGColor);
            CGContextSetLineWidth(context, 1.5);
            CGFloat dash[] = {4.0, 3.0};
            CGContextSetLineDash(context, 0, dash, 2);
            CGContextStrokeEllipseInRect(context, gbRect);
            CGContextSetLineDash(context, 0, NULL, 0);
            
            // Center crosshair
            CGFloat chSize = 3.0;
            CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(context, 1.0);
            CGContextMoveToPoint(context, screenCenter.x - chSize, screenCenter.y);
            CGContextAddLineToPoint(context, screenCenter.x + chSize, screenCenter.y);
            CGContextMoveToPoint(context, screenCenter.x, screenCenter.y - chSize);
            CGContextAddLineToPoint(context, screenCenter.x, screenCenter.y + chSize);
            CGContextStrokePath(context);
        }
    }
}

- (void)drawESPInContext:(CGContextRef)context snapshot:(PARuntimeSnapshot *)snapshot {
    for (PABallState *ball in snapshot.balls) {
        CGPoint overlayCenter = [snapshot overlayPointForPhysicsPoint:ball.position overlayView:self];
        if (overlayCenter.x == 0 && overlayCenter.y == 0) continue;
        
        CGFloat radius = 13.0;
        CGRect ballRect = CGRectMake(overlayCenter.x - radius, overlayCenter.y - radius, radius * 2, radius * 2);
        
        UIColor *fillColor = [UIColor clearColor];
        UIColor *strokeColor = [UIColor whiteColor];
        
        if (ball.isCueBall || ball.number == 0) {
            fillColor = [UIColor colorWithWhite:1.0 alpha:0.15];
            strokeColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        } else if (ball.number >= 1 && ball.number <= 7) {
            // Solids: Vibrant blue glow
            fillColor = [UIColor colorWithRed:0.15 green:0.45 blue:1.0 alpha:0.35];
            strokeColor = [UIColor colorWithRed:0.30 green:0.65 blue:1.0 alpha:0.95];
        } else if (ball.number == 8) {
            // 8 Ball: Dark with gold border
            fillColor = [UIColor colorWithWhite:0.05 alpha:0.6];
            strokeColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:1.0];
        } else if (ball.number >= 9 && ball.number <= 15) {
            // Stripes: Vibrant orange/red glow
            fillColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.1 alpha:0.35];
            strokeColor = [UIColor colorWithRed:1.0 green:0.60 blue:0.2 alpha:0.95];
        }
        
        CGContextSetFillColorWithColor(context, fillColor.CGColor);
        CGContextSetStrokeColorWithColor(context, strokeColor.CGColor);
        CGContextSetLineWidth(context, 1.5);
        
        CGContextFillEllipseInRect(context, ballRect);
        CGContextStrokeEllipseInRect(context, ballRect);
        
        // Draw Ball Number Label
        if (ball.number > 0) {
            NSString *numStr = [NSString stringWithFormat:@"%lu", (unsigned long)ball.number];
            NSDictionary *attrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightHeavy],
                NSForegroundColorAttributeName: [UIColor whiteColor],
            };
            CGSize textSize = [numStr sizeWithAttributes:attrs];
            CGPoint textPos = CGPointMake(overlayCenter.x - textSize.width / 2.0,
                                          overlayCenter.y - textSize.height / 2.0);
            [numStr drawAtPoint:textPos withAttributes:attrs];
        }
    }
}

@end
