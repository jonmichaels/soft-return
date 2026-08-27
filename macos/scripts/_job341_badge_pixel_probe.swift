import AppKit

func render(_ symbolName: String, color: NSColor) -> NSBitmapImageRep? {
    guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
    let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        .applying(.init(paletteColors: [color]))
    guard let configured = base.withSymbolConfiguration(config) else { return nil }
    guard let tiff = configured.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep
}

for name in ["circle.fill", "circle"] {
    guard let rep = render(name, color: .labelColor) else {
        print("\(name): FAILED to render")
        continue
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let center = rep.colorAt(x: w / 2, y: h / 2)
    print("\(name): size=\(w)x\(h) centerAlpha=\(center?.alphaComponent ?? -1)")
}
