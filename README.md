# AppRavenPremiumMock v3.0 — QA Testing Dylib

[![Build & Release](https://github.com/tn2am/appraven-dylib/actions/workflows/build.yml/badge.svg)](https://github.com/tn2am/appraven-dylib/actions/workflows/build.yml)
[![GitHub Release](https://img.shields.io/github/v/release/tn2am/appraven-dylib)](https://github.com/tn2am/appraven-dylib/releases/latest)

> 📥 **Tải nhanh dylib đã build sẵn:**  
> Truy cập [**Releases**](https://github.com/tn2am/appraven-dylib/releases/latest) để tải ngay `AppRavenPremiumMock.dylib` hoặc `AppRavenPremiumMock.zip`.

A dynamic library for **lab/QA testing** that hooks into AppRaven's runtime to simulate `premium = true` state without requiring a real subscription or external services.

## What's New in v3.0

> ⚡ **Added StoreKit bypass and implemented Dyld image monitor**

| Layer | v2.2 | v3.0 |
|-------|------|------|
| Property swizzle | ✅ | ✅ Enhanced |
| Setter blocking | ✅ | ✅ Enhanced |
| KVO watchers | ✅ | ✅ Strong refs + lifecycle |
| **JSON/GraphQL intercept** | ✅ | ✅ `NSJSONSerialization` & `NSURLProtocol` |
| **StoreKit (IAP) Bypass** | ❌ | ✅ `SKPaymentQueue addPayment:` mock |
| **Class load monitor** | ❌ | ✅ `_dyld_register_func_for_add_image` |
| **Periodic re-enforce** | ✅ | ✅ Every 15 seconds |
| **Lifecycle observer** | ✅ | ✅ Foreground, login, refresh |
| **UserDefaults hook** | ✅ | ✅ Read hook (`boolForKey:`) |
| **Multi-phase init** | ✅ | ✅ Init + late sweep |

### Why premium was being lost

1. **GraphQL server responses** — Apollo fetches `MyUserData` from server → `premium: false` overwrites local state
2. **Lazy-loaded Swift classes** — Some ViewModels load after user navigates → never got hooked
3. **App foreground refresh** — Coming back from background triggers data refresh → premium reset
4. **Weak KVO references** — Watchers were getting deallocated → stopped enforcing

## Project Structure

```
AppRavenPremiumMock/
├── Makefile                    # Build & integration automation
├── PremiumMock.h               # Public header + all class/selector defines
├── PremiumMock.m               # Core ObjC runtime hooking logic (v2.0)
├── entitlements.plist          # Signing entitlements
├── inject.sh                   # IPA integration script
└── README.md                   # This file
```

## How It Works

The dylib uses the **Objective-C runtime** (`objc/runtime.h`) to intercept property accessors and method returns at load time (`__attribute__((constructor))`). When loaded into the AppRaven process, it:

1. **4-Phase Initialization** — Hooks apply at 0s (immediate), 0.5s, 3s, and 8s to catch all lazy-loaded classes
2. **Hooks `PremiumVM` + all ViewModels** — Forces `premium` state to always return `true`
3. **Hooks User model properties** — Overrides `premium`, `hasAppleIdPremium`, `isSubscribed` getters
4. **Suppresses premium overlay** — Prevents `showsPremiumV`, `showPaywall`, and related alerts from triggering
5. **Marks `premiumOnly` content** — Overrides `premiumOnly` checks to return `false` (content accessible)
6. **Intercepts JSON responses** — Hooks `NSJSONSerialization` to patch `premium: true` in ALL JSON, including GraphQL
7. **Monitors class loading** — Uses `_dyld_register_func_for_add_image` to hook newly loaded classes
8. **Re-enforces every 10 seconds** — Timer re-applies all hooks periodically
9. **Lifecycle observer** — Re-hooks on foreground, login, data refresh events
10. **UserDefaults guard** — Both writes and hooks `boolForKey:` for premium keys

## Build Requirements

- **macOS** with Xcode Command Line Tools
- iOS SDK (included with Xcode)
- `ldid` for ad-hoc signing (or `codesign`)
- `optool` or `insert_dylib` for dylib injection into the Mach-O binary

### Install dependencies (macOS)

```bash
# Install optool
brew install optool

# Install ldid (if not using codesign)
brew install ldid
```

## Build

```bash
cd AppRavenPremiumMock
make            # Build the dylib
make sign       # Ad-hoc sign
make clean      # Clean build artifacts
```

## Integration into IPA

```bash
# Automated (recommended)
make inject IPA=/path/to/AppRaven_Decrypted.ipa

# Or manual steps:
./inject.sh /path/to/AppRaven_Decrypted.ipa
```

## Verification

After installing the test build, check Console/log output for:

```
[PremiumMock] ═══════════════════════════════════════════
[PremiumMock]   AppRaven PremiumMock v3.0 — QA Testing   
[PremiumMock] ═══════════════════════════════════════════
[PremiumMock] 🚀 PremiumMock v3.0 activating...
[PremiumMock] ✅ Hooked NSJSONSerialization (byte pre-check + full patch)
[PremiumMock] ✅ NSURLProtocol registered + URLSessionConfiguration hooked
[PremiumMock] ✅ Hooked SKPaymentQueue addPayment:
[PremiumMock] ✅ Installed dyld image add monitor
[PremiumMock] ✅ PremiumMock v3.0 active!
[PremiumMock]   Layer 1: Property hooks ✅
[PremiumMock]   Layer 2: UserDefaults ✅
[PremiumMock]   Layer 3: JSON patch ✅
[PremiumMock]   Layer 4: NSURLProtocol ✅
[PremiumMock]   Layer 5: KVO watchers ✅
[PremiumMock]   Layer 6: StoreKit (IAP) ✅
[PremiumMock]   Layer 7: Lifecycle ✅
[PremiumMock]   Layer 8: Timer (15s) ✅
[PremiumMock]   Layer 9: Dyld monitor ✅
```

You can also verify via lldb:

```
(lldb) po [[NSClassFromString(@"_TtC8AppRaven9PremiumVM") new] valueForKey:@"premium"]
1
```
