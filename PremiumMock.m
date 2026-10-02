//
//  PremiumMock.m
//  AppRavenPremiumMock
//
//  v2.2 — Fix premium disappearing:
//  Root cause: SwiftUI reads from Combine @Published internal storage,
//  bypassing ObjC hooked getters. Server GraphQL returns premium:false,
//  Apollo writes to @Published → Combine emits false → UI updates.
//
//  Solution: Patch at MULTIPLE layers:
//  1. NSJSONSerialization — patch ALL JSON containing "premium" (raw byte pre-check)
//  2. NSURLProtocol — intercept HTTP responses before any framework sees them
//  3. Property hooks — safety net for ObjC-level access
//  4. Periodic re-enforcement + lifecycle hooks
//

#import "PremiumMock.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <StoreKit/StoreKit.h>

// ═══════════════════════════════════════════════════════════════
#pragma mark - Forward Declarations
// ═══════════════════════════════════════════════════════════════

static void hookAllPremiumProperties(void);
static void hookKnownTargets(void);
static void hookUserDefaults(void);

// ═══════════════════════════════════════════════════════════════
#pragma mark - Replacement IMPs
// ═══════════════════════════════════════════════════════════════

static BOOL hook_returnYES(id self, SEL _cmd) { return YES; }
static BOOL hook_returnNO(id self, SEL _cmd) { return NO; }
static void hook_setterNoop(id self, SEL _cmd, BOOL value) { /* swallow */ }

// ═══════════════════════════════════════════════════════════════
#pragma mark - Swizzle Helpers
// ═══════════════════════════════════════════════════════════════

static BOOL swizzleMethod(Class cls, SEL sel, IMP newIMP, const char *types) {
    if (!cls) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        method_setImplementation(method, newIMP);
        return YES;
    } else {
        return class_addMethod(cls, sel, newIMP, types);
    }
}

static void hookBoolGetter(const char *className, const char *selName, BOOL returnValue) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    SEL sel = sel_registerName(selName);
    IMP imp = returnValue ? (IMP)hook_returnYES : (IMP)hook_returnNO;
    swizzleMethod(cls, sel, imp, "B@:");
}

static void hookBoolSetter(const char *className, const char *selName) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    SEL sel = sel_registerName(selName);
    swizzleMethod(cls, sel, (IMP)hook_setterNoop, "v@:B");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Hook All Premium Props on a Class
// ═══════════════════════════════════════════════════════════════

static void hookPremiumPropsOnClass(Class cls) {
    if (!cls) return;
    const char *name = class_getName(cls);
    if (!name || strncmp(name, "_TtC8AppRaven", 13) != 0) return;

    const char *yesProps[] = {
        SEL_PREMIUM, SEL_IS_PREMIUM, SEL_HAS_APPLE_PREMIUM,
        SEL_IS_SUBSCRIBED, SEL_HAS_ACTIVE_SUB, SEL_SUBSCRIPTION_ACTIVE,
        SEL_IS_PRO, SEL_PRO, NULL
    };
    const char *noProps[] = {
        SEL_PREMIUM_ONLY, SEL_SHOWS_PREMIUM_V, SEL_SHOW_PREMIUM_V,
        SEL_SHOWS_PREMIUM_ALERT, SEL_SHOWS_PREMIUM_ONLY_INFO,
        SEL_SHOW_PAYWALL, SEL_SHOULD_SHOW_PAYWALL, SEL_SHOWS_SUBSCRIPTION_V, NULL
    };
    const char *blockedSetters[] = {
        "setPremium:", "setIsPremium:", "setHasAppleIdPremium:",
        "setShowsPremiumV:", "setShowPremiumV:", "setShowsPremiumAlert:",
        "setShowsPremiumOnlyInfoAlert:", "setShowPaywall:",
        "setShouldShowPaywall:", "setShowsSubscriptionV:",
        "setIsSubscribed:", "setHasActiveSubscription:",
        "setSubscriptionActive:", "setIsPro:", "setPro:", NULL
    };

    for (int i = 0; yesProps[i]; i++) {
        if (class_getProperty(cls, yesProps[i]) ||
            class_getInstanceMethod(cls, sel_registerName(yesProps[i])))
            hookBoolGetter(name, yesProps[i], YES);
    }
    for (int i = 0; noProps[i]; i++) {
        if (class_getProperty(cls, noProps[i]) ||
            class_getInstanceMethod(cls, sel_registerName(noProps[i])))
            hookBoolGetter(name, noProps[i], NO);
    }
    for (int i = 0; blockedSetters[i]; i++) {
        if (class_getInstanceMethod(cls, sel_registerName(blockedSetters[i])))
            hookBoolSetter(name, blockedSetters[i]);
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - KVO Watcher (with recursion guard)
// ═══════════════════════════════════════════════════════════════

@interface PremiumKVOWatcher : NSObject
@property (nonatomic, strong) id target;
@property (nonatomic, copy) NSString *keyPath;
@property (nonatomic, assign) BOOL desiredValue;
@property (nonatomic, assign) BOOL isUpdating;
@end

@implementation PremiumKVOWatcher
- (instancetype)initWithTarget:(id)target keyPath:(NSString *)keyPath desiredValue:(BOOL)desired {
    self = [super init];
    if (self) {
        _target = target; _keyPath = keyPath; _desiredValue = desired; _isUpdating = NO;
        @try {
            [target addObserver:self forKeyPath:keyPath
                        options:NSKeyValueObservingOptionNew context:NULL];
        } @catch (NSException *e) {}
    }
    return self;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (self.isUpdating) return;
    NSNumber *newVal = change[NSKeyValueChangeNewKey];
    if (!newVal || ![newVal isKindOfClass:[NSNumber class]]) return;
    if ([newVal boolValue] != self.desiredValue) {
        self.isUpdating = YES;
        @try { [object setValue:@(self.desiredValue) forKey:keyPath]; } @catch (NSException *e) {}
        self.isUpdating = NO;
    }
}
- (void)dealloc {
    @try { [_target removeObserver:self forKeyPath:_keyPath]; } @catch (NSException *e) {}
}
@end

static NSMutableArray *g_observers = nil;

static void installKVOWatchers(void) {
    if (!g_observers) g_observers = [NSMutableArray new];
    NSArray *selNames = @[@"shared", @"sharedInstance", @"current"];
    const char *targets[] = { APPRAVEN_PREMIUM_VM, APPRAVEN_HOME_VM, APPRAVEN_MAIN_TVM,
                              APPRAVEN_ACCOUNT_VM, NULL };
    for (int i = 0; targets[i]; i++) {
        Class cls = objc_getClass(targets[i]);
        if (!cls) continue;
        for (NSString *s in selNames) {
            SEL sel = NSSelectorFromString(s);
            if (![cls respondsToSelector:sel]) continue;
            @try {
                id inst = ((id(*)(id, SEL))objc_msgSend)((id)cls, sel);
                if (!inst) continue;
                NSArray *keys = @[@"premium", @"hasAppleIdPremium", @"isPremium"];
                for (NSString *k in keys) {
                    if (class_getProperty([inst class], [k UTF8String])) {
                        PremiumKVOWatcher *w = [[PremiumKVOWatcher alloc]
                            initWithTarget:inst keyPath:k desiredValue:YES];
                        [g_observers addObject:w];
                    }
                }
            } @catch (NSException *e) {}
        }
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - JSON Response Patching (THE KEY FIX)
// ═══════════════════════════════════════════════════════════════

/// Check if raw data contains "premium" substring (fast byte scan).
/// Only if true do we bother patching the parsed JSON.
static BOOL dataContainsPremiumKey(NSData *data) {
    if (!data || data.length < 9) return NO; // "premium" = 7 chars + quotes
    const char *bytes = (const char *)data.bytes;
    NSUInteger len = data.length;
    // Search for "premium" (with quotes, as in JSON)
    const char needle[] = "\"premium\"";
    const size_t needleLen = 9;
    if (len < needleLen) return NO;
    for (NSUInteger i = 0; i <= len - needleLen; i++) {
        if (bytes[i] == '"' && memcmp(bytes + i, needle, needleLen) == 0) {
            return YES;
        }
    }
    return NO;
}

/// Recursively patch premium fields. Returns a NEW (immutable) copy
/// if modifications were made, or the original object if not.
static id patchPremiumInJSON(id obj, BOOL *didPatch) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        NSMutableDictionary *mutable = nil;

        for (NSString *key in dict) {
            id val = dict[key];
            BOOL patchThis = NO;
            id newVal = val;

            // Premium-related keys → force YES
            if ([key isEqualToString:@"premium"] ||
                [key isEqualToString:@"isPremium"] ||
                [key isEqualToString:@"hasAppleIdPremium"] ||
                [key isEqualToString:@"isSubscribed"] ||
                [key isEqualToString:@"hasActiveSubscription"]) {
                if ([val isKindOfClass:[NSNumber class]] && ![val boolValue]) {
                    newVal = @YES;
                    patchThis = YES;
                } else if (val == [NSNull null] || val == nil) {
                    newVal = @YES;
                    patchThis = YES;
                }
            }
            // premiumOnly → force NO
            else if ([key isEqualToString:@"premiumOnly"]) {
                if ([val isKindOfClass:[NSNumber class]] && [val boolValue]) {
                    newVal = @NO;
                    patchThis = YES;
                }
            }
            // Recurse into nested structures
            else if ([val isKindOfClass:[NSDictionary class]] ||
                     [val isKindOfClass:[NSArray class]]) {
                BOOL childPatched = NO;
                newVal = patchPremiumInJSON(val, &childPatched);
                patchThis = childPatched;
            }

            if (patchThis) {
                if (!mutable) mutable = [dict mutableCopy];
                mutable[key] = newVal;
                *didPatch = YES;
            }
        }

        return mutable ? [mutable copy] : obj; // return immutable copy
    }
    else if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = obj;
        NSMutableArray *mutable = nil;

        for (NSUInteger i = 0; i < arr.count; i++) {
            id val = arr[i];
            if ([val isKindOfClass:[NSDictionary class]] ||
                [val isKindOfClass:[NSArray class]]) {
                BOOL childPatched = NO;
                id newVal = patchPremiumInJSON(val, &childPatched);
                if (childPatched) {
                    if (!mutable) mutable = [arr mutableCopy];
                    mutable[i] = newVal;
                    *didPatch = YES;
                }
            }
        }

        return mutable ? [mutable copy] : obj;
    }
    return obj;
}

// Original IMP storage
static id (*orig_JSONObjectWithData)(id, SEL, NSData*, NSJSONReadingOptions, NSError**) = NULL;

/// Hooked NSJSONSerialization — patches premium fields in JSON that contains "premium" key.
/// Uses raw byte pre-check to skip non-AppRaven JSON entirely (zero overhead for ads/other SDKs).
static id hook_JSONObjectWithData(id self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **error) {
    // Fast path: call original first
    id result = orig_JSONObjectWithData(self, _cmd, data, opt, error);

    // Only patch if raw data contains "premium" — skip all other JSON (ads, analytics, etc.)
    if (result && dataContainsPremiumKey(data)) {
        @try {
            BOOL didPatch = NO;
            id patched = patchPremiumInJSON(result, &didPatch);
            if (didPatch) {
                PMLOG(@"⚡ Patched premium fields in JSON response (%lu bytes)", (unsigned long)data.length);
                return patched;
            }
        } @catch (NSException *e) {
            // Never crash — return original
        }
    }
    return result;
}

static void hookJSONSerialization(void) {
    Class jsonClass = objc_getClass("NSJSONSerialization");
    if (!jsonClass) return;

    SEL sel = @selector(JSONObjectWithData:options:error:);
    Method method = class_getClassMethod(jsonClass, sel);
    if (method) {
        orig_JSONObjectWithData = (typeof(orig_JSONObjectWithData))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_JSONObjectWithData);
        PMLOG(@"✅ Hooked NSJSONSerialization (byte pre-check + full patch)");
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - NSURLProtocol — Intercept HTTP Response Bodies
// ═══════════════════════════════════════════════════════════════

/// Custom NSURLProtocol that intercepts responses containing "premium"
/// and patches the body before delivering to the caller (Apollo, etc.)
@interface PremiumPatchURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *dataTask;
@property (nonatomic, strong) NSMutableData *receivedData;
@property (nonatomic, strong) NSURLResponse *receivedResponse;
@end

static NSURLSession *g_protocolSession = nil;

@implementation PremiumPatchURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // Don't re-process our own requests
    if ([NSURLProtocol propertyForKey:@"PremiumMockHandled" inRequest:request]) {
        return NO;
    }
    // Only intercept requests that might return premium data
    // Target: AppRaven's GraphQL API endpoint
    NSString *url = request.URL.absoluteString;
    if (!url) return NO;

    // Intercept GraphQL requests (typically POST to /graphql)
    if ([request.HTTPMethod isEqualToString:@"POST"]) {
        // Check if request body or URL contains graphql hints
        if ([url containsString:@"graphql"] ||
            [url containsString:@"appraven"] ||
            [url containsString:@"api"]) {
            return YES;
        }
        // Check Content-Type for JSON
        NSString *contentType = [request valueForHTTPHeaderField:@"Content-Type"];
        if ([contentType containsString:@"json"]) {
            // Check request body for premium/user queries
            NSData *body = request.HTTPBody;
            if (body && dataContainsPremiumKey(body)) {
                return YES;
            }
            // Also check for MyUserData query
            if (body) {
                NSString *bodyStr = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
                if (bodyStr && ([bodyStr containsString:@"MyUserData"] ||
                                [bodyStr containsString:@"premium"] ||
                                [bodyStr containsString:@"handleSubscription"])) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"PremiumMockHandled" inRequest:mutableReq];

    self.receivedData = [NSMutableData new];

    if (!g_protocolSession) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        g_protocolSession = [NSURLSession sessionWithConfiguration:config
                                                          delegate:self
                                                     delegateQueue:nil];
    }

    self.dataTask = [g_protocolSession dataTaskWithRequest:mutableReq];
    [self.dataTask resume];
}

- (void)stopLoading {
    [self.dataTask cancel];
    self.dataTask = nil;
}

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.receivedResponse = response;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [self.receivedData appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }

    NSData *finalData = self.receivedData;

    // Patch the response body if it contains premium
    if (finalData && dataContainsPremiumKey(finalData)) {
        @try {
            NSError *jsonError = nil;
            id json = [NSJSONSerialization JSONObjectWithData:finalData
                                                     options:0
                                                       error:&jsonError];
            if (json && !jsonError) {
                BOOL didPatch = NO;
                id patched = patchPremiumInJSON(json, &didPatch);
                if (didPatch) {
                    NSData *patchedData = [NSJSONSerialization dataWithJSONObject:patched
                                                                         options:0
                                                                           error:nil];
                    if (patchedData) {
                        finalData = patchedData;
                        PMLOG(@"⚡ NSURLProtocol patched premium in response (%lu→%lu bytes)",
                              (unsigned long)self.receivedData.length,
                              (unsigned long)patchedData.length);
                    }
                }
            }
        } @catch (NSException *e) {
            // Use original data
        }
    }

    // Deliver (potentially patched) response to caller
    [self.client URLProtocol:self didReceiveResponse:self.receivedResponse
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:finalData];
    [self.client URLProtocolDidFinishLoading:self];
}

@end

// ═══════════════════════════════════════════════════════════════
#pragma mark - Hook URLSessionConfiguration to inject our protocol
// ═══════════════════════════════════════════════════════════════

static IMP orig_defaultSessionConfig = NULL;
static IMP orig_ephemeralSessionConfig = NULL;

/// Inject PremiumPatchURLProtocol into session configuration's protocolClasses
static void injectProtocolIntoConfig(NSURLSessionConfiguration *config) {
    if (!config) return;
    NSMutableArray *protocols = [NSMutableArray arrayWithArray:config.protocolClasses ?: @[]];
    if (![protocols containsObject:[PremiumPatchURLProtocol class]]) {
        [protocols insertObject:[PremiumPatchURLProtocol class] atIndex:0];
        config.protocolClasses = protocols;
    }
}

static NSURLSessionConfiguration* hook_defaultSessionConfig(id self, SEL _cmd) {
    NSURLSessionConfiguration *config = ((NSURLSessionConfiguration*(*)(id,SEL))orig_defaultSessionConfig)(self, _cmd);
    injectProtocolIntoConfig(config);
    return config;
}

static NSURLSessionConfiguration* hook_ephemeralSessionConfig(id self, SEL _cmd) {
    NSURLSessionConfiguration *config = ((NSURLSessionConfiguration*(*)(id,SEL))orig_ephemeralSessionConfig)(self, _cmd);
    injectProtocolIntoConfig(config);
    return config;
}

static void hookURLSessionConfiguration(void) {
    Class cls = [NSURLSessionConfiguration class];

    // Hook +defaultSessionConfiguration
    Method m1 = class_getClassMethod(cls, @selector(defaultSessionConfiguration));
    if (m1) {
        orig_defaultSessionConfig = method_getImplementation(m1);
        method_setImplementation(m1, (IMP)hook_defaultSessionConfig);
    }

    // Hook +ephemeralSessionConfiguration
    Method m2 = class_getClassMethod(cls, @selector(ephemeralSessionConfiguration));
    if (m2) {
        orig_ephemeralSessionConfig = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)hook_ephemeralSessionConfig);
    }

    // Also register globally for shared session
    [NSURLProtocol registerClass:[PremiumPatchURLProtocol class]];

    PMLOG(@"✅ NSURLProtocol registered + URLSessionConfiguration hooked");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Class Scanning
// ═══════════════════════════════════════════════════════════════

static void hookAllPremiumProperties(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    for (unsigned int i = 0; i < classCount; i++) {
        @try { hookPremiumPropsOnClass(classes[i]); } @catch (NSException *e) {}
    }
    free(classes);
}

static void hookKnownTargets(void) {
    const char *knownClasses[] = {
        APPRAVEN_PREMIUM_VM, APPRAVEN_MAIN_TVM, APPRAVEN_ACCOUNT_VM,
        APPRAVEN_LOGIN_VM, APPRAVEN_NETWORK, APPRAVEN_HOME_VM,
        APPRAVEN_USER, APPRAVEN_USER_DATA, APPRAVEN_MY_USER_DATA,
        APPRAVEN_SUBSCRIPTION, APPRAVEN_SUBSCRIPTION_VM,
        APPRAVEN_STORE_VM, NULL
    };
    for (int i = 0; knownClasses[i]; i++) {
        Class cls = objc_getClass(knownClasses[i]);
        if (cls) hookPremiumPropsOnClass(cls);
    }

    // Explicit critical hooks
    hookBoolGetter(APPRAVEN_PREMIUM_VM, SEL_PREMIUM, YES);
    hookBoolGetter(APPRAVEN_PREMIUM_VM, SEL_IS_PREMIUM, YES);
    hookBoolGetter(APPRAVEN_PREMIUM_VM, SEL_HAS_APPLE_PREMIUM, YES);
    hookBoolSetter(APPRAVEN_PREMIUM_VM, "setPremium:");

    hookBoolGetter(APPRAVEN_ACCOUNT_VM, SEL_SHOWS_PREMIUM_V, NO);
    hookBoolGetter(APPRAVEN_ACCOUNT_VM, SEL_SHOWS_PREMIUM_ALERT, NO);
    hookBoolGetter(APPRAVEN_ACCOUNT_VM, SEL_SHOWS_PREMIUM_ONLY_INFO, NO);
    hookBoolSetter(APPRAVEN_ACCOUNT_VM, "setShowsPremiumV:");
    hookBoolSetter(APPRAVEN_ACCOUNT_VM, "setShowsPremiumAlert:");

    hookBoolGetter(APPRAVEN_MAIN_TVM, SEL_SHOWS_PREMIUM_V, NO);
    hookBoolGetter(APPRAVEN_MAIN_TVM, SEL_SHOW_PREMIUM_V, NO);
    hookBoolSetter(APPRAVEN_MAIN_TVM, "setShowsPremiumV:");
    hookBoolSetter(APPRAVEN_MAIN_TVM, "setShowPremiumV:");

    hookBoolGetter(APPRAVEN_HOME_VM, SEL_SHOW_PREMIUM_V, NO);
    hookBoolSetter(APPRAVEN_HOME_VM, "setShowPremiumV:");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - UserDefaults Hook
// ═══════════════════════════════════════════════════════════════

static BOOL (*orig_boolForKey)(id, SEL, NSString*) = NULL;
static NSSet *g_premiumDefaultsKeys = nil;

static BOOL hook_boolForKey(id self, SEL _cmd, NSString *key) {
    if (g_premiumDefaultsKeys && [g_premiumDefaultsKeys containsObject:key]) return YES;
    return orig_boolForKey ? orig_boolForKey(self, _cmd, key) : NO;
}

static void hookUserDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"premium"];
    [defaults setBool:YES forKey:@"isPremium"];
    [defaults setBool:YES forKey:@"hasAppleIdPremium"];
    [defaults setBool:YES forKey:@"PremiumPurchased"];
    [defaults setBool:YES forKey:@"isSubscribed"];
    [defaults setBool:YES forKey:@"pro"];
    [defaults synchronize];

    g_premiumDefaultsKeys = [NSSet setWithArray:@[
        @"premium", @"isPremium", @"hasAppleIdPremium",
        @"PremiumPurchased", @"isSubscribed", @"pro"
    ]];

    Method method = class_getInstanceMethod([NSUserDefaults class], @selector(boolForKey:));
    if (method) {
        orig_boolForKey = (typeof(orig_boolForKey))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_boolForKey);
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Lifecycle Observer
// ═══════════════════════════════════════════════════════════════

@interface PremiumLifecycleObserver : NSObject
@end

@implementation PremiumLifecycleObserver
- (instancetype)init {
    self = [super init];
    if (self) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"UIApplicationWillEnterForegroundNotification" object:nil];
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"UIApplicationDidBecomeActiveNotification" object:nil];
    }
    return self;
}
- (void)onReEnforce:(NSNotification *)note {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [PremiumMockLoader reEnforceAllHooks];
    });
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end

static PremiumLifecycleObserver *g_lifecycleObserver = nil;

// ═══════════════════════════════════════════════════════════════
#pragma mark - Periodic Timer
// ═══════════════════════════════════════════════════════════════

static dispatch_source_t g_timer = nil;

static void installPeriodicReEnforcement(void) {
    g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                     dispatch_get_main_queue());
    if (!g_timer) return;
    dispatch_source_set_timer(g_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                              15 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(g_timer, ^{
        @autoreleasepool {
            @try { [PremiumMockLoader reEnforceAllHooks]; } @catch (NSException *e) {}
        }
    });
    dispatch_resume(g_timer);
    PMLOG(@"✅ Timer installed (15s)");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - StoreKit Bypass (IAP Mock)
// ═══════════════════════════════════════════════════════════════

// Mock a successful SKPaymentTransaction
@interface MockPaymentTransaction : NSObject
@property (nonatomic, strong) SKPayment *payment;
@property (nonatomic, assign) SKPaymentTransactionState transactionState;
@property (nonatomic, strong) NSString *transactionIdentifier;
@property (nonatomic, strong) NSDate *transactionDate;
@property (nonatomic, strong) NSData *transactionReceipt;
@end

@implementation MockPaymentTransaction
@end

static void hook_addPayment(id self, SEL _cmd, SKPayment *payment) {
    PMLOG(@"💎 Intercepted SKPaymentQueue addPayment: %@", payment.productIdentifier);
    
    // Create a fake successful transaction
    MockPaymentTransaction *mockTx = [[MockPaymentTransaction alloc] init];
    mockTx.payment = payment;
    mockTx.transactionState = SKPaymentTransactionStatePurchased;
    mockTx.transactionIdentifier = [[NSUUID UUID] UUIDString];
    mockTx.transactionDate = [NSDate date];
    
    // Deliver it to all observers
    NSArray *observers = [self valueForKey:@"_observers"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (id observer in observers) {
            if ([observer respondsToSelector:@selector(paymentQueue:updatedTransactions:)]) {
                [observer paymentQueue:self updatedTransactions:@[mockTx]];
                PMLOG(@"💎 Sent fake success transaction to observer: %@", observer);
            }
        }
    });
}

static void hookStoreKit(void) {
    Class queueCls = objc_getClass("SKPaymentQueue");
    if (queueCls) {
        Method m = class_getInstanceMethod(queueCls, @selector(addPayment:));
        if (m) {
            method_setImplementation(m, (IMP)hook_addPayment);
            PMLOG(@"✅ Hooked SKPaymentQueue addPayment:");
        }
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Dyld Image Monitor
// ═══════════════════════════════════════════════════════════════

static void image_added(const struct mach_header *mh, intptr_t vmaddr_slide) {
    // When a new binary/framework is loaded, check if we need to re-apply hooks
    // This catches lazy-loaded Swift libraries or views.
    dispatch_async(dispatch_get_main_queue(), ^{
        hookKnownTargets();
    });
}

static void installDyldMonitor(void) {
    _dyld_register_func_for_add_image(image_added);
    PMLOG(@"✅ Installed dyld image add monitor");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - PremiumMockLoader
// ═══════════════════════════════════════════════════════════════

@implementation PremiumMockLoader

+ (void)activate {
    PMLOG(@"🚀 PremiumMock v3.0 activating...");

    // Layer 1: Property hooks (ObjC getter/setter swizzle)
    hookKnownTargets();
    hookAllPremiumProperties();

    // Layer 2: UserDefaults
    hookUserDefaults();

    // Layer 3: JSON response patching (NSJSONSerialization hook)
    hookJSONSerialization();

    // Layer 4: NSURLProtocol — intercept HTTP responses BEFORE any framework
    hookURLSessionConfiguration();

    // Layer 5: KVO watchers
    installKVOWatchers();

    // Layer 6: StoreKit fake purchase success
    hookStoreKit();

    // Layer 7: Lifecycle observer
    g_lifecycleObserver = [[PremiumLifecycleObserver alloc] init];

    // Layer 8: Periodic timer
    installPeriodicReEnforcement();

    // Layer 9: Dyld monitor
    installDyldMonitor();

    PMLOG(@"✅ PremiumMock v3.0 active!");
    PMLOG(@"  Layer 1: Property hooks ✅");
    PMLOG(@"  Layer 2: UserDefaults ✅");
    PMLOG(@"  Layer 3: JSON patch ✅");
    PMLOG(@"  Layer 4: NSURLProtocol ✅");
    PMLOG(@"  Layer 5: KVO watchers ✅");
    PMLOG(@"  Layer 6: StoreKit (IAP) ✅");
    PMLOG(@"  Layer 7: Lifecycle ✅");
    PMLOG(@"  Layer 8: Timer (15s) ✅");
    PMLOG(@"  Layer 9: Dyld monitor ✅");
}

+ (void)reEnforceAllHooks {
    @try {
        hookKnownTargets();
        hookAllPremiumProperties();

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setBool:YES forKey:@"premium"];
        [d setBool:YES forKey:@"isPremium"];
        [d setBool:YES forKey:@"hasAppleIdPremium"];
        [d setBool:YES forKey:@"PremiumPurchased"];
        [d setBool:YES forKey:@"isSubscribed"];
        [d setBool:YES forKey:@"pro"];
        [d synchronize];

        installKVOWatchers();
    } @catch (NSException *e) {}
}

@end

// ═══════════════════════════════════════════════════════════════
#pragma mark - Constructor
// ═══════════════════════════════════════════════════════════════

__attribute__((constructor))
static void premiumMockInit(void) {
    @autoreleasepool {
        PMLOG(@"═══════════════════════════════════════════");
        PMLOG(@"  AppRaven PremiumMock v3.0 — QA Testing   ");
        PMLOG(@"═══════════════════════════════════════════");

        // Activate after Swift metadata loaded
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [PremiumMockLoader activate];
        });

        // Late sweep
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PMLOG(@"🔄 Late sweep...");
            [PremiumMockLoader reEnforceAllHooks];
        });
    }
}
