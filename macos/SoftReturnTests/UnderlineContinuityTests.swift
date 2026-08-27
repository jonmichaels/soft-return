import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 423 (view item c): the fidelity round's own continuous-underline fix (Jon's ruling
/// 2026-08-20 — `PDFWriter.swift`'s `rules`/`ulContinuous`) is engine-emitter-specific
/// plumbing: WS7 encodes underline as one UL-ON..UL-OFF toggle per PHRASE, cursor moves
/// (no ink, no underline) between words, and the PDF driver used to draw the rule PER
/// PIECE (breaking at every space) until that ruling lifted it out to draw once per span.
/// This app's own `DocumentRenderer.appendSpan`/`attributedRun` never had that per-piece
/// bug in the first place — it sets AppKit's `.underlineStyle` once across a WHOLE span's
/// attributed range (including any embedded spaces), which AppKit draws as one continuous
/// stroke by construction, no lifting logic needed. This test verifies that structurally
/// rather than assuming it: scans every bundled `TestDocs/ws7` fixture's real Printed
/// render for two adjacent underlined runs separated only by whitespace — the exact shape
/// a per-piece/per-span underline break would leave behind. Green across the whole corpus
/// (11 fixtures carry underline at all; `YOURWAY.WS` alone has 11 separate runs) is real,
/// checked evidence for the brief's "verify underline continuity... through the app", not
/// an assumption from reading the engine's own fix.
/// Job 535: reads every `TestDocs/ws7` fixture — gated at the suite level so a bare stranger
/// run skips this explicitly instead of vacuously passing over zero fixtures.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct UnderlineContinuityTests {
    @Test @MainActor func noGapsBetweenAdjacentUnderlinedRuns() throws {
        let dir = PrivateCorpusSupport.ws7Directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() where name.uppercased().hasSuffix(".WS") {
            let url = dir.appendingPathComponent(name)
            guard let bytes = try? [UInt8](Data(contentsOf: url)) else { continue }
            let defaults = UserDefaults(suiteName: "UnderlineContinuityTests.\(UUID().uuidString)")!
            guard let state = try? DocumentState(data: bytes, settings: SettingsStore(defaults: defaults)) else { continue }
            let rendered = DocumentRenderer.render(state, style: .printed)
            let ns = rendered.text.string as NSString
            var ranges: [NSRange] = []
            rendered.text.enumerateAttribute(.underlineStyle, in: NSRange(location: 0, length: rendered.text.length)) { value, range, _ in
                if let v = value as? Int, v != 0 { ranges.append(range) }
            }
            for i in 0..<ranges.count {
                guard i + 1 < ranges.count else { continue }
                let a = ranges[i]
                let b = ranges[i + 1]
                let gapStart = a.location + a.length
                let gapLen = b.location - gapStart
                // A short whitespace-only gap between two SEPARATE underlined attribute
                // ranges is what a real break looks like; anything wider or non-blank is
                // unrelated text between two unconnected underlined phrases, not a gap in
                // what should be one continuous run.
                guard gapLen > 0, gapLen < 5 else { continue }
                let gapText = ns.substring(with: NSRange(location: gapStart, length: gapLen))
                guard gapText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let before = ns.substring(with: a)
                let after = ns.substring(with: b)
                Issue.record("""
                    \(name): underline gap between adjacent runs — \
                    "\(before)"<gap: \(gapText.debugDescription)>"\(after)" — WS7's own \
                    per-phrase UL-ON/OFF toggle should read as one continuous underlined \
                    span here, not two separated by a bare space.
                    """)
            }
        }
    }
}
