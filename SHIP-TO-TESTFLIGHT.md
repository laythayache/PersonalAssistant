# Ship this to TestFlight

**You are the build agent.** You are running on a Mac that has Xcode and an Apple Developer account
with TestFlight. The author of this code does not have either — he is on Windows, and iOS cannot be
compiled there. That is the entire reason you are being asked.

This document is self-contained. You do not need to ask anyone anything to follow it.

---

## What you are shipping

A local-only iOS personal assistant. Chat interface, creates real AlarmKit alarms from typed
requests in English, Arabic and Arabizi. No account, no server, **no network calls of any kind**.
Everything is on-device.

Read [ARCHITECTURE.md](ARCHITECTURE.md) if you want the design reasoning. You do not need it to do
this job.

---

## Read this before you touch anything

### 1. This repository is PUBLIC

Every push is world-readable the instant it lands, and permanent — rewriting history does not recall
forks, caches or scrapers.

**Never commit:**
- an App Store Connect API key (`.p8`)
- a provisioning profile (`.mobileprovision`), certificate (`.p12`, `.cer`) or private key
- your Apple ID, password, or any email address
- `ExportOptions.plist` — the build script generates it at runtime and it contains your Team ID

Your **Team ID** is not a secret in the cryptographic sense, but keep it out of the repo anyway.
Everything below passes it as an environment variable, never as a committed file.

### 2. Do not redesign anything

You have been asked to **sign, archive and upload**. That is the whole scope.

Do not refactor, do not "improve" the natural-language layer, do not change the data model, do not
upgrade dependencies (there are none), do not reformat files you did not otherwise need to touch.
If you think something is wrong, **write it in your report instead of changing it.**

### 3. Do not force-push

The remote is the only transport between this Mac and the author's Windows machine. A force-push can
strand him on a commit that no longer exists.

### 4. Deployment target is iOS 26.0 and cannot be lowered

The app is built on **AlarmKit** and **Foundation Models**. Neither exists before the iOS 26 SDK.
If you hit an availability error, the answer is never to lower the target.

---

## What is already proven — do not redo this

CI compiles and tests this on a GitHub `macos-26` runner on every push. As of the last green run:

- **0 compiler errors**, 1 warning
- **72 tests in 5 suites pass**, 0 failures
- It produces an arm64 `.ipa` with the widget extension embedded, linking AlarmKit,
  FoundationModels, ActivityKit, AppIntents and SwiftData

So **if it fails to build on your Mac, the likely cause is your local setup, not the code** — most
often a different Xcode version or a missing iOS 26 simulator runtime. Check
[the latest CI run](../../actions) before assuming the source is broken.

**Never verified, by anyone:** no alarm has ever rung, and the UI has never been rendered on a real
screen. That is exactly what this TestFlight build is for.

---

## Step 1 — check the Mac can do this

```bash
sw_vers -productVersion
xcodebuild -version
xcrun simctl list runtimes | grep -i "iOS 26"
```

You need **Xcode 26 or newer**. If it is older, stop and say so in your report — nothing else in
this document will work, and it is not something you can work around.

---

## Step 2 — find your Team ID

```bash
security find-identity -v -p codesigning
```

Look for `Apple Development: Your Name (XXXXXXXXXX)` — but the Team ID is the 10-character string in
the certificate's OU field, which is easier to read from:

```bash
xcrun xcodebuild -showBuildSettings -project PersonalAssistant.xcodeproj -scheme PersonalAssistant 2>/dev/null | grep -i DEVELOPMENT_TEAM
```

If that is empty (it will be — the repo deliberately ships no team), get it from
**Xcode → Settings → Accounts → your Apple ID → your team**, or from
[developer.apple.com/account](https://developer.apple.com/account) under Membership Details.

It is ten uppercase alphanumeric characters.

---

## Step 3 — archive and export

```bash
TEAM_ID=XXXXXXXXXX bash Scripts/ship-testflight.sh
```

That script:

1. Refuses to run on Xcode older than 26
2. Sets a **unique build number from the current timestamp** — TestFlight rejects a build number it
   has already seen, and this is the single most common reason a second upload fails
3. Archives for `iphoneos` with automatic signing under your team
4. Exports an App Store-ready `.ipa` into `build/`
5. Generates `ExportOptions.plist` at runtime and deletes it afterwards, so your Team ID never lands
   in a file that could be committed

**About the bundle identifier.** It is `com.laythayache.PersonalAssistant`, with the widget at
`com.laythayache.PersonalAssistant.Widget`. Bundle IDs are globally unique but **do not have to
match your team's domain** — you can register these under your own team, and `-allowProvisioningUpdates`
will do it automatically the first time. Keep them as they are; changing them means editing two
targets and buys nothing.

---

## Step 4 — upload to TestFlight

Two ways. Pick whichever is less friction for you.

### Option A — Xcode Organizer (GUI, no API key needed)

1. `open PersonalAssistant.xcodeproj`
2. **Window → Organizer → Archives**, select the archive the script just made
3. **Distribute App → TestFlight Internal Only** (or **App Store Connect**), follow the prompts

This is the fewest moving parts for a first upload and needs no extra credentials.

### Option B — command line (needs an App Store Connect API key)

The key must be a **Team key**, not an Individual key — `altool` does not accept Individual keys.
Create it at **App Store Connect → Users and Access → Integrations → App Store Connect API →
Team Keys**, role *App Manager*. You download the `.p8` exactly once.

**Put the `.p8` outside this repository.** `~/private_keys/` is the conventional location.

```bash
xcrun altool --upload-app \
  -f build/PersonalAssistant.ipa \
  -t ios \
  --apiKey YOUR_KEY_ID \
  --apiIssuer YOUR_ISSUER_ID
```

---

## Step 5 — let Layth in

He needs to receive the build on his iPhone 17. **You do not need to give him access to your Apple
account.**

Use an **external tester**:

1. App Store Connect → your app → **TestFlight → External Testing**
2. Create a group, add Layth's Apple ID email (he will send it to you — it is deliberately not
   written in this public repo)
3. Submit the build for **Beta App Review**

The first build of a new app needs Beta App Review — usually hours, occasionally a day. Later builds
in the same group normally go straight through.

*Internal testers* skip review entirely but require adding him as a user on your App Store Connect
team, which gives him visibility into your account. External is the right trade here.

Export compliance will not prompt you: `ITSAppUsesNonExemptEncryption` is already set to `false` in
`Config/App-Info.plist`, which is accurate — the app makes no network calls at all.

---

## Step 6 — report back

Send Layth, in plain text:

- Your Xcode and macOS versions
- Whether the archive succeeded, and the **build number** the script generated
- Whether the upload succeeded, and the version/build visible in App Store Connect
- Whether the build passed Beta App Review, or is still pending
- **Anything you noticed but did not change** — per the scope rule above

If something failed, send the actual error text, not a summary of it. He can fix the code and push;
CI will re-verify it within minutes and you can re-run Step 3.

---

## Known traps

| Symptom | Cause | Fix |
|---|---|---|
| `No profiles for 'com.laythayache.PersonalAssistant' were found` | The App ID does not exist under your team yet | Make sure `-allowProvisioningUpdates` is used — the script does. Xcode registers it on first archive. |
| `The provided entity includes an attribute with a value that has already been used` on upload | Duplicate build number | Re-run the script; it timestamps a fresh one each time. |
| `error: cannot find type 'LiveActivityIntent' in scope` | Missing `import AppIntents` | Already fixed. If you see it, you are on a stale checkout — `git pull`. |
| Widget fails to sign | Its bundle ID must stay a child of the app's | Leave both bundle IDs alone. |
| `altool` rejects your API key | It is an Individual key | Create a **Team** key instead. |
| Availability errors about AlarmKit | Xcode older than 26 | Update Xcode. The target cannot be lowered. |

---

## If you want to run the tests yourself first

```bash
bash Scripts/build-on-mac.sh
```

Builds and runs the full suite with code signing switched off, so it cannot fail for signing
reasons. Writes `build-report.txt`. Entirely optional — CI already does this on every push — but it
is a fast way to confirm your Mac is set up correctly before dealing with certificates.
