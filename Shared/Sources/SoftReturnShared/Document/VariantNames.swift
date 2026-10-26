import CtrlKD

/// The words for what kind of WordStar file a document is, in the three lengths the apps use.
/// One table each, shared by the Mac's bottom bar and Document Info and the iPhone's lists.
extension Variant {
    /// The Mac bottom bar's: "WS4", "WS5+", "Printstream", "Text", "Binary".
    public var shortName: String {
        switch self {
        case .ws4: return "WS4"
        case .ws5plus: return "WS5+"
        case .printstream: return "Printstream"
        case .text: return "Text"
        case .binary: return "Binary"
        }
    }

    /// A list row's: "WordStar 4", "WordStar 5+", "WordStar print stream", "Plain text",
    /// "Binary data".
    public var longName: String {
        switch self {
        case .ws4: return "WordStar 4"
        case .ws5plus: return "WordStar 5+"
        case .printstream: return "WordStar print stream"
        case .text: return "Plain text"
        case .binary: return "Binary data"
        }
    }

    /// Document Info's Kind row: "WordStar 4 document", … "Not a document".
    public var kindName: String {
        switch self {
        case .ws4: return "WordStar 4 document"
        case .ws5plus: return "WordStar 5+ document"
        case .printstream: return "WordStar print stream"
        case .text: return "Plain text"
        case .binary: return "Not a document"
        }
    }
}
