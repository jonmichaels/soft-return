import AppKit

let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "test")
print("name: \(image?.name() ?? "nil")")

let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    .applying(.init(paletteColors: [NSColor.labelColor]))
let configured = image?.withSymbolConfiguration(config)
print("configured name: \(configured?.name() ?? "nil")")
print("isTemplate: \(configured?.isTemplate ?? false)")
