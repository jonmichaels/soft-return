/// One `Document.graphics` entry, resolved and (if found) decoded — the shared result
/// every emitter reads from, and the shape `--pictures`'s resolve step (which needs real
/// filesystem access — SoftReturnCLI, not this Foundation-free engine target) produces.
/// Direct port of `pictures.py`'s `PixResult` dataclass.
public struct PixResult: Hashable, Sendable {
    /// Why resolution/decoding did not reach a usable image.
    ///
    ///   `.unresolved`   -- no candidate file found near the document (or no document
    ///                      path was given to search from at all)
    ///   `.unreadable`   -- a path resolved but the file could not be read
    ///   `.textMode`     -- a real .PIX file, but an alphanumeric-capture variant this
    ///                      decoder does not implement
    ///   `.formatError`  -- a real file, but malformed or an unsupported shape
    public enum ErrorKind: String, Hashable, Sendable {
        case unresolved
        case unreadable
        case textMode = "text-mode"
        case formatError = "format-error"
    }

    public let index: Int
    public let rawPath: String
    public var resolvedPath: String?
    public var error: ErrorKind?
    /// The original .PIX file's bytes, kept (not just `png`) so a caller needing raw
    /// pixels (PDF's own Image XObject, built from `pixDecode`'s RGB rows rather than
    /// parsing PNG back out) can decode once more without re-resolving or re-reading.
    public var rawBytes: [UInt8]?
    public var png: [UInt8]?
    public var gcols: Int?
    public var grows: Int?
    /// From the print-options record only; `nil` means "caller picks a fallback".
    public var widthIn: Double?
    public var heightIn: Double?

    public var ok: Bool { png != nil }

    public init(index: Int, rawPath: String, resolvedPath: String? = nil,
               error: ErrorKind? = nil, rawBytes: [UInt8]? = nil, png: [UInt8]? = nil,
               gcols: Int? = nil, grows: Int? = nil, widthIn: Double? = nil,
               heightIn: Double? = nil) {
        self.index = index
        self.rawPath = rawPath
        self.resolvedPath = resolvedPath
        self.error = error
        self.rawBytes = rawBytes
        self.png = png
        self.gcols = gcols
        self.grows = grows
        self.widthIn = widthIn
        self.heightIn = heightIn
    }
}

/// `raw_path`'s own basename ("C:\PIX\FIGURE1.PIX" -> "FIGURE1.PIX") -- the alt text/tag
/// name shown in a miss report or an `<img alt>`. Port of `_pix_alt`/`_basename`.
public func pixBasename(_ rawPath: String) -> String {
    let normalized = rawPath.replacingAll("\\", with: "/")
    guard let slash = normalized.lastIndex(of: "/") else { return rawPath.isEmpty ? rawPath : normalized }
    let tail = String(normalized[normalized.index(after: slash)...])
    return tail.isEmpty ? rawPath : tail
}
