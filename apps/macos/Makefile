# Build + package the WiZ Light Controller menu-bar app.
#
# Targets:
#   make bundle  - regenerate the JS engine bundle (if Node is available)
#   make build   - swift build -c release
#   make icon    - build build/AppIcon.icns from the source PNG
#   make app     - assemble + codesign "build/WiZ Light Controller.app"
#   make run     - open the assembled app
#   make clean   - remove build artifacts
#
# Signing: ad-hoc ("-") by default. Pass a Developer ID via CODESIGN_IDENTITY,
# e.g. `make app CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)"`.

REPO_ROOT := ../..
APP_NAME := WiZ Light Controller
APP_DIR := build/$(APP_NAME).app
EXECUTABLE := WizApp
RELEASE_BIN := .build/release/$(EXECUTABLE)
JS_BUNDLE := Sources/WizKit/Resources/wiz-core.global.js
ICON_SRC := $(REPO_ROOT)/assets/app_iconhigh.png
# Ad-hoc ("-") by default. Pass a Developer ID via CODESIGN_IDENTITY; an unset or
# empty value (e.g. CI passing an unconfigured secret) falls back to ad-hoc — an
# env/CLI var set to "" is still "defined", so a plain `?=` wouldn't catch it.
override CODESIGN_IDENTITY := $(if $(strip $(CODESIGN_IDENTITY)),$(CODESIGN_IDENTITY),-)

.PHONY: bundle build icon app run clean

# Regenerate the shared engine bundle from @wiz/core. Needs Node 24 + pnpm at
# the repo root. If neither is available the committed bundle suffices, so this
# is a no-op rather than a hard failure.
bundle:
	@if command -v pnpm >/dev/null 2>&1; then \
	  echo "Regenerating JS bundle via pnpm build:jscore"; \
	  ( cd $(REPO_ROOT) && pnpm build:jscore ); \
	else \
	  echo "pnpm not found — using committed $(JS_BUNDLE)"; \
	fi

build:
	swift build -c release

# Build an .icns from the 512x512 source via a temp .iconset + sips resizes.
# A 1024x1024 source is ideal (lets sips produce the @2x 512 slot natively);
# with a 512 source the largest slots are upscaled, which is acceptable here.
icon:
	@rm -rf build/AppIcon.iconset build/AppIcon.icns
	@mkdir -p build/AppIcon.iconset
	@sips -z 16 16     "$(ICON_SRC)" --out build/AppIcon.iconset/icon_16x16.png      >/dev/null
	@sips -z 32 32     "$(ICON_SRC)" --out build/AppIcon.iconset/icon_16x16@2x.png   >/dev/null
	@sips -z 32 32     "$(ICON_SRC)" --out build/AppIcon.iconset/icon_32x32.png      >/dev/null
	@sips -z 64 64     "$(ICON_SRC)" --out build/AppIcon.iconset/icon_32x32@2x.png   >/dev/null
	@sips -z 128 128   "$(ICON_SRC)" --out build/AppIcon.iconset/icon_128x128.png    >/dev/null
	@sips -z 256 256   "$(ICON_SRC)" --out build/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	@sips -z 256 256   "$(ICON_SRC)" --out build/AppIcon.iconset/icon_256x256.png    >/dev/null
	@sips -z 512 512   "$(ICON_SRC)" --out build/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	@sips -z 512 512   "$(ICON_SRC)" --out build/AppIcon.iconset/icon_512x512.png    >/dev/null
	@sips -z 1024 1024 "$(ICON_SRC)" --out build/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	@iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
	@rm -rf build/AppIcon.iconset
	@echo "Built build/AppIcon.icns"

# Assemble the .app bundle and codesign it. Copies the JS engine bundle into
# Contents/Resources so WizCore finds it via Bundle.main at runtime.
app: build icon
	@rm -rf "$(APP_DIR)"
	@mkdir -p "$(APP_DIR)/Contents/MacOS"
	@mkdir -p "$(APP_DIR)/Contents/Resources"
	@cp "$(RELEASE_BIN)" "$(APP_DIR)/Contents/MacOS/$(EXECUTABLE)"
	@cp build/Info.plist "$(APP_DIR)/Contents/Info.plist"
	@cp build/AppIcon.icns "$(APP_DIR)/Contents/Resources/AppIcon.icns"
	@# WizCore loads this via Bundle.main at runtime (it lives in Contents/Resources).
	@cp "$(JS_BUNDLE)" "$(APP_DIR)/Contents/Resources/wiz-core.global.js"
	@codesign --force --deep --options runtime \
	  --entitlements build/WizLightController.entitlements \
	  -s "$(CODESIGN_IDENTITY)" "$(APP_DIR)"
	@echo "Built and signed $(APP_DIR)"

run:
	open "$(APP_DIR)"

clean:
	rm -rf .build build/*.app build/*.icns build/*.iconset
