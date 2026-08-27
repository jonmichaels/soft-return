import AppKit

let appPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

guard let bundle = Bundle(path: appPath) else {
    print("FAIL: could not open bundle at \(appPath)")
    exit(1)
}

guard let image = bundle.image(forResource: "SoftReturn") else {
    print("FAIL: bundle.image(forResource: \"SoftReturn\") returned nil")
    exit(1)
}

print("image size: \(image.size)")
print("representations: \(image.representations.count)")
for rep in image.representations {
    print("  \(rep.pixelsWide)x\(rep.pixelsHigh)")
}

guard let best = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) else {
    print("FAIL: no representations")
    exit(1)
}
let size = NSSize(width: best.pixelsWide, height: best.pixelsHigh)
let flat = NSImage(size: size)
flat.addRepresentation(best)

guard let tiff = flat.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("FAIL: could not render PNG")
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath): \(best.pixelsWide)x\(best.pixelsHigh)")
