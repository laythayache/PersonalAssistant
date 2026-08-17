import Foundation

/// A meaning a word can carry. One word can carry several — "se3a" is both "hour" (a duration) and
/// "o'clock" (a time marker), and only position tells them apart.
enum Concept: Hashable, Sendable {
    // Verbs and nouns that pick the action
    case verbRemind
    case verbCreate
    case verbWake
    case verbCancel
    case verbPostpone
    case verbMove
    case verbList
    case verbDone
    case verbMissed
    case nounAlarm

    // Day anchors
    case today
    case tonight
    case tomorrow
    case yesterday
    /// `Calendar` weekday numbers, 1 = Sunday.
    case weekday(Int)

    // Parts of day
    case morning
    case noon
    case afternoon
    case evening
    case night
    case midnight

    // Recurrence
    case every
    case daily
    case weekdaysWord
    case weekendWord

    // Duration units
    case unitMinute
    case unitHour
    case unitDay
    case unitWeek
    case unitMonth
    case unitYear

    // Glue
    /// "at", "الساعة", "se3a" when it introduces a clock time.
    case oclock
    /// "in", "after", "بعد" — introduces a relative offset.
    case within
    /// "until", "till", "to", "لل" — marks the *new* time in a postpone or move.
    case untilMarker
    case forMarker
    case nextMarker
    case thisMarker
    case questionWord

    // Meridiem
    case am
    case pm

    // Numerals
    case number(Int)
    case half
    case quarter
    /// "illa" / "إلا" — subtract the following fraction from the hour ("4 illa rob3" = 3:45).
    case minusMarker

    // Filler that should never reach a title
    case filler
}

enum Lexicon {

    /// Arabic attaches articles and prepositions directly to the word. "للجمعة" is ل + ل + جمعة.
    /// Longest first, so "لل" wins before "ل".
    private static let arabicPrefixes = ["بال", "وال", "فال", "كال", "لل", "ال", "ل", "ب", "و", "ف", "ك"]

    /// Every meaning of a folded token, including meanings that only appear once a clitic is stripped.
    static func concepts(for folded: String) -> Set<Concept> {
        guard !folded.isEmpty else { return [] }

        var result = table[folded] ?? []

        // A bare run of digits is a number.
        if let value = Int(folded), folded.allSatisfy(\.isNumber) {
            result.insert(.number(value))
        }

        // English plurals and possessives: "tomorrow's", "alarms", "Mondays". The apostrophe is
        // already gone by folding time, so only a trailing "s" is left to strip.
        if result.isEmpty, folded.count > 3, folded.hasSuffix("s"),
           let singular = table[String(folded.dropLast())] {
            result.formUnion(singular)
        }

        if result.isEmpty {
            for prefix in arabicPrefixes where folded.hasPrefix(prefix) && folded.count > prefix.count + 1 {
                let stripped = String(folded.dropFirst(prefix.count))
                if let found = table[stripped] {
                    result.formUnion(found)
                    // "لل" and "ل" mean "to/for", which is what makes "للجمعة" the new time in a move.
                    if prefix == "لل" || prefix == "ل" { result.insert(.untilMarker) }
                    break
                }
            }
        }
        return result
    }

    static func has(_ concept: Concept, _ folded: String) -> Bool {
        concepts(for: folded).contains(concept)
    }

    /// Numeric value of a token, whether written in digits or words, in any of the three scripts.
    static func numericValue(of folded: String) -> Int? {
        if let value = Int(folded), folded.allSatisfy(\.isNumber) { return value }
        for concept in concepts(for: folded) {
            if case .number(let value) = concept { return value }
        }
        return nil
    }

    // MARK: - The table
    //
    // Arabic entries are written in the form the normaliser produces: harakat removed,
    // ة → ه, أ/إ/آ → ا, ى → ي. Writing them any other way means they never match.

    private static let table: [String: Set<Concept>] = {
        var t: [String: Set<Concept>] = [:]

        func add(_ concepts: Set<Concept>, _ words: [String]) {
            for word in words {
                t[word, default: []].formUnion(concepts)
            }
        }

        // MARK: Actions

        add([.verbRemind], [
            "remind", "reminder", "reminders", "remindme",
            "zakkerne", "zakerne", "zakkerni", "zakkirni", "zakerni", "zakrne", "zakkarni",
            "zekerne", "zakirni", "fakkerne", "fakerne", "fakkerni", "fakirni",
            "ذكرني", "ذكريني", "ذكرنا", "ذكر", "فكرني", "تذكير", "تذكره", "ذكرللي"
        ])

        add([.verbCreate], [
            "create", "make", "set", "add", "schedule", "new",
            "3melle", "a3melle", "e3melle", "3mille", "3milli", "amelle", "sawwile", "sawile",
            "اعملي", "اعملللي", "عملي", "سوي", "سويلي", "حط", "حطلي", "ضيف"
        ])

        add([.verbWake], [
            "wake", "wakeup", "wakeme",
            "fayye2ne", "fay2ne", "fay2ni", "fayekne",
            "صحيني", "صحني", "فيقني", "فيقيني"
        ])

        add([.verbCancel], [
            "cancel", "delete", "remove", "kill", "drop", "clear", "cansel", "kansel",
            "alghi", "elghi", "ilghi", "laghi", "shil", "chil", "shilli",
            "الغي", "الغاء", "احذف", "امسح", "شيل", "شيلي", "كنسل", "لغي"
        ])

        add([.verbPostpone], [
            "postpone", "snooze", "delay", "defer", "push", "later",
            "ajjel", "ajel", "2ajjel", "2ajel", "ajjil", "2ajjil", "dahher", "da77er", "dahhir",
            "اجل", "اجلي", "تاجيل", "دحر", "اخر", "اخرلي"
        ])

        add([.verbMove], [
            "move", "change", "edit", "update", "shift", "reschedule", "switch",
            "ghayyer", "ghayer", "8ayyer", "9ayyer", "7arrek", "na2el",
            "غير", "غيرلي", "بدل", "حرك", "نقل", "عدل"
        ])

        add([.verbList], [
            "list", "show", "display", "upcoming",
            "3ende", "3endi", "fi",
            "عندي", "اعرض", "ورجيني", "شوفلي"
        ])

        add([.verbDone], [
            "finished", "finish", "done", "completed", "complete",
            "khalast", "khallast", "5alast", "5allast", "khalaset", "khallasit", "5allaset",
            "khallasna", "3melta", "3meltha",
            "خلصت", "خلصنا", "انجزت", "عملتها", "عملت", "تم"
        ])

        add([.verbMissed], [
            "missed", "miss", "skipped", "skip", "forgot",
            "fewwet", "fawwat", "fawwatt", "nsit", "nseet",
            "فوت", "فوتت", "نسيت", "ضيعت", "فاتني"
        ])

        add([.nounAlarm], [
            "alarm", "alarms", "alert", "alerts",
            "manabbeh", "mnabbeh", "mnabeh", "mounabbih", "manbah",
            "منبه", "منبهات", "تنبيه", "تنبيهات", "موعد", "مواعيد"
        ])

        // MARK: Day anchors

        add([.today], [
            "today", "lyoum", "lyom", "elyoum", "elyom", "ilyom", "alyoum", "elyawm",
            "اليوم", "هاليوم"
        ])

        add([.tonight, .evening], [
            "tonight", "allaile", "hallaile", "hallele", "halele",
            "الليله", "هالليله"
        ])

        add([.tomorrow], [
            "tomorrow", "tmrw", "tmw",
            "bokra", "bukra", "bkra", "bokrra", "boukra", "bacher", "beker",
            "بكرا", "بكره", "غدا", "الغد", "باكر"
        ])

        add([.yesterday], [
            "yesterday", "mbere7", "embere7", "mbare7", "embare7",
            "امبارح", "مبارح", "البارحه", "امس"
        ])

        add([.weekday(1)], [
            "sunday", "sun", "a7ad", "ahad", "l7ad", "el7ad", "hadd",
            "الاحد", "احد", "حد"
        ])
        add([.weekday(2)], [
            "monday", "mon", "tanen", "tnen", "itnen", "ethnen", "etnen", "tnayn",
            "الاثنين", "اثنين", "التنين", "تنين"
        ])
        add([.weekday(3)], [
            "tuesday", "tue", "tues", "talat", "tlete", "tleta", "tlata", "thalatha",
            "الثلاثاء", "ثلاثاء", "التلات", "تلات"
        ])
        add([.weekday(4)], [
            "wednesday", "wed", "weds", "arb3a", "erb3a", "arbi3a", "arbaa", "orb3a",
            "الاربعاء", "اربعاء", "الاربعا", "اربعا"
        ])
        add([.weekday(5)], [
            "thursday", "thu", "thur", "thurs", "khamis", "5amis", "kamis", "khmis",
            "الخميس", "خميس"
        ])
        add([.weekday(6)], [
            "friday", "fri", "jom3a", "jum3a", "jem3a", "jum3ah", "joum3a", "jemaa",
            "الجمعه", "جمعه"
        ])
        add([.weekday(7)], [
            "saturday", "sat", "sabt", "sebt", "sabet",
            "السبت", "سبت"
        ])

        // MARK: Parts of day

        add([.morning], [
            "morning", "sob7", "sobo7", "sob7iye", "sabah", "sabe7", "bakkir",
            "الصبح", "صبح", "صباحا", "صباح", "بكير"
        ])
        add([.noon], [
            "noon", "midday", "dohr", "duhr", "do7r", "dhohr",
            "الظهر", "ظهر", "ظهرا"
        ])
        add([.afternoon], [
            "afternoon", "3asr", "3aser",
            "العصر", "عصرا", "عصر"
        ])
        add([.evening], [
            "evening", "masa", "masa2", "3ashiye", "3achiye",
            "المسا", "مسا", "مساء", "المساء", "العشيه", "عشيه"
        ])
        add([.night], [
            "night", "lail", "leil", "leyl", "layl",
            "الليل", "ليل", "ليلا"
        ])
        add([.midnight], [
            "midnight", "nosleil", "montasafalleil",
            "منتصفالليل"
        ])

        // MARK: Recurrence

        add([.every], [
            "every", "each", "kel", "kil", "kul", "koll", "kell",
            "كل"
        ])
        add([.daily, .every], [
            "daily", "everyday", "yawmiyan", "yaomiyan",
            "يوميا", "يومي"
        ])
        add([.weekdaysWord], [
            "weekday", "weekdays", "workday", "workdays",
            "ايامالدوام"
        ])
        add([.weekendWord], [
            "weekend", "weekends", "wikend",
            "عطله", "الويكند"
        ])

        // MARK: Units

        add([.unitMinute], [
            "minute", "minutes", "min", "mins", "minut",
            "da2ee2a", "da2i2a", "di2i2a", "da2aye2", "d2aye2", "de2ay2",
            "دقيقه", "دقايق", "دقائق", "دقيقتين"
        ])
        add([.unitHour, .oclock], [
            "hour", "hours", "hr", "hrs",
            "se3a", "sa3a", "saa3a", "se3at", "sa3at", "se3tein", "sa3tayn",
            "ساعه", "ساعات", "ساعتين", "الساعه"
        ])
        add([.unitDay], [
            "day", "days", "youm", "yom", "yawm", "ayyam", "iyam", "yomein", "yomayn",
            "يوم", "ايام", "يومين"
        ])
        add([.unitWeek], [
            "week", "weeks", "esbou3", "osbou3", "usbu3", "esbou3ein", "asabi3",
            "اسبوع", "اسابيع", "اسبوعين"
        ])
        add([.unitMonth], [
            "month", "months", "shahr", "shaher", "ashhor", "shahrein",
            "شهر", "اشهر", "شهور", "شهرين"
        ])
        add([.unitYear], [
            "year", "years", "sene", "sane", "sinin",
            "سنه", "سنوات", "سنين"
        ])

        // MARK: Glue

        add([.oclock], [
            "at", "3a", "3al", "oclock", "sharp",
            "علي", "عالساعه"
        ])
        add([.within], [
            "in", "within", "after", "ba3d", "ba3ed", "khilal", "5ilal",
            "بعد", "خلال", "كمان"
        ])
        add([.untilMarker], [
            "until", "till", "untill", "to", "into", "la7ad", "la7ed", "ila", "lal", "la",
            "الى", "لحد", "حتي", "لغايه"
        ])
        add([.forMarker], [
            "for", "about", "regarding", "3ala", "3an",
            "لاجل", "بخصوص", "علشان", "عشان", "تبع"
        ])
        add([.nextMarker], [
            "next", "coming", "jeye", "ijjeye", "eljeye", "jay", "eljay",
            "الجاي", "الجايه", "القادم", "القادمه", "المقبل", "الجايي"
        ])
        add([.thisMarker], [
            "this", "hayda", "hal", "hayde", "had",
            "هاد", "هذا", "هاي", "هذه"
        ])
        add([.questionWord], [
            "what", "whats", "which", "when", "shu", "chou", "eish", "esh", "aish", "wen", "emta",
            "شو", "ايش", "وين", "امتي", "متي", "كم"
        ])

        // MARK: Meridiem

        // Deliberately not "a" and "p": the English article "a" would silently turn every
        // "remind me at 4 to make a call" into an AM alarm.
        add([.am, .morning], ["am", "ص"])
        add([.pm, .evening], ["pm", "م"])

        // MARK: Numerals

        let english = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                       "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                       "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
                       "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]
        for (word, value) in english { add([.number(value)], [word]) }

        let arabizi = ["wa7ad": 1, "wehed": 1, "wahed": 1,
                       "tnen": 2, "tneyn": 2, "tnein": 2, "itnen": 2,
                       "tlete": 3, "tlateh": 3, "talate": 3, "tlata": 3,
                       "arb3a": 4, "arbaa": 4, "arba3a": 4,
                       "khamse": 5, "5amse": 5, "khamsa": 5,
                       "sitte": 6, "site": 6, "sitta": 6,
                       "sab3a": 7, "sabaa": 7, "sab3ah": 7,
                       "tmene": 8, "tmeneh": 8, "tmenye": 8,
                       "tes3a": 9, "tis3a": 9, "tesaa": 9,
                       "3ashra": 10, "3ashara": 10, "3achra": 10,
                       "7das": 11, "7dash": 11, "7da3sh": 11,
                       "tnas": 12, "tna3sh": 12, "tnash": 12]
        for (word, value) in arabizi { add([.number(value)], [word]) }

        let arabic = ["صفر": 0, "واحد": 1, "اثنين": 2, "ثنين": 2, "تنين": 2,
                      "ثلاثه": 3, "تلاته": 3, "اربعه": 4, "خمسه": 5, "سته": 6,
                      "سبعه": 7, "ثمانيه": 8, "تمانيه": 8, "تسعه": 9, "عشره": 10,
                      "احدعش": 11, "اطنعش": 12, "اتنعش": 12, "تنعش": 12,
                      "عشرين": 20, "ثلاثين": 30, "تلاتين": 30]
        for (word, value) in arabic { add([.number(value)], [word]) }
        // Note: "تنين" and "اثنين" are Monday too — both meanings are added, and position decides.

        add([.half], ["half", "nos", "nus", "noss", "nuss", "نص", "نصف"])
        add([.quarter], ["quarter", "rob3", "rub3", "ro3b", "ربع"])
        add([.minusMarker], ["illa", "ella", "minus", "before", "الا"])

        // MARK: Filler — dropped from titles, never affects meaning

        add([.filler], [
            "me", "my", "i", "the", "a", "an", "please", "pls", "plz", "and", "then", "w", "wu", "و",
            "do", "have", "is", "it", "that", "of", "on", "you", "can", "could", "would",
            "ya", "yalla",
            "انا", "يا", "لو", "سمحت", "بليز", "من", "في", "ان", "انه", "هيدا"
        ])

        return t
    }()
}
