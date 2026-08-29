import AppKit

/// One attached screen's ground truth for Help ▸ Copy Display Diagnostics (beta) — the same
/// physical metrics `ActualSizeMagnification` computes from, laid out so Jon can paste a
/// machine's real screen data into a report from ANY Mac (his desk, a second Mac's three 4Ks,
/// anyone's), not just the ones already in this room.
struct DisplayDiagnosticEntry: Equatable {
    let localizedName: String
    /// `NSScreen.frame`, in points — origin included, since a multi-display arrangement's
    /// origins are part of "which screen is this" too.
    let frame: CGRect
    let backingScaleFactor: Double
    /// `CGDisplayScreenSize`, in millimeters. Zero when CoreGraphics couldn't report a
    /// physical size for this display (some external displays lie) — carried through
    /// verbatim rather than folded into `pointsPerInch == nil`, so the report shows exactly
    /// what CoreGraphics said.
    let widthMM: Double
    let heightMM: Double
    /// `nil` exactly when `ActualSizeMagnification.pointsPerInch(from:)` would be `nil` —
    /// CoreGraphics couldn't back this screen with a real physical width.
    let pointsPerInch: Double?
    let actualSizeMagnification: Double
    /// Whether this is the screen the frontmost document window is currently on — the figure
    /// that makes a diagnostic report about "the one page that looked wrong", not just a
    /// generic dump of every screen attached to the machine.
    let isFrontDocumentScreen: Bool
}

/// A pure function of `[DisplayDiagnosticEntry]` to pasteable text — no `NSScreen` in this
/// file at all, so it can be unit-tested with fabricated metrics instead of whatever screens
/// happen to be attached to the machine running the tests. `AppDelegate` is what gathers the
/// real entries and puts the result on the pasteboard.
enum DisplayDiagnostics {
    static func report(entries: [DisplayDiagnosticEntry]) -> String {
        var lines = ["Soft Return Display Diagnostics", "\(entries.count) screen(s)", ""]
        for (index, entry) in entries.enumerated() {
            var name = "Screen \(index + 1): \(entry.localizedName)"
            if entry.isFrontDocumentScreen { name += " (front document window)" }
            lines.append(name)
            lines.append("  frame: \(format(entry.frame.width)) × \(format(entry.frame.height)) pt"
                + " at (\(format(entry.frame.origin.x)), \(format(entry.frame.origin.y)))")
            lines.append("  backingScaleFactor: \(format(entry.backingScaleFactor))")
            lines.append("  CGDisplayScreenSize: \(format(entry.widthMM)) × \(format(entry.heightMM)) mm")
            if let pointsPerInch = entry.pointsPerInch {
                lines.append("  pointsPerInch: \(format(pointsPerInch))")
            } else {
                lines.append("  pointsPerInch: unknown (no physical size reported)")
            }
            lines.append("  Actual Size magnification: \(format(entry.actualSizeMagnification))")
            lines.append("")
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4g", value)
    }
}
