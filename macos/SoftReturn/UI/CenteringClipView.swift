import AppKit

/// A clip view that centres its document view on any axis where the document is SMALLER
/// than the viewport, and scrolls normally on any axis where it is larger.
///
/// `NSClipView`'s own behaviour pins the document to its origin (bottom-left in an
/// unflipped view, top-left in a flipped one) on every axis, always — there is no built-in
/// notion of "smaller than the viewport" at all. That is Jon's baseline finding: the page
/// sits flush left with a wall of dead canvas to its right at every window size wider than
/// the page. `constrainBoundsRect(_:)` is Apple's documented hook for this — it is asked,
/// on every scroll and every resize, what bounds rect it will actually accept, and centring
/// is done by shifting the accepted origin rather than by moving the document view itself
/// (which would fight the scroll view's own bookkeeping).
///
/// Vertical is asymmetric on purpose: when the page is TALLER than the viewport, this makes
/// no adjustment at all, so `super`'s ordinary top-pinned scrolling behaviour — which Jon's
/// ruling calls out as already correct — passes through untouched.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let container = documentView else { return rect }
        let containerFrame = container.frame

        if rect.width > containerFrame.width {
            rect.origin.x = containerFrame.minX - (rect.width - containerFrame.width) / 2
        }
        if rect.height > containerFrame.height {
            rect.origin.y = containerFrame.minY - (rect.height - containerFrame.height) / 2
        }
        return rect
    }
}
