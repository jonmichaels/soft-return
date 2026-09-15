import CtrlKD
import Foundation

/// The standard error for a file we cannot read, phrased for someone holding a 1987
/// floppy rather than a stack trace. The spec asks that it mention the Inspector as the
/// diagnostic route.
///
/// Lifted out of the Mac app's `WSDocument` (an `NSDocument`) unchanged, so an iPhone
/// document can say exactly the same thing: nothing in it is AppKit.
public enum CannotOpenError {
    public static func make(fileName: String?, underlying: Error) -> NSError {
        let name = fileName.map { "“\($0)”" } ?? "That file"
        var reason = "\(name) doesn’t appear to be a WordStar or text document."
        if case ParseError.notConvertible(let variant, _, _) = underlying, variant == .binary {
            reason = "\(name) looks like binary data, not a document."
        }
        return NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
            NSLocalizedDescriptionKey: reason,
            NSLocalizedRecoverySuggestionErrorKey:
                "If you believe it is one, open it anyway and use the bottom bar’s variant "
                + "control to try a specific WordStar format.",
            NSUnderlyingErrorKey: underlying as NSError,
        ])
    }
}
