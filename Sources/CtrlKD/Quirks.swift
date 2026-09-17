/// Quirks: named, individually switchable departures from a literal reading of the bytes.
/// Port of ctrl-kd's `quirks.py`.
///
/// THE RULE THIS SERVES. The engine is faithful by default. A WordStar file's bytes say
/// what they say, and there are plenty of reasons someone would want what the file
/// actually asks for — so nothing here "cleans up" anything silently. What this adds is a
/// way to NAME each departure, say in plain words what it does, say why it applies to THIS
/// document, and let a caller turn it on or off one at a time.
///
/// TWO CLASSES, and the difference is evidence:
///
///   auto    The document's own bytes point at the change. A WS7 header names the printer
///           driver it was last printed through, and some of those drivers were patched so
///           that a given character PRINTS as something other than its code page says.
///           Reproducing what the paper showed IS the faithful answer for such a document,
///           so these are ON by default — but they are named, reported, and switchable, so
///           a reader who wants the raw code-page character can have it.
///
///   opt-in  Nothing in the file says the change is wanted; a person judged it from
///           context. These are OFF by default and stay off until a caller asks by name.
///
/// THE REGISTRY IS SHAPED LIKE `EmitterRegistry`, FOR THE SAME REASONS (`Registry.swift`):
/// a value-type struct with an immutable `.standard`, `register` returning a NEW registry,
/// and NO entry-point plugin discovery — a statically linked package has no installable
/// third-party quirks to find, and the dynamic-loading story is a host-application
/// decision about code signing and sandboxing, not a library one. A host registers what it
/// wants at startup. ctrl-kd's Python side DOES carry the entry-point path
/// (`ctrlkd.quirks`), exactly as it does for emitters, and for the same reason it can.
///
/// WHERE THE CODE LIVES. A quirk's `apply` is a whole-document transform, run once before
/// any emitter reads the blocks. The five driver-keyed quirks are the exception and say so
/// in their own comments: their substitutions were implemented, tested and ruled long
/// before quirks existed, threaded through the renderers at the points that know when to
/// apply them. Moving that code here would change nothing about the output and risk a
/// great deal, so it stayed where it is; those call sites ask `quirkEnabled(_:_:)`, and
/// this registry supplies the name, the reason, the reporting and the switch.

/// Whether a quirk is on because the document's own bytes point at it, or off until a
/// person asks for it. The raw values are the strings the CLI and the layout JSON use.
public enum QuirkClass: String, Hashable, Sendable {
    case auto
    case optIn = "opt-in"
}

/// The baseline a caller starts from, before any per-name `enable`/`disable`.
public enum QuirkMode: String, Hashable, Sendable {
    /// Every applicable `auto` quirk, and no `opt-in` one. The default, and what the
    /// engine did before quirks existed.
    case auto
    /// Nothing at all — the most literal reading of the bytes this converter can give.
    case off
    /// Every quirk this document trips, whichever class it is.
    case all
}

/// One named departure.
public struct Quirk: Sendable {
    /// kebab-case, and stable forever once shipped: it is what a caller types, what the
    /// layout JSON publishes, and what an app stores as a per-document override.
    public let name: String
    /// ONE line of plain language, shown to a user as-is. No internal vocabulary — an app
    /// puts this next to a checkbox, and a reader who has never heard of WordStar has to
    /// understand what turning it on does.
    public let description: String
    public let quirkClass: QuirkClass
    /// The REASON this document trips the quirk, in plain language ("last printed on the
    /// LJ6DTP driver"), or `nil` when it does not apply at all. Cheap: it runs on every
    /// document, quirks or not, so a report can always distinguish "applicable but off"
    /// from "not applicable".
    public let detect: @Sendable (Document) -> String?
    /// The transform. Swift's `Document` is a value type, so this cannot mutate anybody
    /// else's copy; returning the document unchanged is legitimate and means the effect is
    /// implemented at its render site, which asks `quirkEnabled(_:_:)`.
    public let apply: @Sendable (Document) -> Document

    public init(name: String, description: String, quirkClass: QuirkClass,
                detect: @escaping @Sendable (Document) -> String?,
                apply: @escaping @Sendable (Document) -> Document = { $0 }) {
        self.name = name
        self.description = description
        self.quirkClass = quirkClass
        self.detect = detect
        self.apply = apply
    }
}

/// One quirk a document trips, and why — the pair an app shows beside its checkbox.
public struct QuirkApplicability: Hashable, Sendable {
    public let name: String
    public let reason: String
    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// What a particular run decided: everything the document trips, and the subset in force.
/// Recorded on the `Document` (`Document.quirks`) so every later pass — the emitters, the
/// layout JSON's own report, a render site asking `quirkEnabled` — reads the SAME answer
/// rather than re-deriving it.
public struct QuirkDecision: Hashable, Sendable {
    public let applicable: [QuirkApplicability]
    public let applied: [String]
    public init(applicable: [QuirkApplicability], applied: [String]) {
        self.applicable = applicable
        self.applied = applied
    }
    public var applicableNames: [String] { applicable.map(\.name) }
}

/// One row of `QuirkRegistry.list(for:)` — everything a settings list needs to draw a line.
public struct QuirkListing: Hashable, Sendable {
    public let name: String
    public let description: String
    public let quirkClass: QuirkClass
    /// `nil` when the listing was asked for without a document.
    public let applicable: Bool?
    public let reason: String?
    public let enabled: Bool?
}

/// A caller named a quirk this build has never heard of — a typo, or a plugin that is not
/// installed. Carries what it asked for and what IS available, so a CLI or a GUI can say
/// something better than "error".
public enum QuirkError: Error, Hashable, Sendable {
    case unknownQuirk(name: String, known: [String])
}

/// A set of known quirks. Value semantics, deliberately — see `EmitterRegistry`'s own
/// reasoning, which applies here word for word.
public struct QuirkRegistry: Sendable {
    private var order: [String]
    private var quirks: [String: Quirk]

    private init(order: [String], quirks: [String: Quirk]) {
        self.order = order
        self.quirks = quirks
    }

    /// The six built-in quirks, in the order every listing and every report uses.
    public static let standard = QuirkRegistry(
        order: builtInQuirks.map(\.name),
        quirks: Dictionary(uniqueKeysWithValues: builtInQuirks.map { ($0.name, $0) }))

    /// Add a quirk, returning a new registry. Registering a name that already exists
    /// replaces it in place, keeping its position in the order.
    public func register(_ quirk: Quirk) -> QuirkRegistry {
        var copy = self
        if copy.quirks[quirk.name] == nil { copy.order.append(quirk.name) }
        copy.quirks[quirk.name] = quirk
        return copy
    }

    /// THE NAMES THAT SHIPPED IN 4.4.0, still ACCEPTED AS INPUT. Jon's ruling 2026-09-17:
    /// a quirk's identifier is shipped text like any other — it is what a reader types on
    /// the command line, what `--list-quirks` prints, and what the layout JSON publishes —
    /// so it gets the same plain-English, US-spelling treatment the descriptions got. Five
    /// of the six old names also said something untrue or unhelpful: three began
    /// `lj6dtp-`, naming ONE printer driver for a behaviour a reader sees as a property of
    /// their document, and two (`driver-`, `stray-style-`) described the engine's own
    /// plumbing rather than the effect.
    ///
    /// The old names cannot simply vanish: an app released before the rename has them
    /// written into every user's stored per-document overrides. So they are mapped on the
    /// way IN and never produced on the way OUT — `--quirk`/`--no-quirk`, a name read back
    /// from stored settings, and `quirk(_:)` all resolve them, while the registry,
    /// `--list-quirks`, the layout JSON's `quirks_applicable`/`quirks_applied` and every
    /// report say only the new name. ONE DIRECTION, so the two spellings can never both
    /// appear in one output.
    static let aliases: [String: String] = [
        "driver-euro-sign": QuirkName.euroSwap,
        "lj6dtp-typography": QuirkName.smartPunctuation,
        "lj6dtp-box-corners": QuirkName.boxCorners,
        "lj6dtp-colour-as-gray": QuirkName.colorsAsGray,
        "lj6dtp-fill-patterns": QuirkName.fillPatterns,
        "stray-style-strikeout": QuirkName.sawyerStrikeout,
    ]

    /// The name this build knows a quirk by, mapping a retired name to its
    /// replacement. Anything else is handed back untouched — an unknown name is
    /// `resolve`'s error to raise, not this function's.
    public static func canonicalName(_ name: String) -> String {
        aliases[name] ?? name
    }

    public func quirk(_ name: String) -> Quirk? { quirks[Self.canonicalName(name)] }

    /// Every registered name, registration order — for CLI help and for a settings list.
    public func names() -> [String] { order }

    /// `(name, reason)` for every quirk this document trips, registration order.
    /// Independent of what any caller enabled: this is the answer to "what does this file
    /// have available", which is what lets an app offer the choice on a plain, faithful run.
    public func applicable(to doc: Document) -> [QuirkApplicability] {
        order.compactMap { name in
            guard let reason = quirks[name]?.detect(doc), !reason.isEmpty else { return nil }
            return QuirkApplicability(name: name, reason: reason)
        }
    }

    /// Decide what runs for this document.
    ///
    /// Naming a quirk this document does not trip is a NO-OP, not an error — a caller may
    /// hold one standing list and hand it to every document (an app's own settings do
    /// exactly that). Naming one that is not registered at all IS an error: that is a typo
    /// or a missing plugin, and swallowing it would silently give the caller output it did
    /// not ask for.
    public func resolve(_ doc: Document, enable: [String] = [], disable: [String] = [],
                        mode: QuirkMode = .auto) throws -> QuirkDecision {
        // Canonicalised FIRST, so a caller naming a retired spelling (an app's stored
        // overrides from before a rename) selects the same quirk the registry, the report
        // and the layout JSON all name the new way. See `aliases`.
        let enable = enable.map(Self.canonicalName)
        let disable = disable.map(Self.canonicalName)
        for name in enable + disable where quirks[name] == nil {
            throw QuirkError.unknownQuirk(name: name, known: order)
        }
        let applic = applicable(to: doc)
        var applied: [String] = []
        for row in applic {
            guard !disable.contains(row.name), let q = quirks[row.name] else { continue }
            let on = enable.contains(row.name) || mode == .all
                || (mode == .auto && q.quirkClass == .auto)
            if on { applied.append(row.name) }
        }
        return QuirkDecision(applicable: applic, applied: applied)
    }

    /// `doc` with the resolved quirks applied and the decision recorded on it. A host
    /// calls this ONCE, right after parsing, before handing the document to any emitter.
    /// A caller that never calls it gets the default decision anyway (`quirkEnabled` falls
    /// back to "applicable auto quirks are on"), which is byte-identical to the engine
    /// before quirks existed.
    public func applyQuirks(to doc: Document, enable: [String] = [], disable: [String] = [],
                            mode: QuirkMode = .auto) throws -> Document {
        let decision = try resolve(doc, enable: enable, disable: disable, mode: mode)
        var out = doc
        out.quirks = decision
        for name in decision.applied {
            guard let q = quirks[name] else { continue }
            out = q.apply(out)
            // apply() may rebuild the document; the decision has to survive it.
            out.quirks = decision
        }
        return out
    }

    /// Every registered quirk as a row. With a `doc`, each row also carries whether it
    /// applies to that document, why, and whether it is in force.
    public func list(for doc: Document? = nil) -> [QuirkListing] {
        let reasons: [String: String]
        let on: Set<String>
        if let doc {
            reasons = Dictionary(uniqueKeysWithValues:
                applicable(to: doc).map { ($0.name, $0.reason) })
            on = Set(quirkDecision(doc, registry: self).applied)
        } else {
            reasons = [:]
            on = []
        }
        return order.compactMap { name in
            guard let q = quirks[name] else { return nil }
            return QuirkListing(name: q.name, description: q.description,
                                quirkClass: q.quirkClass,
                                applicable: doc == nil ? nil : reasons[name] != nil,
                                reason: doc == nil ? nil : reasons[name],
                                enabled: doc == nil ? nil : on.contains(name))
        }
    }
}

/// The decision in force for `doc`: the one a host recorded, or the default one.
public func quirkDecision(_ doc: Document,
                          registry: QuirkRegistry = .standard) -> QuirkDecision {
    if let recorded = doc.quirks { return recorded }
    return (try? registry.resolve(doc)) ?? QuirkDecision(applicable: [], applied: [])
}

/// Is `name` in force for this document? The question every render site that implements an
/// auto quirk asks.
///
/// The unrecorded case answers from THAT quirk alone rather than resolving the whole set:
/// this is called from inside the PDF writer's own per-document setup, and a document with
/// no recorded decision must not pay for detecting five other quirks to learn about one.
public func quirkEnabled(_ doc: Document, _ name: String) -> Bool {
    if let recorded = doc.quirks { return recorded.applied.contains(name) }
    guard let q = QuirkRegistry.standard.quirk(name) else { return false }
    return q.quirkClass == .auto && q.detect(doc) != nil
}

// ------------------------------------------------------------- the driver quirks
//
// All five were shipped, tested and ruled before quirks mode existed (Jon's ruling
// 2026-09-11 for the euro; register entry C7 and the 2026-08-06 M7 ruling for the LJ6DTP
// substitutions). Their `apply` returns the document unchanged ON PURPOSE: the transforms
// live at the call sites that know when to run them — `pesetaMeansEuro`,
// `modernSemanticFlow`, `driverSubstituter`, `ljSubstitute`, and the PDF writer's own
// colour and pattern resources — and those sites ask `quirkEnabled`.
//
// WHY DETECTION IS THE DRIVER NAME ALONE, and not "does this file contain the character
// the swap would change". Two reasons, and the second decides it:
//
//  1. It IS the provenance a reader should be shown. A document whose own header names a
//     patched driver has these swaps available whether or not today's text happens to use
//     the affected characters — "this document's own printer header triggered three
//     automatic changes" is the thing worth telling, and a narrower test would hide it on
//     exactly the files it explains.
//  2. `quirkEnabled` then reads EXACTLY the predicate these call sites already used before
//     quirks existed (the driver name, in the patched set), so the switch adds a name and
//     a report without being able to change one byte of anybody's output by default.

private func driverName(_ doc: Document) -> String {
    (doc.printerDriver ?? "").trimmed().uppercased()
}

/// Name constants, so a render site and the registry can never disagree by a typo.
public enum QuirkName {
    public static let euroSwap = "euro-swap"
    public static let smartPunctuation = "smart-punctuation"
    public static let boxCorners = "box-corners"
    public static let colorsAsGray = "colors-as-gray"
    public static let fillPatterns = "fill-patterns"
    public static let sawyerStrikeout = "sawyer-strikeout"
}

private let detectEuro: @Sendable (Document) -> String? = { doc in
    let name = driverName(doc)
    guard euroPatchedDrivers.contains(name) else { return nil }
    return "last printed on the \(name) driver, one of the three that were patched to "
        + "print a euro in the peseta character\u{2019}s slot"
}

private let detectLJ6DTP: @Sendable (Document) -> String? = { doc in
    driverName(doc) == "LJ6DTP" ? "last printed on the LJ6DTP driver" : nil
}

// ----------------------------------------------------- the stray strike quirk

/// Did the WRITER type a cross-out? `Span.styles` carries only what the typist toggled
/// inline (WordStar's `^PX`, byte 0x18); a paragraph style's own attribute word arrives
/// separately, on `Block.styleAttrs`. That separation is the whole basis of this quirk: it
/// can tell a cross-out somebody meant from one a style declared.
private func typedStrike(_ doc: Document) -> Bool {
    for block in doc.blocks {
        for line in block.lines where line.spans.contains(where: { $0.styles.contains(.strike) }) {
            _ = line
            return true
        }
    }
    return false
}

private let detectStrayStyleStrikeout: @Sendable (Document) -> String? = { doc in
    guard !typedStrike(doc) else { return nil }
    let struck = doc.blocks.filter { $0.styleAttrs.contains(.strike) }
    guard !struck.isEmpty else { return nil }
    let name = struck.compactMap(\.styleName).first
    let where_ = name.map { "the paragraph style '\($0)' turns it on" }
        ?? "a paragraph style turns it on"
    return "\(where_) and the writing never types a cross-out of its own"
}

/// Drop the style-declared strikeout, and only that.
///
/// Every other attribute a style declares is untouched, and so is every attribute the
/// writer typed: `detect` has already established there is no typed cross-out anywhere in
/// this document, so removing `.strike` from the paragraph styles' own attribute sets
/// cannot take away a cross-out anybody meant. Bold, italic and underline declared by the
/// SAME style survive — a manuscript heading style that is strike plus bold stays bold.
private let applyStrayStyleStrikeout: @Sendable (Document) -> Document = { doc in
    var out = doc
    for i in out.blocks.indices where out.blocks[i].styleAttrs.contains(.strike) {
        out.blocks[i].styleAttrs.remove(.strike)
    }
    // The STYLE LIBRARY's own derived attribute set, too — the RTF `\stylesheet` group and
    // the generated per-style CSS are built from `StyleRecord.attrs`, not from the blocks,
    // so a style left declaring a strike there would put the line back through the
    // reader's own style application. The RAW record words (`attrsOn`/`attrsOff`) are
    // deliberately NOT touched: those are a pass-through of the file's own bytes, and the
    // bytes really do say strikeout — this quirk changes what is RENDERED, never what the
    // document is recorded as saying.
    for i in out.styles.indices {
        guard var record = out.styles[i].record, record.attrs.contains(.strike) else { continue }
        record.suppressedAttrs.insert(.strike)
        out.styles[i] = StyleEntry(name: out.styles[i].name, slot: out.styles[i].slot,
                                   record: record)
    }
    // Running heads and feet carry the same style-declared attributes on their own
    // parallel maps — a head set in a struck style would otherwise keep the line.
    out.headerStyleAttrs = out.headerStyleAttrs.mapValues { $0.subtracting(.strike) }
    out.footerStyleAttrs = out.footerStyleAttrs.mapValues { $0.subtracting(.strike) }
    out.headerStyleAttrsParity = out.headerStyleAttrsParity.mapValues {
        $0.mapValues { $0.subtracting(.strike) } }
    out.footerStyleAttrsParity = out.footerStyleAttrsParity.mapValues {
        $0.mapValues { $0.subtracting(.strike) } }
    return out
}

let builtInQuirks: [Quirk] = [
    Quirk(name: QuirkName.euroSwap,
          description: "Euro instead of peseta",
          quirkClass: .auto, detect: detectEuro),
    Quirk(name: QuirkName.smartPunctuation,
          description: "Real dashes, curly quotes, ellipsis, \u{00A9}",
          quirkClass: .auto, detect: detectLJ6DTP),
    Quirk(name: QuirkName.boxCorners,
          description: "Card suits as box corners (Univers)",
          quirkClass: .auto, detect: detectLJ6DTP),
    Quirk(name: QuirkName.colorsAsGray,
          description: "Screen colors as gray",
          quirkClass: .auto, detect: detectLJ6DTP),
    Quirk(name: QuirkName.fillPatterns,
          description: "Colors 9\u{2013}14 as hatch patterns",
          quirkClass: .auto, detect: detectLJ6DTP),
    Quirk(name: QuirkName.sawyerStrikeout,
          description: "Ignore a strikeout set only by a style",
          quirkClass: .optIn, detect: detectStrayStyleStrikeout,
          apply: applyStrayStyleStrikeout),
]

/// The four LJ6DTP swaps as four booleans, resolved ONCE per render at the PDF writer's
/// own entry points and carried down rather than asked again per line. The code that DOES
/// each swap is unchanged and still lives where it did; these only decide whether it runs.
public struct DriverQuirks: Hashable, Sendable {
    public let typography: Bool
    public let corners: Bool
    public let colour: Bool
    public let patterns: Bool

    /// Neither the Modern PDF path nor any non-LJ6DTP document applies any of them.
    public static let none = DriverQuirks(typography: false, corners: false,
                                          colour: false, patterns: false)

    public init(typography: Bool, corners: Bool, colour: Bool, patterns: Bool) {
        self.typography = typography
        self.corners = corners
        self.colour = colour
        self.patterns = patterns
    }

    public init(_ doc: Document) {
        self.init(typography: quirkEnabled(doc, QuirkName.smartPunctuation),
                  corners: quirkEnabled(doc, QuirkName.boxCorners),
                  colour: quirkEnabled(doc, QuirkName.colorsAsGray),
                  patterns: quirkEnabled(doc, QuirkName.fillPatterns))
    }

    /// Whether either CHARACTER family is in force — the gate `ljSubstitute` sits behind.
    public var characters: Bool { typography || corners }
}
