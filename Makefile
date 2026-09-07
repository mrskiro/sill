PROJECT = Sill.xcodeproj

.PHONY: gen icons build build-mac build-ios test test-core test-mac test-ios format lint device-check clean

gen:
	@test -f Configs/Local.xcconfig || cp Configs/Local.xcconfig.example Configs/Local.xcconfig
	xcodegen generate --spec project.yml --quiet

# Redraws both Assets.xcassets from the parametric spec in the script.
icons:
	swift scripts/make-app-icon.swift

build: build-mac build-ios

build-mac: gen
	xcodebuild -project $(PROJECT) -scheme Sill -destination 'platform=macOS,arch=arm64' -quiet -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

build-ios: gen
	xcodebuild -project $(PROJECT) -scheme SillPhone -destination 'generic/platform=iOS Simulator' -quiet -allowProvisioningUpdates build

test: test-core test-mac test-ios

test-core:
	cd Packages/SillCore && swift test

test-mac: gen
	-@pkill -x Sill 2>/dev/null || true
	xcodebuild -project $(PROJECT) -scheme Sill -destination 'platform=macOS,arch=arm64' -quiet -allowProvisioningUpdates -allowProvisioningDeviceRegistration test

test-ios: gen
	xcodebuild -project $(PROJECT) -scheme SillPhone -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet -allowProvisioningUpdates test

SWIFT_SOURCES = Apps Packages/SillCore/Sources Packages/SillCore/Tests Tests

format:
	xcrun swift-format format --in-place --recursive $(SWIFT_SOURCES)

lint:
	xcrun swift-format lint --recursive --strict $(SWIFT_SOURCES)

device-check: build-mac
	scripts/device-sync-check.sh $(DEVICE)

clean:
	rm -rf $(PROJECT) Packages/SillCore/.build
