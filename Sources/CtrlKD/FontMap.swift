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
    // Albertus (Monotype, Berthold Wolpe): a glyphic/flared-serif display
    // face -- chiseled, incised strokes, neither a classic serif nor a
    // sans. Not in WSFORMAT.TXT's own 245-entry typestyle catalog at all
    // (verified against the public spec, sfwriter.com/wsformat.txt: zero
    // occurrences) -- WordStar's LaserJet printer drivers (LASERJET.PDF,
    // LJ6DTP.PDF, HP4.PDF, all in the Sawyer archive) instead route their
    // own typestyle 50 ("Aachen (Postscript)" per the canonical table) to
    // the real HP-resident face "Albertus PC ..." -- confirmed by the raw
    // driver bytes (name pairs `Aachen\0Albertus PC ...\0`) and by
    // PREVIEW.WS itself, WordStar's own factory demo file, whose caption
    // literally labels that exact font block "Albertus". Herculanum first
    // (closest MAC-native glyphic/incised face); Colonna MT next (the
    // Office-bundled glyphic equivalent, same family as this table's own
    // 'univ. roman' -> Harrington choice); Rockwell as the universal-safe
    // tail (matches 'clarendon'/'aachen' precedent above).
    "albertus":               ["Herculanum", "Colonna MT", "Rockwell"],
    // Marigold (Agfa Compugraphic, Arthur Baker, 1989): a calligraphic
    // script face. Also absent from WSFORMAT.TXT's 245-entry catalog --
    // the same LaserJet driver files route typestyle 81 ("ZapfChancery")
    // to the real HP-resident face "Marigold PC ..." (name pair
    // `ZapfChancery\0Marigold PC ...\0`), so it takes the same modern
    // alternates already ruled for zapfchancery/coronet.
    "marigold":               ["Apple Chancery", "Monotype Corsiva", "Coronet"],
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

/// b24 round 20 (slate item 4): verse-classified units and wrapped centered units read
/// cramped at the document's own default reading line-height (HTML body: 1.6; RTF
/// style/reader default is comparably loose) — poetry and centered material (titles,
/// dedications, verse) conventionally sets SINGLE-spaced internally regardless of the
/// surrounding prose's own spacing. A single named constant, not a hardcoded literal at
/// each call site — Jon's own framing: "single-spaced default BUT parameterize it — I
/// get shown options later; the mechanism lands now." Every consumer (HTML's own
/// `line-height`, RTF's `\sl`/`\slmult0` via `rtfVerseTightSlTwips`) reads this ONE
/// place. Port of `VERSE_LINE_HEIGHT`.
let verseLineHeight = 1.15
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
        // Marigold joins this group (not aliased-in-name, but IN
        // SUBSTITUTION): the LaserJet driver files route ZapfChancery's
        // own typestyle number to the real HP-resident face "Marigold",
        // a calligraphic script -- same category, same modern targets.
        ("zapfchancery|zapf chancery|coronet|marigold", "Monotype Corsiva", "Apple Chancery"),
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
        // Colonna MT: an Office-bundled glyphic/incised display face (same
        // decorative Office set as the 'univ. roman' -> Harrington choice
        // just above) -- the closest chiseled-serif match Office ships to
        // Albertus's flared, non-serif/non-sans character.
        ("albertus", "Colonna MT", "Rockwell"),
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
        // Marigold joins this group in substitution only (LaserJet driver
        // files route ZapfChancery's typestyle to the real HP-resident
        // face "Marigold", a calligraphic script -- same category).
        ("zapfchancery|zapf chancery|coronet|marigold", "Apple Chancery", "Monotype Corsiva"),
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
        // Herculanum: Apple's own bundled glyphic/incised display face
        // (Frutiger, ships standard in macOS's decorative set alongside
        // Papyrus) -- the closest Mac-native chiseled-serif match to
        // Albertus's flared, non-serif/non-sans character.
        ("albertus", "Herculanum", "Copperplate"),
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
        // Marigold joins this group in substitution only (see the office
        // table's own note above) -- same calligraphic-script category.
        ("zapfchancery|zapf chancery|coronet|marigold", "Dancing Script", "Apple Chancery"),
        ("zapfdingbats|zapf dingbats", "Zapf Dingbats", nil),
        ("symbol", "Symbol", nil),
        ("courier|pica|elite|lineprinter|letter gothic|gothic|prestige", "Courier New", nil),
        ("antique olive|optima", "Verdana", nil),
        ("garamond", "EB Garamond", "Garamond"),
        ("clarendon|aachen|rockwell", "Roboto Slab", "Rockwell"),
        ("bodoni", "Bodoni Moda", "Bodoni MT"),
        ("broadway", "Poppins", nil),
        ("univ. roman", "Bodoni Moda", nil),
        // Cinzel: a real, widely-used Google Font cut with flared,
        // Roman-inscriptional glyphic serifs -- the closest catalog match
        // to Albertus's chiseled character; Marcellus (also a real Google
        // Font in the same glyphic/inscriptional family) as the second
        // choice.
        ("albertus", "Cinzel", "Marcellus"),
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
        // Marigold joins this group in substitution only (see the office
        // table's own note above) -- Z003 IS Zapf Chancery's true URW
        // clone, the most faithful available answer for the whole group.
        ("zapfchancery|zapf chancery|coronet|marigold", "Z003", "DejaVu Serif"),
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
        // No free glyphic/flared clone of Albertus exists in the
        // guaranteed-packaged set (fonts-urw-base35 covers only the
        // PostScript base-35; URW's own "Lapidar Serif No. 2" Albertus
        // clone is a separate, non-guaranteed URW++ product, unlike
        // Nimbus/URW Gothic/Z003 -- checked against this box's actual
        // `fc-list`/`apt-cache`, not present). Least-wrong per the
        // coverage rule: DejaVu Serif (always present via fontconfig),
        // Rockwell as falt -- same pairing already used for
        // clarendon/aachen above, for the same reason.
        ("albertus", "DejaVu Serif", "Rockwell"),
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
///
/// `proportional == false` (ctrl-kd round 9, tier-1 evidence) is DECISIVE and short-
/// circuits all of the above: WSFORMAT's generic Non-PostScript typestyles have no real
/// installable face, genuine or fallback -- their OWN table lookups miss, and the
/// generic-style-bits fallback would promote them to Arial/Times New Roman, a real
/// proportional face this record's own bit says it is NOT. Routed through the SAME
/// per-target 'courier' table entry every genuine mono family already resolves through
/// (single source for the target's mono face), never a family-name or falt garnish:
/// there is no honest mono-flavored alternate for a generic NLQ category, so none is
/// invented.
///
/// NOT routed through `resolveFont` (b24 round 21 item 5, the shared target-agnostic
/// resolution) — its own first tier consults `targetFonts`, a per-TARGET curated table
/// with no target-agnostic equivalent there; see `resolveFont`'s own doc comment.
func rtfFonts(_ family: String, generic: GenericStyle? = nil,
              target: FontsTarget = .office, proportional: Bool? = nil) -> (primary: String?, falt: String?) {
    if proportional == false {
        let courier = targetFonts[target]?["courier"] ?? targetFonts[.office]?["courier"]
        return (courier?.primary, courier?.falt)
    }
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

// ---- the shared, target-agnostic resolution (b24 round 21 item 5) --------

/// The resolved, target-agnostic effective font family for one span — the ANSWER
/// every b24 consumer that cares "what face does this actually render as" needs, in a
/// shape that doesn't presuppose which of them is asking.
///
/// This is the round's own architectural deliverable (RULINGS-LEDGER row for item 12):
/// factored out into ONE public function so the app's own view layer (wave 4 — an
/// on-screen Modern preview that must match what export would show) can ask the same
/// question every export emitter already does, without re-deriving the decision or
/// reaching into an emitter-internal function. `resolveFont`/`resolveFont(_:FontChange)`
/// below are the public API; `ResolvedFont` is its return shape.
public struct ResolvedFont: Hashable, Sendable {
    /// The best available face name for FIRST choice — the document's own era name
    /// (`FontChange.family`) when one exists, pass-through per this project's own
    /// "never hardwire a style to a font" rule; `nil` only when the era name itself
    /// was empty (an unnamed typestyle number, or no font run at all).
    public let primary: String?
    /// Ordered, deduplicated fallback names AFTER `primary` — the era's own modern
    /// alternates (`fontAlternates`), in the SAME order every consumer already reads
    /// them: RTF's own `{\*\falt ...}` uses only the first, HTML's own stack uses all
    /// of them before its terminal generic.
    public let alternates: [String]
    /// Whether this family is monospace — decisive over any name/generic evidence,
    /// mirroring WSFORMAT's own `proportional` bit (ctrl-kd round 9's "tier-1
    /// evidence" ruling): a `proportional == false` record is NEVER promoted to a
    /// proportional face however plausible a name/generic match looks. When true, a
    /// consumer's own terminal fallback should be ITS OWN monospace face/keyword, not
    /// `generic` below (which is meaningless here — a WSFORMAT generic-style bit
    /// describes a PROPORTIONAL shape family, never "monospace").
    public let isMonospace: Bool
    /// The WSFORMAT generic-style bucket (sans/serif/script/display) this family
    /// terminates in when nothing more specific resolves and `isMonospace` is false —
    /// the four-way split every b24 consumer already reads off `FontChange.genericStyle`.
    public let generic: GenericStyle?

    public init(primary: String?, alternates: [String], isMonospace: Bool, generic: GenericStyle?) {
        self.primary = primary
        self.alternates = alternates
        self.isMonospace = isMonospace
        self.generic = generic
    }
}

/// Resolve one `(family, generic, proportional)` triple — a `FontChange`'s own
/// pass-through fields — to the shared, target-agnostic `ResolvedFont` answer.
///
/// This is a genuine EXTRACTION, not a new decision: `fontStack` (HTML) below is now a
/// thin wrapper over it (verified byte-identical output, since HTML's own algorithm
/// never involved a per-target table in the first place — the same stack for every
/// `FontsTarget`). Two consumers deliberately stay independent rather than route
/// through this function, and say why at their own definition:
///   - `rtfFonts` (below) — RTF's OWN resolution consults `targetFonts`, a per-TARGET
///     curated (primary, falt) table with no target-agnostic equivalent here; folding
///     that tier into this function would either lose it or make `resolveFont` secretly
///     target-aware, defeating its own purpose.
///   - `pdfFamily` (PDFFonts.swift) — PDF's own resolution is a genuinely different
///     ALGORITHM SHAPE (a one-of-5 base-14 SELECTION with its own tier-2 fixed-pitch-
///     name check, `monoFamilies`), not a candidate list terminating in a CSS/RTF
///     generic; unifying it here would misrepresent what it actually does.
public func resolveFont(family: String, generic: GenericStyle? = nil,
                        proportional: Bool? = nil) -> ResolvedFont {
    var seen: [String] = family.isEmpty ? [] : [family]
    var alternates: [String] = []
    for alt in fontAlternates[asciiLowercased(family)] ?? [] where !seen.contains(alt) {
        alternates.append(alt)
        seen.append(alt)
    }
    return ResolvedFont(primary: family.isEmpty ? nil : family, alternates: alternates,
                        isMonospace: proportional == false, generic: generic)
}

/// Convenience overload reading straight from a `FontChange` — the shared input every
/// b24 consumer (PDF/RTF/HTML, and now the app) already has via `Document.fonts`.
public func resolveFont(_ font: FontChange) -> ResolvedFont {
    resolveFont(family: font.family, generic: font.genericStyle, proportional: font.proportional)
}

/// CSS-style ordered list: original family first, then modern alternates, then the
/// generic from the font block's own style bits.
///
/// `proportional == false` (ctrl-kd round 9) keeps the verbatim family name as harmless
/// first-choice garnish (a browser just skips an unresolvable name) but TERMINATES the
/// stack at the CSS generic `monospace` instead of whatever `generic`'s sans/serif/
/// script/display value would otherwise pick -- the same "never promote to a
/// proportional face" rule as `rtfFonts`, honoured for HTML's own fallback mechanism.
///
/// A thin wrapper over `resolveFont` (b24 round 21 item 5) — the CSS-specific shape
/// (a flat ordered `[String]`, generic rendered as a CSS keyword) lives only here now;
/// the resolution DECISION lives in `resolveFont`.
func fontStack(_ family: String, generic: GenericStyle? = nil, proportional: Bool? = nil) -> [String] {
    let resolved = resolveFont(family: family, generic: generic, proportional: proportional)
    var stack: [String] = []
    if let primary = resolved.primary { stack.append(primary) }
    stack.append(contentsOf: resolved.alternates)
    if resolved.isMonospace {
        stack.append("monospace")
    } else if let generic = resolved.generic, let css = genericCSS[generic] {
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
