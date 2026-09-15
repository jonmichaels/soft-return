// swift-tools-version:6.0
import PackageDescription

// The app code both apps share: the document model, its provenance and restoration
// model, the settings store, and the open/convert/diagnose operations layer. Everything
// here must build for macOS AND iOS, so nothing here may import AppKit or UIKit — the
// iOS app's build enforces that for real, and `NoAppKitBoundaryTests` catches it on a
// Mac-only `swift test` before anyone gets that far.
//
// Floors are the apps' own, not the engine's: macOS 13 (the Mac app's deployment target)
// and iOS 16 (the iPhone app's, Jon's ruling 2026-08-30).
let package = Package(
    name: "SoftReturnShared",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SoftReturnShared", targets: ["SoftReturnShared"]),
    ],
    dependencies: [
        // The engine, one directory up — local path, no pin, the same way `macos/`
        // consumes it. Named so the product reference below does not depend on what the
        // checkout's directory happens to be called.
        .package(name: "CtrlKD", path: ".."),
    ],
    targets: [
        .target(
            name: "SoftReturnShared",
            dependencies: [.product(name: "CtrlKD", package: "CtrlKD")]
        ),
        .testTarget(
            name: "SoftReturnSharedTests",
            dependencies: ["SoftReturnShared"]
        ),
    ]
)
