import AppKit

/// The physical metrics needed to turn a screen into an "Actual Size" magnification factor.
/// A struct rather than a direct `NSScreen`/`CGDirectDisplayID` call site so a test can inject
/// known values instead of depending on whatever real display happens to be attached.
struct DisplayPhysicalMetrics: Equatable {
    /// Physical display width, in millimeters — `CGDisplayScreenSize`. Some external
    /// displays report zero here (no EDID, or CoreGraphics just hasn't read it yet); that is
    /// the fallback signal, not a value to compute against.
    let widthMM: Double
    let heightMM: Double
    /// This screen's own point-space width — `NSScreen.frame.width`. NOT
    /// `CGDisplayPixelsWide`: on a Retina display that call reports the SCALED POINT
    /// resolution (e.g. 1512 on a 14" MacBook Pro), not native pixels — dividing it by
    /// `backingScaleFactor` silently halved the true points-per-inch. Points are the space
    /// the page is actually drawn in, so this is the number the formula needs directly.
    let widthPoints: Double
    /// Kept for diagnostics (Help ▸ Copy Display Diagnostics) only — NOT used by `compute`.
    let backingScaleFactor: Double

    /// Real metrics for `screen`, or `nil` if CoreGraphics can't identify its display or
    /// reports zero physical size — the caller's cue to fall back to `magnification == 1.0`.
    static func live(for screen: NSScreen) -> DisplayPhysicalMetrics? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let sizeMM = CGDisplayScreenSize(displayID)
        guard sizeMM.width > 0, sizeMM.height > 0 else { return nil }
        guard screen.frame.width > 0 else { return nil }
        return DisplayPhysicalMetrics(
            widthMM: Double(sizeMM.width),
            heightMM: Double(sizeMM.height),
            widthPoints: Double(screen.frame.width),
            backingScaleFactor: Double(screen.backingScaleFactor)
        )
    }
}

/// "Actual Size = 100% = Page Size" (Jon's spec): a Letter page must measure 8.5x11 real
/// inches on screen, ruler to glass — not "one page point equals one screen point", which is
/// only true size on a display that happens to run at exactly 72 real points per inch.
enum ActualSizeMagnification {
    /// This screen's true points-per-inch, or `nil` when CoreGraphics couldn't identify the
    /// display or reported a non-positive/non-finite width — the same condition `compute`
    /// falls back to `magnification == 1.0` for. Exposed separately (not just folded into
    /// `compute`) so Help ▸ Copy Display Diagnostics can report the intermediate figure
    /// itself, not just the final ratio.
    static func pointsPerInch(from metrics: DisplayPhysicalMetrics?) -> Double? {
        guard let metrics, metrics.widthMM > 0 else {
            if metrics == nil {
                NSLog("[SoftReturn] Actual Size: no display metrics, falling back to magnification 1.0")
            }
            return nil
        }
        let widthInches = metrics.widthMM / 25.4
        let value = metrics.widthPoints / widthInches
        guard value.isFinite, value > 0 else {
            NSLog("[SoftReturn] Actual Size: non-finite points-per-inch, falling back to magnification 1.0")
            return nil
        }
        return value
    }

    /// The page is laid out in PostScript points, 72 to the inch. `NSScrollView.magnification`
    /// of 1.0 draws one page point as one screen point, so true physical size needs
    /// `displayPointsPerInch / 72` — the ratio between this screen's real points-per-inch and
    /// PostScript's own.
    ///
    /// `nil`, or metrics CoreGraphics couldn't back with a real physical width, fall back to
    /// 1.0 (the old one-point-one-point behavior) rather than propagate a bogus scale.
    static func compute(from metrics: DisplayPhysicalMetrics?) -> Double {
        guard let pointsPerInch = pointsPerInch(from: metrics) else { return 1.0 }
        return pointsPerInch / 72.0
    }
}
