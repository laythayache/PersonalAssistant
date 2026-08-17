import Foundation

/// Short, plain confirmations. Requirement 3 and 24 both ask for brief replies, not paragraphs.
enum Phrasing {

    /// Wraps user-supplied text in Unicode isolates.
    ///
    /// Without this, putting an Arabic title inside an English sentence lets the bidi algorithm
    /// drag the surrounding punctuation to the wrong end — "Set: اتصل برياض for tomorrow" renders
    /// with the "for tomorrow" reversed into the Arabic run. FSI…PDI fences the run off.
    static func isolate(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: Normalizer.isArabicLetter) else { return text }
        return "\u{2068}" + text + "\u{2069}"
    }

    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// "today at 4:00 PM", "tomorrow at 7:00 AM", "Friday at 11:00 AM", "3 Sep at 9:00 AM".
    static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let clock = time(date, calendar: calendar)
        let startToday = calendar.startOfDay(for: now)
        let startTarget = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startToday, to: startTarget).day ?? 0

        switch days {
        case 0: return "today at \(clock)"
        case 1: return "tomorrow at \(clock)"
        case -1: return "yesterday at \(clock)"
        case 2...6:
            let weekday = date.formatted(.dateTime.weekday(.wide))
            return "\(weekday) at \(clock)"
        default:
            let day = date.formatted(.dateTime.day().month(.abbreviated))
            return "\(day) at \(clock)"
        }
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "in under a minute" }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "in \(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return when(date, now: now)
    }

    static func recurrence(_ rule: RecurrenceRule) -> String {
        rule.isRepeating ? ", \(rule.describedBriefly)" : ""
    }

    /// The other reading of an ambiguous bare hour, for the one-tap correction chip.
    static func meridiemAlternative(for date: Date, calendar: Calendar = .current) -> Date? {
        let hour = calendar.component(.hour, from: date)
        let delta = hour < 12 ? 12 : -12
        return calendar.date(byAdding: .hour, value: delta, to: date)
    }
}
