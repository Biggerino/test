#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PAGrantCompletion)(BOOL success, NSString *message, NSDictionary * _Nullable response);

@interface PAGrantService : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) BOOL endpointConfigured;
@property(nonatomic, copy, readonly) NSString *endpointDescription;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *catalog;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *presets;
- (nullable NSString *)storedBearerToken;
- (BOOL)storeBearerToken:(NSString *)token error:(NSError * _Nullable * _Nullable)error;
- (void)submitServerGrants:(NSArray<NSDictionary *> *)grants completion:(PAGrantCompletion)completion;
- (void)grantItems:(NSArray<NSDictionary *> *)grants completion:(PAGrantCompletion)completion;
- (void)applyGrants:(NSArray<NSDictionary *> *)grants completion:(PAGrantCompletion)completion;
- (void)applyOfflineFixtureGrants:(NSArray<NSDictionary *> *)grants completion:(PAGrantCompletion)completion;
- (void)appendAuditEvent:(NSString *)event details:(NSDictionary * _Nullable)details;
- (NSArray<NSDictionary *> *)recentAuditEvents;
- (NSString *)exportAuditJSON;
@end

NS_ASSUME_NONNULL_END
