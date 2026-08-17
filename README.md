# Personal Assistant — iOS

A local-only chat assistant that creates **real AlarmKit alarms** from what you type, in English,
Arabic, or Arabizi. No account, no server, no network calls of any kind.

Design decisions and the two Apple limitations that shaped them: **[ARCHITECTURE.md](ARCHITECTURE.md)**.

---

## Status, stated plainly

| | |
|---|---|
| Written | ✅ complete — app, widget extension, tests, Xcode project |
| Compiled | ❌ **never** — this was built on Windows. No Xcode, no Swift toolchain, no Mac. |
| Run | ❌ never |
| On a device | ❌ never |

Nothing below has been executed. Treat "it builds" as unproven until you have seen it build.
The test suite is the first thing to run, because it is the only thing that can tell you whether
the parsing, date and reconciliation logic is actually right.

---

## Getting it onto the iPhone 17

**You do not need to own a Mac.** You need *macOS compute*, which is not the same thing —
[GitHub Actions](.github/workflows/build.yml) runs `macos-26` with Xcode 26 preinstalled, and that
does the compiling. What no cloud runner can do is see a phone over USB, so only the last step
needs deciding.

### Pick one

| | Mac needed | Cost | App stops working after | Cable |
|---|---|---|---|---|
| **A. CI → sideload from Windows** | no | free | **7 days** | USB to the PC |
| **B. CI → TestFlight** | no | $99/yr | 90 days | none at all |
| **C. Mac with Xcode, direct install** | yes | free | 7 days | USB to the Mac |

**A** is the way to find out whether this works, today, for nothing. CI already builds an unsigned
`.ipa` on every green run — download the artifact from the Actions tab, then sign and install it
from Windows with [Sideloadly](https://sideloadly.io) using your own Apple ID. AltStore does the
same and can auto-refresh over WiFi, which softens the 7-day expiry.

**B** is the right end state. The same workflow can upload straight to TestFlight with an App Store
Connect API key, so the phone never touches a cable and builds last 90 days. It needs the paid
Apple Developer Program. For an app whose entire job is waking you up, a profile that silently
expires mid-week is the real problem — not the build.

**C** only if a Mac turns up anyway. Steps are below.

---

### If you do get to a Mac

#### Step 0 — check it can do this at all, before anything else

The repo is **private**, so `git clone` on someone else's Mac would prompt for your GitHub
credentials and leave them in that machine's keychain. Don't. Get the code as a ZIP instead:

1. In Safari on the Mac, sign in to `github.com` as yourself.
2. Go to `github.com/laythayache/PersonalAssistant`
3. Green **Code** button → **Download ZIP**. Double-click it in Downloads to unpack.

Nothing of yours is left behind, and re-downloading is how you pick up fixes later.

#### Step 1 — build and test it (no signing, no phone, no Apple ID)

Open **Terminal** on the Mac and run these two lines. This is zsh, not PowerShell — everything here
is macOS syntax.

```bash
cd ~/Downloads/PersonalAssistant-main
bash Scripts/build-on-mac.sh
```

The script checks the Mac is capable **before** doing anything slow, then builds and runs the tests
with code signing switched off — so this step cannot fail for signing reasons. It writes
`build-report.txt` in that folder. Send me that file.

It stops immediately, with a plain-English explanation, if Xcode is older than 26 or the iOS 26
simulator runtime is missing. **Xcode 26 is not negotiable**: AlarmKit and Foundation Models do not
exist in any earlier SDK, so no setting can be lowered to work around it.

To pick up fixes afterwards, re-download the ZIP and run the same two lines.

#### Step 2 — put it on the phone

Only once step 1 is green.

1. `open PersonalAssistant.xcodeproj`
2. Select the project at the top of the left sidebar. For each of the three targets —
   `PersonalAssistant`, `PersonalAssistantWidget`, `PersonalAssistantTests` — open
   **Signing & Capabilities**, tick **Automatically manage signing**, and set **Team** to your own
   Apple ID. Add it under **Xcode → Settings → Accounts** if it is not listed. Use *your* Apple ID,
   not the Mac owner's.
3. If Xcode says the bundle identifier is taken, change `com.laythayache` to something else in all
   three. The widget must stay a child of the app: `<app id>.Widget`.
4. Plug the iPhone in, unlock it, tap **Trust** on the phone.
5. Pick the iPhone from the destination menu at the top of the Xcode window. Press **⌘R**.
6. The first install stops with *"Untrusted Developer"*. On the phone:
   **Settings → General → VPN & Device Management → your Apple ID → Trust**. Press ⌘R again.
7. Grant the alarm permission on first launch. Nothing rings without it.

**A free Apple ID is enough.** This app needs no App Group, no push, and no paid capability —
that was a deliberate design constraint. The catch is that a free provisioning profile **expires
after 7 days** and the app silently stops launching.

For an app whose job is waking you up, that expiry is the real problem, not the build. Once you have
seen it work, the **$99/yr Apple Developer Program** takes the profile to a year. Prove it works
first, then decide.

---

## If the build fails

Two places are the likely culprits, and both were written against documentation rather than a
compiler:

**`App/Services/AlarmKitScheduler.swift`** — every alarm is scheduled here and nowhere else. If
Apple has moved an argument label since the documentation I worked from, Xcode's fix-it will name
it. The rest of the app goes through the `AlarmScheduling` protocol and is unaffected.

**`Widget/AssistantAlarmLiveActivity.swift`** — the `countdown(_:)` function is the only code that
reads `AlarmPresentationState`.

Two other files import AlarmKit for one line each: `Shared/AssistantAlarmMetadata.swift` (protocol
conformance) and `App/Intents/AlarmIntents.swift` (`AlarmManager.shared.stop`). That is the
complete list — `grep -rn "import AlarmKit"` to confirm.

If the *project file itself* will not open, regenerate a guaranteed-valid one:

```bash
brew install xcodegen && xcodegen generate
```

`project.yml` describes the same three targets.

---

## Layout

```
App/
  Core/        DayKey, DebugLog, AppRouter
  Data/        SwiftData schema (versioned), migration plan, persistence
  NLU/         Normalizer → Lexicon → RuleParser → DateResolver, plus the Foundation Models layer
  Services/    AlarmKit wrapper, recurrence, collisions, matching, executor, reconciler, review
  Intents/     Alarm button intents (Stop, Open Daily Review)
  UI/          Chat, Upcoming, Daily Review, Onboarding, Projects, Diagnostics
Shared/        The one type the app and widget both need
Widget/        Live Activity — required for AlarmKit to draw an alarm at all
Tests/         Requirement 19's cases, written as executable checks
Config/        Info.plist for each target
```

---

## What the tests cover

`⌘U` runs, among others, one test per sentence from the spec:

- `Remind me tomorrow at 4 to call Riad` → tomorrow 16:00, title `call Riad`
- `ذكرني بكرا الساعة ٤ اتصل برياض` → the same, with the title kept in Arabic
- `zakkerne bokra se3a 4 etsel b Riad` → the same again
- `أجّل موعد بكرا للجمعة` → moves tomorrow's alarm to Friday, keeping its time of day
- `Every Monday at 9…` → one native weekly AlarmKit alarm
- `Remind me every 3 days…` → eight pre-booked alarms, because AlarmKit cannot repeat that way
- Two alarms on one minute → a question, and nothing created behind it
- A postponed alarm → old occurrence preserved and linked in both directions
- An alarm the system lost → re-registered under the **same UUID**, and a second pass is a no-op
- A day with alarms → an evening review; a day without → none
- No review time configured → no review alarm is ever invented

`AlarmLifecycleTests` runs against a real SwiftData store and a fake system clock
(`InMemoryAlarmScheduler`), which can be told to drop an alarm or invent an orphan on demand.

---

## Verifying it on the phone

The tests cannot prove an alarm rings. Do this in order once it is installed:

1. Type `remind me in 2 minutes to test this` → confirm the reply, put the phone down, wait.
   It must ring on the Lock Screen with a Stop button.
2. Type the same thing twice → the second must ask, not stack silently.
3. Turn on Airplane Mode and repeat step 1. Everything must still work.
4. Force-quit the app, restart the phone, and check an alarm set for later still rings.
5. Set an alarm for today, then check **⋯ → Today's review** that evening.

**Diagnostics** (⋯ menu) shows which language layer is live, whether storage opened, and the
reconciliation log — read it there rather than needing the Mac.
