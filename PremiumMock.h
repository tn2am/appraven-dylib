//
//  PremiumMock.h
//  AppRavenPremiumMock
//
//  QA Testing Dylib — Simulates premium = true for lab testing.
//  NOT for production use or distribution.
//
//  v3.0 — Added StoreKit (In-App Purchase) fake success mock and
//         dyld image load monitor for lazy-loaded Swift classes.
//
//  v2.2 — Comprehensive hooks including GraphQL response interception,
//         periodic re-enforcement, and NSNotificationCenter observation.
//

#ifndef PremiumMock_h
#define PremiumMock_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ──────────────────────────────────────────────
// Target class names (Swift mangled names from binary analysis)
// ──────────────────────────────────────────────
#define APPRAVEN_PREMIUM_VM     "_TtC8AppRaven9PremiumVM"
#define APPRAVEN_MAIN_TVM       "_TtC8AppRaven7MainTVM"
#define APPRAVEN_ACCOUNT_VM     "_TtC8AppRaven17AccountSettingsVM"
#define APPRAVEN_LOGIN_VM       "_TtC8AppRaven7LoginVM"
#define APPRAVEN_NETWORK        "_TtC8AppRaven7Network"
#define APPRAVEN_HOME_VM        "_TtC8AppRaven6HomeVM"
#define APPRAVEN_USER           "_TtC8AppRaven4User"
#define APPRAVEN_USER_DATA      "_TtC8AppRaven8UserData"
#define APPRAVEN_MY_USER_DATA   "_TtC8AppRaven10MyUserData"
#define APPRAVEN_SUBSCRIPTION   "_TtC8AppRaven12Subscription"
#define APPRAVEN_SUBSCRIPTION_VM "_TtC8AppRaven14SubscriptionVM"
#define APPRAVEN_STORE_VM       "_TtC8AppRaven7StoreVM"

// ──────────────────────────────────────────────
// Property / selector names (from binary string analysis)
// ──────────────────────────────────────────────

// User model properties
#define SEL_PREMIUM              "premium"
#define SEL_IS_PREMIUM           "isPremium"
#define SEL_HAS_APPLE_PREMIUM    "hasAppleIdPremium"
#define SEL_PREMIUM_ONLY         "premiumOnly"
#define SEL_IS_SUBSCRIBED        "isSubscribed"
#define SEL_HAS_ACTIVE_SUB       "hasActiveSubscription"
#define SEL_SUBSCRIPTION_ACTIVE  "subscriptionActive"
#define SEL_IS_PRO               "isPro"
#define SEL_PRO                  "pro"

// UI flags (on ViewModels)
#define SEL_SHOWS_PREMIUM_V          "showsPremiumV"
#define SEL_SHOW_PREMIUM_V           "showPremiumV"
#define SEL_SHOWS_PREMIUM_ALERT      "showsPremiumAlert"
#define SEL_SHOWS_PREMIUM_ONLY_INFO  "showsPremiumOnlyInfoAlert"
#define SEL_SHOW_PAYWALL             "showPaywall"
#define SEL_SHOULD_SHOW_PAYWALL      "shouldShowPaywall"
#define SEL_SHOWS_SUBSCRIPTION_V     "showsSubscriptionV"

// Logging prefix
#ifdef DEBUG_PREMIUMMOCK
#define PMLOG(fmt, ...) NSLog(@"[PremiumMock] " fmt, ##__VA_ARGS__)
#else
#define PMLOG(fmt, ...) NSLog(@"[PremiumMock] " fmt, ##__VA_ARGS__)
#endif

// ──────────────────────────────────────────────
// Public interface
// ──────────────────────────────────────────────
@interface PremiumMockLoader : NSObject
+ (void)activate;
+ (void)reEnforceAllHooks;
@end

#endif /* PremiumMock_h */
