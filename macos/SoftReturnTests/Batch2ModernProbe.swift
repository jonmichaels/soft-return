import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// A DIAGNOSTIC, not a gate: the app's Modern line list beside the engine's, in full.
///
/// `appModernMatchesTheLibrarysModernPageAndLineBreaks` reports one number per document — a
/// Levenshtein distance over the two line lists — and a number cannot be grouped by cause.
/// This writes both lists out, aligned, so a run of differences can be read as the one thing
/// it usually is.
///
/// Writes into the drop box directory, the one place both sides of the fence can reach.
/// Asserts nothing, so it cannot fail a run.
@Suite(.serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct Batch2ModernProbe {

    static var dumpDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/coder-apptest/batch2",
                                    isDirectory: true)
    }

    /// The gate's own twelve, so the probe and the gate can never be measuring different
    /// documents.
    static let documents = AppModernFidelityTests.documents

    /// Whose PDFs are written out beside the line lists.
    static let pdfDocuments: Set<String> = ["-README", "SCRIPT", "LJ6DTP", "VERSIONS",
                                            "LYING", "WARPRAYR", "BOXES", "SAWYER"]

    @Test @MainActor func dumpModernLinesSideBySide() throws {
        let directory = Self.dumpDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var summary = ""
        // What the app's own state actually holds for the documents with pictures — the
        // Modern line list shows a placeholder and the question is which end of the chain
        // dropped it.
        for name in Self.pdfDocuments.sorted() {
            guard let url = AppNativeFidelityTests.resolveSource(name) else { continue }
            let defaults = UserDefaults(suiteName: "Batch2.\(UUID().uuidString)")!
            guard let bytes = try? Data(contentsOf: url),
                  let state = try? DocumentState(data: [UInt8](bytes),
                                                 settings: SettingsStore(defaults: defaults),
                                                 docPath: url.path)
            else { continue }
            summary += "\(name) at \(url.deletingLastPathComponent().lastPathComponent)/: "
                + "graphics=\(state.document.graphics.count) pixResults=\(state.pixResults.count) "
                + "ok=\(state.pixResults.filter(\.ok).count) "
                + "entries=\(state.pixResults.map { ($0.index, $0.ok, pixBasename($0.rawPath)) })"
                + " spanPix=\(state.document.graphics.count)\n"
        }
        var total = 0
        for name in Self.documents {
            guard let appPDF = try? AppModernFidelityTests.appModernPDF(forDocumentNamed: name,
                                                                       pins: true),
                  let enginePDF = try? AppModernFidelityTests.engineModernPDF(forDocumentNamed: name),
                  let appPages = try? AppModernFidelityTests.lines(of: appPDF),
                  let enginePages = try? AppModernFidelityTests.lines(of: enginePDF)
            else {
                summary += "\(name): could not render\n"
                continue
            }
            // THE BYTES TOO, for the named few — a measure question is answered by where the
            // ink actually stops, not by which words landed on which line.
            if Self.pdfDocuments.contains(name) {
                try? Data(appPDF).write(to: directory.appendingPathComponent("\(name)-app.pdf"))
                try? Data(enginePDF).write(to: directory.appendingPathComponent("\(name)-engine.pdf"))
                // AND EACH SIDE'S WORDS WITH THEIR X, which is the only way to tell a
                // MEASURE difference (the same words, the same places, a different right
                // edge) from a METRICS one (the same words drifting apart along the line).
                for (label, bytes) in [("app", appPDF), ("engine", enginePDF)] {
                    guard let words = try? AppPDFWords.payload(from: bytes).words else { continue }
                    var text = ""
                    for word in words {
                        text += String(format: "p%d y=%.2f x=%.2f size=%.1f %@\n",
                                       word.page, word.y_top_pt, word.x_pt, word.size_pt,
                                       word.text)
                    }
                    try? text.write(to: directory.appendingPathComponent("\(name)-\(label)-words.txt"),
                                    atomically: true, encoding: .utf8)
                }
            }
            let app = appPages.flatMap { $0 }
            let engine = enginePages.flatMap { $0 }
            // THE GATE'S OWN NUMBER, computed the gate's own way (`AppModernFidelityTests
            // .diff` per page, summed) — a probe that scores differently from the gate it
            // serves is a probe that reports progress the gate does not see.
            var distance = 0
            for page in 0..<max(appPages.count, enginePages.count) {
                let a = page < appPages.count ? appPages[page] : []
                let b = page < enginePages.count ? enginePages[page] : []
                distance += AppModernFidelityTests.diff(app: a, library: b).editDistance
            }
            total += distance
            summary += "\(name): distance \(distance) — app \(appPages.count) page(s)/\(app.count) line(s), "
                + "library \(enginePages.count)/\(engine.count)\n"

            // ALIGNED, not zipped: one inserted line on either side shifts every ordinal
            // after it, and a zip then reports the whole rest of the document as different.
            // PAGE BY PAGE FIRST, because that is the quantity the gate scores: it diffs
            // page i against page i, so one line too many on an early page charges every
            // page after it.
            var report = "=== \(name)  app \(app.count) lines, library \(engine.count)\n"
            for page in 0..<max(appPages.count, enginePages.count) {
                let a = page < appPages.count ? appPages[page] : []
                let b = page < enginePages.count ? enginePages[page] : []
                guard a != b else { continue }
                let steps = Self.alignment(app: a, library: b)
                let differing = steps.filter { if case .same = $0 { return false } else { return true } }
                report += "-- page \(page + 1): app \(a.count) line(s), library \(b.count), "
                    + "\(differing.count) differing\n"
                for step in steps {
                    switch step {
                    case .same: continue
                    case .differs(let x, let y):
                        report += "   !! app \(x.prefix(92).debugDescription)\n"
                        report += "   !! lib \(y.prefix(92).debugDescription)\n"
                    case .appOnly(let x):
                        report += "   +A \(x.prefix(92).debugDescription)\n"
                    case .libraryOnly(let y):
                        report += "   +L \(y.prefix(92).debugDescription)\n"
                    }
                }
            }
            report += "\n== flattened ==\n"
            for step in Self.alignment(app: app, library: engine) {
                switch step {
                case .same(let text):
                    report += "    \(text.prefix(96))\n"
                case .differs(let appText, let libraryText):
                    report += "!!  app \(appText.prefix(96).debugDescription)\n"
                    report += "!!  lib \(libraryText.prefix(96).debugDescription)\n"
                case .appOnly(let text):
                    report += "+A  \(text.prefix(96).debugDescription)\n"
                case .libraryOnly(let text):
                    report += "+L  \(text.prefix(96).debugDescription)\n"
                }
            }
            try report.write(to: directory.appendingPathComponent("\(name)-lines.txt"),
                             atomically: true, encoding: .utf8)
        }
        summary += "TOTAL distance \(total) across \(Self.documents.count) document(s)\n"
        // AND THE SAME TWELVE WITH THE GATE'S PINS OFF — what the app SHIPS, measured against
        // today's library. The difference between the two columns is exactly the app-only
        // Modern rules Jon ruled stay in the app and the engines port.
        var shippedTotal = 0
        for name in Self.documents {
            guard let appPDF = try? AppModernFidelityTests.appModernPDF(forDocumentNamed: name,
                                                                       pins: false),
                  let enginePDF = try? AppModernFidelityTests.engineModernPDF(forDocumentNamed: name),
                  let appPages = try? AppModernFidelityTests.lines(of: appPDF),
                  let enginePages = try? AppModernFidelityTests.lines(of: enginePDF)
            else { summary += "SHIPPED \(name): could not render\n"; continue }
            var distance = 0
            for page in 0..<max(appPages.count, enginePages.count) {
                let a = page < appPages.count ? appPages[page] : []
                let b = page < enginePages.count ? enginePages[page] : []
                distance += AppModernFidelityTests.diff(app: a, library: b).editDistance
            }
            shippedTotal += distance
            summary += "SHIPPED \(name): distance \(distance) — app \(appPages.count) page(s)/"
                + "\(appPages.flatMap { $0 }.count) line(s), library \(enginePages.count)/"
                + "\(enginePages.flatMap { $0 }.count)\n"
        }
        summary += "SHIPPED TOTAL \(shippedTotal)\n"
        // WHAT THE APP'S OWN RUNS CARRY — face, size and the `.expansion` the declared
        // character cell asked for, which is the quantity the library states as a `Tz`.
        for name in Self.pdfDocuments.union(["LYING", "WARPRAYR"]).sorted() {
            guard let url = AppNativeFidelityTests.resolveSource(name),
                  let bytes = try? Data(contentsOf: url) else { continue }
            let defaults = UserDefaults(suiteName: "Batch2Tz.\(UUID().uuidString)")!
            let settings = SettingsStore(defaults: defaults)
            settings.modernFontName = AppModernFidelityTests.engineModernFace
            settings.modernFontSize = AppModernFidelityTests.engineModernBodyPt
            guard let state = try? DocumentState(data: [UInt8](bytes), settings: settings,
                                                 docPath: url.path) else { continue }
            state.style.setManually(.modern)
            // THE SAME PINS THE GATE RENDERS UNDER, or this dump describes a layout the gate
            // never sees (`AppModernFidelityTests.appModernPDF` sets both).
            DocumentRenderer.modernBase14MeasurementPin = true
            let rendered = DocumentRenderer.render(state)
            DocumentRenderer.modernBase14MeasurementPin = false
            var tally: [String: Int] = [:]
            rendered.text.enumerateAttributes(
                in: NSRange(location: 0, length: rendered.text.length), options: []
            ) { attributes, range, _ in
                let font = attributes[.font] as? NSFont
                let expansion = (attributes[.expansion] as? Double).map { exp($0) * 100 } ?? 100
                let key = "\(font?.fontName ?? "?")/\(font?.pointSize ?? 0)/"
                    + String(format: "%.2f", expansion)
                tally[key, default: 0] += range.length
            }
            let top = tally.sorted { $0.value > $1.value }.prefix(6)
                .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            summary += "TZ \(name): \(top)\n"
            // EVERY PARAGRAPH'S OWN LEADING, in document order — the quantity the library
            // states as `h = modernLine * sizes.max()` and the one a page's fill is made of.
            var paragraphs = ""
            rendered.text.enumerateAttribute(
                .paragraphStyle, in: NSRange(location: 0, length: rendered.text.length),
                options: []
            ) { value, range, _ in
                guard let style = value as? NSParagraphStyle else { return }
                let text = (rendered.text.string as NSString).substring(with: range)
                    .replacingOccurrences(of: "\n", with: "\\n")
                paragraphs += String(
                    format: "min=%.2f max=%.2f mult=%.3f first=%.2f head=%.2f tail=%.2f :: %@\n",
                    style.minimumLineHeight, style.maximumLineHeight, style.lineHeightMultiple,
                    style.firstLineHeadIndent, style.headIndent, style.tailIndent,
                    String(text.prefix(56)))
            }
            try? paragraphs.write(to: directory.appendingPathComponent("\(name)-paragraphs.txt"),
                                  atomically: true, encoding: .utf8)
            // AND ONE ROW CHARACTER BY CHARACTER, with what each one actually carries — the
            // only way to tell a stretch from a kern from a face.
            let haystack = rendered.text.string as NSString
            for needle in ["Modifying WordStar", "Iosevka Fixed and", "copyright symbols are",
                           "COMPLETELY FRESH"] {
                let found = haystack.range(of: needle)
                guard found.location != NSNotFound else { continue }
                var chars = "\(name) :: \(needle)\n"
                if let style = rendered.text.attribute(.paragraphStyle, at: found.location,
                                                       effectiveRange: nil) as? NSParagraphStyle {
                    chars += String(format: "  PARAGRAPH first=%.2f head=%.2f tail=%.2f align=%d\n",
                                    style.firstLineHeadIndent, style.headIndent,
                                    style.tailIndent, style.alignment.rawValue)
                }
                chars += String(format: "  FRAME x=%.2f w=%.2f\n",
                                rendered.textFrame.origin.x, rendered.textFrame.width)
                let start = max(0, found.location - 8)
                let end = min(haystack.length, found.location + 40)
                for i in start..<end {
                    let r = NSRange(location: i, length: 1)
                    let attrs = rendered.text.attributes(at: i, effectiveRange: nil)
                    let font = attrs[.font] as? NSFont
                    let kern = (attrs[.kern] as? NSNumber)?.doubleValue ?? 0
                    let expansion = (attrs[.expansion] as? NSNumber)?.doubleValue ?? 0
                    chars += String(format: "  %@ u+%04X font=%@/%.1f kern=%.2f exp=%.4f\n",
                                    haystack.substring(with: r).debugDescription,
                                    haystack.character(at: i),
                                    font?.fontName ?? "?", font?.pointSize ?? 0, kern, expansion)
                }
                try? chars.write(
                    to: directory.appendingPathComponent(
                        "\(name)-chars-\(needle.prefix(10).replacingOccurrences(of: " ", with: "_")).txt"),
                    atomically: true, encoding: .utf8)
            }
        }
        try summary.write(to: directory.appendingPathComponent("summary.txt"),
                          atomically: true, encoding: .utf8)
    }

    enum Step {
        case same(String)
        case differs(String, String)
        case appOnly(String)
        case libraryOnly(String)
    }

    /// A plain longest-common-subsequence alignment of the two line lists. Quadratic, which
    /// for a few hundred lines is nothing, and it is what makes a run of differences read as
    /// one cause rather than as everything after the first one.
    static func alignment(app: [String], library: [String]) -> [Step] {
        let a = app, b = library
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty, !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lcs[i][j] = AppModernFidelityTests.sameLine(a[i], b[j])
                        ? lcs[i + 1][j + 1] + 1
                        : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var steps: [Step] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if AppModernFidelityTests.sameLine(a[i], b[j]) {
                steps.append(.same(a[i]))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                // A pair that differs reads better than two one-sided rows when the two
                // lists are simply out of step by content rather than by count.
                if lcs[i + 1][j] == lcs[i][j + 1] {
                    steps.append(.differs(a[i], b[j]))
                    i += 1
                    j += 1
                } else {
                    steps.append(.appOnly(a[i]))
                    i += 1
                }
            } else {
                steps.append(.libraryOnly(b[j]))
                j += 1
            }
        }
        while i < a.count { steps.append(.appOnly(a[i])); i += 1 }
        while j < b.count { steps.append(.libraryOnly(b[j])); j += 1 }
        return steps
    }
}
