#!/bin/zsh
# Cut a release from this machine: archive → export → notarize → staple → GitHub Release.
# `.github/workflows/release.yml` does the same on a tag push, but a private repo bills macOS
# runner minutes at 10x, so this is the cheap path. Both produce the same artifact.
#
# Once, before the first run:
#   xcrun notarytool store-credentials sill-notary \
#     --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer uuid>
# It stores the App Store Connect key in the login keychain, so this script never sees a secret.
#
# Usage: make release VERSION=0.1.0
set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $0 <version>   (e.g. 0.1.0)"; exit 2 }
NOTARY_PROFILE="${SILL_NOTARY_PROFILE:-sill-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/sill-release-XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

step() { print -P "\n%F{blue}==> $1%f" }

# --- preconditions -------------------------------------------------------------------------
step "Checking the tree"
[[ -z "$(git status --porcelain)" ]] || { echo "working tree is dirty"; exit 1 }
scripts/hygiene-check.sh

TEAM="$(awk -F'=' '/^DEVELOPMENT_TEAM/{gsub(/[ \t\r]/,"",$2); print $2}' Configs/Local.xcconfig)"
[[ -n "$TEAM" ]] || { echo "no DEVELOPMENT_TEAM in Configs/Local.xcconfig"; exit 1 }

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "no \"Developer ID Application\" identity in the keychain"; exit 1 }

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "notary profile \"$NOTARY_PROFILE\" is missing — see the header of this script"; exit 1 }

# The Developer ID profile, found by name so a regenerated one is picked up automatically.
# It is needed because keychain-access-groups implies application-identifier.
PROFILE=""
for DIR in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
           "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [[ -d "$DIR" ]] || continue
  for CANDIDATE in "$DIR"/*.provisionprofile(N); do
    PLIST="$(security cms -D -i "$CANDIDATE" 2>/dev/null)" || continue
    NAME="$(printf '%s' "$PLIST" | plutil -extract Name raw -o - - 2>/dev/null)" || continue
    [[ "$NAME" == "Sill Developer ID" ]] || continue
    PROFILE="$CANDIDATE"
    PROFILE_UUID="$(printf '%s' "$PLIST" | plutil -extract UUID raw -o - -)"
    echo "profile $NAME ($PROFILE_UUID) expires $(printf '%s' "$PLIST" | plutil -extract ExpirationDate raw -o - -)"
    break 2
  done
done
[[ -n "$PROFILE" ]] || {
  echo "no \"Sill Developer ID\" profile installed."
  echo "Make one at https://developer.apple.com/account/resources/profiles/add (Developer ID),"
  echo "then copy it into ~/Library/Developer/Xcode/UserData/Provisioning Profiles/."
  exit 1
}

# --- build ---------------------------------------------------------------------------------
step "Archiving $VERSION"
make gen
xcodebuild -project Sill.xcodeproj -scheme Sill -destination 'generic/platform=macOS' \
  -archivePath "$BUILD/Sill.xcarchive" -quiet -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  archive

step "Exporting with Developer ID"
cat > "$BUILD/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key><dict>
    <key>com.mrskiro.sill</key><string>$PROFILE_UUID</string>
  </dict>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$BUILD/Sill.xcarchive" \
  -exportOptionsPlist "$BUILD/export.plist" -exportPath "$BUILD/export" -quiet

# --- notarize ------------------------------------------------------------------------------
step "Notarizing (Apple usually answers in a few minutes)"
cd "$BUILD/export"
ZIP="Sill-$VERSION.zip"
ditto -c -k --keepParent Sill.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple Sill.app
# Re-zip so the download carries the stapled ticket; a ticket cannot be stapled to a zip.
rm "$ZIP"
ditto -c -k --keepParent Sill.app "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"

step "Verifying what will be published"
xcrun stapler validate Sill.app
spctl -a -vvv --type execute Sill.app
codesign -dvv Sill.app 2>&1 | grep -E "Authority=Developer ID Application|flags="

# --- publish -------------------------------------------------------------------------------
step "Publishing v$VERSION"
cd "$ROOT"
git tag -a "v$VERSION" -m "Sill $VERSION" 2>/dev/null || echo "tag v$VERSION already exists, reusing it"
git push origin "v$VERSION"
gh release create "v$VERSION" "$BUILD/export/$ZIP" "$BUILD/export/$ZIP.sha256" \
  --title "Sill v$VERSION" --generate-notes

print -P "\n%F{green}done%f  $(gh release view "v$VERSION" --json url -q .url)"
