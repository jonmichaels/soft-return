import Testing
@testable import CtrlKD

/// b24 engine wave, round 21 item 5 — the shared font resolution, the round's own
/// architectural deliverable. `resolveFont`/`ResolvedFont` (FontMap.swift) factor the
/// "what family does this span actually resolve to" decision into ONE public,
/// target-agnostic function so a consumer that is neither PDF, RTF, nor HTML — the
/// app's own view layer, wave 4 — can ask the same question without re-deriving it or
/// reaching into an emitter-internal helper.

@Test func resolveFontPassesThroughTheEraNameFirst() throws {
    let resolved = resolveFont(family: "Helv", generic: .sans, proportional: true)
    #expect(resolved.primary == "Helv")
    #expect(resolved.alternates == ["Helvetica", "Arial"])
    #expect(!resolved.isMonospace)
    #expect(resolved.generic == .sans)
}

@Test func resolveFontUnmappedNameFallsThroughToGenericAlone() throws {
    let resolved = resolveFont(family: "Some Never-Seen Face", generic: .serif, proportional: true)
    #expect(resolved.primary == "Some Never-Seen Face")
    #expect(resolved.alternates.isEmpty)
    #expect(!resolved.isMonospace)
    #expect(resolved.generic == .serif)
}

@Test func resolveFontEmptyFamilyHasNoPrimary() throws {
    let resolved = resolveFont(family: "", generic: .display, proportional: true)
    #expect(resolved.primary == nil)
    #expect(resolved.alternates.isEmpty)
    #expect(resolved.generic == .display)
}

@Test func resolveFontProportionalFalseIsDecisiveButKeepsTheNameAndAlternatesAsGarnish() throws {
    // round 9's own "tier-1 evidence" ruling: proportional=false is NEVER overridden
    // by a name/generic match -- but the family name and its own alternates still
    // ride along as harmless first-choice garnish before the monospace terminus
    // (matching fontStack's own pre-existing "Courier, Courier New, monospace" shape).
    let resolved = resolveFont(family: "Courier", generic: .sans, proportional: false)
    #expect(resolved.primary == "Courier")
    #expect(resolved.alternates == ["Courier New"])
    #expect(resolved.isMonospace)
}

// FIX (planning #199, Test-Truth-Audit-2026-09-05 section 2(i)):
// `resolveFontFromFontChangeConvenienceOverloadMatchesTheManualCall` (formerly here) was
// deleted -- `resolveFont(_ font: FontChange)` is a literal one-line forward
// (`resolveFont(family: font.family, generic: font.genericStyle, proportional:
// font.proportional)`, FontMap.swift), and the test recomputed that exact same call as its
// "expected" value: guaranteed equal by construction, and it could not have caught a
// transcription bug either, since `family: String`, `generic: GenericStyle` and
// `proportional: Bool` are three DIFFERENT types at those three positions -- an
// argument-order swap fails to compile before this test would ever run. It tested nothing
// the type checker doesn't already guarantee.

@Test func fontStackIsAThinWrapperOverResolveFont() throws {
    // The extraction (b24 round 21 item 5) must not change fontStack's own output.
    //
    // FIX (planning #199, Test-Truth-Audit-2026-09-05 section 2(i)): the original version's
    // "expected" was reconstructed by calling `resolveFont` a SECOND time and re-running
    // `fontStack`'s own assembly logic over its answer -- since `fontStack` itself just
    // calls `resolveFont` once and assembles, calling it again with identical arguments
    // reproduces the identical `ResolvedFont` by construction; only the assembly order
    // was genuinely being checked. Independent literals instead, hand-derived from
    // `fontAlternates`'s own table entries (FontMap.swift, cited per case below) and the
    // documented assembly rule (primary, then alternates, then "monospace" if
    // `proportional == false` else the CSS generic) -- no call to `resolveFont` anywhere
    // in this test now.
    let cases: [(family: String, generic: GenericStyle?, proportional: Bool?, expected: [String])] = [
        // fontAlternates["helv"] = ["Helvetica", "Arial"]; proportional true -> not
        // monospace -> generic .sans -> "sans-serif".
        ("Helv", .sans, true, ["Helv", "Helvetica", "Arial", "sans-serif"]),
        // fontAlternates["courier"] = ["Courier New"]; proportional FALSE -> monospace
        // terminus regardless of generic.
        ("Courier", .sans, false, ["Courier", "Courier New", "monospace"]),
        // Empty family -> no primary, no alternates entry; generic .display -> "fantasy".
        ("", .display, true, ["fantasy"]),
        // fontAlternates["univ. roman"] = ["University Roman", "Georgia"]; proportional
        // nil (not `== false`) -> not monospace -> generic .serif -> "serif".
        ("Univ. Roman", .serif, nil, ["Univ. Roman", "University Roman", "Georgia", "serif"]),
        // fontAlternates["zapf chancery"] = ["Apple Chancery", "Monotype Corsiva"];
        // generic .script -> "cursive".
        ("Zapf Chancery", .script, true,
         ["Zapf Chancery", "Apple Chancery", "Monotype Corsiva", "cursive"]),
        // Not in fontAlternates at all -> no alternates; proportional false -> monospace.
        ("Unmapped Face", .display, false, ["Unmapped Face", "monospace"]),
    ]
    for c in cases {
        #expect(fontStack(c.family, generic: c.generic, proportional: c.proportional) == c.expected,
               "\(c.family)")
    }
}

// MARK: - Albertus / Marigold (port of ctrl-kd's
// test_albertus_and_marigold_resolve_to_glyphic_substitutes_not_generic)

@Test func albertusAndMarigoldResolveToGlyphicSubstitutesNotGeneric() throws {
    // Albertus (Monotype, Berthold Wolpe) and Marigold (Agfa Compugraphic, Arthur
    // Baker) are real WordStar-era HP LaserJet resident faces -- the Sawyer archive's
    // own printer driver files (LASERJET.PDF, LJ6DTP.PDF, HP4.PDF) route WordStar's
    // Aachen/ZapfChancery typestyles to them by name (`Aachen\0Albertus PC ...\0`,
    // `ZapfChancery\0Marigold PC ...\0`), and PREVIEW.WS -- WordStar's own factory
    // demo file -- literally captions its Aachen-typestyle sample "Albertus". Neither
    // name has a typestyle NUMBER of its own in WSFORMAT.TXT's 245-entry catalog
    // (verified against the public spec: zero occurrences), so `typestyleNames` can
    // never produce either string -- but any caller passing the literal family (a
    // document's own declared face, an app font picker, a future producer) must land
    // on a genuinely glyphic/flared or calligraphic substitute, never the target's
    // bare generic primary.
    for target in FontsTarget.allCases {
        // A dedicated targetFonts entry -- not the generic-primary fallback path --
        // is what proves this isn't one incidental office/mac coincidence away from
        // silently matching its own generic (office/mac's script generic already
        // happens to be Monotype Corsiva, the same face zapfchancery's own long-ruled
        // entry chose -- a real answer, not a miss, but not distinguishable from the
        // generic by value alone).
        #expect(targetFonts[target]?["albertus"] != nil)
        #expect(targetFonts[target]?["marigold"] != nil)
        let (aPrimary, aFalt) = rtfFonts("albertus", generic: .serif, target: target, proportional: true)
        #expect(aPrimary != nil)
        #expect(aFalt != aPrimary)
        let (mPrimary, mFalt) = rtfFonts("marigold", generic: .script, target: target, proportional: true)
        #expect(mPrimary != nil)
        #expect(mFalt != mPrimary)
    }
    let albertusStack = fontStack("Albertus", generic: .serif)
    #expect(albertusStack.first == "Albertus")            // pass-through: verbatim name first
    #expect(albertusStack.count > 2 && albertusStack.last == "serif")  // real alternates precede the generic
    let marigoldStack = fontStack("Marigold", generic: .script)
    #expect(marigoldStack.count > 2 && marigoldStack.last == "cursive")
}
