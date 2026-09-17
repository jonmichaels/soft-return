import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 41 (D, and Athena's addition 1): the Native view draws every running head, running foot and automatic page
/// number where the engine resolves it — `Page.headerLines`/`footerLines`/`autoPageno` from `docToPagelines`, the same
/// lines `emitPDF` draws (engine 7372ba6: a running head aligns against its own style's margin and steps by its own line
/// height). The app re-bases x and turns y top-down; it never works a position out for itself. Measured on REF/BOOKLET.WS
/// against real WS7's own numbers, and on every Sawyer-archive document that carries a head or a foot.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct NativeRunningLinesFollowTheEngineTests {
    // Read by the @Test macros outside the main actor, so not isolated to it.
    nonisolated static var sawyer: URL? { PrivateCorpusSupport.sawyerArchiveRoot }

    nonisolated static let skipReason: Comment =
        "private-corpus-gated: needs CTRLKD_PRIVATE_CORPUS or CTRLKD_SAWYER_ARCHIVE — see docs/TESTING.md"

    /// One running line's text and where its left edge and baseline land on the sheet, top-down, in points.
    struct Placement: CustomStringConvertible {
        let text: String
        let x: Double
        let baselineFromTop: Double

        var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

        /// What pairs an engine line with the app's: its visible characters only. The engine's line keeps WordStar's
        /// print-control bytes (^B, ^S, ^Y), which the Native view draws as blank cells, and `∙` is a middle dot there.
        var key: String {
            var visible = String.UnicodeScalarView()
            for scalar in text.unicodeScalars where scalar.value >= 0x20 && scalar != " " && scalar != "\u{00A0}" {
                visible.append(scalar.value == 0x2219 || scalar.value == 0x2022 ? "\u{00B7}" : scalar)
            }
            return String(visible)
        }

        var description: String {
            "\"\(trimmed)\" x \(String(format: "%.1f", x)) baseline \(String(format: "%.1f", baselineFromTop))"
        }
    }

    static func state(_ url: URL) throws -> DocumentState {
        let defaults = try #require(UserDefaults(suiteName: "NativeRunningLines.\(UUID().uuidString)"))
        return try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: SettingsStore(defaults: defaults),
                                 docPath: url.path)
    }

    /// The engine's own placements, per page: its resolved heads, feet and automatic page number.
    static func enginePlacements(_ state: DocumentState) -> [[Placement]] {
        let options = DocumentRenderer.nativeEngineOptions(state)
        let doc = printedDocument(state.document, options: options)
        let pages = docToPagelines(doc, printed: true, pixResults: options.pixResults, pictures: .embed)
        var result: [[Placement]] = []
        for page in pages {
            // Each page flips against its own sheet (engine 07b040c, M31).
            let pageHeight = Double(printedMetrics(state.document, page: page, options: options).pageHeight)
            var lines: [Placement] = []
            let resolved: [HeadFootLine] = (page.headerLines ?? []) + (page.footerLines ?? [])
            for line in resolved {
                lines.append(Placement(text: line.text, x: line.x, baselineFromTop: pageHeight - line.y))
            }
            if let number = page.autoPageno {
                lines.append(Placement(text: number.text, x: number.x, baselineFromTop: pageHeight - number.y))
            }
            result.append(lines)
        }
        return result
    }

    /// The Native view's placements, per page, as `PagedDocumentView.drawRunningLines` puts them — the left edge before
    /// any proportional leading-whitespace skip (`leadingOffset`), which is where the engine's own x is measured.
    static func appPlacements(_ rendered: RenderedDocument) -> [[Placement]] {
        let left = Double(rendered.textFrame.origin.x)
        var result: [[Placement]] = []
        for page in rendered.runningLines {
            var lines: [Placement] = []
            for line in page {
                lines.append(Placement(text: line.text.string, x: left + line.pageLeftOffset,
                                       baselineFromTop: line.baselineFromTop))
            }
            result.append(lines)
        }
        return result
    }

    /// Engine and app placements matched by text, page by page: the lines the app lacks or adds, and the matched pairs
    /// whose x or baseline differ by more than `tolerance` points.
    static func compare(_ engine: [[Placement]], _ app: [[Placement]], tolerance: Double = 0.5)
        -> (missing: [String], extra: [String], moved: [String]) {
        var missing: [String] = []
        var extra: [String] = []
        var moved: [String] = []
        for index in 0..<max(engine.count, app.count) {
            let want: [Placement] = index < engine.count ? engine[index] : []
            var have: [Placement] = index < app.count ? app[index] : []
            for line in want where !line.key.isEmpty {
                guard let found = have.firstIndex(where: { $0.key == line.key }) else {
                    missing.append("p\(index + 1) \(line)")
                    continue
                }
                let drawn = have.remove(at: found)
                if abs(drawn.x - line.x) > tolerance || abs(drawn.baselineFromTop - line.baselineFromTop) > tolerance {
                    moved.append("p\(index + 1) engine \(line), app \(drawn)")
                }
            }
            for line in have where !line.key.isEmpty {
                extra.append("p\(index + 1) \(line)")
            }
        }
        return (missing, extra, moved)
    }

    /// REF/BOOKLET.WS page 1: real WS7 prints both heads on one row 0.57 in down, "Header Even 1" from 0.20 in and
    /// "Header Odd 1" from 9.21 in on the 11 in landscape sheet (engine 7372ba6). The top of page 1, Native beside
    /// Printed: b41-d-booklet-heads-native-vs-printed.png.
    @Test(.enabled(if: sawyer != nil, skipReason))
    func bookletsHeadsLandWhereRealWS7PutsThem() throws {
        let url = try #require(Self.sawyer).appendingPathComponent("REF/BOOKLET.WS")
        let state = try Self.state(url)
        let rendered = DocumentRenderer.render(state, style: .native)
        let engine = Self.enginePlacements(state)
        let app = Self.appPlacements(rendered)
        let enginePageOne: [Placement] = engine.first ?? []
        let appPageOne: [Placement] = app.first ?? []
        print("NATIVE-HEADS BOOKLET.WS page 1: engine \(enginePageOne); app \(appPageOne)")
        let even = try #require(appPageOne.first { $0.trimmed == "Header Even 1" }, "no \"Header Even 1\" on page 1")
        let odd = try #require(appPageOne.first { $0.trimmed == "Header Odd 1" }, "no \"Header Odd 1\" on page 1")
        #expect(abs(even.x - 14.4) <= 0.5, "Header Even 1 starts at \(even.x) pt; real WS7 at 0.20 in")
        #expect(abs(odd.x - 662.9) <= 0.5, "Header Odd 1 starts at \(odd.x) pt; real WS7 at 9.21 in")
        #expect(abs(even.baselineFromTop - odd.baselineFromTop) <= 0.01, "the two heads are not on one row: \(even), \(odd)")
        #expect(abs(odd.baselineFromTop - 41.0) <= 0.5, "the head row sits \(odd.baselineFromTop) pt down; the engine's 612 − 571")
        let result = Self.compare(engine, app)
        #expect(result.missing.isEmpty && result.extra.isEmpty && result.moved.isEmpty,
                "BOOKLET.WS: missing \(result.missing), extra \(result.extra), moved \(result.moved)")
        try NativeSupSubRiseTests.writeComparison(state: state, rendered: rendered,
                                                  name: "b41-d-booklet-heads-native-vs-printed.png")
    }

    /// Every Sawyer-archive document that carries a running head or foot: each head, foot and automatic page number the
    /// Native view draws is one the engine resolved, at the engine's x and baseline, on the same page — none missing,
    /// none extra.
    @Test(.enabled(if: sawyer != nil, skipReason))
    func everyHeadFootAndPageNumberIsWhereTheEngineResolvedIt() throws {
        let root = try #require(Self.sawyer)
        let documents = try Self.documentsWithHeadsOrFeet(under: root)
        try #require(!documents.isEmpty, "no document with a running head or foot under the Sawyer archive")
        var failures: [String] = []
        var checked = 0
        var lineCount = 0
        for url in documents {
            let name = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let state: DocumentState
            do {
                state = try Self.state(url)
            } catch {
                print("NATIVE-HEADS \(name): not opened (\(error))")
                continue
            }
            let rendered = DocumentRenderer.render(state, style: .native)
            let engine = Self.enginePlacements(state)
            let app = Self.appPlacements(rendered)
            let result = Self.compare(engine, app)
            let lines = engine.reduce(0) { $0 + $1.count }
            lineCount += lines
            checked += 1
            let summary = "missing \(result.missing.count), extra \(result.extra.count), moved \(result.moved.count)"
            print("NATIVE-HEADS \(name): \(engine.count) pages, \(lines) engine lines; \(summary)"
                  + (result.missing.isEmpty && result.extra.isEmpty && result.moved.isEmpty
                     ? "" : "; moved \(result.moved.prefix(3)), missing \(result.missing.prefix(3)), extra \(result.extra.prefix(3))"))
            if !(result.missing.isEmpty && result.extra.isEmpty && result.moved.isEmpty) {
                failures.append("\(name): \(summary)")
            }
        }
        print("NATIVE-HEADS: \(checked) documents, \(lineCount) engine lines checked")
        #expect(checked > 0)
        #expect(failures.isEmpty, "\(failures)")
    }

    /// Documents under `root` whose bytes carry a `.h1`–`.h5` or `.f1`–`.f5` dot command at a line start.
    static func documentsWithHeadsOrFeet(under root: URL) throws -> [URL] {
        let extensions: Set<String> = ["ws", "dot", "tst", "lst", "rjs", "how", "doc"]
        let pattern = try NSRegularExpression(pattern: "(?:^|[\\r\\n])\\.[hHfF][1-5]")
        var found: [URL] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in walker where extensions.contains(url.pathExtension.lowercased()) {
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000 else { continue }
            let text = String(decoding: data.map { $0 & 0x7F }, as: UTF8.self)
            if pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                found.append(url)
            }
        }
        return CorpusDocumentFilter.apply(found.sorted { $0.path < $1.path }, name: { $0.lastPathComponent })
    }
}
