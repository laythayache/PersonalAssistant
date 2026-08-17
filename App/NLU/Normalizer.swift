import Foundation

enum TextScript: String, Sendable {
    case latin
    case arabic
    case mixed
    case unknown
}

/// One word of input, kept in both forms.
///
/// `original` is what the user typed and is what ends up in an alarm title. `folded` is the
/// aggressively normalised form that the lexicon matches against. They are produced together from
/// the same split so that index `i` always means the same word in both — that alignment is what
/// lets the parser consume "الساعة" and still put "اتصل برياض" in the title unchanged.
struct Token: Equatable, Sendable {
    let original: String
    let folded: String
    let index: Int
}

struct NormalizedText: Sendable {
    let original: String
    let tokens: [Token]
    let script: TextScript
    /// All folded tokens joined by single spaces. Used for multi-word phrase matching.
    let phrase: String

    func folded(_ index: Int) -> String? {
        guard tokens.indices.contains(index) else { return nil }
        return tokens[index].folded
    }
}

enum Normalizer {

    // MARK: - Entry point

    static func normalize(_ text: String) -> NormalizedText {
        let rawTokens = split(text)
        var tokens: [Token] = []
        tokens.reserveCapacity(rawTokens.count)

        for raw in rawTokens {
            let folded = fold(raw)
            // A token made only of diacritics folds to nothing. Dropping it would misalign the
            // indices, so it is kept with an empty folded form and simply never matches.
            tokens.append(Token(original: raw, folded: folded, index: tokens.count))
        }

        return NormalizedText(original: text,
                              tokens: tokens,
                              script: detectScript(text),
                              phrase: tokens.map(\.folded).joined(separator: " "))
    }

    // MARK: - Splitting

    /// Splits on whitespace and punctuation, keeping `:` and `'` inside a word so that "7:30" and
    /// "what's" survive as single tokens.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""

        for ch in text {
            if ch.isLetter || ch.isNumber || ch == ":" || ch == "'" || ch == "\u{2019}" {
                current.append(ch)
            } else {
                if !current.isEmpty { out.append(current); current = "" }
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Folding

    static func fold(_ token: String) -> String {
        var scalars = String.UnicodeScalarView()

        for scalar in token.unicodeScalars {
            // Arabic-Indic (٠-٩) and Extended Arabic-Indic (۰-۹) digits become ASCII, so "٤" and
            // "4" take the same path through the parser.
            if let ascii = asciiDigit(for: scalar) {
                scalars.append(ascii)
                continue
            }
            if isRemovable(scalar) { continue }
            scalars.append(unifyArabicLetter(scalar))
        }

        var result = String(scalars)
        result = result.replacingOccurrences(of: "'", with: "")
        result = result.replacingOccurrences(of: "\u{2019}", with: "")
        result = result.lowercased()

        // Latin diacritics only; Arabic harakat were already dropped above.
        if !result.unicodeScalars.contains(where: isArabicLetter) {
            result = result.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                    locale: Locale(identifier: "en_US_POSIX"))
        }
        return result
    }

    private static func asciiDigit(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar.value {
        case 0x0660...0x0669: return Unicode.Scalar(scalar.value - 0x0660 + 0x30)
        case 0x06F0...0x06F9: return Unicode.Scalar(scalar.value - 0x06F0 + 0x30)
        default: return nil
        }
    }

    /// Harakat, tatweel, and the Quranic annotation marks. All are decoration that varies between
    /// keyboards, so they must not change whether a word matches.
    private static func isRemovable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x064B...0x065F: return true   // fathatan ... wavy hamza below
        case 0x0640: return true            // tatweel
        case 0x0670: return true            // superscript alef
        case 0x06D6...0x06ED: return true   // Quranic marks
        case 0x0610...0x061A: return true   // honorifics
        case 0x200C...0x200F: return true   // ZWNJ/ZWJ and directional marks
        case 0xFE00...0xFE0F: return true   // variation selectors
        default: return false
        }
    }

    /// Collapses the letter forms that people spell inconsistently. Purely for matching — the
    /// user's own spelling is preserved in `Token.original`.
    private static func unifyArabicLetter(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "\u{0622}", "\u{0623}", "\u{0625}", "\u{0671}":   // آ أ إ ٱ
            return "\u{0627}"                                   // ا
        case "\u{0649}", "\u{0626}":                            // ى ئ
            return "\u{064A}"                                   // ي
        case "\u{0629}":                                        // ة
            return "\u{0647}"                                   // ه
        case "\u{0624}":                                        // ؤ
            return "\u{0648}"                                   // و
        default:
            return scalar
        }
    }

    // MARK: - Script detection

    static func isArabicLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0600...0x06FF).contains(scalar.value)
            || (0x0750...0x077F).contains(scalar.value)
            || (0xFB50...0xFDFF).contains(scalar.value)
            || (0xFE70...0xFEFF).contains(scalar.value)
    }

    static func detectScript(_ text: String) -> TextScript {
        var arabic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isArabicLetter(scalar) { arabic += 1 }
            else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) { latin += 1 }
        }
        switch (arabic > 0, latin > 0) {
        case (true, true): return .mixed
        case (true, false): return .arabic
        case (false, true): return .latin
        case (false, false): return .unknown
        }
    }

    /// True when the text is Arabizi: Latin letters carrying the digit-for-letter substitutions
    /// (3 = ع, 7 = ح, 2 = ء, 5 = خ, 9 = ص) that only appear in romanised Arabic.
    static func looksLikeArabizi(_ normalized: NormalizedText) -> Bool {
        guard normalized.script == .latin || normalized.script == .mixed else { return false }
        for token in normalized.tokens {
            let hasLetter = token.folded.contains { $0.isLetter }
            let hasArabiziDigit = token.folded.contains { "23579".contains($0) }
            if hasLetter && hasArabiziDigit { return true }
        }
        // Words that are unambiguously romanised Arabic even without a digit.
        let markers = ["bokra", "bukra", "bkra", "lyoum", "elyom", "zakkerne", "zakerne",
                       "mnabbeh", "manabbeh", "sabt", "khamis", "tanen", "masa", "sob7", "lal"]
        return markers.contains { normalized.phrase.contains($0) }
    }
}
