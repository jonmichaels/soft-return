import AppKit

extension NSColor {
    /// The desk the page sits on — ONLY the desk. Round 3 split this from the bottom bar's
    /// fill, which used to share this exact colour (see `softReturnTitlebar`); the desk
    /// keeps Jon's ruling untouched by that split.
    ///
    /// Light Mode is Jon's ruling, exact: sRGB 150/255 (0.588). The system's own
    /// `windowBackgroundColor` resolves to ~0.925 in Aqua — near-white, which is why the
    /// page barely read against it and the dead space around a small page looked like part
    /// of the window chrome rather than a desk. Dark Mode is UNCHANGED: the ruling named
    /// Light Mode only, so Dark keeps resolving to the system colour it always has.
    static let softReturnCanvas = NSColor(name: NSColor.Name("SoftReturnCanvas"),
                                           dynamicProvider: resolveCanvas)

    private static func resolveCanvas(for appearance: NSAppearance) -> NSColor {
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else {
            return NSColor(srgbRed: 0.588, green: 0.588, blue: 0.588, alpha: 1.0)
        }
        var resolved = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? resolved
        }
        return resolved
    }

    /// The bottom bar's fill — matches the TITLE BAR, not the desk (Jon's round 3 ruling).
    ///
    /// This window is plain `.titled`, deliberately: no `.texturedBackground`, no
    /// `fullSizeContentView` (see `DocumentWindowController.init`'s doc comment for why the
    /// latter was rejected). `NSWindow.setContentBorderThickness(_:for:)` — the system
    /// mechanism that paints a titlebar-matched bottom border — only draws anything on a
    /// textured window; on a plain titled window it is a silent no-op, and adding
    /// `.texturedBackground` to get it would mean deprecated API and a different window
    /// chrome throughout, not a clean fit for a "thin title bar, BBEdit-class" window. So
    /// this reproduces the titlebar's own colour instead: `windowBackgroundColor` is what a
    /// standard titled window's chrome — including its titlebar — is drawn from, in EITHER
    /// appearance, which is why this resolver never branches on light vs dark the way
    /// `softReturnCanvas` does. It always tracks the system colour, in both appearances.
    static let softReturnTitlebar = NSColor(name: NSColor.Name("SoftReturnTitlebar"),
                                             dynamicProvider: resolveTitlebar)

    private static func resolveTitlebar(for appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? resolved
        }
        return resolved
    }
}
