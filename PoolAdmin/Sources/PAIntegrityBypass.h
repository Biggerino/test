#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Call once at tweak load time (e.g. from a constructor or +load).
/// Patches all known integrity, jailbreak, attestation, and store-validation
/// checks so the app runs normally on enterprise/sideloaded installs.
@interface PAIntegrityBypass : NSObject

/// Full install: all hooks including UIKit-dependent ones (alert suppression).
/// Call from DidFinishLaunching or later.
+ (void)install;

/// Early install: hooks that don't require UIKit. Safe to call from a
/// constructor (__attribute__((constructor))). Installs App Attest
/// neutralisation, receipt hooks, direct-kill hooks, game-class swizzles,
/// and filesystem cloaking. Does NOT install alert suppression (needs UIKit).
+ (void)installEarly;

@end

NS_ASSUME_NONNULL_END
