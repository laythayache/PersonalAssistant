# Fix log — PersonalAssistant

Newest first. Symptom → root cause → fix.

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
