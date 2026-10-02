//
//  PremiumMock.m
//  AppRavenPremiumMock
//
//  Core runtime hooking logic for QA testing.
//  Uses the Objective-C runtime to swizzle property getters
//  on Swift classes exposed to ObjC.
//
//  v2.1 — Crash-safe version:
//  • Removed _dyld_register_func_for_add_image (causes deadlock)
//  • Targeted JSON patching (only AppRaven data, not global)
//  • Safe KVO with recursion guard
//  • Periodic timer for re-enforcement (safe approach)
//
//  Binary analysis findings (AppRaven 2.2.11, build 2):
//  ─────────────────────────────────────────────────────
//  • PremiumVM  (_TtC8AppRaven9PremiumVM)  — ViewModel managing premium state
//  • User model has: premium (Bool), hasAppleIdPremium (Bool)
//  • Content models have: premiumOnly (Bool)
//  • UI flags: _showsPremiumV, _showsPremiumAlert,
//              _showsPremiumOnlyInfoAlert, _showPremiumV
//  • Subscription tiers: premiumMonthly, premiumYearly, premiumOnce
//  • GraphQL: MyUserData fragment includes `premium` field
//  • Apollo GraphQL client stores user data in normalized cache
//

#import "PremiumMock.h"
#import <objc/runtime.h>
#import <objc/message.h>

// ═══════════════════════════════════════════════════════════════
#pragma mark - Forward Declarations
// ═══════════════════════════════════════════════════════════════

static void hookAllPremiumProperties(void);
static void hookKnownTargets(void);
static void hookUserDefaults(void);

// ═══════════════════════════════════════════════════════════════
#pragma mark - Replacement IMPs (Implementations)
// ═══════════════════════════════════════════════════════════════

// Returns YES — used to override premium/hasAppleIdPremium getters
static BOOL hook_returnYES(id self, SEL _cmd) {
    return YES;
}

// Returns NO — used to override premiumOnly and showsPremiumV getters
static BOOL hook_returnNO(id self, SEL _cmd) {
    return NO;
}

// No-op setter — swallows any attempt to set premium = false
static void hook_setterNoop(id self, SEL _cmd, BOOL value) {
    // Ignore value; premium stays true
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Swizzle Helpers
// ═══════════════════════════════════════════════════════════════

/// Swizzle an instance method on a class. If the method doesn't exist,
/// add it with the replacement IMP instead.
static BOOL swizzleMethod(Class cls, SEL sel, IMP newIMP, const char *types) {
    if (!cls) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        method_setImplementation(method, newIMP);
        return YES;
    } else {
        // Method doesn't exist — add it dynamically
        return class_addMethod(cls, sel, newIMP, types);
    }
}

/// Try to swizzle a getter (returns BOOL) on a class by name.
static void hookBoolGetter(const char *className, const char *selName, BOOL returnValue) {
    Class cls = objc_getClass(className);
    if (!cls) return;

    SEL sel = sel_registerName(selName);
    IMP imp = returnValue ? (IMP)hook_returnYES : (IMP)hook_returnNO;
    if (swizzleMethod(cls, sel, imp, "B@:")) {
        PMLOG(@"✅ Hooked %s.%s -> %s", className, selName, returnValue ? "true" : "false");
    }
}

/// Try to swizzle a setter (void, takes BOOL) to no-op.
static void hookBoolSetter(const char *className, const char *selName) {
    Class cls = objc_getClass(className);
    if (!cls) return;

    SEL sel = sel_registerName(selName);
    if (swizzleMethod(cls, sel, (IMP)hook_setterNoop, "v@:B")) {
        PMLOG(@"✅ Hooked setter %s.%s -> noop", className, selName);
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Hook a Single AppRaven Class (All Premium Props)
// ═══════════════════════════════════════════════════════════════

/// Hooks all premium-related properties on a single class.
/// Can be called repeatedly (idempotent — re-sets IMP each time).
static void hookPremiumPropsOnClass(Class cls) {
    if (!cls) return;
    const char *name = class_getName(cls);
    if (!name) return;

    // Only process AppRaven classes (Swift mangled: _TtC8AppRaven...)
    if (strncmp(name, "_TtC8AppRaven", 13) != 0) return;

    // Properties to force YES (only if property actually exists on class)
    const char *yesProps[] = {
        SEL_PREMIUM, SEL_IS_PREMIUM, SEL_HAS_APPLE_PREMIUM,
        SEL_IS_SUBSCRIBED, SEL_HAS_ACTIVE_SUB, SEL_SUBSCRIPTION_ACTIVE,
        SEL_IS_PRO, SEL_PRO, NULL
    };
    // Properties to force NO
    const char *noProps[] = {
        SEL_PREMIUM_ONLY, SEL_SHOWS_PREMIUM_V, SEL_SHOW_PREMIUM_V,
        SEL_SHOWS_PREMIUM_ALERT, SEL_SHOWS_PREMIUM_ONLY_INFO,
        SEL_SHOW_PAYWALL, SEL_SHOULD_SHOW_PAYWALL, SEL_SHOWS_SUBSCRIPTION_V, NULL
    };
    // Setters to block (noop)
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
            class_getInstanceMethod(cls, sel_registerName(yesProps[i]))) {
            hookBoolGetter(name, yesProps[i], YES);
        }
    }

    for (int i = 0; noProps[i]; i++) {
        if (class_getProperty(cls, noProps[i]) ||
            class_getInstanceMethod(cls, sel_registerName(noProps[i]))) {
            hookBoolGetter(name, noProps[i], NO);
        }
    }

    for (int i = 0; blockedSetters[i]; i++) {
        SEL setSel = sel_registerName(blockedSetters[i]);
        if (class_getInstanceMethod(cls, setSel)) {
            hookBoolSetter(name, blockedSetters[i]);
        }
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - KVO / @Published Observation Hook (Safe)
// ═══════════════════════════════════════════════════════════════

/// KVO watcher with recursion guard to prevent infinite loop.
@interface PremiumKVOWatcher : NSObject
@property (nonatomic, strong) id target;
@property (nonatomic, copy) NSString *keyPath;
@property (nonatomic, assign) BOOL desiredValue;
@property (nonatomic, assign) BOOL isUpdating; // recursion guard
@end

@implementation PremiumKVOWatcher

- (instancetype)initWithTarget:(id)target keyPath:(NSString *)keyPath desiredValue:(BOOL)desired {
    self = [super init];
    if (self) {
        _target = target;
        _keyPath = keyPath;
        _desiredValue = desired;
        _isUpdating = NO;
        @try {
            [target addObserver:self
                     forKeyPath:keyPath
                        options:NSKeyValueObservingOptionNew
                        context:NULL];
            PMLOG(@"✅ KVO observer on %@.%@", NSStringFromClass([target class]), keyPath);
        } @catch (NSException *e) {
            PMLOG(@"⚠️  KVO failed for %@: %@", keyPath, e.reason);
        }
    }
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    // Recursion guard — prevent infinite loop
    if (self.isUpdating) return;

    NSNumber *newVal = change[NSKeyValueChangeNewKey];
    if (!newVal || ![newVal isKindOfClass:[NSNumber class]]) return;

    BOOL current = [newVal boolValue];
    if (current != self.desiredValue) {
        self.isUpdating = YES;
        @try {
            [object setValue:@(self.desiredValue) forKey:keyPath];
        } @catch (NSException *e) {
            // Fallback: the hooked getter already returns the right value
        }
        self.isUpdating = NO;
    }
}

- (void)dealloc {
    @try {
        [_target removeObserver:self forKeyPath:_keyPath];
    } @catch (NSException *e) {}
}

@end

// Store observers to keep them alive
static NSMutableArray *g_observers = nil;

/// Install KVO watchers on singleton/shared instances.
static void installKVOWatchers(void) {
    if (!g_observers) {
        g_observers = [NSMutableArray new];
    }

    NSArray *singletonSelectors = @[@"shared", @"sharedInstance", @"current"];

    const char *targetClasses[] = {
        APPRAVEN_PREMIUM_VM, APPRAVEN_HOME_VM, APPRAVEN_MAIN_TVM,
        APPRAVEN_ACCOUNT_VM, NULL
    };

    for (int i = 0; targetClasses[i]; i++) {
        Class cls = objc_getClass(targetClasses[i]);
        if (!cls) continue;

        for (NSString *selStr in singletonSelectors) {
            SEL sel = NSSelectorFromString(selStr);
            if ([cls respondsToSelector:sel]) {
                @try {
                    id instance = ((id(*)(id, SEL))objc_msgSend)((id)cls, sel);
                    if (instance) {
                        // Only add watchers for properties that actually exist
                        if (class_getProperty([instance class], "premium")) {
                            PremiumKVOWatcher *w = [[PremiumKVOWatcher alloc]
                                initWithTarget:instance keyPath:@"premium" desiredValue:YES];
                            [g_observers addObject:w];
                        }
                        if (class_getProperty([instance class], "hasAppleIdPremium")) {
                            PremiumKVOWatcher *w = [[PremiumKVOWatcher alloc]
                                initWithTarget:instance keyPath:@"hasAppleIdPremium" desiredValue:YES];
                            [g_observers addObject:w];
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Targeted JSON Response Patching
// ═══════════════════════════════════════════════════════════════

/// Recursively patch premium fields in a JSON object.
static id patchPremiumInJSON(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mutable = [obj mutableCopy];
        for (NSString *key in [mutable allKeys]) {
            if ([key isEqualToString:@"premium"] ||
                [key isEqualToString:@"isPremium"] ||
                [key isEqualToString:@"hasAppleIdPremium"]) {
                mutable[key] = @YES;
            } else if ([key isEqualToString:@"premiumOnly"]) {
                mutable[key] = @NO;
            } else {
                id val = mutable[key];
                if ([val isKindOfClass:[NSDictionary class]] ||
                    [val isKindOfClass:[NSArray class]]) {
                    mutable[key] = patchPremiumInJSON(val);
                }
            }
        }
        return mutable;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *mutable = [obj mutableCopy];
        for (NSUInteger i = 0; i < mutable.count; i++) {
            id val = mutable[i];
            if ([val isKindOfClass:[NSDictionary class]] ||
                [val isKindOfClass:[NSArray class]]) {
                mutable[i] = patchPremiumInJSON(val);
            }
        }
        return mutable;
    }
    return obj;
}

/// Check if JSON data looks like an AppRaven GraphQL response
/// by looking for "data" key with nested user/premium fields.
static BOOL isAppRavenGraphQLResponse(id obj) {
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *dict = obj;

    // GraphQL responses have a "data" key
    if (dict[@"data"]) return YES;

    // Or direct user data with premium field
    if (dict[@"premium"] || dict[@"hasAppleIdPremium"] ||
        dict[@"isPremium"] || dict[@"MyUserData"]) return YES;

    return NO;
}

// Original IMP storage for NSJSONSerialization
static id (*orig_JSONObjectWithData)(id, SEL, NSData*, NSJSONReadingOptions, NSError**) = NULL;

/// Swizzled JSONObjectWithData — ONLY patches AppRaven GraphQL responses
static id hook_JSONObjectWithData(id self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **error) {
    id result = orig_JSONObjectWithData(self, _cmd, data, opt, error);
    if (result) {
        @try {
            // Only patch if it looks like AppRaven data
            if (isAppRavenGraphQLResponse(result)) {
                result = patchPremiumInJSON(result);
            }
        } @catch (NSException *e) {
            // Never crash — return original result
        }
    }
    return result;
}

/// Hook NSJSONSerialization — targeted to only patch AppRaven responses.
static void hookJSONSerialization(void) {
    Class jsonClass = objc_getClass("NSJSONSerialization");
    if (!jsonClass) return;

    SEL sel = @selector(JSONObjectWithData:options:error:);
    Method method = class_getClassMethod(jsonClass, sel);
    if (method) {
        orig_JSONObjectWithData = (typeof(orig_JSONObjectWithData))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_JSONObjectWithData);
        PMLOG(@"✅ Hooked NSJSONSerialization (targeted GraphQL patching)");
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Apollo Cache Intercept
// ═══════════════════════════════════════════════════════════════

static void hookApolloCachePremiumField(void) {
    PMLOG(@"✅ Apollo cache premium field override active (via JSON + property hooks)");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Enumerate All Classes for Premium Properties
// ═══════════════════════════════════════════════════════════════

/// Scan all AppRaven classes at runtime and hook any that have
/// premium-related properties.
static void hookAllPremiumProperties(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    int hookCount = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        @try {
            Class cls = classes[i];
            const char *name = class_getName(cls);
            if (!name) continue;

            // Only process AppRaven classes
            if (strncmp(name, "_TtC8AppRaven", 13) != 0) continue;

            hookPremiumPropsOnClass(cls);
            hookCount++;
        } @catch (NSException *e) {
            // Skip problematic classes
        }
    }

    free(classes);
    PMLOG(@"✅ Scanned %d AppRaven classes", hookCount);
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Targeted Hooks (Known Classes)
// ═══════════════════════════════════════════════════════════════

/// Hook specifically known classes/selectors found in binary analysis.
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
        if (cls) {
            hookPremiumPropsOnClass(cls);
        }
    }

    // ── Extra: explicit hooks for critical paths ──
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
#pragma mark - UserDefaults Persistence Intercept
// ═══════════════════════════════════════════════════════════════

/// Original IMP for NSUserDefaults boolForKey:
static BOOL (*orig_boolForKey)(id, SEL, NSString*) = NULL;

/// Premium keys set
static NSSet *g_premiumDefaultsKeys = nil;

/// Hooked boolForKey: — returns YES for premium keys only
static BOOL hook_boolForKey(id self, SEL _cmd, NSString *key) {
    if (g_premiumDefaultsKeys && [g_premiumDefaultsKeys containsObject:key]) {
        return YES;
    }
    if (orig_boolForKey) {
        return orig_boolForKey(self, _cmd, key);
    }
    return NO;
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

    Method method = class_getInstanceMethod([NSUserDefaults class],
                                            @selector(boolForKey:));
    if (method) {
        orig_boolForKey = (typeof(orig_boolForKey))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_boolForKey);
        PMLOG(@"✅ Hooked NSUserDefaults.boolForKey: for premium keys");
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Lifecycle Observer (App Foreground, etc.)
// ═══════════════════════════════════════════════════════════════

@interface PremiumLifecycleObserver : NSObject
@end

@implementation PremiumLifecycleObserver

- (instancetype)init {
    self = [super init];
    if (self) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        // App lifecycle — these are the real UIKit notification names
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"UIApplicationWillEnterForegroundNotification" object:nil];
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"UIApplicationDidBecomeActiveNotification" object:nil];

        PMLOG(@"✅ Lifecycle observer installed");
    }
    return self;
}

- (void)onReEnforce:(NSNotification *)note {
    PMLOG(@"⚡ Re-enforcing hooks (%@)", note.name);
    // Delay slightly to let the app finish its own updates first
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [PremiumMockLoader reEnforceAllHooks];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

static PremiumLifecycleObserver *g_lifecycleObserver = nil;

// ═══════════════════════════════════════════════════════════════
#pragma mark - Periodic Re-Enforcement Timer
// ═══════════════════════════════════════════════════════════════

static dispatch_source_t g_timer = nil;

/// Repeating timer that re-applies hooks every 15 seconds.
static void installPeriodicReEnforcement(void) {
    g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                     dispatch_get_main_queue());
    if (!g_timer) return;

    // Fire every 15 seconds, with 5 seconds leeway for power efficiency
    dispatch_source_set_timer(g_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                              15 * NSEC_PER_SEC,
                              5 * NSEC_PER_SEC);

    dispatch_source_set_event_handler(g_timer, ^{
        @autoreleasepool {
            @try {
                [PremiumMockLoader reEnforceAllHooks];
            } @catch (NSException *e) {
                PMLOG(@"⚠️  Timer re-enforce error: %@", e.reason);
            }
        }
    });

    dispatch_resume(g_timer);
    PMLOG(@"✅ Periodic re-enforcement timer installed (every 15s)");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - PremiumMockLoader Implementation
// ═══════════════════════════════════════════════════════════════

@implementation PremiumMockLoader

+ (void)activate {
    PMLOG(@"🚀 Activating PremiumMock v2.1 for AppRaven QA testing...");

    // 1. Hook known targets from binary analysis
    hookKnownTargets();

    // 2. Scan all AppRaven classes
    hookAllPremiumProperties();

    // 3. Set & hook UserDefaults
    hookUserDefaults();

    // 4. Hook JSON parsing (targeted — only GraphQL responses)
    hookJSONSerialization();

    // 5. Apollo cache layer
    hookApolloCachePremiumField();

    // 6. KVO watchers for @Published properties
    installKVOWatchers();

    // 7. Lifecycle observer (foreground)
    g_lifecycleObserver = [[PremiumLifecycleObserver alloc] init];

    // 8. Periodic re-enforcement timer
    installPeriodicReEnforcement();

    PMLOG(@"✅ PremiumMock v2.1 activation complete!");
    PMLOG(@"────────────────────────────────────────");
    PMLOG(@"  premium              = true");
    PMLOG(@"  hasAppleIdPremium    = true");
    PMLOG(@"  premiumOnly          = false (unlocked)");
    PMLOG(@"  showsPremiumV        = false (suppressed)");
    PMLOG(@"  JSON patch           = targeted GraphQL only");
    PMLOG(@"  Periodic re-enforce  = every 15s");
    PMLOG(@"  Lifecycle observer   = active");
    PMLOG(@"────────────────────────────────────────");
}

+ (void)reEnforceAllHooks {
    @try {
        hookKnownTargets();
        hookAllPremiumProperties();

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:YES forKey:@"premium"];
        [defaults setBool:YES forKey:@"isPremium"];
        [defaults setBool:YES forKey:@"hasAppleIdPremium"];
        [defaults setBool:YES forKey:@"PremiumPurchased"];
        [defaults setBool:YES forKey:@"isSubscribed"];
        [defaults setBool:YES forKey:@"pro"];
        [defaults synchronize];

        installKVOWatchers();
    } @catch (NSException *e) {
        PMLOG(@"⚠️  reEnforceAllHooks error: %@", e.reason);
    }
}

@end

// ═══════════════════════════════════════════════════════════════
#pragma mark - Constructor (Auto-load on dylib injection)
// ═══════════════════════════════════════════════════════════════

__attribute__((constructor))
static void premiumMockInit(void) {
    @autoreleasepool {
        PMLOG(@"═══════════════════════════════════════════");
        PMLOG(@"  AppRaven PremiumMock v2.1 — QA Testing   ");
        PMLOG(@"  NOT FOR PRODUCTION USE OR DISTRIBUTION   ");
        PMLOG(@"═══════════════════════════════════════════");

        // Delayed activation to ensure Swift classes are registered
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [PremiumMockLoader activate];
        });

        // Second sweep after app is more fully loaded
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PMLOG(@"🔄 Late sweep for newly loaded classes...");
            [PremiumMockLoader reEnforceAllHooks];
        });

        PMLOG(@"✅ Dylib loaded — activation scheduled");
    }
}
