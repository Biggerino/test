#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Call once at tweak load time (e.g. from a constructor or +load).
/// Patches all known integrity, jailbreak, attestation, and store-validation
/// checks so the app runs normally on enterprise/sideloaded installs.
@interface PAIntegrityBypass : NSObject
+ (void)install;
@end

NS_ASSUME_NONNULL_END
