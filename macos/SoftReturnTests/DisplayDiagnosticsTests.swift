import AppKit
import Testing
@testable import SoftReturn

/// Help ▸ Copy Display Diagnostics (beta): `DisplayDiagnostics.report(entries:)` is a pure
/// function of injected metrics, not real `NSScreen`s — so these tests pin its output against
/// fabricated screens instead of whatever happens to be attached to the machine running them.
@Suite struct DisplayDiagnosticsTests {

    @Test func reportsEveryFieldForASingleKnownScreen() throws {
        let entry = DisplayDiagnosticEntry(
            localizedName: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            backingScaleFactor: 2.0,
            widthMM: 597.6,
            heightMM: 336.15,
            pointsPerInch: 108.86,
            actualSizeMagnification: 1.512,
            isFrontDocumentScreen: true
        )
        let report = DisplayDiagnostics.report(entries: [entry])

        #expect(report.contains("Studio Display"))
        #expect(report.contains("(front document window)"))
        #expect(report.contains("2560"))
        #expect(report.contains("1440"))
        #expect(report.contains("2")) // backingScaleFactor
        #expect(report.contains("597.6"))
        #expect(report.contains("336.")) // 336.15, rounded to 4 significant digits
        #expect(report.contains("108.9")) // 108.86, rounded to 4 significant digits
        #expect(report.contains("1.512"))
        #expect(report.contains("1 screen(s)"))
    }

    @Test func marksOnlyTheFrontDocumentScreenAndListsEveryScreen() throws {
        let front = DisplayDiagnosticEntry(
            localizedName: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            backingScaleFactor: 2.0, widthMM: 301, heightMM: 195,
            pointsPerInch: 127.6, actualSizeMagnification: 1.772,
            isFrontDocumentScreen: true)
        let other = DisplayDiagnosticEntry(
            localizedName: "LG UltraFine", frame: CGRect(x: 1512, y: 0, width: 1280, height: 720),
            backingScaleFactor: 2.0, widthMM: 597, heightMM: 336,
            pointsPerInch: 108.6, actualSizeMagnification: 1.508,
            isFrontDocumentScreen: false)

        let report = DisplayDiagnostics.report(entries: [front, other])

        #expect(report.contains("2 screen(s)"))
        #expect(report.contains("Built-in Retina Display"))
        #expect(report.contains("LG UltraFine"))
        // Exactly one "(front document window)" marker, on the right screen.
        let markerCount = report.components(separatedBy: "(front document window)").count - 1
        #expect(markerCount == 1)
        let frontLineRange = try #require(report.range(of: "Built-in Retina Display"))
        let frontLine = report[frontLineRange.lowerBound...].prefix(while: { $0 != "\n" })
        #expect(frontLine.contains("(front document window)"))
    }

    /// "if CGDisplayScreenSize returns 0" has a diagnostics-side twin: a screen
    /// `ActualSizeMagnification` couldn't compute a real points-per-inch for must say so in
    /// plain words, not print a NaN or silently omit the line.
    @Test func reportsUnknownPointsPerInchInWordsRatherThanANumber() throws {
        let entry = DisplayDiagnosticEntry(
            localizedName: "Unknown External Display",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 1.0, widthMM: 0, heightMM: 0,
            pointsPerInch: nil, actualSizeMagnification: 1.0,
            isFrontDocumentScreen: false)

        let report = DisplayDiagnostics.report(entries: [entry])
        #expect(report.contains("pointsPerInch: unknown"))
    }

    @Test func noAttachedScreensProducesAHeaderWithZeroCount() throws {
        let report = DisplayDiagnostics.report(entries: [])
        #expect(report.contains("0 screen(s)"))
    }
}
