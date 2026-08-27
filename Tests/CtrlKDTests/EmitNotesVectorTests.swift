import Foundation
import Testing
@testable import CtrlKD

/// Byte-parity proof for the ctrl-kd 1.2.0 note-rendering port, against the SAME
/// `Fixtures/notes-vectors-1.2.0.json` `NotesVectorTests.swift` reads for `notes[]`/`meta`
/// — this file decodes the `emit` field that one deliberately leaves alone ("`emit`...
/// belong to later lanes... not decoded or asserted here"). Six cases × four formats
/// (text/markdown/html/rtf) × three note settings (default/all_notes/no_notes) = 72
/// string-equality assertions, one per `emit.<format>.<setting>` value in the fixture.
///
/// `Foundation` is imported here for `JSONDecoder`/`Bundle` only; the `CtrlKD` library
/// target itself stays Foundation-free.

private struct EmitVectorFile: Decodable {
    let generator: String
    let cases: [String: EmitVectorCase]
}

private struct EmitVectorCase: Decodable {
    let inputHex: String
    let emit: EmitByFormat

    enum CodingKeys: String, CodingKey {
        case inputHex = "input_hex"
        case emit
    }
}

private struct EmitByFormat: Decodable {
    let text: EmitBySetting
    let markdown: EmitBySetting
    let html: EmitBySetting
    let rtf: EmitBySetting
}

/// The same three note-selection settings the task brief names, decoded together so a
/// caller can index by the name rather than repeat three `if`s per format.
private struct EmitBySetting: Decodable {
    let defaultSetting: String
    let allNotes: String
    let noNotes: String

    enum CodingKeys: String, CodingKey {
        case defaultSetting = "default"
        case allNotes = "all_notes"
        case noNotes = "no_notes"
    }

    func expected(for setting: NoteSetting) -> String {
        switch setting {
        case .default: return defaultSetting
        case .allNotes: return allNotes
        case .noNotes: return noNotes
        }
    }
}

/// The three settings the vectors exercise, paired with the `EmitOptions` each names.
private enum NoteSetting: String, CaseIterable {
    case `default`
    case allNotes = "all_notes"
    case noNotes = "no_notes"

    var options: EmitOptions {
        switch self {
        case .default: return EmitOptions()
        case .allNotes: return EmitOptions(notes: EmitOptions.allNotes)
        case .noNotes: return EmitOptions(notes: EmitOptions.noNotes)
        }
    }
}

private func bytesFromHex(_ hex: String) -> [UInt8] {
    let chars = Array(hex)
    precondition(chars.count % 2 == 0, "hex string must have an even length")
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    for i in stride(from: 0, to: chars.count, by: 2) {
        out.append(UInt8(String(chars[i...(i + 1)]), radix: 16)!)
    }
    return out
}

@Test func notesVectorsEmit1_2_0() throws {
    let url = try #require(
        Bundle.module.url(forResource: "notes-vectors-1.2.0", withExtension: "json"),
        "notes-vectors-1.2.0.json missing from the test bundle"
    )
    let file = try JSONDecoder().decode(EmitVectorFile.self, from: Data(contentsOf: url))
    #expect(file.generator == "ctrl-kd 1.2.0")
    #expect(file.cases.count == 6)

    for name in file.cases.keys.sorted() {
        let v = file.cases[name]!
        let doc = parseWS(bytesFromHex(v.inputHex))

        for setting in NoteSetting.allCases {
            let options = setting.options
            let label = "\(name)/\(setting.rawValue)"

            #expect(emitText(doc, options: options) == v.emit.text.expected(for: setting),
                    "\(label): text")
            #expect(emitMarkdown(doc, options: options) == v.emit.markdown.expected(for: setting),
                    "\(label): markdown")
            #expect(emitHTML(doc, options: options) == v.emit.html.expected(for: setting),
                    "\(label): html")
            #expect(emitRTF(doc, options: options) == v.emit.rtf.expected(for: setting),
                    "\(label): rtf")
        }
    }
}

/// Task item 3, directly: the `stray_sentinel` case's degraded reference must not crash —
/// or hang, or throw — in ANY of the four formats, at ANY note setting (the guard has to
/// hold whether or not the caller even asked to see notes). `notesVectorsEmit1_2_0` above
/// already proves the exact output; this is the explicit "does not crash" statement the
/// task brief asks for, isolated from the 71 other assertions so a reader doesn't have to
/// infer it from a byte-equality pass.
@Test func straySentinelNeverCrashesInAnyFormatOrSetting() throws {
    let url = try #require(Bundle.module.url(forResource: "notes-vectors-1.2.0", withExtension: "json"))
    let file = try JSONDecoder().decode(EmitVectorFile.self, from: Data(contentsOf: url))
    let v = try #require(file.cases["stray_sentinel"])
    let doc = parseWS(bytesFromHex(v.inputHex))

    for setting in NoteSetting.allCases {
        let options = setting.options
        _ = emitText(doc, options: options)
        _ = emitMarkdown(doc, options: options)
        _ = emitHTML(doc, options: options)
        _ = emitRTF(doc, options: options)
    }
    // Reaching here without crashing/hanging/throwing IS the assertion; nothing to #expect.
}
