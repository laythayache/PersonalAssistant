#!/bin/bash
#
# Run this on the Mac. It answers, in order:
#   1. Can this Mac build the project at all?   (Xcode 26 and an iOS 26 SDK are non-negotiable)
#   2. Does the code compile?
#   3. Do the tests pass?
#
# It never installs anything and never touches signing — the simulator build needs neither, which
# keeps a whole class of failure out of the first attempt. Device install is a separate GUI step.
#
# Usage:   bash Scripts/build-on-mac.sh
#
# Everything lands in build-report.txt. Send me that file.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

REPORT="build-report.txt"
LOG="build-full.log"
: > "$REPORT"
: > "$LOG"

say() { echo "$@" | tee -a "$REPORT"; }
rule() { say "------------------------------------------------------------"; }

say "PersonalAssistant — build report"
say "generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
rule

# ---------------------------------------------------------------------------
# 1. Can this Mac do the job?
# ---------------------------------------------------------------------------

say "MACHINE"
say "  macOS:        $(sw_vers -productVersion) ($(uname -m))"

if ! command -v xcodebuild >/dev/null 2>&1; then
    say ""
    say "STOP: xcodebuild is not on the PATH."
    say "Xcode is not installed, or only the Command Line Tools are."
    say "Install Xcode 26 from the App Store, open it once to let it finish setup, then re-run this."
    exit 1
fi

XCODE_PATH="$(xcode-select -p 2>/dev/null)"
XCODE_LINE="$(xcodebuild -version 2>/dev/null | head -1)"
XCODE_VER="$(echo "$XCODE_LINE" | awk '{print $2}')"
XCODE_MAJOR="${XCODE_VER%%.*}"

say "  Xcode:        ${XCODE_VER:-unknown}   ($XCODE_PATH)"

IOS_SDK="$(xcodebuild -showsdks 2>/dev/null | grep -oE 'iphoneos[0-9]+\.[0-9]+' | tail -1 | sed 's/iphoneos//')"
say "  iOS SDK:      ${IOS_SDK:-none found}"

# The whole app is built on two frameworks that did not exist before iOS 26: AlarmKit and
# Foundation Models. An older Xcode cannot compile a single file of it.
if [ -z "${XCODE_MAJOR:-}" ] || [ "$XCODE_MAJOR" -lt 26 ] 2>/dev/null; then
    say ""
    say "STOP: this project needs Xcode 26 or newer. This Mac has ${XCODE_VER:-an unknown version}."
    say ""
    say "Why it is not negotiable: the app is built on AlarmKit and the Foundation Models"
    say "framework. Neither exists before the iOS 26 SDK, so an older Xcode cannot compile any"
    say "of it — this is not a setting that can be lowered."
    say ""
    say "Fix: App Store -> Xcode -> Update. Xcode 26 needs macOS Sequoia 15.6 or newer;"
    say "this Mac is on $(sw_vers -productVersion)."
    say ""
    say "If several Xcodes are installed, point the tools at the new one:"
    say "  sudo xcode-select -s /Applications/Xcode.app"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Pick a simulator
# ---------------------------------------------------------------------------

SIM_NAME="$(xcrun simctl list devices available 2>/dev/null \
    | awk '/^-- iOS 26/{f=1;next} /^--/{f=0} f' \
    | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]*//; s/ \(.*//')"

if [ -z "$SIM_NAME" ]; then
    say ""
    say "STOP: no iOS 26 simulator is installed."
    say ""
    say "Fix: open Xcode -> Settings -> Components, and install the iOS 26 simulator runtime."
    say "It is a large download. Then re-run this script."
    say ""
    say "Simulators this Mac does have:"
    xcrun simctl list devices available 2>/dev/null | tee -a "$REPORT"
    exit 1
fi

say "  Simulator:    $SIM_NAME (iOS 26)"
say ""
say "This Mac can build the project."
rule

DESTINATION="platform=iOS Simulator,name=$SIM_NAME"

# ---------------------------------------------------------------------------
# 3. Build
# ---------------------------------------------------------------------------

say "BUILDING (simulator, code signing off)"

xcodebuild \
    -project PersonalAssistant.xcodeproj \
    -scheme PersonalAssistant \
    -destination "$DESTINATION" \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build >> "$LOG" 2>&1
BUILD_STATUS=$?

ERRORS="$(grep -E '(^|[[:space:]])error:' "$LOG" | sort -u)"
ERROR_COUNT="$(printf '%s' "$ERRORS" | grep -c . )"

if [ "$BUILD_STATUS" -ne 0 ]; then
    say "  RESULT: FAILED ($ERROR_COUNT distinct errors)"
    say ""
    say "  Every error, deduplicated:"
    say ""
    printf '%s\n' "$ERRORS" | sed 's/^/    /' | tee -a "$REPORT" >/dev/null
    printf '%s\n' "$ERRORS" | sed 's/^/    /'
    rule
    say "Send me build-report.txt. Do not try to fix these by hand."
    exit 1
fi

say "  RESULT: BUILD SUCCEEDED"
rule

# ---------------------------------------------------------------------------
# 4. Test
# ---------------------------------------------------------------------------

say "RUNNING TESTS"
say "  These are the checks that prove the parsing, dates, collisions and"
say "  reconciliation are right. They were written but never run."
say ""

xcodebuild \
    -project PersonalAssistant.xcodeproj \
    -scheme PersonalAssistant \
    -destination "$DESTINATION" \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    test >> "$LOG" 2>&1
TEST_STATUS=$?

PASSED="$(grep -cE "Test case .* passed|✔ Test .* passed" "$LOG")"
FAILED_LINES="$(grep -E "Test case .* failed|✘ Test .* recorded an issue|error: .*XCTAssert|Issue recorded" "$LOG" | sort -u)"
FAILED_COUNT="$(printf '%s' "$FAILED_LINES" | grep -c . )"

if [ "$TEST_STATUS" -eq 0 ]; then
    say "  RESULT: ALL TESTS PASSED  (~$PASSED checks)"
    rule
    say "The logic is verified. Next step is putting it on the phone —"
    say "see 'Installing on the iPhone' in README.md."
else
    say "  RESULT: $FAILED_COUNT FAILURES  (~$PASSED passed)"
    say ""
    printf '%s\n' "$FAILED_LINES" | sed 's/^/    /' | tee -a "$REPORT" >/dev/null
    printf '%s\n' "$FAILED_LINES" | sed 's/^/    /'
    rule
    say "A failure here means my logic is wrong, not your Mac. Send me build-report.txt."
fi

say ""
say "Full log: $LOG"
say "Send me: $REPORT"
exit 0
