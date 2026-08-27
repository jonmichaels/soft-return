import CtrlKD
import Foundation

/// Where a displayed setting's current value came from.
///
/// The build spec fixes this vocabulary and its punctuation: **(Detected) / (Manual) /
/// (Default)**, parenthesized, shown after the value everywhere it appears — "WS5+
/// (Detected)", "Letter (Default)". It is one word of UI text, but it is the difference
/// between "the file says so" and "we guessed", which is the whole trust story for a
/// program that opens documents nobody can read any more.
///
/// Distinct from `CtrlKD.Provenance`, which has only the parser's own two cases, because
/// the app has a third: the user overrode it by hand.
enum SettingProvenance: String, Hashable, Sendable {
    /// The file itself said so — a dot command, or the byte-level detector.
    case detected
    /// The user chose it explicitly, overriding whatever was detected or defaulted.
    case manual
    /// Nothing said otherwise; this is the app's documented fallback.
    case `default`

    /// Lift the library's provenance into the app's three. `.manual` is only ever set by
    /// user action, so it has no counterpart to map from.
    init(_ library: CtrlKD.Provenance) {
        switch library {
        case .file:           self = .detected
        case .default:        self = .default
        // A `--page-settings` preset override: "declared-but-not-file" (engine commit
        // 45b9726) — something concretely determined the value, just not the document's
        // own dot commands, so it belongs with `.detected` rather than the "nothing said
        // otherwise" `.default` bucket.
        case .machineDefault: self = .detected
        }
    }

    /// The parenthesized suffix, including its leading space: `" (Detected)"`.
    var suffix: String {
        switch self {
        case .detected: return " (Detected)"
        case .manual:   return " (Manual)"
        case .default:  return " (Default)"
        }
    }

    /// Spoken form for accessibility labels, where parentheses would be read as
    /// punctuation noise: "WS5+, detected" beats "WS5+ open paren Detected close paren".
    var spokenSuffix: String {
        switch self {
        case .detected: return ", detected"
        case .manual:   return ", set manually"
        case .default:  return ", default"
        }
    }
}

/// A value together with where it came from. Each of the bottom bar's four controls is one
/// of these, and its display string is always `value + provenance.suffix`.
struct Resolved<Value: Equatable>: Equatable {
    var value: Value
    var provenance: SettingProvenance

    init(_ value: Value, _ provenance: SettingProvenance) {
        self.value = value
        self.provenance = provenance
    }

    /// Replace the value by user action — which by definition makes it `.manual`.
    mutating func setManually(_ newValue: Value) {
        value = newValue
        provenance = .manual
    }
}
