#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Hooks StoreKit so that in-app purchases are intercepted and items
/// are granted directly to the account via the runtime bridge.
/// Call +install once at tweak load time.
@interface PAStoreInterceptor : NSObject
+ (void)install;
@end

NS_ASSUME_NONNULL_END
