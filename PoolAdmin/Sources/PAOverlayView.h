#import <UIKit/UIKit.h>
#import "PATrajectoryEngine.h"
#import "PARuntimeBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface PAOverlayView : UIView

+ (instancetype)shared;

/// Attach to the game window. Automatically starts rendering.
- (void)attachToWindow:(UIWindow *)window;
- (void)detach;

/// Master toggles
@property(nonatomic) BOOL trajectoryEnabled;
@property(nonatomic) BOOL espEnabled;
@property(nonatomic) BOOL pocketGuidesEnabled;
@property(nonatomic) BOOL ghostBallEnabled;

/// Trajectory options (shared with admin panel)
@property(nonatomic, strong) PATrajectoryOptions *options;

/// Visual customization
@property(nonatomic) CGFloat lineWidth;
@property(nonatomic) CGFloat lineOpacity;

/// Force an immediate redraw
- (void)setNeedsTrajectoryUpdate;

@end

NS_ASSUME_NONNULL_END
