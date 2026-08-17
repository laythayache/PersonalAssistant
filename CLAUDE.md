# PersonalAssistant — repo notes

Global rules in `C:\Users\user\.claude\CLAUDE.md` apply here and are not repeated.
Only what is specific to this project is written below.

---

## Policy

Copy of the confirmed section in `C:\Users\user\.claude\memory\policies.md`, which stays the source
of truth. If the two ever disagree, say so out loud rather than picking one.

- **branch:** commit straight to main.
- **push:** yes, push to main. **Never force** — the remote is the transport to the build machine,
  so a force-push can strand the Mac on a commit that no longer exists.
- **deploy:** none, ever. Built with Xcode on a Mac, installed to the iPhone over USB. A push moves
  source and nothing else.
- **server:** none. No backend, no database, no network calls of any kind.
- **who runs it:** **Layth runs the build. Claude cannot** — the Mac is a friend's machine with no
  SSH route from the Windows PC, and iOS cannot be compiled on Windows. Deliberate exception to the
  global rule, for a physical reason. Hand over **one script**, not a stream of pasted commands.
  The Mac is **zsh, not PowerShell** — the usual shell rule is inverted on that machine only.
- **blast radius:** no infrastructure — but **this repo is PUBLIC.** Every push is world-readable
  the moment it lands, and permanent: rewriting history does not recall forks, caches or scrapers.
  Verified clean when it was published (0 credential matches in the tree *and* in all history, no
  `.env`/`.p8`/`.pem` ever committed, commit author is a GitHub noreply address). **Never commit an
  App Store Connect `.p8`, a provisioning profile, or any key here** — those belong in encrypted
  repository secrets. Public is deliberate: it makes the macOS CI runners free and unmetered.
- **status:** confirmed 2026-08-17

---

## The thing that shapes everything

**This repo cannot be built on Layth's machine.** He is on Windows 11; Xcode is macOS-only.
Every claim about this code compiling, running, or working is **assumed** until it has been
opened on a Mac. Never write "done" about anything here without saying which of those three it means.

---

## Two Apple limitations, verified August 2026

Do not design around either of these being false without re-checking first.

1. **`Alarm.Schedule.Relative.Recurrence` has two cases: `.never` and `.weekly([DayOfWeek])`.**
   There is no every-N-days, monthly or yearly. Anything other than weekly is expanded by
   `RecurrenceEngine` into a rolling window of individual `.fixed` alarms, topped up on every
   launch. `AlarmManager.AlarmError.maximumLimitReached` is real — the window is 8 deep for a
   reason.

2. **Apple's on-device `SystemLanguageModel` does not support Arabic.** 15 languages as of
   iOS 26.1; Arabic is not among them. Arabic and Arabizi are therefore handled entirely by the
   deterministic rules layer, and `FoundationModelInterpreter.canHandle` refuses them. The check is
   made at runtime against `supportedLanguages`, so it will start working by itself if Apple adds
   Arabic — do not hardcode the refusal.

---

## Where to change what

| Change | File |
|---|---|
| Scheduling or cancelling an alarm | `App/Services/AlarmKitScheduler.swift` — everything else uses the `AlarmScheduling` protocol |
| The alarm's Stop button behaviour | `App/Intents/AlarmIntents.swift` — a custom `stopIntent` means **the app** must call `AlarmManager.shared.stop`, or the alarm keeps ringing |
| A new word, spelling or Arabizi variant | `App/NLU/Lexicon.swift` |
| How a sentence is taken apart | `App/NLU/RuleParser.swift` |
| Any calendar arithmetic | `App/NLU/DateResolver.swift` — nothing else computes a `Date` |
| What a command does to the store | `App/Services/CommandExecutor.swift` |
| Store ↔ AlarmKit drift | `App/Services/Reconciler.swift` |

The Live Activity in `Widget/` is not decoration. Without a widget extension declaring
`ActivityConfiguration(for: AlarmAttributes<…>.self)`, AlarmKit has nothing to draw and alarms do
not present.

---

## Invariants that must not be broken

- **`AlarmOccurrence.id == alarmKitID`** for one-shot and rolling alarms. That identity is what
  makes a reconciliation repair overwrite rather than duplicate. A natively repeating weekly series
  is the one exception: every occurrence in the series shares the one system alarm's ID.
- **Nothing is deleted.** Cancelling sets a status and writes an `Event`. Postponing creates a new
  occurrence and links it both ways. `originalScheduledAt` is never rewritten.
- **The user's raw text is stored before anything is interpreted.** If every layer fails, the words
  still exist. `Interpreter.interpret` never throws and never returns nil.
- **The End-of-Day Review time is never invented.** If `AppSettings.endOfDayHour` is nil, no review
  alarm is ever created. Onboarding asks; skipping leaves it nil on purpose.
- **A day with zero user alarms gets no review.** Both directions are enforced in
  `DailyReviewService.reconcileReview`.

---

## Autonomy

Requirement 5 is LOW autonomy and it is a product rule, not a style preference. The app executes
what was asked and nothing more: no habit analysis, no suggested rescheduling, no invented projects,
no proactive anything. The only thing it creates without being asked is the End-of-Day Review alarm,
and only under the conditions above.

---

## Testing

`Tests/` is named after requirement 19's cases, one test per sentence in the spec. It exists because
the author could not compile or run anything — it is the verification step, not a formality. Run
`⌘U` on a simulator before trusting any behaviour described in a commit message or a README.
