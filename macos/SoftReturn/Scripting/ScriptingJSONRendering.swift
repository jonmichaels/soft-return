import CtrlKD
import Foundation

/// Job 216 (b12 leg A, ae-result-shape): renders `CtrlKD.InfoValue` as JSON text, in the
/// exact documented shape `SoftReturnCLI.JSONValue.render()` (the `sr --diagnose` output)
/// promises — keys sorted, two-space indent, non-ASCII emitted as UTF-8 rather than
/// `\uXXXX`. `SoftReturnCLI` is a regular (non-executable) SPM target in the `soft-return`
/// engine repo, but that repo's `Package.swift` only declares `CtrlKD` as a `product` —
/// `SoftReturnCLI` itself is not importable across the package boundary from this app, so
/// this is a faithful, independently-maintained REPLICA of `JSONValue.render()`'s algorithm
/// (verified line-for-line against `Sources/SoftReturnCLI/JSON.swift` in the engine repo at
/// the commit this app currently depends on), not a shortcut — see the job report for why a
/// second copy was necessary rather than a shared dependency.
///
/// `diagnose`/`import page settings` both need this: job 216's field-notes exemplar survey
/// (NetNewsWire/Skim) found no shipping app auto-packages a CUSTOM sdef record type as a
/// command reply — `text` is one of the shapes Cocoa provably packages (see
/// `DiagnosisScripting.descriptor(from:)`'s old doc comment for the record-type defect this
/// replaces). Both commands' results are exactly the same `InfoValue` tree diagnose already
/// computes/exposes, so one renderer serves both.
enum ScriptingJSONRendering {
    static func render(_ value: InfoValue) -> String {
        render(value, indent: 0)
    }

    private static func render(_ value: InfoValue, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .string(let s):
            return quote(s)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let body = items.map { inner + render($0, indent: indent + 2) }.joined(separator: ",\n")
            return "[\n" + body + "\n" + pad + "]"
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            let body = fields.keys.sorted().map { key in
                inner + quote(key) + ": " + render(fields[key]!, indent: indent + 2)
            }.joined(separator: ",\n")
            return "{\n" + body + "\n" + pad + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00" + hex2(UInt8(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func hex2(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
