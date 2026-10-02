#
# Makefile — AppRavenPremiumMock
#
# Build a .dylib for QA testing of AppRaven premium state.
#
# Usage:
#   make                          Build the dylib
#   make sign                     Ad-hoc sign with ldid
#   make codesign                 Sign with codesign (alternative)
#   make inject IPA=<path.ipa>    Inject into IPA and repackage
#   make clean                    Remove build artifacts
#

# ── Configuration ──────────────────────────────────────────────
DYLIB_NAME     = AppRavenPremiumMock
OUTPUT         = $(DYLIB_NAME).dylib
SOURCES        = PremiumMock.m
HEADERS        = PremiumMock.h
ENTITLEMENTS   = entitlements.plist

# ── Toolchain ──────────────────────────────────────────────────
# Adjust SDK path if needed. Find yours with:
#   xcrun --sdk iphoneos --show-sdk-path
CC             = clang
SDKROOT       ?= $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
ARCH           = arm64
MIN_IOS        = 15.0

# ── Compiler Flags ─────────────────────────────────────────────
CFLAGS  = -arch $(ARCH) \
          -isysroot $(SDKROOT) \
          -miphoneos-version-min=$(MIN_IOS) \
          -dynamiclib \
          -fobjc-arc \
          -Wall \
          -Wextra \
          -O2 \
          -DNDEBUG

LDFLAGS = -framework Foundation \
          -framework UIKit \
          -lobjc

# ── Targets ────────────────────────────────────────────────────

.PHONY: all clean sign codesign inject help

all: $(OUTPUT)

$(OUTPUT): $(SOURCES) $(HEADERS)
	@echo "╔═══════════════════════════════════════════════╗"
	@echo "║  Building $(DYLIB_NAME).dylib                ║"
	@echo "╚═══════════════════════════════════════════════╝"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(OUTPUT) $(SOURCES)
	@echo "✅ Built: $(OUTPUT)"
	@file $(OUTPUT)

sign: $(OUTPUT)
	@echo "── Signing with ldid ──"
	ldid -S$(ENTITLEMENTS) $(OUTPUT)
	@echo "✅ Signed: $(OUTPUT)"

codesign: $(OUTPUT)
	@echo "── Signing with codesign ──"
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(OUTPUT)
	@echo "✅ Signed: $(OUTPUT)"

inject: $(OUTPUT)
	@if [ -z "$(IPA)" ]; then \
		echo "❌ Usage: make inject IPA=/path/to/AppRaven.ipa"; \
		exit 1; \
	fi
	@echo "── Injecting into IPA ──"
	chmod +x inject.sh
	./inject.sh "$(IPA)" "$(OUTPUT)"

clean:
	@echo "── Cleaning ──"
	rm -f $(OUTPUT)
	rm -rf build/
	@echo "✅ Clean"

help:
	@echo ""
	@echo "AppRavenPremiumMock — QA Testing Dylib"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  make              Build the dylib"
	@echo "  make sign         Sign with ldid"
	@echo "  make codesign     Sign with codesign"
	@echo "  make inject IPA=  Inject into IPA"
	@echo "  make clean        Remove artifacts"
	@echo ""
