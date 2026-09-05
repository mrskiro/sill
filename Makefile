PROJECT = Sill.xcodeproj

.PHONY: gen build build-mac build-ios test test-core test-mac test-ios hygiene device-check clean

gen:
	@test -f Configs/Local.xcconfig || cp Configs/Local.xcconfig.example Configs/Local.xcconfig
	xcodegen generate --spec project.yml --quiet

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

hygiene:
	scripts/hygiene-check.sh

device-check: build-mac
	scripts/device-sync-check.sh $(DEVICE)

clean:
	rm -rf $(PROJECT) Packages/SillCore/.build
