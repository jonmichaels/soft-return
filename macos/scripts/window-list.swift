// Lists on-screen windows as JSON, so a script can turn an app name into the
// window ID that `screencapture -l` wants.
//
// Usage:
//   swift macos/scripts/window-list.swift              # every on-screen window
//   swift macos/scripts/window-list.swift "Soft Return" # windows whose owner matches
//
// Enumeration itself needs no permission. Window TITLES do: macOS gates them
// behind Screen Recording for the CALLING process, and — measured on this Mac,
// 2026-08-02 — a grant that lets `screencapture` work does NOT extend to a
// binary we compile ourselves. Every layer-0 title came back empty while
// `screencapture -l` captured those same windows fine.
//
// So callers must NOT match on title. Match on ownerName (never gated) plus
// layer 0, which is what screenshot-window.sh does.

import CoreGraphics
import Foundation

let filter = CommandLine.arguments.dropFirst().first

guard
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("window-list: CGWindowListCopyWindowInfo returned nothing\n".utf8))
    exit(1)
}

struct Window: Encodable {
    let windowID: UInt32
    let ownerName: String
    let ownerPID: Int
    let title: String
    let layer: Int
    let x: Double, y: Double, width: Double, height: Double
}

let windows: [Window] = raw.compactMap { info in
    guard
        let id = info[kCGWindowNumber as String] as? UInt32,
        let bounds = info[kCGWindowBounds as String] as? [String: Double]
    else { return nil }

    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    if let filter, !owner.localizedCaseInsensitiveContains(filter) { return nil }

    return Window(
        windowID: id,
        ownerName: owner,
        ownerPID: info[kCGWindowOwnerPID as String] as? Int ?? -1,
        title: info[kCGWindowName as String] as? String ?? "",
        layer: info[kCGWindowLayer as String] as? Int ?? 0,
        x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
        width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
    )
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(windows))
FileHandle.standardOutput.write(Data("\n".utf8))
