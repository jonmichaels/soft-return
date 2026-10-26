#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

/// Port of `targetFonts[.mac]` (`CtrlKD/FontMap.swift:192-217`, `internal` — same
/// "parallel port, not a call" discipline as this file's other engine ports, e.g.
/// `nativeLJ6DTPColourGray`/`nativeLJ6DTPCharSubst` above). Keys are the RENDERED family
/// (`FontChange.family`, i.e. the typestyle name up to its first parenthetical), lowercased.
/// `falt` is that row's own second modern name — "fallback chain per the mapping's
/// alternates" (this job's brief) — tried when the primary can't be resolved to an
/// installed font; unlisted families fall through to `nativeMacGenericPrimary` below,
/// the font block's own generic-style bits as terminus, exactly like `rtfFonts`'s own
/// fallback order (`FontMap.swift:279-281`).
let nativeMacFontRows: [String: (primary: String, falt: String?)] = {
    func expand(_ rows: [(keys: String, primary: String, falt: String?)])
        -> [String: (primary: String, falt: String?)] {
        var flat: [String: (primary: String, falt: String?)] = [:]
        for row in rows {
            for key in row.keys.split(separator: "|") { flat[String(key)] = (row.primary, row.falt) }
        }
        return flat
    }
    var rows = expand([
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
    ])
    #if os(iOS)
    // iOS 16 has neither Apple Chancery nor Monotype Corsiva (job 550's floor scan,
    // iOS-Font-Map.md): the chancery row is Snell Roundhand there. Phosphate Solid is absent
    // too, but the broadway row's own falt, Futura, is present; and Arial Narrow is taken
    // by `iosHelveticaNarrow` in the resolvers below.
    for key in ["zapfchancery", "zapf chancery", "coronet"] {
        rows[key] = ("Snell Roundhand", nil)
    }
    #endif
    return rows
}()

/// Port of `genericPrimary[.mac]` (`CtrlKD/FontMap.swift:116-117`). The terminus for any
/// typestyle name `nativeMacFontRows` doesn't carry — an unmapped family still gets a
/// USEFUL Mac-native face from its font block's own generic-style bits, never nothing.
#if os(iOS)
let nativeMacGenericPrimary: [GenericStyle: String] = [
    .sans: "Helvetica", .serif: "Times New Roman", .script: "Snell Roundhand", .display: "Futura",
]
#else
let nativeMacGenericPrimary: [GenericStyle: String] = [
    .sans: "Helvetica", .serif: "Times New Roman", .script: "Apple Chancery", .display: "Futura",
]
#endif

/// `entry.family`, lowercased, redirected to the short mono key ("courier"/"pica"/"elite"/
/// "lineprinter") when it's one of those NAMES WITH A SUFFIX the spec's own table carries
/// (e.g. `"Courier Italic (TI 855)"` -> family `"Courier Italic"`) — same `hasPrefix` guard
/// and same reasoning `nativeMonoFamilies`'s own doc comment already gives: these are
/// monospace-family variants the `.mac` table's exact-string keys don't spell out
/// individually, and belong on that family's own mapped face, not the generic-style
/// fallback its OTHER bits (serif/sans) might otherwise select.
func nativeMacFamilyKey(_ family: String) -> String {
    let lower = family.lowercased()
    if let mono = nativeMonoFamilies.first(where: { lower.hasPrefix($0) }) { return mono }
    return lower
}

/// Job 306 (b18): the `nativeMacFontRows` keys Jon's ruling names — Native's courier-class
/// mapping (`"courier|pica|elite|lineprinter"` and `"prestige"`, the two rows this job's
/// brief quotes verbatim; `"letter gothic|gothic"`'s primary is Menlo, not this class, so it
/// is untouched even though its OWN `falt` happens to be "Courier New" too).
///
/// Job 312/b19 (2026-08-14, Jon's ruling, SUPERSEDES job 306's Modern scoping below): Modern's
/// VIEW now resolves these rows to Courier Prime too, same as Native —
/// `renderModern`/`renderModernAnnotated`'s `attributedLine` calls now pass
/// `useCourierPrime: true` (`DocumentRenderer.swift`). What still keeps the views apart is the
/// EMITTED-output boundary, not a Modern/Native split: every emitter (RTF/HTML/MD/DOCX/CLI/QL
/// text) calls `nativeMacFontName`/`attributedLine`'s callers with `useCourierPrime`
/// defaulted `false` or explicitly `false`, so `OutputParityTests` still pins every output
/// surface to "Courier New" — only the two on-screen views (Native's Printed render and
/// Modern's) pass `true`. See `ModernViewerStyleTests
/// .bodyProseKeepsTheDocumentsOwnCourierNotTheUsersGeorgiaSetting` for the pinned Modern-side
/// expectation this must never regress.
let courierPrimeRowKeys: Set<String> = ["courier", "pica", "elite", "lineprinter", "prestige"]

/// Job 394 (391 root cause 3): the DECISIVE monospace verdict for `nativeMacFontName`
/// below, consulted BEFORE any name/generic-style lookup there — a direct call to the
/// engine's own shared `resolveFont` (`CtrlKD/FontMap.swift`'s b24 round 21 item 5
/// architectural deliverable: "ONE public function so the app's own view layer... can
/// ask the SAME question every export emitter already does, without re-deriving the
/// decision"), not a reimplementation of the bit test. `rtfFonts`'s own doc comment
/// states the rule this mirrors: "`proportional == false`... is DECISIVE and short-
/// circuits all of the above... routed through the SAME per-target 'courier' table entry
/// every genuine mono family already resolves through, never a family-name or falt
/// garnish." Before this job, `nativeMacFontName` had NO such short-circuit: a WSFORMAT
/// typestyle with `proportional == false` but no entry in `nativeMacFontRows` (ctrl-kd's
/// generic Non-PostScript categories — "NPS SansSer Qual"/"NPS Serif Qual", typestyle
/// numbers 103/104, SCRIPT.WS's own screenplay body font) fell all the way through to
/// `nativeMacGenericPrimary`'s sans/serif bucket and rendered a real PROPORTIONAL Mac
/// face for a record whose own bit says it is NOT one — the live Native/Modern view (and
/// therefore print and the AppKit-rendered PDF export, which both call this same
/// function) diverging from the RTF/PDF emitters, which already apply this identical
/// short-circuit via `rtfFonts`/`pdfFamily`.
func nativeMacIsMonospace(_ entry: FontChange) -> Bool {
    resolveFont(entry).isMonospace
}

/// The Mac font name (plus fallback alternate) for one WS5+ font-block span — replaces the
/// base-14 `nativeFontFamily`/`nativeFontPostScriptName` pair this job removed. Symbol/
/// dingbat BYTE-ENCODING detection (`entry.symbolMap`, and the typestyle-name prefix checks
/// job 186/210 already established) still takes priority over the name-driven table lookup,
/// unchanged from before this job: those bytes need the Symbol/Zapf Dingbats glyphs to mean
/// anything at all, independent of what face the typestyle name would otherwise select.
/// `nativeMacIsMonospace` (job 394, its own doc comment above) takes priority right after
/// those two — same "decisive, ahead of the name table" position `rtfFonts` gives the
/// identical bit.
///
/// `useCourierPrime` (job 306, default `false` so every EMITTER caller/test is unaffected):
/// the two on-screen views' own callers pass `true` (Native since job 306; Modern since
/// job 312/b19, 2026-08-14), substituting the bundled Courier Prime
/// (`CourierPrimeFontRegistration`) as primary with "Courier New" as `falt` — reached only if
/// the bundled face somehow failed to register/load — for exactly the two rows
/// `courierPrimeRowKeys` names, ahead of the shared `nativeMacFontRows` lookup.
func nativeMacFontName(_ entry: FontChange, useCourierPrime: Bool = false) -> (primary: String, falt: String?) {
    let name = (entry.typestyleName ?? "").lowercased()
    if name.hasPrefix("symbol") { return ("Symbol", nil) }
    if name.contains("dingbat") { return ("Zapf Dingbats", nil) }
    switch entry.symbolMap {
    case .math: return ("Symbol", nil)
    case .symbols: return ("Zapf Dingbats", nil)
    case .cp437, .cp850: break
    }
    if nativeMacIsMonospace(entry) {
        if useCourierPrime { return ("Courier Prime", "Courier New") }
        return nativeMacFontRows["courier"] ?? ("Courier New", nil)
    }
    let key = nativeMacFamilyKey(entry.family)
    if useCourierPrime, courierPrimeRowKeys.contains(key) {
        return ("Courier Prime", "Courier New")
    }
    if let row = nativeMacFontRows[key] { return row }
    return (nativeMacGenericPrimary[entry.genericStyle] ?? "Helvetica", nil)
}

/// Bold/italic traits onto a resolved Mac face via `NSFontManager`, same mechanism
/// `DocumentRenderer.styled(_:with:)` already uses for Modern style — a family name has no
/// fixed 4-member PostScript variant table the way base-14 did, so traits are synthesised
/// instead of looked up. Symbol and Zapf Dingbats are excluded: both are single-form faces
/// (no bold/italic member exists), and asking `NSFontManager` to synthesise a trait it can't
/// find on the family risks it substituting a DIFFERENT family entirely rather than doing
/// nothing — the same risk `styled(_:with:)`'s own early-return-on-no-traits avoids for the
/// common case, made explicit here for these two.
func nativeApplyTraits(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
    guard font.familyName != "Symbol" && font.familyName != "Zapf Dingbats" else { return font }
    var traits: NSFontTraitMask = []
    if bold { traits.insert(.boldFontMask) }
    if italic { traits.insert(.italicFontMask) }
    guard !traits.isEmpty else { return font }
    return NSFontManager.shared.convert(font, toHaveTrait: traits)
}

/// `NSFont` for one WS5+ font-block span at `size`, trying the mapped primary name, then
/// its `falt`, then giving up (the caller falls back to the document's own Courier — see
/// `resolvedFont`'s call site). Every name in `nativeMacFontRows`/`nativeMacGenericPrimary`
/// is a real installed macOS font (Jon's device verification, `FontMap.swift:140-142`'s own
/// citation — "every mac cell device-verified... Font Book, locked-flag test"), so the
/// `falt`/`nil` path is a defensive fallback, not an expected one.
/// THE BASE-14 FACE THE LIBRARY'S OWN MODERN PDF WOULD SET THIS RUN IN.
///
/// Used only under `DocumentRenderer.modernBase14MeasurementPin` — see that flag's own doc
/// comment for why a gate needs it and why the product never does. `pdfFamily` is the
/// library's own answer (`PDFFonts.swift`, now `public`), so the two sides cannot drift: this
/// asks the emitter which of the five families it would select, and then names the Mac face
/// that is metric-compatible with it.
///
/// Times New Roman for `.times` is not an approximation of convenience: measured glyph by
/// glyph across the printable ASCII range, macOS's Times New Roman matches the engine's AFM
/// Times-Roman table to 0.24/1000 em at worst and 0.08 on average.
/// The PDF `/BaseFont` name the library would set this run in — `base14(pdfFamily(entry),
/// bold:italic:)`, re-derived here because `base14` is `internal` to CtrlKD while the family
/// it takes is not. The four-variant order is the library's own
/// (`(bold ? 1 : 0) + (italic ? 2 : 0)`), and neither symbol face has variants.
func modernBase14Name(_ entry: FontChange?, bold: Bool, italic: Bool) -> String {
    base14Name(pdfFamily(entry), bold: bold, italic: italic)
}

/// `base14(family, bold:italic:)` itself, re-spelled here because the library's own is
/// `internal` while the family it takes is not. Split out from `modernBase14Name` for the
/// one caller that has already decided the family by Modern's own rule rather than
/// `pdfFamily`'s — see `renderModern`'s `modernFontlessFamily`.
func base14Name(_ family: CtrlKD.PDFFamily, bold: Bool, italic: Bool) -> String {
    let index = (bold ? 1 : 0) + (italic ? 2 : 0)
    switch family {
    case .times:
        return ["Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic"][index]
    case .helvetica:
        return ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique"][index]
    case .courier:
        return ["Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"][index]
    case .symbol: return "Symbol"
    case .zapfDingbats: return "ZapfDingbats"
    }
}

func modernBase14MacFont(
    _ entry: FontChange?, size: CGFloat, bold: Bool, italic: Bool
) -> NSFont? {
    let family: String
    switch pdfFamily(entry) {
    case .times: family = "Times New Roman"
    case .helvetica: family = "Helvetica"
    case .courier: family = "Courier New"
    case .symbol: family = "Symbol"
    case .zapfDingbats: family = "Zapf Dingbats"
    }
    guard let base = NSFont(name: family, size: size) else { return nil }
    return nativeApplyTraits(base, bold: bold, italic: italic)
}

func nativeResolvedMacFont(
    _ entry: FontChange, size: CGFloat, bold: Bool, italic: Bool, useCourierPrime: Bool = false
) -> NSFont? {
    let (primary, falt) = nativeMacFontName(entry, useCourierPrime: useCourierPrime)
    #if os(iOS)
    if primary == "Arial Narrow" { return iosHelveticaNarrow(size: size, bold: bold, italic: italic) }
    #endif
    for name in [primary, falt].compactMap({ $0 }) {
        if let base = NSFont(name: name, size: size) {
            return nativeApplyTraits(base, bold: bold, italic: italic)
        }
    }
    return nil
}

/// Job 445 (b27 item 7 part 1 — job 442's diagnosis, `outbox/job442/report.md`): whether
/// `font` has a REAL glyph, via `CTFontGetGlyphsForCharacters` (the Core Text coverage API
/// — no hardcoded box-drawing/cp437 codepoint list here), for every character in `text`.
/// `NSFont(name:size:)` succeeding only proves the FAMILY exists; it says nothing about
/// which Unicode blocks that face's own cmap covers — job 442 measured that neither
/// `Courier` nor `Courier Prime` covers cp437 box-drawing, yet both construct cleanly,
/// which is exactly the gap `nativeResolvedMacFont` above never checks. `NSFont`/`CTFont`
/// are toll-free bridged on macOS, so `font as CTFont` needs no re-lookup.
func fontCoversAllCharacters(_ font: NSFont, in text: String) -> Bool {
    let units = Array(text.utf16)
    guard !units.isEmpty else { return true }
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count)
}

/// Coverage-aware sibling of `nativeResolvedMacFont` above (job 445, part 1 of the b27
/// box-corner fix). Tries the SAME `[primary, falt]` candidate order that function already
/// tries, but its stop condition is stricter: a candidate is accepted only once it both
/// CONSTRUCTS and COVERS (`fontCoversAllCharacters`) every character actually being set —
/// `nativeResolvedMacFont` stops at construction alone, which is how it silently keeps
/// `Courier Prime` for a box-drawing run neither `Courier Prime` nor its own bundled name
/// contains a glyph for, letting AppKit's own missing-glyph substitution pick an unmanaged
/// fallback (Menlo on this machine) instead. When NO candidate covers `text`, falls back to
/// the first candidate that at least constructed — same "never return nil when the old code
/// would have shown something" guarantee `nativeResolvedMacFont` itself keeps.
///
/// NOT YET WIRED into any render path — `resolvedFont`/`graphicCells` still call
/// `nativeResolvedMacFont`. Wiring this in (and the per-glyph run-boundary tracking that
/// needs, per job 442's own recommended-fix section) is part 2, a separate job.
public func nativeCoverageAwareResolvedMacFont(
    _ entry: FontChange, size: CGFloat, bold: Bool, italic: Bool, useCourierPrime: Bool = false,
    coveringCharactersIn text: String
) -> NSFont? {
    let (primary, falt) = nativeMacFontName(entry, useCourierPrime: useCourierPrime)
    #if os(iOS)
    if primary == "Arial Narrow" { return iosHelveticaNarrow(size: size, bold: bold, italic: italic) }
    #endif
    var firstConstructed: NSFont?
    for name in [primary, falt].compactMap({ $0 }) {
        guard let base = NSFont(name: name, size: size) else { continue }
        if firstConstructed == nil { firstConstructed = base }
        if fontCoversAllCharacters(base, in: text) {
            return nativeApplyTraits(base, bold: bold, italic: italic)
        }
    }
    return firstConstructed.map { nativeApplyTraits($0, bold: bold, italic: italic) }
}

/// Job 210 (b11 leg 3): port of `colourGrayLJ6DTP` (`CtrlKD/PDFDriverLJ6DTP.swift:15-19`,
/// `internal` — same "parallel port, not a call" discipline as `nativeFontFamily` above).
/// LJ6DTP's colour palette as grayscale (0 black, 1 white). Applied ONLY when the document
/// declares driver LJ6DTP (`Document.printerDriver`, `public`); every other document's
/// `span.colour` is ignored, matching the engine's own `doc.printerDriver == "LJ6DTP" ?
/// colourGrayLJ6DTP : [:]` gate (`PDFWriter.swift:708`). Index 15 (`1.0`, white) is the
/// KNOCKOUT — white text set to overprint a black-filled vector bar (`PDFWriter.swift:484`'s
/// own comment: "white (15) text overprinted onto a black bar punches out of it exactly as
/// the LaserJet printed it").
let nativeLJ6DTPColourGray: [Int: Double] = [
    1: 0.15, 2: 0.25, 3: 0.50, 4: 0.75, 5: 0.85, 6: 0.95, 7: 0.98,
    15: 1.0,
]

/// job-489 (C1 — "Pattern fills are FLATTENED TO GREY"): indices 9-14 (HP1-HP6) are NOT flat
/// grays at all — they're six visually distinct tiling patterns (horizontal, vertical, two
/// diagonals, crosshatch, dense X), `LJ6DTPPattern`'s own doc comment
/// (`NativeVectorGraphics.swift`), port of the engine's `lj6dtpHPPatterns`
/// (`PDFDriverLJ6DTP.swift:43-50`). Collapsing them into `nativeLJ6DTPColourGray`'s single
/// mid-gray (as this app did before this job) made page 5's whole point — six textures
/// distinguishable from each other — read as one swatch repeated six times. Kept as its own
/// set (rather than folded into `nativeLJ6DTPColourGray`) because a pattern needs a
/// DIFFERENT resolution path than a flat gray: `driverColour` returns a real tiled
/// `NSColor(patternImage:)` for these, never a `colourMap` lookup.
public let lj6dtpHPPatternIndices: Set<Int> = [9, 10, 11, 12, 13, 14]

/// Job 226: port of `ljSubst`/`ljSubstUnivers` (`CtrlKD/PDFDriverLJ6DTP.swift:26-41`,
/// `private` — same parallel-port discipline as `nativeLJ6DTPColourGray` above, one level
/// deeper: even the ENGINE'S OWN `DocumentRenderer`-facing callers can't see these, they're
/// `private` to that one file). LJ6DTP's driver patches PC-8 slots so typing `_` PRINTS an
/// em dash, `` ` ``/`'` print curly singles, `«»` print curly doubles, and the WordStar-era
/// smiley/sun glyphs the author typed for ©/… print as such — "an em dash is an em dash in
/// any century" (the engine's own ruling 2026-08-06 M7 comment). Gated identically to the
/// engine (`entry.proportional`, `PDFDriverLJ6DTP.swift:49`/`61`) by `nativeLJ6DTPSubstitute`
/// below — fixed-pitch runs (Courier, Letter Gothic, LinePrinter) are never patched, matching
/// the driver's own chart.
// Job 401 (Class 3 diagnosis): widened from `private` to `internal` (no behaviour change)
// so `NativeStructuralParityTests.swift`'s `EngineTruth` — a different file in the same
// module — can reuse this SAME verified port instead of a second copy. Needed because
// `docToPagelines`'s own `PageLine.text` is PRE-substitution: the engine applies
// `ljSubstitute` later, inside `lineOpsPrinted` (`PDFWriter.swift:509`), directly on the
// segments it is about to draw — a step that never writes back into `Page.lines`. So the
// PDF a viewer actually shows (and what this app already matches) carries the substituted
// glyph, but the "engine truth" this test harness read via `docToPagelines` was still the
// raw pre-substitution character — a harness blind spot, not an app defect. See that
// file's own `EngineTruth.structuralPages` for the call site and citation.
public let nativeLJ6DTPCharSubst: [Character: Character] = [
    "\u{263B}": "\u{00A9}",   // ☻ -> ©
    "\u{263C}": "\u{2026}",   // ☼ -> …
    "'": "\u{2019}",          // ' -> '
    "_": "\u{2014}",          // _ -> — (em dash)
    "`": "\u{2018}",          // ` -> '
    "\u{00AB}": "\u{201C}",   // « -> "
    "\u{00BB}": "\u{201D}",   // » -> "
    "\u{2261}": "\u{2013}",   // ≡ -> – (en dash)
]
// Job 495 (Class 7 residual, LJ6DTP.WS page 3): was `\u{250C}`/`\u{2510}`/`\u{2514}`/
// `\u{2518}` (plain sharp-corner ┌┐└┘) — job 226 ported the WRONG engine table. The
// engine has TWO separate Univers-corner tables (`PDFDriverLJ6DTP.swift:78-96`):
// `ljSubstUnivers` (real PDF print-time substitution, `♥♦♣♠ -> ╭╮╰╯`, drawn as a
// stroked quarter-circle join via `arcCorners`/`graphicOps`) and
// `ljSubstUniversSemantic` (a SEPARATE table, that file's own doc comment: "for a
// layout/RTF/HTML consumer... it gets a CHARACTER... the character WordStar's own
// chart names for these slots is the plain box corner" — i.e. explicitly NOT what a
// vector-capable Printed renderer should draw). Job 226 ported the semantic table by
// mistake. Landing on plain ┌┐└┘ additionally happens to collide with `boxArms`
// (`NativeVectorGraphics.swift`) — a SECOND, real box-drawing character set — so
// LJ6DTP.WS's own "You type / Shows on screen as / Prints as" reference table
// (page 3, and the isolated "rounded box corner (Univers only)" demo lines just above
// it) wrongly decomposed into sharp-corner box ARMS instead of showing a rounded-corner
// glyph, an extra 16 vector ops job 494's own Class 7 table carried unexplained
// (confirmed via `PAGE3-ORD`/`PAGE3-ALLLINE` probes this job: every one of the 16 extra
// fills traces to exactly these 4 characters, 2 `boxArms` fills each, at 8 real-fragment
// occurrences). `\u{256D}`-`\u{256F}` (BOX DRAWINGS LIGHT ARC) are not in `boxArms`/
// `symbolShapes`/any of the app's graphicChars sets, so they now draw as ordinary TEXT —
// a real Unicode box-drawing glyph most system fonts carry directly (not the missing-
// glyph '?' case `graphicChars` exists to patch), a closer visual match to the engine's
// own rounded join than a sharp corner, with no vector geometry needed to port.
public let nativeLJ6DTPCharSubstUnivers: [Character: Character] = [
    "\u{2665}": "\u{256D}",   // ♥ -> ╭
    "\u{2666}": "\u{256E}",   // ♦ -> ╮
    "\u{2663}": "\u{2570}",   // ♣ -> ╰
    "\u{2660}": "\u{256F}",   // ♠ -> ╯
]

/// A KERNED PAIR OF SINGLE CURLY QUOTES IS A DOUBLE ONE.
///
/// Two of the driver's substituted slots are only SINGLE quotes (backtick to single open,
/// typed apostrophe to single close), and doubling them is how an LJ6DTP document fakes a
/// proper curly DOUBLE quote that the DeskTop symbol set has no character for — its own
/// prose says so: "we've also added these two pairs to the PDF kerning tables", so the pair
/// prints TUCKED TOGETHER and reads as one glyph, and only while `.kr` is on.
///
/// The engine collapses the pair to the real double quote rather than inventing a sub-glyph
/// kern (`PDFDriverLJ6DTP.swift`'s `collapsingDoubled`, measured against the page's own
/// capture), and this had the per-character half of that substitution and not this half:
/// LJ6DTP.WS page 2 read "``But these quotation marks are just right..." on the app's side
/// against the engine's proper pair. Page 2 is where the document demonstrates the
/// difference on purpose, typing the identical characters once under `.kr off` and once
/// under `.kr on`, so the kerning gate is not optional.
///
/// Left to right and NON-overlapping, matching the engine's own port of Python's
/// `str.replace`: three in a row collapse to one replacement plus one leftover.
func nativeCollapsingDoubled(_ text: String, _ character: Character,
                                      to replacement: Character) -> String {
    let characters = Array(text)
    guard characters.contains(character) else { return text }
    var out = ""
    var index = 0
    while index < characters.count {
        if characters[index] == character, index + 1 < characters.count,
           characters[index + 1] == character {
            out.append(replacement)
            index += 2
        } else {
            out.append(characters[index])
            index += 1
        }
    }
    return out
}

/// LJ6DTP's character substitutions for one proportional run — port of `ljSubstitute`
/// (`PDFDriverLJ6DTP.swift`), the PRINT-path one: `entry` `nil` (no font block) or
/// fixed-pitch is a no-op, matching the engine's own guard, and `kerning` is the line's own
/// `.kr` state (see `nativeCollapsingDoubled` above).
public func nativeLJ6DTPSubstitute(_ text: String, entry: FontChange?, kerning: Bool = true) -> String {
    guard let entry, entry.proportional else { return text }
    var out = String(text.map { nativeLJ6DTPCharSubst[$0] ?? $0 })
    if kerning {
        out = nativeCollapsingDoubled(out, "\u{2018}", to: "\u{201C}")
        out = nativeCollapsingDoubled(out, "\u{2019}", to: "\u{201D}")
    }
    if (entry.typestyleName ?? "").hasPrefix("Univers") {
        out = String(out.map { nativeLJ6DTPCharSubstUnivers[$0] ?? $0 })
    }
    return out
}

/// Job 240 (b13, Part 1): `nativeEscDegrade`/`nativeEscFallback` (job 226's port of
/// `escFallback`, `CtrlKD/PDFWriter.swift:40-47`) REMOVED from this native path — MAC
/// VIEWING RULING (decision register 2026-08-11; skill registry #25). That degradation
/// existed only because `emitPDF` hand-encodes Printed-mode text as a `/WinAnsiEncoding`
/// (cp1252) PDF string literal, which has no slot for •, ‼, or the box-drawing rule
/// characters — a PDF-EXPORT constraint. AppKit's text stack draws real Unicode against a
/// real installed font; every Mac face this renderer now resolves through
/// `nativeMacFontName` carries all six of these glyphs natively, so there is nothing here
/// for a degradation table to guard against. The engine's own `emitPDF`/QL-via-PDF path is
/// untouched — Jon ruled that PDF output looks good as is; this removal is scoped to the
/// native viewer's own text attributes only.
