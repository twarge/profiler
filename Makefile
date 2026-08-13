# Builds Profiler, the Mac and iPad beam-profiler app.
#
#   make            debug build
#   make release    optimised build
#   make test       build, then run the analyser self-test
#   make run        Debug build and launch (matches Xcode's Run action)
#   make bench      per-stage timings for one frame
#   make ios        optimised build for an iPad
#   make ios-sim    build for the iOS Simulator
#   make icon       re-render the app icon
#   make clean
#
# make builds into its own DerivedData (build/DerivedData), deliberately not
# Xcode's: two build systems writing one Products directory is a race. Xcode
# relinks a dylib inside the .app while make's build is still signing the
# bundle, and CodeSign fails with a nonzero exit. The price is one extra full
# compile the first time; after that both stay incremental in their own trees.
#
# Concurrent makes are serialized behind Scripts/with-build-lock for the same
# reason — two `make test` runs would otherwise race each other's codesign.

.PHONY: all mac release test run bench ios ios-sim icon clean

DERIVED = build/DerivedData
XCB = xcodebuild -project apps/Profiler.xcodeproj -scheme Profiler \
  -derivedDataPath $(DERIVED)
LOCK = Scripts/with-build-lock

BUILT = $(XCB) -showBuildSettings
APP_DEBUG = $(shell $(BUILT) -configuration Debug 2>/dev/null \
	| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2}')/Profiler.app
APP_RELEASE = $(shell $(BUILT) -configuration Release 2>/dev/null \
	| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2}')/Profiler.app

all: mac

mac:
	$(LOCK) $(XCB) -destination "platform=macOS" -configuration Debug \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built for macOS (Debug)"

release:
	$(LOCK) $(XCB) -destination "platform=macOS" -configuration Release \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built for macOS (Release)"

# Validates the ISO 11146 moment calculation against analytically-known beams.
# Runs the built binary directly, so it exercises the same code the app ships.
# Under the lock: re-signing a binary while it runs kills it mid-test.
test: mac
	@$(LOCK) "$(APP_DEBUG)/Contents/MacOS/Profiler" --self-test

# The shared scheme's Run action uses Debug, so this builds and launches that same
# configuration. `open` does not attach LLDB; press Run in Xcode when a debugger is needed.
run: mac
	@open "$(APP_DEBUG)"

# Installing on an iPad is a ⌘R from Xcode; these just check the build. Release for the
# same reason `run` is — see above. Edit Scheme › Run › Build Configuration › Release
# before running on the device, or the analyser will drop most frames.
ios:
	$(LOCK) $(XCB) -destination "generic/platform=iOS" -configuration Release \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built for iOS (Release)"

ios-sim:
	$(LOCK) $(XCB) -destination "generic/platform=iOS Simulator" \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built for iOS Simulator"

# Redraws the icon into the asset catalog. The PNGs are committed, so this is only
# needed when the design in the script changes. Colormap.swift is compiled in rather
# than having its colours copied, so the icon cannot drift from the beam view.
# The generator runs under the lock: it rewrites PNGs a concurrent build may be
# signing into the app.
icon:
	@mkdir -p build
	@swiftc -O -o build/make-app-icon Scripts/make-app-icon.swift \
	  apps/Profiler/Sources/Analysis/Colormap.swift \
	  apps/Profiler/Sources/Analysis/BeamFrame.swift
	@$(LOCK) build/make-app-icon

# Everything make produces lives under build/, so this is the whole clean.
# Xcode's own DerivedData is Xcode's to manage.
clean:
	rm -rf build

# Where a frame's time goes, stage by stage. Release for the same reason `run` is —
# a debug build's profile is dominated by retain/release and bounds checks, which is
# not the profile that ships.
bench: release
	@$(LOCK) "$(APP_RELEASE)/Contents/MacOS/Profiler" --benchmark
