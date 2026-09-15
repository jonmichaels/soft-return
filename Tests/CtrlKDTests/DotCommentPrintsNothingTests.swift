import Foundation
import Testing
@testable import CtrlKD

/// A WordStar COMMENT puts no ink on paper — and no number standing in for it either
/// (planning #270, triage round 2026-09-14, item 1). sr half of ctrl-kd's
/// `tests/test_dot_comment_prints_nothing.py`.
///
/// `..` is WordStar's non-printing comment LINE: MicroPro's own reference gives it no
/// paper presence at all, and real WS7 agrees — `sawyer/REF/REFORM.DOT` carries three
/// `..` lines and its v4 PRISTINE capture has no mark, no digit and no shift where they
/// sit. The ^ON comment BLOCK is a different construct and is equally silent on paper
/// (ruling 2026-08-06 M9), so both origins are covered by one rule.
///
/// What went wrong before this: the mark survived into the printed LINE and was only
/// dropped at the drawing step. Under `.pf on` the re-wrap had already reduced it to
/// characters and fused the three of them into the word "123", which printed at the head
/// of REFORM.DOT's next line and shifted it +16.50pt — that document's whole pcl-tier
/// residual.
///
/// Fixtures are built with sequential `+=`, never a chained `+` expression (planning
/// #253: the macOS type-checker abandons those).
@Suite struct DotCommentPrintsNothingTests {

    static func ws7Block(_ cmd: UInt8, _ content: [UInt8] = []) -> [UInt8] {
        let count = UInt16(content.count + 4)
        let lo = UInt8(count & 0xFF), hi = UInt8(count >> 8)
        var out: [UInt8] = [0x1D, lo, hi, cmd]
        out += content
        out += [lo, hi, 0x1D]
        return out
    }

    static func build(_ body: [UInt8], dots: [UInt8] = []) -> Document {
        var src = ws7Block(0x00)
        src += dots
        src += body
        return parseWS(src)
    }

    static func printedLines(_ doc: Document) -> [String] {
        docToPagelines(doc, printed: true).flatMap { page in
            page.map { $0.map(\.text).joined() }
        }
    }

    /// Three `..` comment lines, the REFORM.DOT shape.
    static var threeComments: [UInt8] {
        var out = bytes("..one")
        out += HARD
        out += bytes("..two")
        out += HARD
        out += bytes("..three")
        out += HARD
        return out
    }

    /// One ^ON comment BLOCK (symmetric type 6) around its own aside text.
    static var onCommentBody: [UInt8] {
        var out = bytes("Body")
        var payload = [UInt8](repeating: 0, count: 8)
        payload += bytes("aside")
        out += ws7Block(0x06, payload)
        out += bytes(" text")
        out += HARD
        return out
    }

    @Test func aDotCommentLinePrintsNothingAtAll() {
        var body = Self.threeComments
        body += bytes("Since all \"if\" commands")
        body += HARD
        let doc = Self.build(body)
        #expect(doc.notes.filter { $0.kind == .comment }.count == 3)
        #expect(Self.printedLines(doc) == ["Since all \"if\" commands"])
    }

    @Test func thePrintedLineKeepsNoReferenceSpanForAComment() {
        var body = Self.threeComments
        body += bytes("Body")
        body += HARD
        let doc = Self.build(body)
        let kept = pfRewrappedLines(doc, doc.blocks[0])[0].spans
        #expect(kept.map(\.text) == ["Body"])
        #expect(!kept.contains { $0.styles.contains(.fnref) })
    }

    @Test func threeCommentMarksNeverFuseIntoAPrintedWord() {
        // The REFORM.DOT shape: `.pf on` re-wraps the paragraph the marks were deferred
        // onto, and the re-wrap works one character at a time.
        var body = Self.threeComments
        body += bytes("Since all \"if\" commands evaluate")
        body += SOFT
        body += bytes("as true during editing")
        body += HARD
        var dots = bytes(".pf on")
        dots += HARD
        dots += bytes(".rm 6.5\"")
        dots += HARD
        let text = Self.printedLines(Self.build(body, dots: dots)).joined()
        #expect(!text.contains("123"))
        #expect(text.hasPrefix("Since all \"if\" commands"))
    }

    @Test func aCommentMarkCostsTheReWrapNoWidth() {
        // Three marks are three columns WordStar never spent: counted, they would break
        // the paragraph one word earlier.
        var body = bytes("aaaa bbbb cccc dddd eeee ffff gggg hhhh")
        body += SOFT
        body += bytes("iiii")
        body += HARD
        var dots = bytes(".pf on")
        dots += HARD
        dots += bytes(".rm 4.0\"")
        dots += HARD
        var commented = Self.threeComments
        commented += body
        #expect(Self.printedLines(Self.build(commented, dots: dots))
                == Self.printedLines(Self.build(body, dots: dots)))
    }

    @Test func anOnCommentBlockIsEquallySilentOnPaper() {
        let doc = Self.build(Self.onCommentBody)
        #expect(doc.notes.map(\.kind) == [.comment])
        #expect(Self.printedLines(doc) == ["Body text"])
    }

    @Test func aRealNoteReferenceStillPrints() {
        // The rule is about COMMENTS, not about marks — a footnote whose own mark
        // follows a comment's must still resolve to itself, which is exactly what the
        // printed body's number-keyed lookup is for.
        var body = bytes("..aside")
        body += HARD
        body += bytes("Body")
        var payload = [UInt8](repeating: 0, count: 8)
        payload += bytes("the note")
        body += Self.ws7Block(0x03, payload)
        body += bytes(" text")
        body += HARD
        let doc = Self.build(body)
        #expect(doc.notes.map(\.kind) == [.comment, .footnote])
        #expect(Self.printedLines(doc).first == "Body1 text")
    }
}
