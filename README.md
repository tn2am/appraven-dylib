# AppRavenPremiumMock v2.0 — QA Testing Dylib

[![Build & Release](https://github.com/tn2am/appraven-dylib/actions/workflows/build.yml/badge.svg)](https://github.com/tn2am/appraven-dylib/actions/workflows/build.yml)
[![GitHub Release](https://img.shields.io/github/v/release/tn2am/appraven-dylib)](https://github.com/tn2am/appraven-dylib/releases/latest)

> 📥 **Tải nhanh dylib đã build sẵn:**  
> Truy cập [**Releases**](https://github.com/tn2am/appraven-dylib/releases/latest) để tải ngay `AppRavenPremiumMock.dylib` hoặc `AppRavenPremiumMock.zip`.

A dynamic library for **lab/QA testing** that hooks into AppRaven's runtime to simulate `premium = true` state without requiring a real subscription or external services.

## What's New in v2.0

> ⚡ **Fixes the issue where premium disappears after a while.**

| Layer | v1.0 | v2.0 |
|-------|------|------|
| Property swizzle | ✅ | ✅ Enhanced (more selectors) |
| Setter blocking | ✅ | ✅ Enhanced (all setters) |
| KVO watchers | ⚠️ Weak refs | ✅ Strong refs + lifecycle |
| **JSON/GraphQL intercept** | ❌ | ✅ `NSJSONSerialization` hook |
| **Class load monitor** | ❌ | ✅ `_dyld_register_func_for_add_image` |
| **Periodic re-enforce** | ❌ | ✅ Every 10 seconds |
| **Lifecycle observer** | ❌ | ✅ Foreground, login, refresh |
| **UserDefaults hook** | ⚠️ Write only | ✅ Read hook (`boolForKey:`) |
| **Multi-phase init** | ⚠️ Single delay | ✅ 4-phase (0s, 0.5s, 3s, 8s) |

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
[PremiumMock]   AppRaven PremiumMock v2.0 — QA Testing   
[PremiumMock] ═══════════════════════════════════════════
[PremiumMock] ✅ Phase 1 complete (immediate hooks applied)
[PremiumMock] ✅ Hooked NSJSONSerialization.JSONObjectWithData → premium fields patched
[PremiumMock] ✅ PremiumMock v2.0 activation complete!
[PremiumMock]   premium              = true
[PremiumMock]   hasAppleIdPremium    = true
[PremiumMock]   premiumOnly          = false (unlocked)
[PremiumMock]   JSON response patch  = active
[PremiumMock]   Class load monitor   = active
[PremiumMock]   Periodic re-enforce  = every 10s
[PremiumMock]   Lifecycle observer   = active
```

You can also verify via lldb:

```
(lldb) po [[NSClassFromString(@"_TtC8AppRaven9PremiumVM") new] valueForKey:@"premium"]
1
```
