#import "PAGrantService.h"

#import <Security/Security.h>

#import "PARuntimeBridge.h"

namespace {

static NSString *const kTokenService = @"com.miniclip.8ballpoolmult.pool-admin";
static NSString *const kTokenAccount = @"grant-api-bearer";
static NSString *const kAuditDefaultsKey = @"PoolAdmin.Audit.v1";
static const NSUInteger kMaximumAuditEvents = 200;

static NSArray<NSDictionary *> *DefaultCatalog(void) {
    return @[
        @{ @"title": @"Coins", @"kind": @"coins", @"amount": @100000 },
        @{ @"title": @"Cash", @"kind": @"cash", @"amount": @500 },
        @{ @"title": @"XP", @"kind": @"xp", @"amount": @25000 },
        @{ @"title": @"VIP Points", @"kind": @"vip_points", @"amount": @1000 },
        @{ @"title": @"Pool Points", @"kind": @"pool_points", @"productId": @"38156", @"amount": @1000 },
        @{ @"title": @"Cue Pieces", @"kind": @"cue_pieces", @"requiresProductId": @YES, @"amount": @20 },
        @{ @"title": @"Cue", @"kind": @"cue", @"requiresProductId": @YES, @"amount": @1 },
        @{ @"title": @"Product", @"kind": @"product", @"requiresProductId": @YES, @"amount": @1 },
        @{ @"title": @"Golden Shots", @"kind": @"golden_shot", @"requiresProductId": @YES, @"amount": @5 },
        @{ @"title": @"Lucky Shots", @"kind": @"lucky_shot", @"requiresProductId": @YES, @"amount": @5 },
        @{ @"title": @"Victory Boxes", @"kind": @"victory_box", @"requiresProductId": @YES, @"amount": @3 },
        @{ @"title": @"Spins", @"kind": @"spin", @"requiresProductId": @YES, @"amount": @10 },
        @{ @"title": @"Scratchers", @"kind": @"scratcher", @"requiresProductId": @YES, @"amount": @10 },
        @{ @"title": @"Tournament Tickets", @"kind": @"tournament_ticket", @"requiresProductId": @YES, @"amount": @5 },
        @{ @"title": @"Avatar", @"kind": @"avatar", @"requiresProductId": @YES, @"amount": @1 },
        @{ @"title": @"Decal", @"kind": @"decal", @"requiresProductId": @YES, @"amount": @1 },
        @{ @"title": @"Season Pass", @"kind": @"season_pass", @"amount": @1 },
        @{ @"title": @"Elite Pass", @"kind": @"elite_pass", @"amount": @1 },
    ];
}

static NSArray<NSDictionary *> *DefaultPresets(void) {
    return @[
        @{ @"title": @"Economy QA",
           @"grants": @[
               @{ @"kind": @"coins", @"amount": @1000000 },
               @{ @"kind": @"cash", @"amount": @10000 },
               @{ @"kind": @"xp", @"amount": @100000 },
               @{ @"kind": @"vip_points", @"amount": @5000 },
           ] },
        @{ @"title": @"Pass QA",
           @"grants": @[
               @{ @"kind": @"season_pass", @"amount": @1 },
               @{ @"kind": @"elite_pass", @"amount": @1 },
               @{ @"kind": @"pool_points", @"productId": @"38156", @"amount": @5000 },
           ] },
        @{ @"title": @"Minigames QA",
           @"grants": @[
               @{ @"kind": @"golden_shot", @"amount": @10 },
               @{ @"kind": @"lucky_shot", @"amount": @10 },
               @{ @"kind": @"spin", @"amount": @25 },
               @{ @"kind": @"scratcher", @"amount": @25 },
           ] },
    ];
}

static NSString *ISO8601Now(void) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ formatter = [NSISO8601DateFormatter new]; });
    return [formatter stringFromDate:NSDate.date];
}

}  // namespace

@interface PAGrantService ()
@property(nonatomic, copy) NSDictionary *configuration;
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *catalog;
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *presets;
@end

@implementation PAGrantService

+ (instancetype)shared {
    static PAGrantService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [PAGrantService new]; });
    return service;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *path = [NSBundle.mainBundle pathForResource:@"PoolAdminConfig" ofType:@"plist"];
        NSDictionary *configuration = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        _configuration = [configuration isKindOfClass:NSDictionary.class] ? configuration : @{};
        NSArray *catalog = _configuration[@"Catalog"];
        NSArray *presets = _configuration[@"Presets"];
        _catalog = [catalog isKindOfClass:NSArray.class] && catalog.count ? catalog : DefaultCatalog();
        _presets = [presets isKindOfClass:NSArray.class] && presets.count ? presets : DefaultPresets();
    }
    return self;
}

- (BOOL)endpointConfigured {
    NSString *endpoint = self.configuration[@"GrantEndpoint"];
    NSURL *url = [endpoint isKindOfClass:NSString.class] ? [NSURL URLWithString:endpoint] : nil;
    return url != nil && [url.scheme.lowercaseString isEqualToString:@"https"];
}

- (NSString *)endpointDescription {
    NSString *endpoint = self.configuration[@"GrantEndpoint"];
    return self.endpointConfigured ? endpoint : @"Not configured";
}

- (NSMutableDictionary *)keychainQuery {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kTokenService,
        (__bridge id)kSecAttrAccount: kTokenAccount,
    } mutableCopy];
}

- (NSString *)storedBearerToken {
    NSMutableDictionary *query = [self keychainQuery];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nullptr;
    const OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (BOOL)storeBearerToken:(NSString *)token error:(NSError **)error {
    NSMutableDictionary *query = [self keychainQuery];
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus status;
    if (token.length == 0) {
        status = SecItemDelete((__bridge CFDictionaryRef)query);
        if (status == errSecItemNotFound) status = errSecSuccess;
    } else {
        NSDictionary *attributes = @{(__bridge id)kSecValueData: data};
        status = SecItemUpdate((__bridge CFDictionaryRef)query,
                               (__bridge CFDictionaryRef)attributes);
        if (status == errSecItemNotFound) {
            query[(__bridge id)kSecValueData] = data;
            query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
            status = SecItemAdd((__bridge CFDictionaryRef)query, nullptr);
        }
    }
    if (status != errSecSuccess && error) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    }
    return status == errSecSuccess;
}

- (void)submitServerGrants:(NSArray<NSDictionary *> *)grants completion:(PAGrantCompletion)completion {
    [self grantItems:grants completion:completion];
}

- (void)grantItems:(NSArray<NSDictionary *> *)grants completion:(PAGrantCompletion)completion {
    [self applyGrants:grants completion:completion];
    
    NSString *token = [self storedBearerToken];
    if (!self.endpointConfigured || token.length == 0) {
        return;
    }
    
    NSDictionary *player = [PARuntimeBridge.shared playerSummary];
    NSString *accountId = [player[@"userId"] description];
    if (accountId.length == 0) {
        return;
    }

    NSString *requestId = NSUUID.UUID.UUIDString;
    NSDictionary *bundleInfo = NSBundle.mainBundle.infoDictionary;
    NSDictionary *body = @{
        @"schemaVersion": @1,
        @"requestId": requestId,
        @"requestedAt": ISO8601Now(),
        @"accountId": accountId,
        @"source": @"ios-pool-admin",
        @"grants": grants,
        @"client": @{
            @"bundleId": NSBundle.mainBundle.bundleIdentifier ?: @"",
            @"version": bundleInfo[@"CFBundleShortVersionString"] ?: @"",
            @"build": bundleInfo[@"CFBundleVersion"] ?: @"",
        },
    };
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!jsonData) {
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.configuration[@"GrantEndpoint"]]
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:20.0];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:requestId forHTTPHeaderField:@"Idempotency-Key"];

    NSURLSessionConfiguration *sessionConfiguration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    sessionConfiguration.timeoutIntervalForRequest = 20.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfiguration];
    [self appendAuditEvent:@"server-grant-request" details:@{ @"requestId": requestId, @"grants": grants }];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data,
                                                             NSURLResponse *response,
                                                             NSError *networkError) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL success = !networkError && http.statusCode >= 200 && http.statusCode < 300;
        NSString *message = networkError.localizedDescription;
        if (!message.length && [json[@"message"] isKindOfClass:NSString.class]) message = json[@"message"];
        if (!message.length) message = success ? @"Grant accepted" : [NSString stringWithFormat:@"Grant service returned HTTP %ld.", (long)http.statusCode];
        [self appendAuditEvent:success ? @"server-grant-accepted" : @"server-grant-failed"
                         details:@{ @"requestId": requestId,
                                    @"status": @(http.statusCode),
                                    @"message": message }];
        [session finishTasksAndInvalidate];
    }] resume];
}

- (void)applyGrants:(NSArray<NSDictionary *> *)grants completion:(PAGrantCompletion)completion {
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    NSUInteger applied = 0;
    for (NSDictionary *grant in grants) {
        NSError *error = nil;
        if ([PARuntimeBridge.shared applyGrant:grant error:&error]) {
            applied++;
        } else {
            [failures addObject:error.localizedDescription ?: @"Unknown grant error"];
        }
    }
    NSString *message;
    if (failures.count == 0) {
        message = [NSString stringWithFormat:@"Applied %lu grant%@ successfully.",
                   (unsigned long)applied,
                   applied == 1 ? @"" : @"s"];
    } else {
        message = [NSString stringWithFormat:@"Applied %lu; %@",
                   (unsigned long)applied,
                   [failures componentsJoinedByString:@" · "]];
    }
    [self appendAuditEvent:@"runtime-grant" details:@{ @"grants": grants,
                                                      @"applied": @(applied),
                                                      @"failures": failures }];
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(applied > 0, message, nil);
        });
    }
}

- (void)applyOfflineFixtureGrants:(NSArray<NSDictionary *> *)grants completion:(PAGrantCompletion)completion {
    [self applyGrants:grants completion:completion];
}

- (void)appendAuditEvent:(NSString *)event details:(NSDictionary *)details {
    if (!event.length) return;
    @synchronized (self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableArray *events = [[defaults arrayForKey:kAuditDefaultsKey] mutableCopy] ?: [NSMutableArray array];
        NSMutableDictionary *entry = [@{ @"timestamp": ISO8601Now(), @"event": event } mutableCopy];
        if (details) entry[@"details"] = details;
        [events addObject:entry];
        if (events.count > kMaximumAuditEvents) {
            [events removeObjectsInRange:NSMakeRange(0, events.count - kMaximumAuditEvents)];
        }
        [defaults setObject:events forKey:kAuditDefaultsKey];
    }
}

- (NSArray<NSDictionary *> *)recentAuditEvents {
    NSArray *events = [NSUserDefaults.standardUserDefaults arrayForKey:kAuditDefaultsKey];
    return [events isKindOfClass:NSArray.class] ? events : @[];
}

- (NSString *)exportAuditJSON {
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self recentAuditEvents]
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
}

@end
