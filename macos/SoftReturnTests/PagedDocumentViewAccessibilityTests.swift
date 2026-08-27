import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// HEADLESS COVERAGE FOR THE ACCESSIBILITY AUDIT'S SIX FINDINGS.
///
/// `AccessibilityAuditUITests` needs a real console to run `performAccessibilityAudit`
/// against (XCUITest) — it cannot run in this (SoftReturnTests) target at all. These tests
/// exercise the same three defect classes the audit reported without XCUITest: they build
/// the real views and check the same properties an audit would (role, label, and — for
/// clipped Printed text — that the accessible string is not itself truncated), entirely
/// off-screen. Job report: three kinds, two findings each.
@MainActor
private func fixtureState(_ name: String = "dropped-chapter.ws4") throws -> DocumentState {
    try Oracle.state(for: Oracle.fixturesDirectory.appendingPathComponent(name))
}

// MARK: - Parent/child mismatch (2 findings)

/// Finding 1: `PagedDocumentView` hosted `.textArea` children with no role of its own — an
/// untyped node between the scroll view's `.scrollArea` and its typed children.
@Test @MainActor func pagedDocumentViewHasAGroupRoleForItsPageChildren() {
    let view = PagedDocumentView()
    #expect(view.accessibilityRole() == .group)
    #expect(view.accessibilityLabel() == "Document pages")
}

/// Finding 2: `BottomBar`'s layout-only `NSStackView` sat between the bar's own `.group`
/// and its popups with no role of its own either. Explicitly removed from the
/// accessibility tree so the popups parent directly to the bar.
@Test @MainActor func bottomBarsLayoutStackIsRemovedFromTheAccessibilityTree() throws {
    let bar = BottomBar()
    #expect(bar.accessibilityRole() == .group)
    let stack = try #require(RenderProbeKit.descendants(bar).compactMap { $0 as? NSStackView }.first,
                             "no NSStackView inside BottomBar")
    #expect(stack.isAccessibilityElement() == false)
}

// MARK: - Label not human-readable (2 findings)

/// Finding 1: every page view carried `.textArea` with no label, so several simultaneous
/// pages (Continuous Scroll) were indistinguishable to VoiceOver.
@Test @MainActor func pageViewsCarryHumanReadablePageLabels() throws {
    let state = try fixtureState()
    let (rendered, view, _) = Oracle.layOut(state)
    view.setContent(rendered, display: .continuousScroll)
    #expect(!view.pageViews.isEmpty, "no pages laid out — nothing to label")
    let total = view.pageViews.count
    for (index, page) in view.pageViews.enumerated() {
        #expect(page.accessibilityLabel() == "Page \(index + 1) of \(total)",
                "page \(index) has label \(page.accessibilityLabel() ?? "nil")")
    }
}

/// Finding 2: `document-scroll-view` carried an accessibility IDENTIFIER — a programmatic
/// handle — with no LABEL standing in for it, which is what a human ever hears.
@Test @MainActor func documentScrollViewHasAHumanReadableLabel() throws {
    let state = try fixtureState()
    let controller = DocumentWindowController(state: state)
    controller.showWindow(nil)
    let content = try #require(controller.window?.contentView)
    let scrollView = try #require(
        RenderProbeKit.descendants(content).compactMap { $0 as? NSScrollView }.first)
    #expect(scrollView.accessibilityIdentifier() == "document-scroll-view")
    let label = scrollView.accessibilityLabel()
    #expect(label != nil && !label!.isEmpty, "no accessibility label")
    #expect(label != scrollView.accessibilityIdentifier(),
            "the label is just the identifier — not human-readable")
}

// MARK: - Potentially inaccessible text (2 findings)

/// Printed style clips lines wider than the column (`.byClipping` — see
/// `DocumentRenderer.renderPrinted`, required so a wrapped line never shifts pagination off
/// the library's own page breaks). The audit is right to ask whether that also hides text
/// from assistive technology. It does not: a text view's accessible value is its
/// `NSTextStorage` content, which is never truncated, regardless of what the glyphs painted.
/// Checked against two fixtures — two of the audit's findings — so this is not a
/// single-document coincidence.
@Test @MainActor func printedPageTextIsFullyPresentDespiteVisualClipping() throws {
    for name in ["boundary.ws4", "narrow.ws4"] {
        let state = try fixtureState(name)
        let expected = docToPagelines(state.document, printed: true)
        let (_, _, pages) = Oracle.layOut(state)
        try #require(!expected.isEmpty, "\(name): library produced no pages")
        try #require(!pages.isEmpty, "\(name): app laid out no pages")

        let libraryText = expected[0].map { $0.map(\.text).joined() }
        let appText = Oracle.pageText(of: pages[0])
        for (index, wanted) in libraryText.enumerated() where index < appText.count {
            #expect(appText[index].trimmingCharacters(in: .whitespaces)
                        == wanted.trimmingCharacters(in: .whitespaces),
                    "\(name) line \(index): accessible text does not match the library's full line — visual clipping reached the accessible string")
        }
    }
}

/// The same guarantee at the `NSTextView` level the audit actually inspects: `.string`
/// (what `accessibilityValue()` is built from) is the whole page, not a display-clipped
/// prefix of it — checked by simply requiring every line's full character count made it
/// into the stored string, not just what a 65-column-wide container could show on screen.
@Test @MainActor func pageTextViewStringCarriesFullLineWidthNotJustVisibleWidth() throws {
    let state = try fixtureState("boundary.ws4")
    // NOT a second `setContent` call — `Oracle.layOut` already built `pages` from `view`;
    // rebuilding would tear down and replace the very text views `pages` points at (see
    // `setContent`'s teardown of the old layout-manager chain), leaving `pages.first` a
    // stale reference to a view that no longer carries this content.
    let (_, _, pages) = Oracle.layOut(state)
    let page = try #require(pages.first)
    let stored = page.textView.string
    let expected = docToPagelines(state.document, printed: true).first?
        .map { $0.map(\.text).joined() }.joined(separator: "\n") ?? ""
    for line in expected.split(separator: "\n") {
        #expect(stored.contains(line.trimmingCharacters(in: .whitespaces)) || line.isEmpty,
                "line missing from the accessible string entirely: \(line)")
    }
}
