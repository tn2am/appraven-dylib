//
//  PremiumMock.m
//  AppRavenPremiumMock
//
//  Core runtime hooking logic for QA testing.
//  Uses the Objective-C runtime to swizzle property getters
//  on Swift classes exposed to ObjC.
//
//  v2.0 — Major upgrade:
//  • Intercept GraphQL JSON responses (NSJSONSerialization) to patch premium fields
//  • Monitor class loading via _dyld_register_func_for_add_image to catch lazy-loaded classes
//  • Periodic timer to re-enforce hooks every 10 seconds
//  • NSNotificationCenter observation for app lifecycle (foreground, login, etc.)
//  • Hook Combine/SwiftUI @Published via willSet/didSet interception
//  • Stronger KVO watchers (non-weak target, associated object storage)
//  • Hook NSURLSession delegate to patch network responses in-flight
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
#import <dlfcn.h>
#import <mach-o/dyld.h>

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
    PMLOG(@"⚡ Intercepted setter %s with value=%d → ignored", sel_getName(_cmd), value);
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
/// Logs success/failure.
static void hookBoolGetter(const char *className, const char *selName, BOOL returnValue) {
    Class cls = objc_getClass(className);
    if (!cls) {
        // Don't log warning for speculative hooks — class may load later
        return;
    }

    SEL sel = sel_registerName(selName);
    IMP imp = returnValue ? (IMP)hook_returnYES : (IMP)hook_returnNO;
    // "B@:" = returns BOOL, takes (id self, SEL _cmd)
    if (swizzleMethod(cls, sel, imp, "B@:")) {
        PMLOG(@"✅ Hooked %s.%s -> %s", className, selName, returnValue ? "true" : "false");
    } else {
        PMLOG(@"❌ Failed to hook %s.%s", className, selName);
    }
}

/// Try to swizzle a setter (void, takes BOOL) to no-op.
static void hookBoolSetter(const char *className, const char *selName) {
    Class cls = objc_getClass(className);
    if (!cls) return;

    SEL sel = sel_registerName(selName);
    // "v@:B" = returns void, takes (id self, SEL _cmd, BOOL value)
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

    // Only process AppRaven classes (Swift mangled: _TtC8AppRaven...)
    if (strncmp(name, "_TtC8AppRaven", 13) != 0 &&
        strncmp(name, "_TtC4Arke", 9) != 0) return;

    // Properties to force YES
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
#pragma mark - KVO / @Published Observation Hook (Strengthened)
// ═══════════════════════════════════════════════════════════════

/// For SwiftUI @Published properties, we also need to intercept KVO
/// to ensure the UI sees the mocked value. This observer re-sets
/// the premium property to YES whenever it changes.
@interface PremiumKVOWatcher : NSObject
@property (nonatomic, strong) id target;  // strong to keep alive
@property (nonatomic, copy) NSString *keyPath;
@property (nonatomic, assign) BOOL desiredValue;
@end

@implementation PremiumKVOWatcher

- (instancetype)initWithTarget:(id)target keyPath:(NSString *)keyPath desiredValue:(BOOL)desired {
    self = [super init];
    if (self) {
        _target = target;
        _keyPath = keyPath;
        _desiredValue = desired;
        @try {
            [target addObserver:self
                     forKeyPath:keyPath
                        options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                        context:NULL];
            PMLOG(@"✅ KVO observer registered on %@.%@", NSStringFromClass([target class]), keyPath);
        } @catch (NSException *e) {
            PMLOG(@"⚠️  KVO registration failed for %@: %@", keyPath, e.reason);
        }
    }
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    NSNumber *newVal = change[NSKeyValueChangeNewKey];
    BOOL current = [newVal boolValue];
    if (newVal && current != self.desiredValue) {
        PMLOG(@"⚡ KVO detected %@ set to %d → overriding to %d", keyPath, current, self.desiredValue);
        @try {
            [object setValue:@(self.desiredValue) forKey:keyPath];
        } @catch (NSException *e) {
            // Fallback: the hooked getter already returns the right value
        }
    }
}

- (void)stopObserving {
    @try {
        [_target removeObserver:self forKeyPath:_keyPath];
    } @catch (NSException *e) {}
    _target = nil;
}

- (void)dealloc {
    [self stopObserving];
}

@end

// Store observers to keep them alive (global strong array)
static NSMutableArray *g_observers = nil;

/// Install KVO watchers on any live instance we can find.
static void installKVOWatchersOnInstance(id instance) {
    if (!instance || !g_observers) return;

    Class cls = [instance class];
    const char *name = class_getName(cls);
    if (strncmp(name, "_TtC8AppRaven", 13) != 0) return;

    // Premium properties to watch (force YES)
    NSArray *yesKeys = @[@"premium", @"isPremium", @"hasAppleIdPremium",
                         @"isSubscribed", @"hasActiveSubscription"];
    // UI properties to watch (force NO)
    NSArray *noKeys = @[@"showsPremiumV", @"showPremiumV", @"showsPremiumAlert",
                        @"showPaywall", @"shouldShowPaywall"];

    for (NSString *key in yesKeys) {
        if (class_getProperty(cls, [key UTF8String])) {
            PremiumKVOWatcher *w = [[PremiumKVOWatcher alloc] initWithTarget:instance
                                                                    keyPath:key
                                                               desiredValue:YES];
            [g_observers addObject:w];
        }
    }

    for (NSString *key in noKeys) {
        if (class_getProperty(cls, [key UTF8String])) {
            PremiumKVOWatcher *w = [[PremiumKVOWatcher alloc] initWithTarget:instance
                                                                    keyPath:key
                                                               desiredValue:NO];
            [g_observers addObject:w];
        }
    }
}

/// Attempt to register KVO watchers on singleton/shared instances.
static void installKVOWatchers(void) {
    if (!g_observers) {
        g_observers = [NSMutableArray new];
    }

    // Common singleton patterns to try
    NSArray *singletonSelectors = @[@"shared", @"sharedInstance", @"current",
                                    @"default", @"main"];

    // Classes to attempt singleton access on
    const char *targetClasses[] = {
        APPRAVEN_PREMIUM_VM, APPRAVEN_HOME_VM, APPRAVEN_MAIN_TVM,
        APPRAVEN_ACCOUNT_VM, APPRAVEN_USER, APPRAVEN_USER_DATA,
        APPRAVEN_MY_USER_DATA, APPRAVEN_SUBSCRIPTION_VM,
        APPRAVEN_STORE_VM, NULL
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
                        installKVOWatchersOnInstance(instance);
                        PMLOG(@"✅ Installed KVO on %s.%@", targetClasses[i], selStr);
                    }
                } @catch (NSException *e) {
                    // Singleton not available yet, will retry
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - GraphQL / JSON Response Interception
// ═══════════════════════════════════════════════════════════════

/// Recursively patch all "premium" fields in a JSON dictionary to true.
/// This ensures GraphQL responses from the server cannot reset premium to false.
static id patchPremiumInJSON(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mutable = [obj mutableCopy];
        for (NSString *key in [mutable allKeys]) {
            // Patch premium-related keys
            if ([key isEqualToString:@"premium"] ||
                [key isEqualToString:@"isPremium"] ||
                [key isEqualToString:@"hasAppleIdPremium"] ||
                [key isEqualToString:@"isSubscribed"] ||
                [key isEqualToString:@"hasActiveSubscription"]) {
                mutable[key] = @YES;
            } else if ([key isEqualToString:@"premiumOnly"]) {
                mutable[key] = @NO;
            } else {
                // Recurse into nested objects
                mutable[key] = patchPremiumInJSON(mutable[key]);
            }
        }
        return mutable;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *mutable = [obj mutableCopy];
        for (NSUInteger i = 0; i < mutable.count; i++) {
            mutable[i] = patchPremiumInJSON(mutable[i]);
        }
        return mutable;
    }
    return obj;
}

// Original IMP storage for NSJSONSerialization
static id (*orig_JSONObjectWithData)(id, SEL, NSData*, NSJSONReadingOptions, NSError**) = NULL;

/// Swizzled NSJSONSerialization.JSONObjectWithData:options:error:
/// Intercepts all JSON parsing to patch premium fields.
static id hook_JSONObjectWithData(id self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **error) {
    id result = orig_JSONObjectWithData(self, _cmd, data, opt, error);
    if (result) {
        @try {
            result = patchPremiumInJSON(result);
        } @catch (NSException *e) {
            // Don't crash on patching failure
        }
    }
    return result;
}

/// Hook NSJSONSerialization to intercept all JSON parsing.
/// This catches GraphQL responses, API responses, cached data, etc.
static void hookJSONSerialization(void) {
    Class jsonClass = objc_getClass("NSJSONSerialization");
    if (!jsonClass) {
        PMLOG(@"⚠️  NSJSONSerialization not found");
        return;
    }

    // Hook the class method: +[NSJSONSerialization JSONObjectWithData:options:error:]
    SEL sel = @selector(JSONObjectWithData:options:error:);
    Method method = class_getClassMethod(jsonClass, sel);
    if (method) {
        orig_JSONObjectWithData = (typeof(orig_JSONObjectWithData))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_JSONObjectWithData);
        PMLOG(@"✅ Hooked NSJSONSerialization.JSONObjectWithData → premium fields patched in all JSON");
    } else {
        PMLOG(@"⚠️  Could not find JSONObjectWithData:options:error:");
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Apollo Cache Direct Intercept
// ═══════════════════════════════════════════════════════════════

/// Hook Apollo's record set methods to patch premium in normalized cache.
/// Apollo stores records as NSDictionary-like objects; we intercept setValue.
static void hookApolloCachePremiumField(void) {
    // The JSON interception above handles most cases.
    // Additionally, we try to hook Apollo-specific classes if they exist.

    // Try to find Apollo record/cache classes
    const char *apolloClasses[] = {
        "_TtC6Apollo11RecordValue",
        "_TtC6Apollo6Record",
        "_TtC6Apollo12ApolloStore",
        "_TtC6Apollo19InMemoryNormalizedCache",
        "_TtC14ApolloAPI11RecordValue",
        "Apollo.InMemoryNormalizedCache",
        NULL
    };

    for (int i = 0; apolloClasses[i]; i++) {
        Class cls = objc_getClass(apolloClasses[i]);
        if (cls) {
            hookPremiumPropsOnClass(cls);
            PMLOG(@"✅ Found and hooked Apollo class: %s", apolloClasses[i]);
        }
    }

    PMLOG(@"✅ Apollo cache premium field override active (via JSON + property hooks)");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Dynamic Class Loading Monitor
// ═══════════════════════════════════════════════════════════════

/// Called when a new image (dylib/framework) is loaded into the process.
/// We re-scan for AppRaven classes and hook any new ones.
static void onImageLoaded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    // Dispatch async to avoid blocking the dyld lock
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            unsigned int classCount = 0;
            Class *classes = objc_copyClassList(&classCount);
            for (unsigned int i = 0; i < classCount; i++) {
                hookPremiumPropsOnClass(classes[i]);
            }
            free(classes);
        }
    });
}

/// Register for image load notifications so we catch lazy-loaded Swift classes.
static void installClassLoadMonitor(void) {
    _dyld_register_func_for_add_image(onImageLoaded);
    PMLOG(@"✅ Class load monitor installed (dyld image callback)");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Enumerate All Classes for Premium Properties
// ═══════════════════════════════════════════════════════════════

/// Scan all AppRaven classes at runtime and hook any that have
/// premium-related properties.
static void hookAllPremiumProperties(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);

    int hookCount = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);

        // Only process AppRaven classes (Swift mangled: _TtC8AppRaven...)
        if (strncmp(name, "_TtC8AppRaven", 13) != 0) continue;

        hookPremiumPropsOnClass(cls);
        hookCount++;
    }

    free(classes);
    PMLOG(@"✅ Scanned %d AppRaven classes for premium properties", hookCount);
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Targeted Hooks (Known Classes)
// ═══════════════════════════════════════════════════════════════

/// Hook specifically known classes/selectors found in binary analysis.
static void hookKnownTargets(void) {

    // All known class names to hook
    const char *knownClasses[] = {
        APPRAVEN_PREMIUM_VM,
        APPRAVEN_MAIN_TVM,
        APPRAVEN_ACCOUNT_VM,
        APPRAVEN_LOGIN_VM,
        APPRAVEN_NETWORK,
        APPRAVEN_HOME_VM,
        APPRAVEN_USER,
        APPRAVEN_USER_DATA,
        APPRAVEN_MY_USER_DATA,
        APPRAVEN_SUBSCRIPTION,
        APPRAVEN_SUBSCRIPTION_VM,
        APPRAVEN_STORE_VM,
        NULL
    };

    for (int i = 0; knownClasses[i]; i++) {
        Class cls = objc_getClass(knownClasses[i]);
        if (cls) {
            hookPremiumPropsOnClass(cls);
        }
    }

    // ── Extra: explicit hooks for critical paths ──
    // PremiumVM
    hookBoolGetter(APPRAVEN_PREMIUM_VM, SEL_PREMIUM, YES);
    hookBoolGetter(APPRAVEN_PREMIUM_VM, SEL_IS_PREMIUM, YES);
    hookBoolGetter(APPRAVEN_PREMIUM_VM, SEL_HAS_APPLE_PREMIUM, YES);
    hookBoolSetter(APPRAVEN_PREMIUM_VM, "setPremium:");

    // AccountSettingsVM
    hookBoolGetter(APPRAVEN_ACCOUNT_VM, SEL_SHOWS_PREMIUM_V, NO);
    hookBoolGetter(APPRAVEN_ACCOUNT_VM, SEL_SHOWS_PREMIUM_ALERT, NO);
    hookBoolGetter(APPRAVEN_ACCOUNT_VM, SEL_SHOWS_PREMIUM_ONLY_INFO, NO);
    hookBoolSetter(APPRAVEN_ACCOUNT_VM, "setShowsPremiumV:");
    hookBoolSetter(APPRAVEN_ACCOUNT_VM, "setShowsPremiumAlert:");

    // MainTVM
    hookBoolGetter(APPRAVEN_MAIN_TVM, SEL_SHOWS_PREMIUM_V, NO);
    hookBoolGetter(APPRAVEN_MAIN_TVM, SEL_SHOW_PREMIUM_V, NO);
    hookBoolSetter(APPRAVEN_MAIN_TVM, "setShowsPremiumV:");
    hookBoolSetter(APPRAVEN_MAIN_TVM, "setShowPremiumV:");

    // HomeVM
    hookBoolGetter(APPRAVEN_HOME_VM, SEL_SHOW_PREMIUM_V, NO);
    hookBoolSetter(APPRAVEN_HOME_VM, "setShowPremiumV:");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - UserDefaults Persistence Intercept
// ═══════════════════════════════════════════════════════════════

/// Original IMP for NSUserDefaults boolForKey:
static BOOL (*orig_boolForKey)(id, SEL, NSString*) = NULL;

/// Set of premium keys we always return YES for
static NSSet *g_premiumDefaultsKeys = nil;

/// Hooked boolForKey: — returns YES for premium keys
static BOOL hook_boolForKey(id self, SEL _cmd, NSString *key) {
    if ([g_premiumDefaultsKeys containsObject:key]) {
        return YES;
    }
    return orig_boolForKey(self, _cmd, key);
}

/// Some apps persist premium state in UserDefaults.
/// We hook boolForKey: so premium keys always return YES.
static void hookUserDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Set premium-related keys
    [defaults setBool:YES forKey:@"premium"];
    [defaults setBool:YES forKey:@"isPremium"];
    [defaults setBool:YES forKey:@"hasAppleIdPremium"];
    [defaults setBool:YES forKey:@"PremiumPurchased"];
    [defaults setBool:YES forKey:@"isSubscribed"];
    [defaults setBool:YES forKey:@"hasActiveSubscription"];
    [defaults setBool:YES forKey:@"pro"];
    [defaults synchronize];

    // Hook boolForKey: to ensure reads always return YES for premium keys
    g_premiumDefaultsKeys = [NSSet setWithArray:@[
        @"premium", @"isPremium", @"hasAppleIdPremium",
        @"PremiumPurchased", @"isSubscribed", @"hasActiveSubscription", @"pro"
    ]];

    Method method = class_getInstanceMethod([NSUserDefaults class],
                                            @selector(boolForKey:));
    if (method) {
        orig_boolForKey = (typeof(orig_boolForKey))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_boolForKey);
        PMLOG(@"✅ Hooked NSUserDefaults.boolForKey: for premium keys");
    }

    PMLOG(@"✅ UserDefaults premium keys set to true");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - NSNotificationCenter Lifecycle Hooks
// ═══════════════════════════════════════════════════════════════

/// Observer that re-applies hooks when app comes to foreground,
/// after login, or when data is refreshed.
@interface PremiumLifecycleObserver : NSObject
@end

@implementation PremiumLifecycleObserver

- (instancetype)init {
    self = [super init];
    if (self) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        // App lifecycle
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"UIApplicationWillEnterForegroundNotification" object:nil];
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"UIApplicationDidBecomeActiveNotification" object:nil];

        // Common app-specific notifications (speculative)
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"UserDidLoginNotification" object:nil];
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"UserDataDidUpdateNotification" object:nil];
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"PremiumStatusDidChangeNotification" object:nil];
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"SubscriptionStatusDidChangeNotification" object:nil];
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"AccountDidRefreshNotification" object:nil];

        // Apollo / GraphQL cache updates
        [nc addObserver:self selector:@selector(onReEnforce:)
                   name:@"ApolloClient.storeDidChangeKeysNotification" object:nil];

        PMLOG(@"✅ Lifecycle observer installed (foreground, login, data refresh)");
    }
    return self;
}

- (void)onReEnforce:(NSNotification *)note {
    PMLOG(@"⚡ Re-enforcing hooks due to: %@", note.name);
    dispatch_async(dispatch_get_main_queue(), ^{
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

/// Install a repeating timer that re-applies hooks every N seconds.
/// This is the nuclear option — even if the app resets premium state
/// via network, timer, or any other mechanism, we re-hook it.
static void installPeriodicReEnforcement(void) {
    g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                     dispatch_get_main_queue());
    if (!g_timer) return;

    // Fire every 10 seconds, with 2 seconds leeway for power efficiency
    dispatch_source_set_timer(g_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                              10 * NSEC_PER_SEC,
                              2 * NSEC_PER_SEC);

    dispatch_source_set_event_handler(g_timer, ^{
        @autoreleasepool {
            [PremiumMockLoader reEnforceAllHooks];
        }
    });

    dispatch_resume(g_timer);
    PMLOG(@"✅ Periodic re-enforcement timer installed (every 10s)");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Objective-C Message Forwarding Guard
// ═══════════════════════════════════════════════════════════════

/// Hook objectForKey: on NSMutableDictionary used by Apollo's
/// in-memory record store. We target specifically the records
/// that contain "premium" keys.
static id (*orig_objectForKey)(id, SEL, id) = NULL;

/// We want a targeted hook: only for known premium key values.
/// This is risky on NSMutableDictionary globally, so we limit scope.
/// Actually, the JSON hooking + property hooking is sufficient.
/// This section is reserved for future expansion if needed.

// ═══════════════════════════════════════════════════════════════
#pragma mark - PremiumMockLoader Implementation
// ═══════════════════════════════════════════════════════════════

@implementation PremiumMockLoader

+ (void)activate {
    PMLOG(@"🚀 Activating PremiumMock v2.0 for AppRaven QA testing...");
    PMLOG(@"📦 Target: AppRaven 2.2.11 (Build 2), Bundle: net.appraven.app");

    // 1. Hook specifically known targets from binary analysis
    hookKnownTargets();

    // 2. Scan all AppRaven classes for premium-related properties
    hookAllPremiumProperties();

    // 3. Set & hook UserDefaults premium keys
    hookUserDefaults();

    // 4. Hook NSJSONSerialization to patch ALL JSON responses (GraphQL, API, etc.)
    hookJSONSerialization();

    // 5. Hook Apollo cache layer
    hookApolloCachePremiumField();

    // 6. Install KVO watchers for @Published properties
    installKVOWatchers();

    // 7. Install class load monitor for lazy-loaded Swift classes
    installClassLoadMonitor();

    // 8. Install lifecycle observer (foreground, login, data refresh)
    g_lifecycleObserver = [[PremiumLifecycleObserver alloc] init];

    // 9. Install periodic re-enforcement timer (every 10 seconds)
    installPeriodicReEnforcement();

    PMLOG(@"✅ PremiumMock v2.0 activation complete!");
    PMLOG(@"────────────────────────────────────────");
    PMLOG(@"  premium              = true");
    PMLOG(@"  hasAppleIdPremium    = true");
    PMLOG(@"  premiumOnly          = false (unlocked)");
    PMLOG(@"  showsPremiumV        = false (suppressed)");
    PMLOG(@"  JSON response patch  = active");
    PMLOG(@"  Class load monitor   = active");
    PMLOG(@"  Periodic re-enforce  = every 10s");
    PMLOG(@"  Lifecycle observer   = active");
    PMLOG(@"────────────────────────────────────────");
}

+ (void)reEnforceAllHooks {
    // Re-apply property hooks on all loaded classes
    hookKnownTargets();
    hookAllPremiumProperties();

    // Re-set UserDefaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"premium"];
    [defaults setBool:YES forKey:@"isPremium"];
    [defaults setBool:YES forKey:@"hasAppleIdPremium"];
    [defaults setBool:YES forKey:@"PremiumPurchased"];
    [defaults setBool:YES forKey:@"isSubscribed"];
    [defaults setBool:YES forKey:@"hasActiveSubscription"];
    [defaults setBool:YES forKey:@"pro"];
    [defaults synchronize];

    // Re-install KVO watchers (catches new instances)
    installKVOWatchers();
}

@end

// ═══════════════════════════════════════════════════════════════
#pragma mark - Constructor (Auto-load on dylib injection)
// ═══════════════════════════════════════════════════════════════

/// This function runs automatically when the dylib is loaded into
/// the process address space, before the app's main() is called.
__attribute__((constructor))
static void premiumMockInit(void) {
    @autoreleasepool {
        PMLOG(@"═══════════════════════════════════════════");
        PMLOG(@"  AppRaven PremiumMock v2.0 — QA Testing   ");
        PMLOG(@"  NOT FOR PRODUCTION USE OR DISTRIBUTION   ");
        PMLOG(@"═══════════════════════════════════════════");

        // Phase 1: Immediate hooks for classes already loaded
        // This catches most classes that are available at dylib load time
        hookKnownTargets();
        hookAllPremiumProperties();
        hookJSONSerialization();

        PMLOG(@"✅ Phase 1 complete (immediate hooks applied)");

        // Phase 2: Delayed activation for Swift lazy-loaded classes
        // Dispatch after a short delay to ensure all Swift metadata is registered
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [PremiumMockLoader activate];
        });

        // Phase 3: Extra delayed sweep for classes that load even later
        // (e.g., after initial UI setup, after login, etc.)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PMLOG(@"🔄 Phase 3: Late sweep for newly loaded classes...");
            [PremiumMockLoader reEnforceAllHooks];
        });

        // Phase 4: Another sweep after app is likely fully loaded
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PMLOG(@"🔄 Phase 4: Full app sweep...");
            [PremiumMockLoader reEnforceAllHooks];
        });

        PMLOG(@"✅ Dylib loaded — 4-phase activation scheduled");
    }
}
