#!/bin/bash
#
# Archive and export an App Store-ready .ipa, ready to upload to TestFlight.
#
#   TEAM_ID=XXXXXXXXXX bash Scripts/ship-testflight.sh
#
# Your Team ID is passed in the environment and written only to a temporary ExportOptions.plist
# that is deleted on exit. This repository is public — nothing of yours is left behind in it.
#
# Full instructions, including how to upload and how to add a tester: SHIP-TO-TESTFLIGHT.md

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

ARCHIVE="build/PersonalAssistant.xcarchive"
EXPORT_DIR="build"
OPTIONS="build/ExportOptions.plist"

# The plist carries the Team ID, so remove it however this script ends — including on Ctrl-C.
cleanup() { rm -f "$OPTIONS"; }
trap cleanup EXIT INT TERM

say()  { echo "$@"; }
rule() { echo "------------------------------------------------------------"; }

say "PersonalAssistant — archive for TestFlight"
rule

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

if [ -z "${TEAM_ID:-}" ]; then
    say "STOP: TEAM_ID is not set."
    say ""
    say "Run it like this:"
    say "    TEAM_ID=XXXXXXXXXX bash Scripts/ship-testflight.sh"
    say ""
    say "Your Team ID is ten uppercase characters. Find it in"
    say "Xcode -> Settings -> Accounts -> your Apple ID, or at"
    say "developer.apple.com/account under Membership Details."
    exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    say "STOP: xcodebuild is not on the PATH. Install Xcode 26 and open it once."
    exit 1
fi

XCODE_VER="$(xcodebuild -version | head -1 | awk '{print $2}')"
XCODE_MAJOR="${XCODE_VER%%.*}"
say "macOS: $(sw_vers -productVersion)   Xcode: $XCODE_VER   Team: $TEAM_ID"

# AlarmKit and Foundation Models are iOS 26 SDK only. There is no way around this.
if [ -z "${XCODE_MAJOR:-}" ] || [ "$XCODE_MAJOR" -lt 26 ] 2>/dev/null; then
    say ""
    say "STOP: this project needs Xcode 26 or newer. This Mac has ${XCODE_VER:-an unknown version}."
    say "The app is built on AlarmKit and Foundation Models, which do not exist in any earlier SDK."
    say "The deployment target cannot be lowered to compensate."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build number
# ---------------------------------------------------------------------------

# App Store Connect rejects a build number it has already accepted, and that rejection happens
# *after* a full archive and upload. A timestamp is always unique and always increases.
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
say "Build number: $BUILD_NUMBER"
rule

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------

say "ARCHIVING (this is the slow part)"

rm -rf "$ARCHIVE"
mkdir -p "$EXPORT_DIR"

xcodebuild \
    -project PersonalAssistant.xcodeproj \
    -scheme PersonalAssistant \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive 2>&1 | tee build/archive.log | grep -E "error:|warning: .*signing|Signing|ARCHIVE" | head -40

ARCHIVE_STATUS="${PIPESTATUS[0]}"

if [ "$ARCHIVE_STATUS" -ne 0 ] || [ ! -d "$ARCHIVE" ]; then
    say ""
    say "  RESULT: ARCHIVE FAILED"
    say ""
    say "  Errors:"
    grep -E "(^|[[:space:]])error:" build/archive.log | sort -u | head -40 | sed 's/^/    /'
    say ""
    say "  Full log: build/archive.log"
    say "  Signing problems are covered in the 'Known traps' table of SHIP-TO-TESTFLIGHT.md."
    exit 1
fi

say "  RESULT: ARCHIVE SUCCEEDED"
rule

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

say "EXPORTING .ipa"

cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$OPTIONS" \
    -allowProvisioningUpdates 2>&1 | tee build/export.log | tail -20

EXPORT_STATUS="${PIPESTATUS[0]}"

if [ "$EXPORT_STATUS" -ne 0 ]; then
    say ""
    say "  RESULT: EXPORT FAILED"
    grep -E "(^|[[:space:]])error:" build/export.log | sort -u | head -30 | sed 's/^/    /'
    say "  Full log: build/export.log"
    exit 1
fi

IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)"

rule
say "DONE"
say ""
say "  .ipa:         ${IPA:-not found}"
say "  build number: $BUILD_NUMBER"
say "  size:         $(du -h "$IPA" 2>/dev/null | cut -f1)"
say ""
say "Next: upload it. Either"
say "  A) Xcode -> Window -> Organizer -> Archives -> Distribute App   (no API key needed)"
say "  B) xcrun altool --upload-app -f \"$IPA\" -t ios --apiKey KEY_ID --apiIssuer ISSUER_ID"
say ""
say "Then add Layth as an external tester. Step 5 of SHIP-TO-TESTFLIGHT.md."
say ""
say "Tell him build number $BUILD_NUMBER so he knows which build he is installing."
