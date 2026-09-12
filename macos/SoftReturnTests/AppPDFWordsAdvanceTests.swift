import Foundation
import Testing
@testable import SoftReturn

/// THE EXTRACTOR'S OWN GATE: a word's x comes from the advances inside its `Tj`, not from
/// whichever `Tm` happened to open the run.
///
/// ## Why this suite exists
///
/// `AppPDFWords` is the instrument every Native-gate number is taken with, and it was found
/// giving every glyph in a run the same x — on a real document, under a change that only
/// altered whether Quartz emitted a `Tc` operator. Every prior investigation of that ran
/// through a real 16-page document and a private capture, which is far too much machinery to
/// see one arithmetic fault through.
///
/// So these PDFs are written here, byte by byte, with exactly the shape the app's own Quartz
/// output has and nothing else: a nominal `1 Tf` with the real size carried in the text
/// matrix, one `Tj` holding a whole line of four words, and a 600/1000 fixed-pitch font. Two
/// variants, differing only in whether a `Tc` is present, because that was the only
/// difference between the working and failing real-document cases.
@Suite struct AppPDFWordsAdvanceTests {

    /// A one-page PDF drawing `text` as a single `Tj`, at 12pt via the text matrix, in a
    /// 600/1000 fixed-pitch font — the app's own op shape.
    ///
    /// `earlierCharSpacing` reproduces the real stream's other structural feature: a `Tc` set
    /// on an EARLIER line, inside its own `q`/`Q` pair. `Tc` is text state, so `Q` restores
    /// it and it must not reach this line at all.
    private static func onePageOneTj(_ text: String, charSpacing: String?,
                                     earlierCharSpacing: String? = nil) -> [UInt8] {
        let spacing = charSpacing.map { "\($0) Tc " } ?? ""
        let earlier = earlierCharSpacing.map {
            "q 1 0 0 -1 57.6 753 cm BT \($0) Tc 12 0 0 -12 0 129 Tm /F1 1 Tf (   ) Tj ET Q "
        } ?? ""
        let content = """
        \(earlier)q 1 0 0 -1 57.6 753 cm BT \(spacing)12 0 0 -12 151.2 201 Tm /F1 1 Tf (\(text)) Tj ET Q
        """
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append("""
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
        /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>
        """)
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        // FirstChar 32 through 122, every width 600 — a fixed-pitch face, same as the
        // subsets Quartz embeds for Courier.
        let widths = Array(repeating: "600", count: 122 - 32 + 1).joined(separator: " ")
        objects.append("""
        << /Type /Font /Subtype /TrueType /BaseFont /Courier /Encoding /MacRomanEncoding \
        /FirstChar 32 /LastChar 122 /Widths [ \(widths) ] >>
        """)

        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += """
        trailer
        << /Size \(objects.count + 1) /Root 1 0 R >>
        startxref
        \(xrefOffset)
        %%EOF
        """
        return Array(pdf.utf8)
    }

    /// The line the real failure was found on, reduced to its essentials: four words in one
    /// `Tj`, starting at page x 208.8 (the `cm` translate of 57.6 plus the `Tm` of 151.2),
    /// each character 7.2pt wide.
    private static let line = "Monday, August 12, 2024"
    private static let wanted: [(String, Double)] = [
        ("Monday,", 208.8),                 // column 0 of the run
        ("August", 208.8 + 8 * 7.2),        // 266.4
        ("12,", 208.8 + 15 * 7.2),          // 316.8
        ("2024", 208.8 + 19 * 7.2),         // 345.6
    ]

    private func check(charSpacing: String?, label: String,
                       earlierCharSpacing: String? = nil) throws {
        let pdf = Self.onePageOneTj(Self.line, charSpacing: charSpacing,
                                    earlierCharSpacing: earlierCharSpacing)
        let payload = try AppPDFWords.payload(from: pdf)
        // The earlier decoy line is three spaces, which segment to no words at all; only
        // this line's own four words should be here.
        let words = payload.words.filter { $0.page == 1 }.sorted { $0.x_pt < $1.x_pt }

        try #require(words.count == Self.wanted.count, """
            \(label): expected \(Self.wanted.count) words from one Tj, got \(words.count) \
            — \(words.map(\.text))
            """)
        var failures: [String] = []
        for (index, expected) in Self.wanted.enumerated() {
            let word = words[index]
            if word.text != expected.0 {
                failures.append("word \(index) is \"\(word.text)\", expected \"\(expected.0)\"")
            }
            // A tolerance well under one column: any real advance fault is 7.2pt or more.
            if abs(word.x_pt - expected.1) > 0.05 {
                failures.append(String(format: "\"%@\" at x=%.2f, expected %.2f",
                                       word.text, word.x_pt, expected.1))
            }
        }
        let message = "\(label): \(failures.count) of \(Self.wanted.count) words misplaced — "
            + failures.joined(separator: "; ")
            + ". Every word after the first taking the run's own origin is the signature of "
            + "the pen not carrying between glyphs inside a Tj."
        #expect(failures.isEmpty, "\(message)")
    }

    /// With a `Tc` present — the shape the app emits today, and the one that was reading
    /// correctly on real documents.
    @Test func wordsInsideOneTjAdvanceWithCharacterSpacing() throws {
        try check(charSpacing: "0.0001", label: "with Tc")
    }

    /// With no `Tc` at all.
    @Test func wordsInsideOneTjAdvanceWithoutCharacterSpacing() throws {
        try check(charSpacing: nil, label: "no Tc")
    }

    /// THE REAL SHAPE. A `Tc` set on an earlier line, inside its own `q`/`Q`, and this line
    /// setting none of its own — exactly what -README's stream does, and the only structural
    /// difference between the reading that worked and the reading that put every word of a
    /// line at the line's own origin.
    ///
    /// `Tc` belongs to the text state, which `q` saves and `Q` restores, so the earlier
    /// line's value must not reach this one. A reader that carries it forward applies a
    /// per-character correction that was never in force here.
    @Test func anEarlierLinesCharacterSpacingDoesNotSurviveItsOwnQ() throws {
        try check(charSpacing: nil, label: "Tc restored at Q", earlierCharSpacing: "-0.0214")
    }
}
