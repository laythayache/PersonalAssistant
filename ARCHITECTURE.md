# Architecture — Personal Assistant (iOS)

Decisions made before any code was written. Each one names the constraint that forced it.

---

## 1. Language understanding: deterministic first, Apple's model second

**Verified constraint:** Apple's on-device `SystemLanguageModel` (Foundation Models framework)
supports 15 languages as of iOS 26.1 — Dutch, Swedish, Turkish, Spanish, Danish, Chinese, Italian,
Japanese, Norwegian, French, Portuguese, English, German, Korean, Vietnamese.
**Arabic is not one of them.** Arabizi (Arabic in Latin letters with 3/7/2 digit-letters) is not a
language any model is trained on at all.

Half of the required input languages are therefore outside the only free, offline, private model on
the device. An LLM-first design would fail requirement 4 on exactly the inputs that matter most.

**So the pipeline is three layers, in this order:**

| Layer | What it is | When it runs | Cost |
|---|---|---|---|
| 1. Rules | Swift normalizer + lexicon + grammar + calendar resolver (`App/NLU/`) | Always, first | ~1 ms, no model load |
| 2. Apple on-device model | `FoundationModels`, `@Generable` **slot** extraction | Only if layer 1 confidence < 0.6 **and** the model is available **and** `supportedLanguages` contains the detected language | ~1–3 s |
| 3. Structured fallback | Raw text saved as a note + a one-tap prefilled alarm form | If both above fail | instant |

Layer 2 never produces a `Date`. It produces *slots* ("tomorrow", "4", "pm"), and the same
deterministic `DateResolver` that layer 1 uses turns those into an absolute timestamp. This is
requirement 16 — the model is not allowed to invent a date.

Language gating is checked **at runtime** against `SystemLanguageModel.default.supportedLanguages`,
not hardcoded. The day Apple adds Arabic, layer 2 starts serving Arabic with no code change.

**No cloud LLM.** Not shipped, not optional, not stubbed behind a toggle. Everything above runs
with the device in Airplane Mode. `Interpreter` is a protocol, so adding a cloud layer later is a
new conformance rather than a rewrite — but nothing calls out to a network today.

**Speed:** priority 1 was speed. The rules layer answers in about a millisecond with no model
warm-up. In practice it will handle nearly everything you actually type, and the on-device model is
the exception path, not the hot path.

---

## 2. Alarms: AlarmKit, with one limitation you need to know about

`AlarmKit` is the whole alarm layer. No background audio, no long-running tasks, no local
notification hacks. The app can be force-quit and the alarms still ring.

**Verified limitation:** `Alarm.Schedule.Relative.Recurrence` has exactly two cases — `.never` and
`.weekly([DayOfWeek])`. There is no "every N days", no monthly, no yearly.

| You say | How it is scheduled |
|---|---|
| "every Monday at 9" | Native `.weekly([.monday])` — one alarm, repeats forever |
| "every weekday at 7" | Native `.weekly([.monday ... .friday])` |
| "every day at 8" | Native `.weekly([all seven])` |
| **"every 3 days"** | **Not native.** Rolling: the next 8 occurrences are pre-scheduled as separate `.fixed` alarms, topped up every time the app opens |
| "every month on the 4th" | Same rolling strategy |

The rolling strategy means an "every 3 days" chain is booked **21 days ahead** (8 occurrences, first
to last) without you opening the app once, and is re-extended to 21 days on every launch. It does
not depend on the app running in the background. If you never open the app for longer than that,
the chain stops — that is the honest boundary of what Apple's public API allows.

`AlarmManager.AlarmError.maximumLimitReached` is a real error the system throws; the scheduler
catches it, logs it, and surfaces it in chat rather than failing silently.

All alarm **scheduling** goes through one file — `App/Services/AlarmKitScheduler.swift` — behind the
`AlarmScheduling` protocol. Everything else in the app, and every test, talks to the protocol.

Three other files touch AlarmKit, each for one narrow reason, and they are the full list:

| File | Why |
|---|---|
| `Shared/AssistantAlarmMetadata.swift` | one line: conforming the metadata struct to `AlarmMetadata` |
| `App/Intents/AlarmIntents.swift` | `AlarmManager.shared.stop(id:)` — a custom stop intent means the app, not the system, has to stop the alarm |
| `Widget/AssistantAlarmLiveActivity.swift` | reads `AlarmPresentationState` to draw the countdown |

---

## 3. Persistence: SwiftData, versioned from day one

`VersionedSchema` + `SchemaMigrationPlan` are wired before there is anything to migrate, because
retrofitting them after the first schema change is the painful order.

Enums are stored as `String` raw values with typed computed accessors. SwiftData can persist enums
directly, but a raw `String` column survives adding a case without a migration, and this app will
grow cases.

Nothing is ever deleted or summarised away. Cancelling an alarm sets a status and writes an
`Event`; it does not remove a row. The original text you typed is stored verbatim on every item
alongside the structured interpretation of it.

---

## 4. Data model

```
AppSettings   ─ end-of-day review time, onboarding state, defaults
Project       ─ "Life" always exists and cannot be deleted
  └ AlarmItem ─ title, originalText, interpretationJSON, recurrence rule
      └ AlarmOccurrence ─ one row per fire time; status; alarmKitID; postponedFrom/To
Conversation
  └ Message   ─ role, text, and the command JSON that the text produced
DailyLog      ─ one per calendar day; free-text notes; review completion
Event         ─ append-only audit trail of every state change
```

`AlarmOccurrence.id` **is** the AlarmKit alarm ID. That is what makes reconciliation idempotent —
re-scheduling a repair uses the same UUID, so it can never duplicate an alarm.

---

## 5. Reconciliation

AlarmKit and SwiftData drift the moment the system drops an alarm, the user reboots, or a schedule
call fails. On every launch and every foreground, `Reconciler` runs:

1. Read `AlarmManager.shared.alarms` → the set of IDs the system actually holds.
2. Persisted occurrence is `scheduled`, in the future, missing from the system → **re-schedule it**
   under the same UUID.
3. System holds an alarm we have no record of → **cancel it** (this app owns every alarm it creates).
4. Persisted occurrence is `scheduled` but its time has passed → mark `pendingReview`.
5. Top up rolling recurrences.
6. Ensure today's End-of-Day Review alarm exists **only if** at least one real alarm was set for today.

Every repair and every failure is written to `Event` and to a local log file.

---

## 6. Deployment target

**iOS 26.0.** AlarmKit and Foundation Models both require it. The iPhone 17 ships above this.

Swift language mode 5 (Swift 6 compiler). Concurrency is written correctly — the store and executor
are `@MainActor`, the scheduler is `Sendable` — but full Swift 6 strict checking is not switched on,
because it turns benign patterns into build errors and this project has to compile cleanly on your
machine on the first try.

---

## 7. Permissions requested

- **AlarmKit** (`NSAlarmKitUsageDescription`) — the only permission prompt at launch.
- **Live Activities** (`NSSupportsLiveActivities`) — a capability, not a prompt.

Nothing else. No contacts, calendar, location, microphone, photos, health, notifications, or
network access of any kind. There is no App Group, no push entitlement, and no account — which also
means this builds and signs under a **free** Apple ID.

---

## 8. What this design will not do

Stated plainly, because these are consequences of the requirements rather than of laziness.

- **"Every 3 days" is capped at a 21-day unattended horizon.** Apple's API has no other option.
- **Bare "at 4" is assumed to be PM** (1–6 → PM, 7–11 → AM). Rather than block you with a question
  every time, the alarm is created immediately and the confirmation carries a one-tap "4 AM?" chip.
  This trades one guaranteed extra tap for a rare corrective tap.
- **Arabic input never reaches Apple's model.** It is handled entirely by the rules layer. Where the
  rules layer cannot parse Arabic, you get the fallback form — not a wrong alarm.
- **Unit tests run on the Simulator**, not the device.
