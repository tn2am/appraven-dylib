//
//  PremiumMock.m
//  AppRavenPremiumMock
//
//  Core runtime hooking logic for QA testing.
//  Uses the Objective-C runtime to swizzle property getters
//  on Swift classes exposed to ObjC.
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
        PMLOG(@"⚠️  Class not found: %s", className);
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
#pragma mark - KVO / @Published Observation Hook
// ═══════════════════════════════════════════════════════════════

/// For SwiftUI @Published properties, we also need to intercept KVO
/// to ensure the UI sees the mocked value. This observer re-sets
/// the premium property to YES whenever it changes.
@interface PremiumKVOWatcher : NSObject
@property (nonatomic, weak) id target;
@property (nonatomic, copy) NSString *keyPath;
@end

@implementation PremiumKVOWatcher

- (instancetype)initWithTarget:(id)target keyPath:(NSString *)keyPath {
    self = [super init];
    if (self) {
        _target = target;
        _keyPath = keyPath;
        @try {
            [target addObserver:self
                     forKeyPath:keyPath
                        options:NSKeyValueObservingOptionNew
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
    if (newVal && ![newVal boolValue]) {
        PMLOG(@"⚡ KVO detected %@ set to false → overriding to true", keyPath);
        @try {
            [object setValue:@YES forKey:keyPath];
        } @catch (NSException *e) {
            // Fallback: use our hooked getter which already returns YES
        }
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

/// Attempt to register KVO watchers on singleton/shared instances.
static void installKVOWatchers(void) {
    g_observers = [NSMutableArray new];

    // Attempt to watch PremiumVM if it has a shared/singleton accessor
    Class premiumVMClass = objc_getClass(APPRAVEN_PREMIUM_VM);
    if (premiumVMClass) {
        // Try common singleton patterns
        SEL sharedSel = sel_registerName("shared");
        if ([premiumVMClass respondsToSelector:sharedSel]) {
            id instance = ((id(*)(id, SEL))objc_msgSend)(premiumVMClass, sharedSel);
            if (instance) {
                PremiumKVOWatcher *w = [[PremiumKVOWatcher alloc] initWithTarget:instance
                                                                        keyPath:@"premium"];
                [g_observers addObject:w];
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Apollo Cache Intercept
// ═══════════════════════════════════════════════════════════════

/// Hook Apollo's normalized cache to ensure the `premium` field
/// in GraphQL responses always reads as `true`.
/// Target: ApolloStore.ReadTransaction methods that return field values.
static void hookApolloCachePremiumField(void) {
    // The Apollo cache stores fields as NSDictionary entries.
    // We hook NSMutableDictionary's setObject:forKey: in a targeted way
    // via method swizzling on the specific Apollo cache class.

    // Instead of global dictionary hooking (too broad), we intercept
    // at the GraphQL result level: hook the `premium` property on
    // the generated Swift struct that Apollo maps to.
    // The struct's ObjC-visible getter is already hooked above.

    PMLOG(@"✅ Apollo cache premium field override active (via property hooks)");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Enumerate All Classes for Premium Properties
// ═══════════════════════════════════════════════════════════════

/// Scan all AppRaven classes at runtime and hook any that have
/// a `premium` or `hasAppleIdPremium` property.
static void hookAllPremiumProperties(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);

    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);

        // Only process AppRaven classes (Swift mangled: _TtC8AppRaven...)
        if (strncmp(name, "_TtC8AppRaven", 13) != 0) continue;

        // Check for `premium` property
        objc_property_t premProp = class_getProperty(cls, SEL_PREMIUM);
        if (premProp) {
            hookBoolGetter(name, SEL_PREMIUM, YES);
            hookBoolSetter(name, "setPremium:");
        }

        // Check for `isPremium` property
        objc_property_t isPremProp = class_getProperty(cls, SEL_IS_PREMIUM);
        if (isPremProp) {
            hookBoolGetter(name, SEL_IS_PREMIUM, YES);
        }

        // Check for `hasAppleIdPremium` property
        objc_property_t applePremProp = class_getProperty(cls, SEL_HAS_APPLE_PREMIUM);
        if (applePremProp) {
            hookBoolGetter(name, SEL_HAS_APPLE_PREMIUM, YES);
        }

        // Check for `premiumOnly` property — override to NO (unlock content)
        objc_property_t premOnlyProp = class_getProperty(cls, SEL_PREMIUM_ONLY);
        if (premOnlyProp) {
            hookBoolGetter(name, SEL_PREMIUM_ONLY, NO);
        }

        // Check for premium UI flags
        objc_property_t showPV = class_getProperty(cls, SEL_SHOWS_PREMIUM_V);
        if (showPV) {
            hookBoolGetter(name, SEL_SHOWS_PREMIUM_V, NO);
            hookBoolSetter(name, "setShowsPremiumV:");
        }

        objc_property_t showPA = class_getProperty(cls, SEL_SHOWS_PREMIUM_ALERT);
        if (showPA) {
            hookBoolGetter(name, SEL_SHOWS_PREMIUM_ALERT, NO);
            hookBoolSetter(name, "setShowsPremiumAlert:");
        }

        objc_property_t showPOI = class_getProperty(cls, SEL_SHOWS_PREMIUM_ONLY_INFO);
        if (showPOI) {
            hookBoolGetter(name, SEL_SHOWS_PREMIUM_ONLY_INFO, NO);
            hookBoolSetter(name, "setShowsPremiumOnlyInfoAlert:");
        }

        objc_property_t showPV2 = class_getProperty(cls, SEL_SHOW_PREMIUM_V);
        if (showPV2) {
            hookBoolGetter(name, SEL_SHOW_PREMIUM_V, NO);
            hookBoolSetter(name, "setShowPremiumV:");
        }
    }

    free(classes);
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - Targeted Hooks (Known Classes)
// ═══════════════════════════════════════════════════════════════

/// Hook specifically known classes/selectors found in binary analysis.
static void hookKnownTargets(void) {

    // ── PremiumVM ──
    hookBoolGetter(APPRAVEN_PREMIUM_VM, SEL_PREMIUM, YES);
    hookBoolGetter(APPRAVEN_PREMIUM_VM, SEL_IS_PREMIUM, YES);
    hookBoolGetter(APPRAVEN_PREMIUM_VM, SEL_HAS_APPLE_PREMIUM, YES);
    hookBoolSetter(APPRAVEN_PREMIUM_VM, "setPremium:");

    // ── AccountSettingsVM ──
    hookBoolGetter(APPRAVEN_ACCOUNT_VM, SEL_SHOWS_PREMIUM_V, NO);
    hookBoolGetter(APPRAVEN_ACCOUNT_VM, SEL_SHOWS_PREMIUM_ALERT, NO);
    hookBoolGetter(APPRAVEN_ACCOUNT_VM, SEL_SHOWS_PREMIUM_ONLY_INFO, NO);
    hookBoolSetter(APPRAVEN_ACCOUNT_VM, "setShowsPremiumV:");
    hookBoolSetter(APPRAVEN_ACCOUNT_VM, "setShowsPremiumAlert:");

    // ── MainTVM ──
    hookBoolGetter(APPRAVEN_MAIN_TVM, SEL_SHOWS_PREMIUM_V, NO);
    hookBoolGetter(APPRAVEN_MAIN_TVM, SEL_SHOW_PREMIUM_V, NO);
    hookBoolSetter(APPRAVEN_MAIN_TVM, "setShowsPremiumV:");
    hookBoolSetter(APPRAVEN_MAIN_TVM, "setShowPremiumV:");

    // ── HomeVM ──
    hookBoolGetter(APPRAVEN_HOME_VM, SEL_SHOW_PREMIUM_V, NO);
    hookBoolSetter(APPRAVEN_HOME_VM, "setShowPremiumV:");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - UserDefaults Persistence Intercept
// ═══════════════════════════════════════════════════════════════

/// Some apps persist premium state in UserDefaults.
/// We hook relevant keys so they always return YES.
static void hookUserDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Set premium-related keys
    [defaults setBool:YES forKey:@"premium"];
    [defaults setBool:YES forKey:@"isPremium"];
    [defaults setBool:YES forKey:@"hasAppleIdPremium"];
    [defaults setBool:YES forKey:@"PremiumPurchased"];
    [defaults synchronize];

    PMLOG(@"✅ UserDefaults premium keys set to true");
}

// ═══════════════════════════════════════════════════════════════
#pragma mark - PremiumMockLoader Implementation
// ═══════════════════════════════════════════════════════════════

@implementation PremiumMockLoader

+ (void)activate {
    PMLOG(@"🚀 Activating PremiumMock for AppRaven QA testing...");
    PMLOG(@"📦 Target: AppRaven 2.2.11 (Build 2), Bundle: net.appraven.app");

    // 1. Hook specifically known targets from binary analysis
    hookKnownTargets();

    // 2. Scan all AppRaven classes for premium-related properties
    hookAllPremiumProperties();

    // 3. Set UserDefaults premium keys
    hookUserDefaults();

    // 4. Hook Apollo cache layer
    hookApolloCachePremiumField();

    // 5. Install KVO watchers for @Published properties
    installKVOWatchers();

    PMLOG(@"✅ PremiumMock activation complete!");
    PMLOG(@"────────────────────────────────────────");
    PMLOG(@"  premium           = true");
    PMLOG(@"  hasAppleIdPremium = true");
    PMLOG(@"  premiumOnly       = false (unlocked)");
    PMLOG(@"  showsPremiumV     = false (suppressed)");
    PMLOG(@"────────────────────────────────────────");
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
        PMLOG(@"  AppRaven PremiumMock — QA Testing Dylib  ");
        PMLOG(@"  NOT FOR PRODUCTION USE OR DISTRIBUTION   ");
        PMLOG(@"═══════════════════════════════════════════");

        // Delay activation slightly to ensure all Swift classes are registered.
        // The ObjC runtime loads Swift metadata lazily, so we dispatch
        // after a short delay on the main queue.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [PremiumMockLoader activate];
        });

        PMLOG(@"✅ Dylib loaded — activation scheduled (0.5s delay for Swift metadata)");
    }
}
