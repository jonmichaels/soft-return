import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// b24 completion, C5 (VIEW HALF): Modern Show Invisibles draws a mark at a comment's
/// zero-width anchor run (`SemanticRun.ref != nil`, `text == ""` — `Layout.swift`'s own
/// round-22 run contract) at its true inline position, same styling family as every other
/// invisible-ink class this view already marks (`DocumentRenderer.renderModernAnnotated`).
/// Comments stay opt-in (`EmitOptions.defaultNotes` excludes `.comment`) — there is no
/// on-screen "show comments" control yet (a disclosed gap, not this job's own scope: C5 is
/// drawing the mark once a comment IS in the flow, not adding the toggle that puts one
/// there), so this test drives `renderModernAnnotated(_:notes:)` directly — the same
/// testability seam `attributedLine`'s own doc comment already established.
@Suite struct CommentAnchorInViewsTests {

    // MARK: - Fixture (mirrors `Tests/CtrlKDTests/Fixtures.swift`'s `ws7Block`/`ws7Note`,
    // and `LayoutMarksTests.commentDoc()`, byte-for-byte, in the engine repo)

    private static func ws7Block(_ cmd: UInt8, payload: [UInt8] = []) -> [UInt8] {
        let count = UInt16(payload.count + 4)
        let countBytes: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
        var out: [UInt8] = [0x1d]
        out.append(contentsOf: countBytes)
        out.append(cmd)
        out.append(contentsOf: payload)
        out.append(contentsOf: countBytes)
        out.append(0x1d)
        return out
    }

    /// One footnote/endnote/annotation/comment note block (types 3-6): line count, note
    /// number, conversion flag, then note text — numberFormat 3 / convertTo 0, matching the
    /// engine fixture helper's own defaults.
    private static func ws7Note(_ text: [UInt8], cmd: UInt8, number: Int) -> [UInt8] {
        let convFlag: UInt8 = 0x30
        var content: [UInt8] = [
            1, 0,
            UInt8(number & 0xFF), UInt8((number >> 8) & 0xFF),
            convFlag,
        ]
        content.append(contentsOf: text)
        return ws7Block(cmd, payload: content)
    }

    /// "Alpha " + a margin comment + "beta gamma." — the round-18 export fixture shape
    /// (`LayoutMarksTests.commentDoc`, engine repo), so this render can be checked against
    /// the SAME anchor position the engine's own tests already pin (between "Alpha" and
    /// "beta").
    private static func commentFixtureBytes() -> [UInt8] {
        var out = ws7Block(0x00)
        out.append(contentsOf: Array("Alpha ".utf8))
        out.append(contentsOf: ws7Note(Array("A margin comment.".utf8), cmd: 0x06, number: 0))
        out.append(contentsOf: Array("beta gamma.\r\n".utf8))
        return out
    }

    @MainActor
    private static func state() throws -> DocumentState {
        let defaults = UserDefaults(suiteName: "CommentAnchorInViewsTests.\(UUID().uuidString)")!
        let st = try DocumentState(data: commentFixtureBytes(), settings: SettingsStore(defaults: defaults))
        st.style.setManually(.modern)
        return st
    }

    /// Hosts `rendered` in a real `PagedDocumentView` inside an offscreen window and forces
    /// layout — real AppKit rendering (`RenderProbeKit.renderPNG`'s own doc comment: "not a
    /// synthetic draw"), minus the full `DocumentWindowController` chain, which has no way
    /// to ask for `.comment` notes yet.
    @MainActor
    private static func host(_ rendered: RenderedDocument) -> (window: NSWindow, pageView: PagedDocumentView) {
        let pageView = PagedDocumentView(frame: NSRect(origin: .zero, size: rendered.pageSize))
        pageView.setContent(rendered, display: .singlePage)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: rendered.pageSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pageView
        window.setContentSize(rendered.pageSize)
        window.appearance = NSAppearance(named: .aqua)
        pageView.layoutSubtreeIfNeeded()
        return (window, pageView)
    }

    private enum ProbeError: Error {
        case noPageView
        case markNotFound
        case noBitmap
    }

    /// Non-white ink anywhere inside `rect` (page-text-view point coordinates), scanned the
    /// same way `RenderProbeKit.inkMargins` does (Retina-safe pixel<->point scale, flipped
    /// view so bitmap row 0 is the view's own top).
    private static func hasInk(in bitmap: NSBitmapImageRep, rect: NSRect, viewSize: CGSize,
                               tolerance: CGFloat = 0.06) -> Bool {
        guard viewSize.width > 0, viewSize.height > 0, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0
        else { return false }
        let scaleX = CGFloat(bitmap.pixelsWide) / viewSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / viewSize.height
        let x0 = max(0, Int(rect.minX * scaleX))
        let x1 = min(bitmap.pixelsWide - 1, Int(rect.maxX * scaleX))
        let y0 = max(0, Int(rect.minY * scaleY))
        let y1 = min(bitmap.pixelsHigh - 1, Int(rect.maxY * scaleY))
        guard x0 <= x1, y0 <= y1 else { return false }
        for y in y0...y1 {
            for x in x0...x1 {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(c.redComponent - 1) > tolerance || abs(c.greenComponent - 1) > tolerance
                    || abs(c.blueComponent - 1) > tolerance {
                    return true
                }
            }
        }
        return false
    }

    /// The comment mark's own on-page rect, in the FIRST page view's coordinate space —
    /// `boundingRect(forGlyphRange:in:)` plus `textContainerOrigin` (`NSTextView`'s own
    /// container-to-view offset), the standard AppKit conversion.
    @MainActor
    private static func markRect(in pageView: PagedDocumentView) throws -> (rect: NSRect, view: NSTextView) {
        guard let textView = pageView.pageViews.first, let container = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { throw ProbeError.noPageView }
        let whole = textView.string as NSString
        let markRange = whole.range(of: "[comment]")
        guard markRange.location != NSNotFound else { throw ProbeError.markNotFound }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: markRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return (rect, textView)
    }

    /// The mark renders — real ink — at its true inline position, when comments are opted
    /// in for the flow (`notes: [.comment]`) and Show Invisibles is on
    /// (`renderModernAnnotated` is the invisibles-on render path by construction).
    @Test @MainActor func commentAnchorMarkRendersInkAtInlinePosition() throws {
        let st = try Self.state()
        let rendered = DocumentRenderer.renderModernAnnotated(st, notes: [.comment])
        #expect(rendered.text.string.contains("[comment]"),
                "the comment anchor's mark text is missing from the rendered Modern flow")
        // Sanity: the mark sits strictly between the two words its anchor separates.
        let s = rendered.text.string as NSString
        let alphaAt = s.range(of: "Alpha").location
        let markAt = s.range(of: "[comment]").location
        let betaAt = s.range(of: "beta").location
        #expect(alphaAt != NSNotFound && markAt != NSNotFound && betaAt != NSNotFound)
        #expect(alphaAt < markAt && markAt < betaAt,
                "the comment mark must sit between the words its anchor separates")

        let (window, pageView) = Self.host(rendered)
        _ = window
        let (rect, textView) = try Self.markRect(in: pageView)
        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else {
            throw ProbeError.noBitmap
        }
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            textView.cacheDisplay(in: textView.bounds, to: bitmap)
        }
        #expect(Self.hasInk(in: bitmap, rect: rect, viewSize: textView.bounds.size),
                "no ink rendered at the comment anchor's own on-page rect")
    }

    /// Comments stay opt-in: the default flow (no `notes:` override, matching
    /// `renderWithInvisibles(_:)`'s one live call site) carries no anchor and draws no mark
    /// — same fixture, same Show Invisibles pass, only the note-kind set differs.
    @Test @MainActor func commentAnchorMarkAbsentWhenCommentsNotOptedIn() throws {
        let st = try Self.state()
        let rendered = DocumentRenderer.renderModernAnnotated(st)
        #expect(!rendered.text.string.contains("[comment]"),
                "the comment mark rendered even though comments were not opted into the flow")
    }
}
