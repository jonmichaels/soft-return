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

// ---- render targets (Jon's ruling, 2026-08-04 night) -----------------------
// One RTF file cannot serve every importer (Office-private fonts, Cocoa's
// falt-blindness, Docs' web catalog), so the CALLER picks a target:
//   office  Word-first (default): fonts DISTRIBUTED WITH MS OFFICE (Century
//           Gothic etc. are Office-only -- bare Windows has just the web-core
//           set plus Palatino Linotype), resolved by Word AND Google Docs;
//           LibreOffice substitutes them decently via its own tables
//   mac     Cocoa-native names -- TextEdit/Pages/Soft Return.app world
//   google  Docs' own catalog where it has something Office lacks (chancery)
//   linux   the URW base-35 clones (Ghostscript heritage, packaged everywhere
//           as fonts-urw-base35): free metric-compatible copies of EXACTLY
//           this era's set -- URW Gothic IS Avant Garde, URW Bookman IS
//           Bookman, C059 IS New Century Schoolbook, P052 IS Palatino, Z003
//           IS Zapf Chancery, Nimbus Sans/Roman/Mono PS are Helvetica/Times/
//           Courier. The most faithful target of all, and libre.
// Coverage rule: a family with no entry in FONT_ALTS still gets a USEFUL face
// from its font block's own generic-style bits -- never nothing.

/// Which importer the RTF font names are chosen FOR. Python spells this as the string
/// `fonts_target='office'` and lets argparse's `choices` police it; here the closed
/// vocabulary is the type, so `GENERIC_PRIMARY.get(target, GENERIC_PRIMARY['office'])`'s
/// unknown-target arm is unreachable by construction and is not written below.
public enum FontsTarget: String, Hashable, Sendable, CaseIterable {
    case office
    case mac
    case google
    case linux
}

/// `GENERIC_PRIMARY` (fontmap.py) — the target's face for each of the font block's own
/// generic-style bits, which is what an unmapped (or unnamed) font lands on.
let genericPrimary: [FontsTarget: [GenericStyle: String]] = [
    .office: [.sans: "Arial", .serif: "Times New Roman",
              .script: "Monotype Corsiva", .display: "Impact"],
    .mac:    [.sans: "Helvetica", .serif: "Georgia",
              .script: "Apple Chancery", .display: "Futura"],
    .google: [.sans: "Arial", .serif: "Times New Roman",
              .script: "Dancing Script", .display: "Impact"],
    .linux:  [.sans: "DejaVu Sans", .serif: "DejaVu Serif",
              .script: "Z003", .display: "DejaVu Sans"],
]

/// `TARGET_OVERRIDES` (fontmap.py) — where a target's best name differs from the head of
/// `fontAlternates`, which is Office-first.
let targetOverrides: [FontsTarget: [String: String]] = [
    .office: [:],
    // macOS-native stand-ins for the Office-private set: Futura carries the
    // Avant Garde geometry; Iowan Old Style is the closest native to
    // Bookman's warmth; Georgia was DESIGNED as a screen Schoolbook-alike.
    .mac: [
        "avant garde": "Futura",
        "bookman": "Iowan Old Style",
        "cntry schlbk": "Georgia",
        "newcntschlbk": "Georgia",
        "new century schoolbook": "Georgia",
        "century": "Georgia",
        "american classic": "Iowan Old Style",
        "helv": "Helvetica",
        "helvetica": "Helvetica",
        "univers": "Helvetica Neue",
    ],
    // URW base-35 canonical family names (the C059/P052/Z003 codes ARE the
    // modern fontconfig names; older aliases 'Century SchoolBook L' /
    // 'URW Palladio L' / 'URW Chancery L' still resolve on most distros).
    .linux: [
        "avant garde": "URW Gothic",
        "bookman": "URW Bookman",
        "cntry schlbk": "C059",
        "newcntschlbk": "C059",
        "new century schoolbook": "C059",
        "century": "C059",
        "american classic": "C059",
        "palatino": "P052",
        "zapfchancery": "Z003",
        "zapf chancery": "Z003",
        "coronet": "Z003",
        "helv": "Nimbus Sans",
        "helvetica": "Nimbus Sans",
        "helv narrow": "Nimbus Sans Narrow",
        "helv cond.": "Nimbus Sans Narrow",
        "helvetica narrow": "Nimbus Sans Narrow",
        "univers": "Nimbus Sans",
        "times": "Nimbus Roman",
        "tms rmn": "Nimbus Roman",
        "cg times": "Nimbus Roman",
        "courier": "Nimbus Mono PS",
        "pica": "Nimbus Mono PS",
        "elite": "Nimbus Mono PS",
        "lineprinter": "Nimbus Mono PS",
        "symbol": "Standard Symbols PS",
    ],
    // Docs resolves the Microsoft names natively; its one real gap is a
    // chancery script -- Dancing Script is the stock calligraphic answer.
    .google: [
        "zapfchancery": "Dancing Script",
        "zapf chancery": "Dancing Script",
        "coronet": "Dancing Script",
    ],
]

/// `(primary, falt_or_nil)` for an RTF fonttbl entry. The primary is the target's best
/// AVAILABLE name; the falt is the next-best MODERN name -- never the era name (Jon: 'no
/// use keeping the ALT font that crazy title' -- nothing modern resolves 'PS SansSer
/// Qual'; the verbatim era name stays first-class in `Document.fonts` and the HTML
/// stacks). A family with no table entry gets the target's generic primary from the font
/// block's own style bits, so EVERY font run lands on a usable face.
///
/// Python's `rtf_fonts` (fontmap.py). `generic` is optional here as it is there, even
/// though `FontChange.genericStyle` always has one: the falsy-`generic_style` arm is what
/// makes the "no primary at all" return reachable, and dropping it would drop that.
func rtfFonts(_ family: String, generic: GenericStyle? = nil,
              target: FontsTarget = .office) -> (primary: String?, falt: String?) {
    let key = asciiLowercased(family)
    let alts = fontAlternates[key] ?? []
    let primary = targetOverrides[target]?[key]
        ?? alts.first
        ?? generic.flatMap { genericPrimary[target]?[$0] }
    guard let primary else { return (family.isEmpty ? nil : family, nil) }
    // Python's `next((a for a in alts if a != primary), None)`: the FIRST alternate that
    // isn't already the primary — a second modern name, or nothing.
    return (primary, alts.first { $0 != primary })
}

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
