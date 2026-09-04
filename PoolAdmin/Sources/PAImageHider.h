#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Hides our injected image from the checks the game performs by scanning
/// loaded libraries: `_dyld_image_count` / `_dyld_get_image_name` are
/// rebound in every loaded image to skip our file, and
/// +[NSBundle allFrameworks] is filtered the same way.
/// Call +install FIRST at boot, before any other hook.
@interface PAImageHider : NSObject
+ (void)install;
+ (BOOL)isHiddenImagePath:(nullable const char *)path;
@end

NS_ASSUME_NONNULL_END
