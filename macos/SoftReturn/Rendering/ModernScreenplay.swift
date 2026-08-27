import CtrlKD

/// b27 item 11: the app's own port of ctrl-kd's screenplay-format detection
/// (`detect_screenplay_blocks`/`_SCREENPLAY_SLUGLINE_RE`/`_SCREENPLAY_PAGE_MARKER_RE`/
/// `_SCREENPLAY_TRAILING_SCENE_NUM_RE`, `core.py`; Swift reference `Screenplay.swift`,
/// ctrl-kd c82b2ff, `soft-return` @ 45b9726). A port, not a reuse: these four functions are
/// `internal` to the `CtrlKD` module (not `public`), so `renderModern` cannot call them
/// directly — the same architectural split job 434's title-clipping fix already
/// established ("port the RULE, keep it separable from font metrics, do not try to consume
/// engine geometry"). `SemanticItem.para`'s `bi` field (added for exactly this: "lets a
/// consumer re-check content-based whole-document detectors... without re-deriving block
/// boundaries itself") is what makes the port possible without walking `doc.blocks` a
/// second time under a different contract.
///
/// THE RULE, as ctrl-kd's `PDFModernLayout.swift`/`modernFlow` implements it (Native and
/// Printed already pass it via ordinary fixed-pitch/overprint fidelity — see
/// `DocumentRenderer.renderModern`'s own citation on why Modern needs a dedicated port):
/// inside a screenplay-detected region only —
///   (a) a page-number marker (a line that is nothing but whitespace and a bare 1-4 digit
///       number, optional trailing period — SCRIPT.WS's own "1.") starts a new page.
///       Modern has no page-break decision at render time (AppKit's own later layout owns
///       that), so this app has nothing to port for (a) — noted, not silently dropped.
///   (b) that SAME page-number-marker line renders flush against the right margin, not
///       left-aligned.
///   (c) a screenplay slugline carrying its own right-hand scene number (real screenplay
///       convention: the number repeats at both margins) must never wrap that number onto
///       its own line.
enum ModernScreenplay {
    /// Port of `matchesScreenplaySlugline` (`Screenplay.swift`) — WordStar gives no dot
    /// command for a slugline; the convention is ALL CAPS at a line's own start, an
    /// optional 1-4-digit scene number, an optional WordStar merge-var scene marker, then
    /// one of INT./EXT./INT./EXT./INT/EXT./I/E. followed by a space or tab. Case-sensitive
    /// by design — a lowercase "int." in ordinary prose must never match.
    static func matchesSlugline(_ text: String) -> Bool {
        let chars = Array(text)
        let n = chars.count
        func isSpaceTab(_ c: Character) -> Bool { c == " " || c == "\t" }
        var i = 0
        while i < n, isSpaceTab(chars[i]) { i += 1 }
        var digits = 0
        while i < n, digits < 4, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
        while i < n, isSpaceTab(chars[i]) { i += 1 }
        var afterPrefix = i
        if i < n, chars[i] == "&" {
            var j = i + 1
            var count = 0
            while j < n, count < 24, chars[j] != "&", chars[j] != "\r", chars[j] != "\n" {
                j += 1
                count += 1
            }
            if count >= 1, j < n, chars[j] == "&" {
                var k = j + 1
                while k < n, isSpaceTab(chars[k]) { k += 1 }
                afterPrefix = k
            }
        }
        func tryLiteral(_ lit: [Character]) -> Bool {
            guard afterPrefix + lit.count < n else { return false }
            for (k, c) in lit.enumerated() where chars[afterPrefix + k] != c { return false }
            return isSpaceTab(chars[afterPrefix + lit.count])
        }
        for lit in [Array("INT."), Array("EXT."), Array("INT./EXT."), Array("INT/EXT."), Array("I/E.")] {
            if tryLiteral(lit) { return true }
        }
        return false
    }

    /// Port of `matchesScreenplayPageMarker` — a bare 1-4 digit number (optional trailing
    /// period), full-string match against the WHOLE visible line so a slugline's own
    /// leading scene number ("1     INT. ...") never qualifies (letters follow the digits
    /// on that line).
    static func matchesPageMarker(_ text: String) -> Bool {
        let chars = Array(text)
        let n = chars.count
        func isSpaceTab(_ c: Character) -> Bool { c == " " || c == "\t" }
        var i = 0
        while i < n, isSpaceTab(chars[i]) { i += 1 }
        var digits = 0
        while i < n, digits < 4, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
        guard digits >= 1 else { return false }
        if i < n, chars[i] == "." { i += 1 }
        while i < n, isSpaceTab(chars[i]) { i += 1 }
        return i == n
    }

    /// Port of `matchesScreenplayTrailingSceneNumber` — true iff the line's trailing
    /// (post-whitespace-trim) content is a 1-4 digit run immediately preceded by a literal
    /// space or tab. Real screenplay convention: the scene number repeats at the right
    /// margin of its own slugline.
    static func matchesTrailingSceneNumber(_ text: String) -> Bool {
        let chars = Array(text)
        var end = chars.count
        while end > 0, chars[end - 1] == " " || chars[end - 1] == "\t" { end -= 1 }
        var start = end
        while start > 0, chars[start - 1].isASCII, chars[start - 1].isNumber { start -= 1 }
        let digitCount = end - start
        guard digitCount >= 1, digitCount <= 4, start > 0 else { return false }
        let prev = chars[start - 1]
        return prev == " " || prev == "\t"
    }

    private static func blockHasSlugline(_ block: Block) -> Bool {
        for line in block.lines {
            let text = line.spans.map(\.text).joined()
            if matchesSlugline(text) { return true }
        }
        return false
    }

    /// Port of `detectScreenplayBlocks` — anchors on a genuine slugline, then grows the
    /// region forward (ladder/action lines) until the next slugline, a heading, or
    /// `maxRegionBlocks`, whichever comes first. Corpus-swept (ctrl-kd, 2026-08-18, the
    /// full 86-file Sawyer WS7 tree) to match exactly one real document, SCRIPT.WS.
    static func detectBlocks(_ doc: Document) -> Set<Int> {
        let maxRegionBlocks = 40
        var sluglineBi: Set<Int> = []
        for (bi, block) in doc.blocks.enumerated() where block.kind == .para && blockHasSlugline(block) {
            sluglineBi.insert(bi)
        }
        guard !sluglineBi.isEmpty else { return [] }
        var region: Set<Int> = []
        let n = doc.blocks.count
        for start in sluglineBi {
            region.insert(start)
            let end = min(n, start + 1 + maxRegionBlocks)
            guard start + 1 < end else { continue }
            for bi in (start + 1)..<end {
                let b = doc.blocks[bi]
                if b.kind != .para || b.heading != 0 || sluglineBi.contains(bi) { break }
                region.insert(bi)
            }
        }
        return region
    }

    /// Port of `PDFModernLayout.swift`'s `screenplayMarkerBis`: a page-number marker sits
    /// BEFORE its scene's slugline, but `detectBlocks`'s region only grows forward from its
    /// slugline anchor — so the marker's own block index is never IN `screenplayBlocks`.
    /// Widen candidacy one or two blocks forward (covering an intervening blank-only block)
    /// instead of touching the shared detector's own region-growth rule.
    static func markerCandidateBlocks(_ screenplayBlocks: Set<Int>, blockCount: Int) -> Set<Int> {
        guard !screenplayBlocks.isEmpty else { return [] }
        return Set((0..<blockCount).filter {
            screenplayBlocks.contains($0 + 1) || screenplayBlocks.contains($0 + 2)
        })
    }

    /// Rule (c)'s render-side half: collapse the baked WordStar overprint padding between a
    /// slugline's real content and its own right-hand scene number to a single tab
    /// character, so AppKit's word-wrap has nothing left to break inside — the padding was
    /// sized for WordStar's fixed-pitch column grid, and at Modern's real (wider,
    /// proportional-font) measure the literal run of spaces alone is what pushes the line
    /// past the container and wraps the number onto its own left-anchored line. The caller
    /// pairs this with a paragraph-level right tab stop at the line's own measure so the
    /// number still lands flush against the margin regardless of its own width. Falls back
    /// to the spans unchanged if the trailing-number boundary can't be located inside them
    /// (never crashes, never corrupts content — the caller's own regression, not a user-
    /// visible one, if this ever happens on real content).
    static func collapseSceneNumberGap(_ spans: [Span]) -> [Span] {
        let joined = spans.map(\.text).joined()
        let chars = Array(joined)
        var end = chars.count
        while end > 0, chars[end - 1] == " " || chars[end - 1] == "\t" { end -= 1 }
        var numStart = end
        while numStart > 0, chars[numStart - 1].isASCII, chars[numStart - 1].isNumber { numStart -= 1 }
        guard end - numStart >= 1, end - numStart <= 4, numStart > 0,
              chars[numStart - 1] == " " || chars[numStart - 1] == "\t" else { return spans }
        var gapStart = numStart
        while gapStart > 0, chars[gapStart - 1] == " " || chars[gapStart - 1] == "\t" { gapStart -= 1 }
        guard gapStart > 0 else { return spans }

        var out: [Span] = []
        var offset = 0
        var tabInserted = false
        for span in spans {
            let text = Array(span.text)
            let spanStart = offset
            let spanEnd = offset + text.count
            offset = spanEnd
            if spanEnd <= gapStart {
                out.append(span)
                continue
            }
            if spanStart >= numStart {
                out.append(span)
                continue
            }
            let localGapStart = max(0, min(text.count, gapStart - spanStart))
            let localNumStart = max(0, min(text.count, numStart - spanStart))
            if localGapStart > 0 {
                var kept = span
                kept.text = String(text[0..<localGapStart])
                out.append(kept)
            }
            if !tabInserted {
                out.append(Span(text: "\t", styles: span.styles, font: span.font, colour: span.colour))
                tabInserted = true
            }
            if localNumStart < text.count {
                var tail = span
                tail.text = String(text[localNumStart...])
                out.append(tail)
            }
        }
        return out
    }
}
