import AppKit

let path = CommandLine.arguments[1]
guard let data = FileManager.default.contents(atPath: path),
      let rep = NSBitmapImageRep(data: data) else {
    print("FAIL: could not load \(path)")
    exit(1)
}

let w = rep.pixelsWide
let h = rep.pixelsHigh
print("size: \(w)x\(h)")

let corners: [(String, Int, Int)] = [
    ("top-left", 0, 0),
    ("top-right", w - 1, 0),
    ("bottom-left", 0, h - 1),
    ("bottom-right", w - 1, h - 1),
]

for (name, x, y) in corners {
    if let color = rep.colorAt(x: x, y: y) {
        print("\(name) (\(x),\(y)) alpha=\(color.alphaComponent)")
    } else {
        print("\(name) (\(x),\(y)) alpha=<nil colorAt>")
    }
}
