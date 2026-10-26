#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

extension DocumentRenderer {
    // MARK: - Modern structure rules (M-rules addendum, def-list/bullet/centered)

    /// Character-range slice of styled spans, preserving each span's own attributes —
    /// the app-side port of the engine's internal (module-private) `sliceSpans`
    /// (`CtrlKD/EmitHTML.swift`), needed here because a def-list label/body or a
    /// spaces-centered line's own padding is sliced off the STYLED spans, not the
    /// plain joined text, so a bold/italic/font run inside the kept text survives.
    static func sliceSpans(_ spans: [Span], start: Int, end: Int? = nil) -> [Span] {
        let total = spans.reduce(0) { $0 + $1.text.count }
        let end = end ?? total
        var out: [Span] = []
        var pos = 0
        for sp in spans {
            let chars = Array(sp.text)
            let spStart = pos, spEnd = pos + chars.count
            pos = spEnd
            let lo = max(start, spStart), hi = min(end, spEnd)
            if lo < hi {
                out.append(Span(text: String(chars[(lo - spStart)..<(hi - spStart)]), styles: sp.styles,
                                font: sp.font, colour: sp.colour, pctlHMI: sp.pctlHMI))
            }
        }
        return out
    }

    /// Strips a spaces-centered row's own leading/trailing padding off the styled
    /// spans — port of the engine's `htmlCenteredRow`. A no-op for a real
    /// `align=center` tag row: `modernSemanticFlow` already stripped that padding
    /// upstream (M3), so lead/trail are both 0 there.
    static func centerStrippedSpans(_ spans: [Span]) -> [Span] {
        let raw = Array(spans.map(\.text).joined())
        var lead = 0
        while lead < raw.count, raw[lead] == " " { lead += 1 }
        var trail = 0
        while trail < raw.count, raw[raw.count - 1 - trail] == " " { trail += 1 }
        return sliceSpans(spans, start: lead, end: raw.count - trail)
    }

    /// A bullet row's own real text start — job 329/b21, Jon's field note on VERSIONS.WS's
    /// Sawyer-customizations bullets: "the line wrap doesn't line up with the first line
    /// after the • bullet." `structuredPrefixAndBody`'s marker+gap is always the same two
    /// characters (`"\u{2022} "`), but Modern's body font is PROPORTIONAL — this app's own
    /// font of the user's choice, not the library's fixed-pitch Courier — so those two
    /// characters' real advance width varies by font/size and almost never lands on a
    /// whole number of `colPt`-wide monospace cells. Job 299's original `bulletHangCols:
    /// 2` (a column count, like the def-list hang) assumed it would; it didn't, which is
    /// exactly the misalignment Jon's screenshot caught. Measured via `CTLine`'s real
    /// typographic advance — the same measurement style `inkTop` above already uses for
    /// glyph geometry — rather than a `NSAttributedString.size()` probe (this file's own
    /// job-240-era doc comment on `.size()` flags it as unreliable against real TextKit
    /// layout).
    /// E8 (engine ac9ddd6, Jon 2026-09-17: "Modern's bullets and the gap after them must match Native/Printed"): on a row
    /// the engine classifies as a bullet whose marker is a graphic character drawn on its cell (`■`), the one space after
    /// the marker is one cell wide too — the width the marker's own pin gave it — so the first word starts two cells past
    /// the marker, as in Printed and Native. Any other row, and an ordinary glyph marker (`*`, `-`), is returned as it is.
    @MainActor
    public static func modernBulletGapCell(_ line: NSAttributedString, structure: RowStructure?) -> NSAttributedString {
        guard structure?.kind == .bullet, let marker = structure?.marker, let first = marker.first,
              graphicChars.contains(first) else { return line }
        let text = line.string as NSString
        var at = 0
        while at < text.length, text.character(at: at) == 0x20 { at += 1 }
        let markerLength = (marker as NSString).length
        let spaceAt = at + markerLength
        guard spaceAt + 1 < text.length, text.substring(with: NSRange(location: at, length: markerLength)) == marker,
              text.character(at: spaceAt) == 0x20, text.character(at: spaceAt + 1) != 0x20,
              let markerFont = line.attribute(.font, at: at, effectiveRange: nil) as? NSFont,
              let spaceFont = line.attribute(.font, at: spaceAt, effectiveRange: nil) as? NSFont else { return line }
        let pin = (line.attribute(.kern, at: at, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        let cell = nativeResolvedAdvance(of: marker, in: markerFont) + pin
        let space = nativeResolvedAdvance(of: " ", in: spaceFont)
        guard cell > space else { return line }
        let out = NSMutableAttributedString(attributedString: line)
        out.addAttribute(.kern, value: Float(cell - space), range: NSRange(location: spaceAt, length: 1))
        return out
    }

    static func bulletMarkerWidthPt(
        _ marker: String, font: NSFont, entry: FontChange?, printedPt: Int
    ) -> Double {
        guard !marker.isEmpty else { return 0 }
        // A GRAPHIC MARKER COSTS ITS CELL, because that is what the line will actually
        // advance by: `modernPinGraphicCells` and `nativePinGraphicCells` both pin a graphic
        // character to `spanPitch(entry, printedPt)`, so measuring the marker's own NATURAL
        // glyph advance here put the hang where the glyph would have gone rather than where
        // it goes. Measured on VERSIONS.WS's Sawyer bullets: the wrapped line sat 1.26pt off
        // its own first line's text, which is exactly job 329/b21's field report reopened.
        let cell = nativeSpanPitch(entry, printedPt)
        var total = 0.0
        var plain = ""
        func flushPlain() {
            guard !plain.isEmpty else { return }
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: plain, attributes: [.font: font]))
            total += CTLineGetTypographicBounds(line, nil, nil, nil)
            plain = ""
        }
        let characters = Array(marker)
        for (index, character) in characters.enumerated() {
            if graphicChars.contains(character) {
                flushPlain()
                total += cell
            } else if character == " ", index == characters.count - 1, index > 0, graphicChars.contains(characters[index - 1]) {
                // E8 (engine ac9ddd6): a graphic marker's gap is one cell as well — `modernBulletGapCell`.
                flushPlain()
                total += cell
            } else {
                plain.append(character)
            }
        }
        flushPlain()
        return total
    }

    /// The indent LADDER's one step (job 299, Jon's field report on VERSIONS.WS/
    /// CONVERT.WS): how far EACH nesting level sits past the one above it, in WordStar
    /// print columns (the same `colPt` conversion every other Modern indent uses). Level
    /// 1 (outermost) sits at the 1in margin (`ladderIndentCols` at the call site is 0
    /// there); a level-2 row sits `levelStepCols` past that, and so on — one constant,
    /// so a nested def-list under a bullet (CONVERT.WS's WSASC/WSOLD/ASCWS) always reads
    /// as a clearly deeper level regardless of what raw column the source document
    /// happened to use for either row. 4 columns (~0.4in at the library's default 12cpi)
    /// is comfortably wider than the 1-2 column gap the raw-column bug was producing
    /// (CONVERT.WS's nested rows sat a single column past their parent bullet) while
    /// staying short of `defHangCols`-scale hang indents that would read as a second
    /// column of body text rather than a nesting step.
    static let levelStepCols: Double = 4

    /// The marker/label prefix and the body spans for one classified bullet/def row —
    /// port of `EmitHTML.swift`'s own per-kind slicing (a bullet's body is
    /// `raw.count - bodyLen...`; a def's label is `lead..<lead+labelLen`, its body
    /// `raw.count - bodyLen...`). The marker glyph itself is replaced with a plain
    /// bullet (U+2022) rather than the document's own glyph — Modern is a reading
    /// view, and HTML makes the identical substitution: a real `<li>`'s marker comes
    /// from its own CSS `list-style`, never `RowStructure.marker` (`_render_list_nodes`
    /// never reads it).
    static func structuredPrefixAndBody(
        kind: RowStructureKind, structure: RowStructure, spans: [Span]
    ) -> (prefix: [Span], body: [Span]) {
        let raw = Array(spans.map(\.text).joined())
        switch kind {
        case .bullet:
            let bodyLen = structure.body?.count ?? 0
            let body = sliceSpans(spans, start: raw.count - bodyLen, end: nil)
            // THE ROW'S OWN MARKER, not a substitute. This returned a plain `"\u{2022} "`,
            // reasoning from `EmitHTML` — where a real `<li>`'s marker comes from CSS
            // `list-style` and the document's glyph genuinely has nowhere to go. Modern's
            // PDF is not that: the library's own `modernLineOps` keeps the marker in the
            // row's tokens and draws it, as GEOMETRY when it is one of `graphicChars`
            // (-SCREEN.WS and -README.WS both mark with the cp437 solid square, which the
            // library emits as a filled rectangle). Substituting a bullet put a glyph on the
            // line that the document never had and the library never draws, in a face whose
            // advance is not the marker's, so the row's whole measure moved with it.
            //
            // Sliced, never synthesized: everything from the row's first non-space to where
            // its body begins is the marker and the gap the author actually typed.
            var lead = 0
            while lead < raw.count, raw[lead] == " " { lead += 1 }
            let markerEnd = max(lead, raw.count - bodyLen)
            let marker = sliceSpans(spans, start: lead, end: markerEnd)
            return (marker.isEmpty ? [Span(text: "\u{2022} ")] : marker, body)
        case .def:
            var lead = 0
            while lead < raw.count, raw[lead] == " " { lead += 1 }
            let labelLen = structure.label?.count ?? 0
            let bodyLen = structure.body?.count ?? 0
            let body = sliceSpans(spans, start: raw.count - bodyLen, end: nil)
            // ONE STRUCTURAL SEPARATOR, not the author's own padding. A def row's raw text
            // carries typewriter column padding between label and body (VERSIONS.WS pads to
            // column 15 with eight spaces), and Modern re-sets the row as a HANGING LABEL,
            // where that padding is geometry the new shape has already replaced. Two spaces,
            // whatever the author typed.
            //
            // This carried the typed gap through for a while, on the reading that "the
            // library synthesizes nothing — its `modernFlow` carries the row's tokens
            // through". That was true of the library as it then stood and is not true of it
            // now: planning #263 ported the app's own def-row shape into both engines, and
            // `modernDefRuns` states the rule outright — "the author's own column padding
            // [...] is typewriter geometry, not content [...] replaced by one structural
            // separator", the same slice the HTML export has always made. Measured on
            // VERSIONS.WS with the typed gap kept: its first def row put the body at
            // x=158.73 against the library's 137.70, and the first line of every row in the
            // block then dropped the word the library's line ends with — 20 of the 24 rows
            // this document and -README were still carrying on the Modern gate.
            let labelEnd = max(lead + labelLen, lead)
            let prefix = sliceSpans(spans, start: lead, end: labelEnd)
            return (prefix + [Span(text: "  ")], body)
        }
    }
}
