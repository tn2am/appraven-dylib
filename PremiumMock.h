//
//  PremiumMock.h
//  AppRavenPremiumMock
//
//  QA Testing Dylib — Simulates premium = true for lab testing.
//  NOT for production use or distribution.
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

// ──────────────────────────────────────────────
// Property / selector names (from binary string analysis)
// ──────────────────────────────────────────────

// User model properties
#define SEL_PREMIUM              "premium"
#define SEL_IS_PREMIUM           "isPremium"
#define SEL_HAS_APPLE_PREMIUM    "hasAppleIdPremium"
#define SEL_PREMIUM_ONLY         "premiumOnly"

// UI flags (on ViewModels)
#define SEL_SHOWS_PREMIUM_V          "showsPremiumV"
#define SEL_SHOW_PREMIUM_V           "showPremiumV"
#define SEL_SHOWS_PREMIUM_ALERT      "showsPremiumAlert"
#define SEL_SHOWS_PREMIUM_ONLY_INFO  "showsPremiumOnlyInfoAlert"

// Logging prefix
#define PMLOG(fmt, ...) NSLog(@"[PremiumMock] " fmt, ##__VA_ARGS__)

// ──────────────────────────────────────────────
// Public interface
// ──────────────────────────────────────────────
@interface PremiumMockLoader : NSObject
+ (void)activate;
@end

#endif /* PremiumMock_h */
