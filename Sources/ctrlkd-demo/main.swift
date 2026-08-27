import CtrlKD

// Proof of life for the milestone: raw WordStar bytes -> Document -> Markdown, with no
// files and no dependencies. Run with `swift run ctrlkd-demo`.
//
// The fixture is built byte-by-byte here, the way a WS4 file actually looks on disk:
// bit 7 set on the last character of every word, ^B toggles around the title, a soft
// return where WordStar word-wrapped, and a hard return ending the paragraph.

/// WS4 sets bit 7 on the last character of each word ("microjustify" flags).
func ws4(_ text: String) -> [UInt8] {
    text.split(separator: " ", omittingEmptySubsequences: false)
        .map { word -> [UInt8] in
            var bytes = Array(word.utf8)
            if !bytes.isEmpty { bytes[bytes.count - 1] |= 0x80 }
            return bytes
        }
        .joined(separator: [0x20])
        .map { $0 }
}

let boldToggle: [UInt8] = [0x02]
let soft: [UInt8] = [0x8d, 0x0a]
let hard: [UInt8] = [0x0d, 0x0a]

var document: [UInt8] = boldToggle + ws4("Treaty Of Fort Laramie") + boldToggle
document += hard + hard
document += ws4("The commission met at the fort in the spring and the terms were read") + soft
document += ws4("aloud to everyone assembled there.") + hard
document += [0x1a]        // ^Z end-of-file marker, as WordStar wrote it

/// Two-digit hex without Foundation's `String(format:)`, keeping the demo as
/// dependency-free as the library.
func hex(_ byte: UInt8) -> String {
    let digits = "0123456789abcdef"
    let hi = digits[digits.index(digits.startIndex, offsetBy: Int(byte >> 4))]
    let lo = digits[digits.index(digits.startIndex, offsetBy: Int(byte & 0x0F))]
    return String(hi) + String(lo)
}

print("--- raw bytes (\(document.count)) ---")
print(document.map(hex).joined(separator: " "))

let detection = detect(document)
print("\n--- detect ---")
print("variant: \(detection.variant.rawValue)  high-bit bytes: \(detection.highBitBytes)  "
      + "soft returns: \(detection.softReturns)  text: \(detection.textPct)%")

let doc = try parse(document)
print("\n--- document ---")
print("blocks: \(doc.blocks.count)  margin estimate: \(doc.marginEstimate.map(String.init) ?? "n/a")")

print("\n--- markdown ---")
print(emitMarkdown(doc), terminator: "")

print("--- text ---")
print(emitText(doc), terminator: "")
