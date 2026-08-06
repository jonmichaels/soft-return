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
    // No Wingdings here (ruling, 2026-08-05): its glyph MAPPING differs, so a fallback to
    // it would print wrong symbols -- and dingbat runs are transliterated to real Unicode
    // anyway, which any font-stack terminus can render.
    "zapfdingbats":           ["Zapf Dingbats"],
    "zapf dingbats":          ["Zapf Dingbats"],
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
///
/// `.mac` serif is Times New Roman (Jon's ruling, 2026-08-05): the generic fires for
/// UNKNOWN faces, and the era-honest render is the era's own neutral serif -- Georgia now
/// means exactly one thing on mac (New Century Schoolbook, via `TARGET_FONTS` below).
/// `.google` display is Poppins: Impact exists in Docs' MENU but the import CONVERTER
/// maps names through an internal table that lacks it (Jon's three import tests,
/// 2026-08-05 -- the Drive previewer renders Impact, conversion turns every declaration
/// form into Arial identically).
let genericPrimary: [FontsTarget: [GenericStyle: String]] = [
    .office: [.sans: "Arial", .serif: "Times New Roman",
              .script: "Monotype Corsiva", .display: "Impact"],
    .mac:    [.sans: "Helvetica", .serif: "Times New Roman",
              .script: "Apple Chancery", .display: "Futura"],
    .google: [.sans: "Arial", .serif: "Times New Roman",
              .script: "Dancing Script", .display: "Poppins"],
    .linux:  [.sans: "DejaVu Sans", .serif: "DejaVu Serif",
              .script: "Z003", .display: "DejaVu Sans"],
]

/// The sophisticated body: what a document with NO font information at all (every WS4
/// file, fontless WS5+) reads in under Modern. Jon's specimen ruling 2026-08-05: "Georgia
/// 14 at 1in margins -- like reading a cozy book" -- and one font for ALL targets, because
/// RTF's falt and HTML's font stack carry the no-Georgia case natively (the per-target
/// variation lives in the FALLBACK). PDF is not here: base-14 by design principle, it
/// renders the body as Times at the same size ("the PDF needs to work no matter what.
/// Times New Roman 14. It has to be.").
let modernBodySize = 14
let modernBodyFonts: [FontsTarget: (primary: String, falt: String)] = [
    .office: ("Georgia", "Times New Roman"),
    .mac:    ("Georgia", "Times New Roman"),
    .google: ("Georgia", "Times New Roman"),
    .linux:  ("Georgia", "P052"),
]

// ---- the FINAL RULED FONT TABLE (CLI-Defaults-Audit, 2026-08-05) ----------
// Complete per-target (primary, falt) pairs. Every mac cell device-verified by Jon (Font
// Book, locked-flag test); office cells verified against Microsoft's published Windows-11
// + cloud-fonts lists (11 names are M365 cloud fonts: menu-visible, auto-fetch, absent
// from disk -- the target means CURRENT CONNECTED WORD); google cells verified by Jon's
// Docs import tests (MS names NEVER survive conversion; Google-catalog names and the web
// core minus Impact do); linux primaries are the URW true clones (Ghostscript tier) with
// every falt a guaranteed-tier name (Liberation rides LibreOffice, DejaVu rides
// fontconfig itself).
//
// A `nil` falt means the primary is already the safest name available.

/// Flatten alias groups (`"a|b|c"`) into one `key -> (primary, falt)` table, mirroring
/// Python's `_expand`.
private func expandTargetFonts(
    _ rows: [(keys: String, primary: String, falt: String?)]
) -> [String: (primary: String, falt: String?)] {
    var flat: [String: (primary: String, falt: String?)] = [:]
    for row in rows {
        for key in row.keys.split(separator: "|") {
            flat[String(key)] = (row.primary, row.falt)
        }
    }
    return flat
}

let targetFonts: [FontsTarget: [String: (primary: String, falt: String?)]] = [
    .office: expandTargetFonts([
        ("avant garde", "Century Gothic", "ITC Avant Garde Gothic"),
        ("bookman", "Bookman Old Style", "Georgia"),
        ("cntry schlbk|newcntschlbk|new century schoolbook|century", "Century Schoolbook", "Georgia"),
        ("american classic", "Century Schoolbook", "Georgia"),
        ("helv|helvetica", "Arial", "Helvetica Neue"),
        ("helv narrow|helv cond.|helvetica narrow", "Arial Narrow", "Helvetica Neue Condensed"),
        ("palatino", "Palatino Linotype", "Palatino"),
        ("tms rmn|times|cg times", "Times New Roman", nil),
        ("zapfchancery|zapf chancery|coronet", "Monotype Corsiva", "Apple Chancery"),
        ("zapfdingbats|zapf dingbats", "Zapf Dingbats", "Segoe UI Symbol"),
        ("symbol", "Symbol", nil),
        ("courier|pica|elite|lineprinter", "Courier New", nil),
        ("letter gothic|gothic", "Consolas", "Courier New"),
        ("prestige", "Courier New", nil),
        ("univers", "Arial", "Helvetica Neue"),
        ("cg triumvirate|ps sansser qual", "Arial", "Helvetica"),
        ("antique olive", "Candara", "Verdana"),
        ("optima", "Candara", "Optima"),
        ("garamond", "Garamond", "EB Garamond"),
        ("clarendon", "Rockwell", "Clarendon"),
        ("aachen|rockwell", "Rockwell", "Courier New"),
        ("bodoni", "Bodoni MT", "Bodoni 72"),
        ("broadway", "Broadway", nil),
        ("univ. roman", "Harrington", "Georgia"),
    ]),
    .mac: expandTargetFonts([
        ("avant garde", "Futura", "Century Gothic"),
        ("bookman", "Cochin", "Bookman Old Style"),
        ("cntry schlbk|newcntschlbk|new century schoolbook|century", "Georgia", "Century Schoolbook"),
        ("american classic", "Baskerville", "Century Schoolbook"),
        ("helv|helvetica", "Helvetica", "Arial"),
        ("helv narrow|helv cond.|helvetica narrow", "Arial Narrow", "Helvetica Neue Condensed"),
        ("palatino", "Palatino", "Palatino Linotype"),
        ("tms rmn|times|cg times", "Times New Roman", nil),
        ("zapfchancery|zapf chancery|coronet", "Apple Chancery", "Monotype Corsiva"),
        ("zapfdingbats|zapf dingbats", "Zapf Dingbats", nil),
        ("symbol", "Symbol", nil),
        ("courier|pica|elite|lineprinter", "Courier New", nil),
        ("letter gothic|gothic", "Menlo", "Courier New"),
        ("prestige", "Courier New", nil),
        ("univers", "Helvetica Neue", "Arial"),
        ("cg triumvirate|ps sansser qual", "Helvetica", "Arial"),
        ("antique olive", "Optima", "Verdana"),
        ("optima", "Optima", "Candara"),
        ("garamond", "Hoefler Text", "Garamond"),
        ("clarendon", "Rockwell", "Clarendon"),
        ("aachen|rockwell", "Rockwell", "Courier New"),
        ("bodoni", "Bodoni 72", "Bodoni MT"),
        ("broadway", "Phosphate Solid", "Futura"),
        ("univ. roman", "Didot", "Georgia"),
    ]),
    .google: expandTargetFonts([
        ("avant garde", "Poppins", "Century Gothic"),
        ("bookman", "Merriweather", "Bookman Old Style"),
        ("cntry schlbk|newcntschlbk|new century schoolbook|century", "Georgia", "Century Schoolbook"),
        ("american classic", "Georgia", "Century Schoolbook"),
        ("helv|helvetica|univers", "Arial", nil),
        ("cg triumvirate|ps sansser qual", "Arial", nil),
        ("helv narrow|helv cond.|helvetica narrow", "PT Sans Narrow", "Arial Narrow"),
        ("palatino", "Lora", "Palatino Linotype"),
        ("tms rmn|times|cg times", "Times New Roman", nil),
        ("zapfchancery|zapf chancery|coronet", "Dancing Script", "Apple Chancery"),
        ("zapfdingbats|zapf dingbats", "Zapf Dingbats", nil),
        ("symbol", "Symbol", nil),
        ("courier|pica|elite|lineprinter|letter gothic|gothic|prestige", "Courier New", nil),
        ("antique olive|optima", "Verdana", nil),
        ("garamond", "EB Garamond", "Garamond"),
        ("clarendon|aachen|rockwell", "Roboto Slab", "Rockwell"),
        ("bodoni", "Bodoni Moda", "Bodoni MT"),
        ("broadway", "Poppins", nil),
        ("univ. roman", "Bodoni Moda", nil),
    ]),
    .linux: expandTargetFonts([
        ("avant garde", "URW Gothic", "DejaVu Sans"),
        ("bookman", "URW Bookman", "DejaVu Serif"),
        ("cntry schlbk|newcntschlbk|new century schoolbook|century", "C059", "DejaVu Serif"),
        ("american classic", "C059", "DejaVu Serif"),
        ("helv|helvetica|univers", "Nimbus Sans", "Liberation Sans"),
        ("cg triumvirate|ps sansser qual", "Nimbus Sans", "Liberation Sans"),
        ("helv narrow|helv cond.|helvetica narrow", "Nimbus Sans Narrow", "DejaVu Sans"),
        ("palatino", "P052", "DejaVu Serif"),
        ("tms rmn|times|cg times", "Nimbus Roman", "Liberation Serif"),
        ("zapfchancery|zapf chancery|coronet", "Z003", "DejaVu Serif"),
        ("zapfdingbats|zapf dingbats", "D050000L", "Zapf Dingbats"),
        ("symbol", "Standard Symbols PS", "Symbol"),
        ("courier|pica|elite|lineprinter", "Nimbus Mono PS", "Liberation Mono"),
        ("letter gothic|gothic", "DejaVu Sans Mono", "Nimbus Mono PS"),
        ("prestige", "Nimbus Mono PS", "Liberation Mono"),
        ("antique olive|optima", "DejaVu Sans", "Verdana"),
        ("garamond", "P052", "DejaVu Serif"),
        ("clarendon|aachen|rockwell", "DejaVu Serif", "Rockwell"),
        ("bodoni", "C059", "DejaVu Serif"),
        ("broadway", "URW Gothic", "DejaVu Sans"),
        ("univ. roman", "DejaVu Serif", nil),
    ]),
]

/// `(primary, falt_or_nil)` for an RTF fonttbl entry, from the FINAL RULED FONT TABLE. A
/// family with no table entry gets the target's generic primary from the font block's own
/// style bits (a primary that RESOLVES beats a period name Cocoa/Docs cannot -- the
/// verbatim era name stays first-class in `Document.fonts` and the HTML stacks), falling
/// all the way back to the family's own name when even the bits are absent.
///
/// Python's `rtf_fonts` (fontmap.py). `generic` is optional here as it is there, even
/// though `FontChange.genericStyle` always has one: the falsy-`generic_style` arm is what
/// makes the "no primary at all" return reachable, and dropping it would drop that.
func rtfFonts(_ family: String, generic: GenericStyle? = nil,
              target: FontsTarget = .office) -> (primary: String?, falt: String?) {
    let key = asciiLowercased(family)
    if let pair = targetFonts[target]?[key] {
        return pair
    }
    let alts = fontAlternates[key] ?? []
    let primary = alts.first ?? generic.flatMap { genericPrimary[target]?[$0] }
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
