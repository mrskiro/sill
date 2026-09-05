#!/bin/zsh
# Real-device sync check: Mac app (SILL_DEBUG=1) ↔ the paired iPhone, driven without typing.
# Usage: scripts/device-sync-check.sh <device-identifier>
set -u
dev="${1:?device identifier (xcrun devicectl list devices)}"
bundle="${SILL_BUNDLE_ID:-com.mrskiro.sill}"
stamp=$(date +%H%M%S)
work="${TMPDIR:-/tmp}/sill-device-check"; mkdir -p "$work"
# The sandboxed Mac app keeps its database in its container.
macdb="$HOME/Library/Containers/$bundle/Data/Library/Application Support/Sill/sill.sqlite"
# Ask xcodebuild where the built app is instead of guessing at DerivedData.
app=$(xcodebuild -project Sill.xcodeproj -scheme Sill -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d "/" n}')
[ -d "$app" ] || { echo "built Mac app not found (run make build-mac first)"; exit 2; }

pull_phone_db() {
  for f in sill.sqlite sill.sqlite-wal; do
    xcrun devicectl device copy from --device "$dev" --domain-type appDataContainer --domain-identifier "$bundle" \
      --source "Library/Application Support/Sill/$f" --destination "$work/$f" >/dev/null 2>&1
  done
}
wait_for() { # wait_for <seconds> <description> <command…>
  local secs=$1 what=$2; shift 2
  for i in $(seq 1 "$secs"); do
    if "$@" >/dev/null 2>&1; then echo "  ok   $what (${i}s)"; return 0; fi
    sleep 1
  done
  echo "  FAIL $what (timeout ${secs}s)"; return 1
}
mac_has() { sqlite3 "$macdb" "select count(*) from note where deleted_at is null and content = '$1';" | grep -q '^1$'; }
phone_has() { pull_phone_db; sqlite3 "$work/sill.sqlite" "select count(*) from note where deleted_at is null and content = '$1';" | grep -q '^1$'; }

echo "1. Mac app with debug commands"
pkill -x Sill 2>/dev/null; sleep 1
SILL_DEBUG=1 "$app/Contents/MacOS/Sill" >/dev/null 2>&1 &
sleep 3

echo "2. iPhone app launches and creates a note"
phone_note="autotest-phone-$stamp"
xcrun devicectl device process launch --device "$dev" --terminate-existing \
  --environment-variables "{\"SILL_AUTOTEST_NOTE\":\"$phone_note\"}" "$bundle" >/dev/null 2>&1
result=0
wait_for 40 "phone note reached the Mac" mac_has "$phone_note" || result=1

echo "3. Mac creates a note, pokes the phone"
mac_note="autotest-mac-$stamp"
open "sill://debug/create?content=$mac_note"
wait_for 40 "mac note reached the phone" phone_has "$mac_note" || result=1

echo "4. Cleanup (tombstones propagate to the phone)"
open "sill://debug/delete?title=autotest-"
sleep 3
[ $result -eq 0 ] && echo "PASS" || echo "FAIL"
exit $result
