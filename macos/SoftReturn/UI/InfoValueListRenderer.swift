import CtrlKD
import Foundation

/// Renders `InfoValue` (the `sr --diagnose` report tree) as a plain, indented key/value
/// list — the Inspector's "Diagnose" section (job 314: "the --diagnose JSON surface...
/// rendered as a readable list, since the Inspector is diagnose's app home"). Deliberately
/// NOT `ScriptingJSONRendering`'s JSON syntax (braces, quotes, commas): that renderer exists
/// for a SCRIPT to parse a reply; this is for a person reading a panel, so the punctuation
/// that exists only to satisfy JSON grammar is dropped in favour of indentation doing the
/// same job. Field names are kept verbatim (`variant`, `mt_lines`, ...) rather than
/// humanized — the same names `sr --diagnose` prints, on purpose, so what a person reads
/// here and what a script or a terminal shows never disagree.
enum InfoValueListRenderer {
    static func readableList(_ value: InfoValue) -> String {
        render(value, indent: 0)
    }

    private static func render(_ value: InfoValue, indent: Int) -> String {
        guard case .object(let fields) = value else {
            return pad(indent) + scalar(value)
        }
        guard !fields.isEmpty else { return pad(indent) + "—" }
        return fields.keys.sorted().map { key in
            renderField(key: key, value: fields[key]!, indent: indent)
        }.joined(separator: "\n")
    }

    private static func renderField(key: String, value: InfoValue, indent: Int) -> String {
        let label = pad(indent) + key + ":"
        switch value {
        case .object(let fields):
            guard !fields.isEmpty else { return label + " —" }
            let body = fields.keys.sorted()
                .map { renderField(key: $0, value: fields[$0]!, indent: indent + 1) }
                .joined(separator: "\n")
            return label + "\n" + body

        case .array(let items):
            guard !items.isEmpty else { return label + " —" }
            if items.allSatisfy(isScalar) {
                return label + " " + items.map(scalar).joined(separator: ", ")
            }
            let body = items.map { item -> String in
                guard case .object(let fields) = item else {
                    return pad(indent + 1) + "- " + scalar(item)
                }
                let inner = fields.keys.sorted()
                    .map { renderField(key: $0, value: fields[$0]!, indent: indent + 2) }
                    .joined(separator: "\n")
                return pad(indent + 1) + "-\n" + inner
            }.joined(separator: "\n")
            return label + "\n" + body

        default:
            return label + " " + scalar(value)
        }
    }

    /// Internal, not private: `InspectorRows` reuses this exact scalar-vs-container test when
    /// it builds the Diagnose section's rows, so the two renderers can never disagree about
    /// what counts as a leaf value.
    static func isScalar(_ value: InfoValue) -> Bool {
        switch value {
        case .object, .array: return false
        default: return true
        }
    }

    /// Internal, not private: shared with `InspectorRows` for the same reason as `isScalar`
    /// above — one formatting of a scalar `InfoValue`, not two that can drift apart.
    static func scalar(_ value: InfoValue) -> String {
        switch value {
        case .null: return "—"
        case .bool(let b): return b ? "Yes" : "No"
        case .int(let i): return String(i)
        case .double(let d): return String(format: "%.4g", d)
        case .string(let s): return s.isEmpty ? "—" : s
        case .array, .object: return "—"
        }
    }

    private static func pad(_ indent: Int) -> String { String(repeating: "  ", count: indent) }
}
