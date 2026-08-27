import AppKit
import CtrlKD
import PDFKit
import Testing
@testable import SoftReturn

/// Job 298 — the ROOT CAUSE, found by reading PDFKit's own internal view tree rather than a
/// screenshot.
///
/// Diagnostic evidence (OLDTIMES.WS, 1100x800, Fit, before this file's fix): `pdfView.bounds`
/// was 1100x776 and `fitScale` was computed correctly from the page's OWN 612x792 `mediaBox` —
/// job 278's `pageShadowsEnabled = false` fix and its rect-only probe were both right about
/// that. But PDFKit's internal `PDFDocumentView` (what actually gets magnified by
/// `pdfView.scaleFactor`) was laid out at 628x811 — 16pt/19pt LARGER than the page — because
/// `pageBreakMargins` (a separate PDFKit default, independent of `pageShadowsEnabled`) pads a
/// page's layout slot whether or not a shadow is drawn there. Scaling a 811pt-tall document
/// view by `fitScale` (0.9798) produces 794.6pt of content for a 776pt-tall viewport: 18.6pt of
/// real, measured overflow — invisible to a rect probe with 1.0pt tolerance on the PAGE size
/// (which was always correct), and invisible to `dataWithPDF(inside:)` unless it happens to
/// land on the exact live pixel a legacy-style, always-visible `NSScroller` occupies. PDFKit's
/// own scroll view responded to that real overflow with a genuine vertical `NSScroller` —
/// `hidden == false`, `alphaValue == 1.0`, `scrollerStyle == .legacy` (this Mac has no mouse in
/// use, so PDFKit picks the always-visible style, same as `DocumentWindowController`'s own
/// scroller-style comment already notes for `scrollView`) — Jon's field screenshots' grey band
/// and live scrollbar.
///
/// `pdfView.pageBreakMargins = NSEdgeInsetsZero` (in `DocumentWindowController.buildContent()`)
/// makes `PDFDocumentView`'s true size equal the page's `mediaBox`, the same contract the
/// shadow fix already established — verified below by reading PDFKit's OWN internal scroller
/// state directly. This does not need a screenshot: whether a legacy scroller is `isHidden` is
/// ground truth about whether PDFKit itself thinks the content overflows, and it is available
/// synchronously with no Screen Recording permission (see `LivePrintedFramingTests.swift`'s doc
/// comment for why that permission is not available to the hosted test bundle in this session).
@MainActor
private enum ScrollerFramingEvidence {
    static let oldtimesURL = OracleByteParityTests.ws7Directory.appendingPathComponent("OLDTIMES.WS")

    static func controller(width: CGFloat = 1100, height: CGFloat = 800) throws -> DocumentWindowController {
        let state = try Oracle.state(for: oldtimesURL)
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)
        controller.window?.setContentSize(NSSize(width: width, height: height))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    /// Every `NSScroller` inside `view`'s subtree, whether or not it is currently showing one
    /// — a scroller that exists but stays `isHidden` is the "not needed" case.
    static func scrollers(in view: NSView) -> [NSScroller] {
        (view as? NSScroller).map { [$0] } ?? view.subviews.flatMap(scrollers(in:))
    }

    /// `PDFDocumentView`'s own frame size — PDFKit's internal document view PDFKit itself
    /// applies `scaleFactor` to. Equal to the page's `mediaBox` size only when
    /// `pageBreakMargins` is zero.
    static func documentViewSize(in pdfView: PDFView) -> CGSize? {
        func walk(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "PDFDocumentView" { return view }
            for sub in view.subviews {
                if let found = walk(sub) { return found }
            }
            return nil
        }
        return walk(pdfView)?.frame.size
    }
}

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func printedScrollerNotNeededAtFit() throws {
    let controller = try ScrollerFramingEvidence.controller()
    controller.setZoom(.fit)
    controller.setStyle(.printed)
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    let pdfView = controller.pdfView
    let page = try #require(pdfView.document?.page(at: 0))
    let pageSize = page.bounds(for: .mediaBox).size
    let documentViewSize = try #require(ScrollerFramingEvidence.documentViewSize(in: pdfView),
        "could not find PDFKit's internal PDFDocumentView")

    #expect(abs(documentViewSize.width - pageSize.width) < 0.5,
        "PDFDocumentView is \(documentViewSize.width)pt wide for a \(pageSize.width)pt page — pageBreakMargins padding it")
    #expect(abs(documentViewSize.height - pageSize.height) < 0.5,
        "PDFDocumentView is \(documentViewSize.height)pt tall for a \(pageSize.height)pt page — pageBreakMargins padding it")

    let visibleScrollers = ScrollerFramingEvidence.scrollers(in: pdfView).filter { !$0.isHidden && $0.alphaValue > 0 }
    #expect(visibleScrollers.isEmpty,
        "Printed shows \(visibleScrollers.count) live scroller(s) at Fit that Native does not — \(visibleScrollers.map(\.frame))")
}

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func printedScrollerNotNeededAt100Percent() throws {
    let controller = try ScrollerFramingEvidence.controller()
    controller.setZoom(.percent(100))

    // Whatever "100%" (actual size, screen-DPI-dependent — see `ZoomSetting.scale`) makes
    // Native itself need, at the SAME window and zoom — the parity that matters is with
    // Native's own live scroller state, not a derived "should it overflow" guess that can
    // disagree with AppKit's own rounding.
    controller.setStyle(.native)
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    let scrollView = try #require(controller.pagedView.enclosingScrollView)
    let nativeScrollers = ScrollerFramingEvidence.scrollers(in: scrollView).filter { !$0.isHidden && $0.alphaValue > 0 }

    controller.setStyle(.printed)
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    let pdfView = controller.pdfView
    let printedScrollers = ScrollerFramingEvidence.scrollers(in: pdfView).filter { !$0.isHidden && $0.alphaValue > 0 }

    #expect(nativeScrollers.isEmpty == printedScrollers.isEmpty,
        "Native has \(nativeScrollers.count) live scroller(s) at 100%, Printed has \(printedScrollers.count) — not parity")
}

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func printedScrollerNotNeededAfterWindowResize() throws {
    let controller = try ScrollerFramingEvidence.controller(width: 900, height: 700)
    controller.setZoom(.fit)
    controller.setStyle(.printed)
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    controller.window?.setContentSize(NSSize(width: 1200, height: 900))
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    let pdfView = controller.pdfView
    let page = try #require(pdfView.document?.page(at: 0))
    let pageSize = page.bounds(for: .mediaBox).size
    let documentViewSize = try #require(ScrollerFramingEvidence.documentViewSize(in: pdfView))
    #expect(abs(documentViewSize.width - pageSize.width) < 0.5)
    #expect(abs(documentViewSize.height - pageSize.height) < 0.5)

    let visibleScrollers = ScrollerFramingEvidence.scrollers(in: pdfView).filter { !$0.isHidden && $0.alphaValue > 0 }
    #expect(visibleScrollers.isEmpty,
        "Printed shows \(visibleScrollers.count) live scroller(s) after a window resize — \(visibleScrollers.map(\.frame))")
}
