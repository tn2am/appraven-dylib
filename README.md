# AppRavenPremiumMock — QA Testing Dylib

A dynamic library for **lab/QA testing** that hooks into AppRaven's runtime to simulate `premium = true` state without requiring a real subscription or external services.

## Project Structure

```
AppRavenPremiumMock/
├── Makefile                    # Build & integration automation
├── Tweak.x                     # Logos/ObjC runtime hooks (main hook file)
├── PremiumMock.h               # Public header
├── PremiumMock.m               # Core ObjC runtime hooking logic
├── entitlements.plist          # Signing entitlements
├── inject.sh                   # IPA integration script
└── README.md                   # This file
```

## How It Works

The dylib uses the **Objective-C runtime** (`objc/runtime.h`) to intercept property accessors and method returns at load time (`__attribute__((constructor))`). When loaded into the AppRaven process, it:

1. **Hooks `PremiumVM`** — Forces `premium` state to always return `true`
2. **Hooks User model properties** — Overrides `premium` and `hasAppleIdPremium` getters
3. **Suppresses premium overlay** — Prevents `_showsPremiumV` and related alerts from triggering
4. **Marks `premiumOnly` content** — Overrides `premiumOnly` checks to return `false` (content accessible)

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
[PremiumMock] ✅ Dylib loaded successfully
[PremiumMock] ✅ Hooked PremiumVM.premium -> true
[PremiumMock] ✅ Hooked user.premium -> true
[PremiumMock] ✅ Hooked hasAppleIdPremium -> true
[PremiumMock] ✅ Suppressed premium overlay
[PremiumMock] ✅ premiumOnly -> false (content unlocked)
```

You can also verify via lldb:

```
(lldb) po [[NSClassFromString(@"_TtC8AppRaven9PremiumVM") new] valueForKey:@"premium"]
1
```
