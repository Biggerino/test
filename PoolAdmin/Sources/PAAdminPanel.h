#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class PATrajectoryOptions;

/// Notification posted when trajectory options change in the admin panel.
FOUNDATION_EXPORT NSString *const PAAdminPanelTrajectoryOptionsChangedNotification;

/// Notification posted when user toggles the trajectory overlay on/off.
FOUNDATION_EXPORT NSString *const PAAdminPanelTrajectoryEnabledChangedNotification;

/// Notification posted when user toggles ball highlights.
FOUNDATION_EXPORT NSString *const PAAdminPanelBallHighlightsChangedNotification;

@interface PAAdminPanel : NSObject

+ (instancetype)shared;

/// Call once from your tweak entry point after the main window is available.
- (void)attachToWindow:(UIWindow *)window;

/// Remove the panel and toggle button from the window.
- (void)detach;

/// Programmatically show/hide the panel.
@property(nonatomic, getter=isPanelVisible) BOOL panelVisible;

/// Current trajectory options as configured by the user.
@property(nonatomic, readonly) PATrajectoryOptions *trajectoryOptions;

/// Whether the trajectory overlay is enabled.
@property(nonatomic, readonly) BOOL trajectoryEnabled;

/// Whether ball highlights are enabled.
@property(nonatomic, readonly) BOOL ballHighlightsEnabled;

/// Force a refresh of displayed player info values.
- (void)refreshPlayerInfo;

@end

NS_ASSUME_NONNULL_END
