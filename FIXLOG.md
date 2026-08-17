# Fix log — PersonalAssistant

Newest first. Symptom → root cause → fix.

---

## 2026-08-17 — CI reported 884 errors on a passing build

**Symptom.** Run `32027630133` went green, produced the `.ipa`, and its own summary said
`errors: 884`. Both cannot be true.

**Root cause.** The workflow counted errors with `grep -E '(^|[[:space:]])error:'`. While SwiftData
creates a store, the simulator emits hundreds of `CoreData: error:` lines — routine runtime chatter
that the pattern happily matched. All 884 were noise; there were **zero** real compiler errors.

**Why it mattered even though the build passed.** The number is what a future run gets read against.
884 phantom errors would bury the one real error that actually broke something.

**Second problem, found while fixing the first.** `tests passed:` printed nothing, because the grep
was written for XCTest's output and the suite uses Swift Testing. That is the more dangerous of the
two: **`xcodebuild` exits 0 when a test bundle runs zero tests**, so a green build that proved
nothing is indistinguishable from a green build that proved everything.

**Fix.** Exclude `CoreData: error:` and `[error]` os_log lines from the error count. Read the test
count from Swift Testing's own `Test run with N tests` summary, and **fail the build when N is 0**.

**Verified both halves, because a guard that only ever sees the good case is not a guard.**

- *Allows the good case:* run `32028368521` reported `COMPILE ERRORS: (none)` and
  `tests executed: 72`, agreeing exactly with what reading the downloaded log by hand had shown.
- *Blocks the bad case:* the extraction logic was run locally against a synthetic log of a green
  build that executed zero tests, and against a log with no test summary at all. Both yield
  `count=0` and fire the guard. A log claiming 3 tests yields 3 — the number is read, not assumed.

The local half matters: proving it on a runner would have cost about 60 billed minutes to learn
something a shell loop answers for free.

---

## 2026-08-17 — Recursive macro expansion from a nested `#require`

**Symptom.** With the app target compiling clean, run `32027462203` failed with a single error and
no file of ours named in it:
`error: recursive expansion of macro 'require(_:_:sourceLocation:)'`.

**Root cause.** `Tests/AlarmLifecycleTests.swift` had a `#require` inside another `#require`:

```swift
let new = try #require(env.store.occurrence(id: try #require(old.postponedToID)))
```

Swift Testing's `#require` expands into a form containing `#require`, so nesting it makes the macro
expand into itself. The error surfaced against a generated `@__swiftmacro_…` file, which is why it
did not point at any source line worth reading.

**Fix.** Split it into two statements. `#expect` containing a `#require` is fine — only
`#require` inside `#require` recurses.

**Why it only appeared now:** the test bundle builds *after* the app target, so the previous run
never reached it. Compiling is not the same as compiling the tests, which is not the same as
passing them.

---

## 2026-08-17 — `LiveActivityIntent` not found, and nine actor-isolation errors

**Symptom.** First real compile, on a GitHub `macos-26` runner with Xcode 26. Eleven errors, every
one of them in `App/Services/AlarmKitScheduler.swift`. Run `32027188666`, `xcodebuild` exit 65.

**Root cause, part one.** `cannot find type 'LiveActivityIntent' in scope`. It is an **AppIntents**
type, not an AlarmKit one — AlarmKit merely accepts it as a parameter. The file imported AlarmKit
and assumed the intent type came with it. That single missing import also produced the
`generic parameter 'Metadata' could not be inferred` error further down: with the intent arguments
failing to type-check, Swift could not infer `AlarmConfiguration<Metadata>` either. One cause, two
symptoms, twenty lines apart.

**Root cause, part two.** The other nine were `DebugLog` calls. `DebugLog` is `@MainActor`;
`AlarmKitScheduler` was not. Every log line was therefore a cross-actor call needing `await`, and
the two inside the nonisolated `static func translate` could not be awaited at all.

**Fix.** `import AppIntents`, and isolate `AlarmScheduling` and both conformers to the main actor.
Every caller — executor, reconciler, review service, engine, tests — was already on the main actor,
so this removed the whole class of error rather than papering over nine instances of it.
`AssistantEngine.init` also had to stop defaulting `scheduler` to `AlarmKitScheduler()`, because a
default argument is evaluated at the call site and that type is now isolated.

**Confirmed, not assumed:** `AlarmManager.authorizationState` and `.alarms` are throwing but **not**
async — the compiler flagged neither. The original reading of the API was right on that point.

---

## 2026-08-17 — Postpone read the wrong half of the sentence as the new time

**Symptom.** `Postpone that until tomorrow at 3` resolved to tomorrow at **09:00** and treated
`3` as a description of the alarm being moved.

**Root cause.** The split between "the alarm you mean" and "the time to move it to" was made by
testing each time expression for a preceding `until`/`to`/`لـ`. In that sentence only `tomorrow`
carries the marker; `at 3` sits after it in the same trailing phrase and was classified as target.

**Fix.** Split by position instead of per-atom: find the first marked time expression and take
everything from there onwards as the new time. `RuleParser.parse`.

Found by tracing requirement 19's sentences by hand; caught before any device ran it.

---

## 2026-08-17 — Arabic "للجمعة" was not recognised as a new time

**Symptom.** `أجّل موعد بكرا للجمعة` resolved Friday as part of the *target* rather than as where
the alarm was moving to, so the postpone had no destination.

**Root cause.** `isUntilMarked` only looked at the two tokens *before* a time expression. Arabic
fuses the preposition onto the word — "to Friday" is one token, `للجمعة` — so the marker was inside
the token being tested, never before it.

**Fix.** Check the token itself for `.untilMarker` before looking backwards. The lexicon already
reports both meanings for a clitic-prefixed token; the parser was simply not asking.
`RuleParser.isUntilMarked`.

---

## 2026-08-17 — A day-only reference matched nothing

**Symptom.** Same Arabic sentence: `بكرا` is the only thing identifying which alarm to move, and
the matcher returned "I could not find which alarm to postpone" even with exactly one alarm that day.

**Root cause.** A same-day match scored 0.3, below the 0.35 viability floor, so it was discarded
before the decision step ever saw it.

**Fix.** Raised a day-only match to 0.45, and added a rule that a single viable candidate at 0.4 or
above is a unique match — if nothing else matched at all, it is not a guess between alternatives.
Two alarms on the same day still both score 0.45 and still produce a question.
`OccurrenceMatcher.rank` and `.decide`.

---

## 2026-08-17 — "Remind me every 3 days" produced no alarm

**Symptom.** A recurrence with no time named at all resolved to nil and fell through to the
"when should that go off?" form, instead of creating a repeating alarm at the default hour.

**Root cause.** `DateResolver.resolve` returns nil for an empty `TimeSpec` by design. A sentence
that names a rhythm but no clock leaves the spec empty once the recurrence words are consumed.

**Fix.** When a recurrence was detected and the spec is otherwise empty, anchor it to today so the
default reminder hour applies and the resolver rolls it forward. `RuleParser.parse`.

---

## 2026-08-17 — "check this" was truncated to "check"

**Symptom.** `Remind me every 3 days to check this` produced an alarm titled `check`.

**Root cause.** `this` was in the glue set trimmed from both ends of a title, because it is
scaffolding in `this Friday`. At the end of a sentence it is content.

**Fix.** Split the glue set: `.thisMarker` is trimmed from the left only. `RuleParser.trimGlue`.

---

## 2026-08-17 — "What alarms do I have tomorrow?" ignored the day

**Symptom.** The list came back unfiltered.

**Root cause.** The executor read the day filter from `targetAt`, which the parser only populates
for cancel/postpone/edit. For a list, the day lands in `scheduledAt`.

**Fix.** `CommandExecutor.list` now reads `targetAt ?? scheduledAt`.

---

## 2026-08-17 — "a" and "p" would have turned ordinary sentences into AM alarms

**Symptom.** Caught while writing the lexicon, before any test existed.

**Root cause.** `a` and `p` were listed as abbreviations for AM and PM. `a` is the English indefinite
article — `remind me at 4 to make a call` contains one.

**Fix.** Removed both. `am`/`pm` and the Arabic `ص`/`م` remain. `Lexicon`.
