#!/bin/zsh
# App Store screenshots for the iPhone app, 6.9" set (1320 × 2868), into build/screenshots/.
#
#   scripts/app-store-screenshots.sh
#
# Builds for the simulator (signed, like `make build-ios`: the device identity lives in the keychain
# access group, so an unsigned build has no sync at all), starts from a clean install, seeds notes through the SILL_AUTOTEST_NOTE
# launch hook, spreads their dates with sqlite3 so the list shows several sections, then captures the
# list, the editor and the Sync screen via SILL_AUTOTEST_SCREEN. No taps are needed, so it runs unattended.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="iPhone 17 Pro Max"
BUNDLE=com.mrskiro.sill
OUT=build/screenshots
DERIVED=build/sim

make gen >/dev/null
xcodebuild -project Sill.xcodeproj -scheme SillPhone -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" -quiet -allowProvisioningUpdates build
APP=$(find "$DERIVED/Build/Products" -name Sill.app -path '*iphonesimulator*' | head -1)

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState discharging --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"

launch() {  # launch [ENV=value ...]; waits for the first frame
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  env "$@" xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
  sleep 3
}
seed() { launch SIMCTL_CHILD_SILL_AUTOTEST_NOTE="$1"; }

seed $'Call the dentist about the Thursday slot'
seed $'# Book notes\n\nChapter 3 argues that most planning is really a way of postponing the first step. Keep the first step small enough to do today.'
seed $'# Ideas for the talk\n\n- Start with the demo, not the slides\n- One example per section, no more\n- End on the sync question people always ask'
seed $'# Groceries\n\n- [x] Oat milk\n- [x] Coffee beans\n- [ ] Lemons\n- [ ] Bread\n- [ ] Something green'
seed $'# Tuesday\n\n- [x] Move the sync log link into Help\n- [ ] Ask about the office Wi-Fi\n- [ ] Return the library book\n\nRemember to check the Sync screen after lunch.'
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true

# Dates: one note per list section. Versions are untouched, only the timestamps move.
DB="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)/Library/Application Support/Sill/sill.sqlite"
now=$(date +%s); day=86400
sqlite3 "$DB" "
update note set created_at=$now-12*$day-10800, updated_at=$now-12*$day-10800 where content like 'Call the dentist%';
update note set created_at=$now-5*$day-25200,  updated_at=$now-5*$day-25200  where content like '# Book notes%';
update note set created_at=$now-$day-7200,     updated_at=$now-$day-7200     where content like '# Ideas%';
update note set created_at=$now-10800,         updated_at=$now-10800         where content like '# Groceries%';
update note set created_at=$now-600,           updated_at=$now-120           where content like '# Tuesday%';"

mkdir -p "$OUT"
shot() { xcrun simctl io "$DEVICE" screenshot --type png "$OUT/$1.png" >/dev/null; }
launch SIMCTL_CHILD_SILL_AUTOTEST_SCREEN=list; shot 1-notes
launch;                                        shot 2-editor
launch SIMCTL_CHILD_SILL_AUTOTEST_SCREEN=sync; shot 3-sync
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl status_bar "$DEVICE" clear
ls -la "$OUT"
