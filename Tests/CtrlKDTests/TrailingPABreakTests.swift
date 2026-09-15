import Foundation
import Testing
@testable import CtrlKD

/// planning #264 item 4 (packet row A10, the remainder): no trailing break that the
/// document never earned, in HTML, text and Markdown either. Port of ctrl-kd da2fd21.
///
/// Item 2 gave RTF the rule real WS7 follows — a `.pa` that is the document's own last
/// block only opens a page when at least one more real line of content was typed after it
/// before EOF (planning #228, eleven harness probes) — and left the other three emitters
/// marking a break the document never earned, each as the LAST thing in the file,
/// separating the document from nothing: HTML a page rule, printed text a form feed
/// (Modern text, a row of dashes), Markdown a `---`. Same already-parsed fact
/// (`Document.paEofBlankAfter`), read once, in `trailingPASkipIndex`
/// (EmitterRules.swift); `emitRTF` calls it too, in place of the inline copy item 2 left
/// behind. RTF's own half stays pinned in `RTFPagedSurfaceTests`.
///
/// TWO THINGS STATED OUT LOUD, because the round's brief named "HTML … and printed text":
/// MARKDOWN IS INCLUDED (its Modern `---` and its printed facsimile's form feed are the
/// same marker for the same non-event), and MODERN IS INCLUDED, on item 2's own precedent
/// — RTF suppressed the trailing break in both modes.
@Suite struct TrailingPABreakTests {
    static func doc(paEofBlankAfter: Bool, trailingBreak: Bool = true) -> Document {
        var d = Document()
        d.blocks = [Block(kind: .para, lines: [Line(spans: [Span(text: "body")])])]
        if trailingBreak { d.blocks.append(Block(kind: .pagebreak)) }
        d.paEofBlankAfter = paEofBlankAfter
        return d
    }

    @Test(arguments: [EmitMode.printed, .modern])
    func htmlDrawsNoTrailingRuleForABareTrailingPa(mode: EmitMode) {
        #expect(!emitHTML(Self.doc(paEofBlankAfter: false), mode: mode)
            .contains("<hr class=\"pb\">"))
    }

    @Test(arguments: [EmitMode.printed, .modern])
    func htmlKeepsTheRuleWhenTheDocumentEarnedThePage(mode: EmitMode) {
        #expect(emitHTML(Self.doc(paEofBlankAfter: true), mode: mode)
            .contains("<hr class=\"pb\">"))
    }

    @Test func printedTextEmitsNoTrailingFormFeed() {
        #expect(!emitText(Self.doc(paEofBlankAfter: false), mode: .printed).contains("\u{0C}"))
        #expect(emitText(Self.doc(paEofBlankAfter: true), mode: .printed).contains("\u{0C}"))
    }

    @Test func modernTextEmitsNoTrailingDashedSeparator() {
        // Modern's marker is decorative rather than a page, but it is the same fact
        // deciding it -- and a separator to nothing is no better than a blank page.
        let dashes = String(repeating: "-", count: 20)
        #expect(!emitText(Self.doc(paEofBlankAfter: false), mode: .modern).contains(dashes))
        #expect(emitText(Self.doc(paEofBlankAfter: true), mode: .modern).contains(dashes))
    }

    @Test func modernMarkdownEmitsNoTrailingRule() {
        let off = emitMarkdown(Self.doc(paEofBlankAfter: false), mode: .modern)
        #expect(!off.trimmed().hasSuffix("---"))
        #expect(emitMarkdown(Self.doc(paEofBlankAfter: true), mode: .modern)
            .trimmed().hasSuffix("---"))
    }

    @Test func printedMarkdownEmitsNoTrailingFormFeed() {
        // Printed Markdown is a fenced facsimile built from the text renderer's own
        // lines, so its marker is the form feed, not a `---`.
        #expect(!emitMarkdown(Self.doc(paEofBlankAfter: false), mode: .printed)
            .contains("\u{0C}"))
        #expect(emitMarkdown(Self.doc(paEofBlankAfter: true), mode: .printed)
            .contains("\u{0C}"))
    }

    @Test(arguments: [EmitMode.printed, .modern])
    func aMidDocumentPaIsUntouchedInEveryEmitter(mode: EmitMode) {
        // Only the DOCUMENT'S OWN LAST block is ever in question.
        var d = Self.doc(paEofBlankAfter: false, trailingBreak: false)
        d.blocks.append(Block(kind: .pagebreak))
        d.blocks.append(Block(kind: .para, lines: [Line(spans: [Span(text: "after")])]))
        #expect(emitHTML(d, mode: mode).contains("<hr class=\"pb\">"))
        #expect(emitRTF(d, mode: mode).contains(#"\page"#))
        if mode == .printed {
            #expect(emitText(d, mode: mode).contains("\u{0C}"))
            #expect(emitMarkdown(d, mode: mode).contains("\u{0C}"))
        } else {
            #expect(emitText(d, mode: mode).contains(String(repeating: "-", count: 20)))
            #expect(emitMarkdown(d, mode: mode).contains("---"))
        }
    }

    @Test(arguments: [EmitMode.printed, .modern])
    func aDocumentThatNeverEndsInPaIsUnchanged(mode: EmitMode) {
        // `paEofBlankAfter` is only meaningful when the last block IS a pagebreak, and
        // absence must not start suppressing anything.
        let d = Self.doc(paEofBlankAfter: false, trailingBreak: false)
        #expect(trailingPASkipIndex(d) == nil)
        #expect(!emitHTML(d, mode: mode).contains("<hr class=\"pb\">"))
        #expect(!emitRTF(d, mode: mode).contains(#"\page"#))
    }
}
