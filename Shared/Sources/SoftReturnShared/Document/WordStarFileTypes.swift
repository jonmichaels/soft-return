import Foundation

/// The file types Soft Return claims, in one place for both apps. Old WordStar files carry
/// whatever extension their author typed, or none, so this list decides only what the apps
/// DECLARE to the system (Info.plist) and what they list or pre-filter by name; whether a
/// file is really WordStar is the detector's call, never the name's.
///
/// The Info.plist declarations are build-time data and cannot call this type, so
/// `WordStarFileTypesTests` fails when either app's declaration drifts from it.
/// Matching is case-insensitive throughout: files off a DOS floppy are upper case.
public enum WordStarFileTypes {

    /// The UTI both apps export for a WordStar document.
    public static let documentUTI = "me.beforeti.wordstar-document"

    /// The UTI both apps export for a WordStar `.PIX` picture.
    public static let pictureUTI = "me.beforeti.wordstar-pix"

    /// The document extensions claimed for `documentUTI`, lower case: `.ws`, the numbered
    /// `.ws0`...`.ws9` (also WordStar's backups), `.wsd`, `.wsm`, and WordStar's own backup
    /// and temporary shapes `.ws-bak` and `.ws-$$$`.
    public static let documentExtensions: Set<String> = [
        "ws", "ws0", "ws1", "ws2", "ws3", "ws4", "ws5", "ws6", "ws7", "ws8", "ws9",
        "wsd", "wsm", "ws-bak", "ws-$$$",
    ]

    /// The extension claimed for `pictureUTI`. The format has no signature, so the
    /// extension is the only way to tell one.
    public static let pictureExtension = "pix"

    /// Everything claimed: the document extensions and the picture extension.
    public static let claimed: Set<String> = documentExtensions.union([pictureExtension])

    /// Whether the file name or URL ends in one of the claimed document extensions.
    public static func isDocument(_ url: URL) -> Bool {
        isDocument(name: url.lastPathComponent)
    }

    public static func isDocument(name: String) -> Bool {
        documentExtensions.contains(extensionOf(name))
    }

    /// Whether the file name or URL is a `.PIX` picture.
    public static func isPicture(_ url: URL) -> Bool {
        isPicture(name: url.lastPathComponent)
    }

    public static func isPicture(name: String) -> Bool {
        extensionOf(name) == pictureExtension
    }

    /// Whether the file name or URL ends in any claimed extension.
    public static func isClaimed(_ url: URL) -> Bool {
        isClaimed(name: url.lastPathComponent)
    }

    public static func isClaimed(name: String) -> Bool {
        claimed.contains(extensionOf(name))
    }

    private static func extensionOf(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}
