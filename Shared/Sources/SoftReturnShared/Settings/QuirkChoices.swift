import CtrlKD
import Foundation

/// Batch 46 (Jon's quirks rulings, 2026-09-16): which of the engine's quirks are on — the app's defaults, and a
/// document's own choices over them. The quirks themselves, their names and their one-line descriptions are the
/// engine's (`QuirkRegistry.standard`); this is only the set of switches, stored and applied the same way on both apps.
///
/// Applied through `QuirkRegistry.applyQuirks` with mode `.off` and every switched-on name enabled, so the set is the
/// whole answer: nothing the engine's own mode would add on top. `shipped` is exactly the engine's `.auto` — the five
/// driver quirks on, stray style strikeout off — so a person who never opens Quirks gets the output they always had.
public struct QuirkChoices: Hashable, Sendable {
    /// Every quirk, the engine's order.
    public static var names: [String] { QuirkRegistry.standard.names() }

    /// The switched-on names.
    public private(set) var enabled: Set<String>

    public init<Names: Sequence>(enabled: Names) where Names.Element == String {
        let known = Set(Self.names)
        self.enabled = Set(enabled).intersection(known)
    }

    /// The engine's own defaults: every `auto`-class quirk, no `opt-in` one.
    public static let shipped = QuirkChoices(enabled: names.filter { QuirkRegistry.standard.quirk($0)?.quirkClass == .auto })
    public static let all = QuirkChoices(enabled: names)
    public static let off = QuirkChoices(enabled: [])

    /// Settings ▸ Quirks' segmented control. Custom is no set of its own: it is what the control shows when the
    /// switches match none of the other three.
    public enum Preset: String, CaseIterable, Hashable, Sendable {
        case auto, all, off, custom

        public var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .all: return "All"
            case .off: return "Off"
            case .custom: return "Custom"
            }
        }

        /// The switches a preset sets; nil for Custom.
        public var choices: QuirkChoices? {
            switch self {
            case .auto: return .shipped
            case .all: return .all
            case .off: return .off
            case .custom: return nil
            }
        }
    }

    public var preset: Preset {
        switch self {
        case .shipped: return .auto
        case .all: return .all
        case .off: return .off
        default: return .custom
        }
    }

    public func isOn(_ name: String) -> Bool { enabled.contains(name) }

    public mutating func set(_ name: String, on: Bool) {
        guard Self.names.contains(name) else { return }
        if on { enabled.insert(name) } else { enabled.remove(name) }
    }

    /// These switches with a document's own choices laid over them.
    public func overridden(by overrides: [String: Bool]) -> QuirkChoices {
        var result = self
        for (name, on) in overrides { result.set(name, on: on) }
        return result
    }

    /// `document` with these quirks applied and the decision recorded on it — the one call every parse goes through.
    public func apply(to document: CtrlKD.Document) -> CtrlKD.Document {
        let registry = QuirkRegistry.standard
        let enable = registry.names().filter(enabled.contains)
        // Every name comes from the registry itself, so the unknown-name error cannot happen; the unquirked document
        // is the safe answer if it ever did.
        return (try? registry.applyQuirks(to: document, enable: enable, mode: .off)) ?? document
    }

    /// The one-line description the rows show under a quirk's name — the engine's own words.
    public static func description(of name: String) -> String {
        QuirkRegistry.standard.quirk(name)?.description ?? ""
    }

    /// A quirk's row title, from the canvas (batch 46): the engine's name made readable.
    public static func title(of name: String) -> String {
        switch name {
        case QuirkName.euro: return "Euro sign"
        case QuirkName.ljTypography: return "LJ6DTP typography"
        case QuirkName.ljBoxCorners: return "LJ6DTP box corners"
        case QuirkName.ljColourAsGray: return "LJ6DTP colour as gray"
        case QuirkName.ljFillPatterns: return "LJ6DTP fill patterns"
        case QuirkName.strayStyleStrikeout: return "Stray style strikeout"
        default: return name
        }
    }
}

extension QuirkChoices: Codable {
    /// Stored as every quirk's name with its switch, so a quirk a later engine adds reads its shipped default rather
    /// than off.
    public init(from decoder: Decoder) throws {
        let stored = try [String: Bool](from: decoder)
        self = QuirkChoices.shipped.overridden(by: stored)
    }

    public func encode(to encoder: Encoder) throws {
        try Dictionary(uniqueKeysWithValues: Self.names.map { ($0, isOn($0)) }).encode(to: encoder)
    }
}
