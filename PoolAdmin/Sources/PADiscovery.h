#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runtime discovery: enumerates classes/methods in the main executable
/// whose names match integrity-check keywords (receipt, attestation,
/// jailbreak, fraud, tamper, store validation, kill switches) and logs
/// them to the file log. Run once on-device; the output tells us exactly
/// which selectors 56.29 verdicts on, so hooks can target those instead
/// of guessing. Bounded output (stops after kMaxLines).
@interface PADiscovery : NSObject
+ (void)run;
+ (void)runInBackground;
@end

NS_ASSUME_NONNULL_END
