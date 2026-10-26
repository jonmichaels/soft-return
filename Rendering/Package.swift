// swift-tools-version:6.0
import PackageDescription

// The renderer both apps draw documents with: the engine's output turned into text, pages and the
// pictures and rules drawn on them (Native, Modern, the Show Invisibles marks, Quick Look's engine
// half). The Mac app and its two extensions link it; the iPhone compiles the same sources into its
// own targets, beside the names it maps from AppKit to UIKit.
let package = Package(
    name: "SoftReturnRendering",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SoftReturnRendering", targets: ["SoftReturnRendering"]),
    ],
    dependencies: [
        .package(name: "CtrlKD", path: ".."),
        .package(name: "SoftReturnShared", path: "../Shared"),
    ],
    targets: [
        .target(
            name: "SoftReturnRendering",
            dependencies: [
                .product(name: "CtrlKD", package: "CtrlKD"),
                .product(name: "SoftReturnShared", package: "SoftReturnShared"),
            ]
        ),
    ]
)
