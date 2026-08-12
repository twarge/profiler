# Builds Profile, the Mac beam-profiler app.
#
#   make            debug build
#   make release    optimised build
#   make test       build, then run the analyser self-test
#   make run        build and launch
#   make clean

.PHONY: all mac release test run clean

APP_DEBUG = $(shell xcodebuild -project apps/Profiler.xcodeproj -scheme Profiler \
	-configuration Debug -showBuildSettings 2>/dev/null \
	| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2}')/Profiler.app

all: mac

# Exactly what Xcode's own Build does — same scheme, same default
# DerivedData — so a make build and a ⌘B are the same build.
mac:
	xcodebuild -project apps/Profiler.xcodeproj -scheme Profiler \
	  -destination "platform=macOS" -allowProvisioningUpdates -quiet build
	@echo "==> Built for macOS"

release:
	xcodebuild -project apps/Profiler.xcodeproj -scheme Profiler \
	  -destination "platform=macOS" -configuration Release \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built for macOS (Release)"

# Validates the ISO 11146 moment calculation against analytically-known beams.
# Runs the built binary directly, so it exercises the same code the app ships.
test: mac
	@"$(APP_DEBUG)/Contents/MacOS/Profiler" --self-test

run: mac
	@open "$(APP_DEBUG)"

clean:
	rm -rf build
	xcodebuild -project apps/Profiler.xcodeproj -scheme Profiler -quiet clean
