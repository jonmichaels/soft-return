import Foundation
import Testing
@testable import CtrlKD

/// planning #264 item 5: the head's OWN print attributes reach the RTF header and footer
/// groups. Port of ctrl-kd dd2f13f.
///
/// THE DEFECT. A `.h#`/`.f#` argument can name a style-sheet entry, and that entry's own
/// bold/italic/underline belongs to every run on the line — exactly the way a body
/// paragraph's `styleAttrs` does. Core has parsed them since planning #255
/// (`Document.headerStyleAttrs`/`footerStyleAttrs`, plus the `_parity` siblings for a
/// two-sided template) and the PDF has drawn them since then; RTF read only the line's
/// INLINE toggle bytes, so a head whose weight came from its style printed light.
///
/// The corpus's galley template is the worked example, and it carries no toggle byte at
/// all — both its `.h1o` and its `.h1e` declare a bold style:
///
///     before  {\headerr \pard\plain \qr\f1\fs24 {TITLE 舦? {\chpgn }}\par}
///     after   {\headerr \pard\plain \qr\f1\fs24 {\b TITLE 舦? {\chpgn }}\par}
///
/// Per LINE and per PARITY, the same "parity wins, plain is the fallback" rule `hfAttr`
/// already applies to the head's face and its alignment.
@Suite struct RTFHeadStyleAttrsTests {
    /// A one-paragraph document with running-head events and, optionally, the style
    /// attributes the head's own style-sheet entry declares.
    static func doc(_ events: [(HFKind, Int, String, HFParity?)],
                    plainAttrs: [Int: Style] = [:],
                    parityAttrs: [Int: [HFParity: Style]] = [:],
                    footerAttrs: [Int: Style] = [:]) -> Document {
        var d = Document()
        d.blocks = [Block(kind: .para, lines: [Line(spans: [Span(text: "body")])])]
        for (kind, line, text, parity) in events {
            d.hfEvents.append(HFEvent(kind: kind, line: line, text: text, blockAnchor: 0))
            d.hfEventsParity.append(parity)
            if kind == .header { d.headers[line] = text } else { d.footers[line] = text }
        }
        d.headerStyleAttrs = plainAttrs
        d.headerStyleAttrsParity = parityAttrs
        d.footerStyleAttrs = footerAttrs
        return d
    }

    @Test(arguments: [EmitMode.printed, .modern])
    func aHeadsOwnBoldReachesTheHeaderGroup(mode: EmitMode) {
        let out = emitRTF(Self.doc([(.header, 1, "TITLE", nil)],
                                   plainAttrs: [1: .bold]), mode: mode)
        #expect(out.contains(#"{\b TITLE}"#))
    }

    @Test func aFooterTakesTheSameTreatment() {
        let out = emitRTF(Self.doc([(.footer, 1, "FOOT", nil)],
                                   footerAttrs: [1: .bold]), mode: .printed)
        #expect(out.contains(#"{\footer "#))
        #expect(out.contains(#"{\b FOOT}"#))
    }

    @Test func theAttributesArePerParity() {
        // A two-sided template can declare a different style on each side, and a parity
        // that names none does not inherit the other side's.
        let out = emitRTF(Self.doc([(.header, 1, "ODD", .odd),
                                    (.header, 1, "EVEN", .even)],
                                   parityAttrs: [1: [.odd: .bold]]), mode: .printed)
        #expect(out.contains(#"{\b ODD}"#))
        #expect(out.contains("{EVEN}"))
    }

    @Test func theAttributesArePerLine() {
        // A two-line head styles each line on its own.
        let out = emitRTF(Self.doc([(.header, 1, "FIRST", nil), (.header, 2, "SECOND", nil)],
                                   plainAttrs: [2: .bold]), mode: .printed)
        #expect(out.contains("{FIRST}"))
        #expect(out.contains(#"{\b SECOND}"#))
    }

    @Test func aStyleAttributeMergesWithAnInlineToggle() {
        // The style's set is unioned into each run's own, so an italic toggle inside a
        // bold-styled head comes out bold-italic -- and the run the toggle does not cover
        // stays merely bold. 0x19 is WordStar's italic toggle (`hfRuns`' own table).
        let text = "PLAIN\u{19}ITAL\u{19}"
        let out = emitRTF(Self.doc([(.header, 1, text, nil)],
                                   plainAttrs: [1: .bold]), mode: .printed)
        #expect(out.contains(#"{\b PLAIN}"#))
        #expect(out.contains(#"{\b \i ITAL}"#) || out.contains(#"{\i \b ITAL}"#))
    }

    @Test func aHeadThatDeclaresNoStyleIsByteIdentical() {
        // The overwhelming majority of documents: absence must add nothing.
        #expect(emitRTF(Self.doc([(.header, 1, "TITLE", nil)]), mode: .printed)
                == emitRTF(Self.doc([(.header, 1, "TITLE", nil)], plainAttrs: [:]),
                           mode: .printed))
    }

    @Test func theAutomaticPageNumberFooterCarriesNoStyle() {
        // WordStar's own stock automatic number is not a declared footer and has no style
        // sheet behind it, so nothing here reaches it.
        let out = emitRTF(Self.doc([(.header, 1, "TITLE", nil)],
                                   plainAttrs: [1: .bold]), mode: .printed)
        #expect(out.contains(#"{\footer \pard\plain \qc\f1\fs24 {\chpgn }\par}"#))
    }
}
