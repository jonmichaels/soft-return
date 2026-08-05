/// Era font names -> modern equivalents, as FALLBACKS (never replacements).
///
/// The WordStar-era names (the PostScript base-35 set, LaserJet cartridge faces) mostly
/// don't exist under those names on a modern system: a Mac has Helvetica but not
/// Helvetica Narrow; Windows has Bookman Old Style but not Bookman. Per the pass-through
/// rule the ORIGINAL name always travels first; these lists supply what a renderer should
/// try next, ending with what the font block's own generic-style bits say
/// (sans/serif/script/display).
///
///   RTF   uses the first alternate via `{\*\falt ...}` -- RTF's native fallback
///         mechanism, honoured by Word.
///   HTML  uses the whole list as a font-family stack.
///
/// Keys are the RENDERED family (typestyle name up to its parenthetical), compared
/// case-insensitively. Extend freely; unlisted names simply fall through to the generic.
///
/// Direct port of `src/ctrlkd/fontmap.py`; the table is deliberately editable and is
/// carried over entry for entry, including the corpus spellings the archive actually uses
/// (`NewCntSchlbk`, `Helv Narrow`, `PS SansSer Qual`, `Univ. Roman`, …).
let fontAlternates: [String: [String]] = [
    // PostScript base-35 and friends
    "avant garde":            ["Century Gothic", "ITC Avant Garde Gothic"],
    "bookman":                ["Bookman Old Style"],
    "cntry schlbk":           ["Century Schoolbook", "New Century Schoolbook"],
    "newcntschlbk":           ["Century Schoolbook", "New Century Schoolbook"],
    "new century schoolbook": ["Century Schoolbook"],
    "century":                ["Century Schoolbook"],
    "helv":                   ["Helvetica", "Arial"],
    "helvetica":              ["Arial", "Helvetica Neue"],
    "helv cond.":             ["Arial Narrow", "Helvetica Neue Condensed"],
    "helv narrow":            ["Arial Narrow", "Helvetica Neue Condensed"],
    "helvetica narrow":       ["Arial Narrow", "Helvetica Neue Condensed"],
    "palatino":               ["Palatino", "Palatino Linotype", "Book Antiqua"],
    "tms rmn":                ["Times New Roman", "Times"],
    "times":                  ["Times New Roman"],
    "zapfchancery":           ["Apple Chancery", "Monotype Corsiva"],
    "zapf chancery":          ["Apple Chancery", "Monotype Corsiva"],
    "zapfdingbats":           ["Zapf Dingbats", "Wingdings"],
    "zapf dingbats":          ["Zapf Dingbats", "Wingdings"],
    "symbol":                 ["Symbol"],
    "courier":                ["Courier New"],
    "pica":                   ["Courier New"],
    "elite":                  ["Courier New"],
    "lineprinter":            ["Courier New"],
    "letter gothic":          ["Letter Gothic", "Courier New"],
    "gothic":                 ["Letter Gothic", "Courier New"],
    "prestige":               ["Prestige Elite", "Courier New"],
    // common LaserJet/DTP-era scalables seen in the wild
    "univers":                ["Helvetica Neue", "Arial"],
    "antique olive":          ["Optima", "Verdana"],
    "cg times":               ["Times New Roman"],
    "cg triumvirate":         ["Arial", "Helvetica"],
    "garamond":               ["Garamond", "EB Garamond"],
    "optima":                 ["Optima", "Candara"],
    "clarendon":              ["Clarendon", "Rockwell"],
    "aachen":                 ["Rockwell", "Courier New"],
    "bodoni":                 ["Bodoni 72", "Bodoni MT", "Didot"],
    "broadway":               ["Broadway"],
    "univ. roman":            ["University Roman", "Georgia"],
    "ps sansser qual":        ["Arial", "Helvetica"],
    "american classic":       ["Century Schoolbook", "Georgia"],
    "rockwell":               ["Rockwell", "Courier New"],
    "coronet":                ["Coronet", "Apple Chancery", "Monotype Corsiva"],
]

/// `_GENERIC_CSS` -- the CSS generic family for the typestyle word's generic-style bits.
private let genericCSS: [GenericStyle: String] = [
    .sans: "sans-serif", .serif: "serif", .script: "cursive", .display: "fantasy",
]

/// CSS-style ordered list: original family first, then modern alternates, then the
/// generic from the font block's own style bits.
func fontStack(_ family: String, generic: GenericStyle? = nil) -> [String] {
    var stack: [String] = family.isEmpty ? [] : [family]
    for alt in fontAlternates[asciiLowercased(family)] ?? [] where !stack.contains(alt) {
        stack.append(alt)
    }
    if let generic, let css = genericCSS[generic] {
        stack.append(css)
    }
    return stack
}

/// The single best alternate for RTF's `{\*\falt ...}`, or `nil`.
func rtfAlternate(_ family: String) -> String? {
    fontAlternates[asciiLowercased(family)]?.first
}

extension String {
    /// Python's `str.islower()`: at least one cased character, and every cased character
    /// lowercase. Used to tell a bare CSS generic (`sans-serif`) from a family name
    /// (`Courier New`), which is exactly the distinction the stack's quoting turns on.
    /// Lives here because that is its only caller. ASCII-only for the same reason
    /// `asciiLowercased` is: every name either side of this test is ASCII, and a full
    /// Unicode case fold is Foundation's job, not this library's.
    var isLowercaseCased: Bool {
        var sawCased = false
        for scalar in unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A { return false }   // upper
            if scalar.value >= 0x61 && scalar.value <= 0x7A { sawCased = true }
        }
        return sawCased
    }
}
