// swift-tools-version:5.9
import PackageDescription

// What every test target in the repo shares and none owns: where the corpus variables are
// read (and what a Skip or a loud failure says), where the repo root is, and a scratch
// directory that cleans up after itself.
//
// Foundation only, and no `Testing` or `XCTest` import: the engine and Shared test targets,
// the Mac app's tests and the iPhone app's tests all consume it, and each of those picks its
// own test framework. The one thing that needs `Testing` (a trait that cites the skip
// message) is a few lines in each test target; `docs/TESTING.md` shows it.
//
// Tools version 5.9, the engine package's own: SwiftPM reads every dependency's manifest before it builds anything,
// so a 6.0 manifest here stopped `brew install sr` on Swift 5.10 (macOS 14's Xcode 15.4) even though `sr` never builds
// this package (v4.6.0, planning #585).
//
// Floors: macOS 10.15 because the engine package (`../Package.swift`) tests at that floor and
// SwiftPM refuses a target that depends on a product with a higher one; iOS 16 is the
// iPhone app's. Nothing here needs more than that.
let package = Package(
    name: "TestSupport",
    platforms: [.macOS(.v10_15), .iOS(.v16)],
    products: [
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    targets: [
        .target(name: "TestSupport"),
        .testTarget(name: "TestSupportTests", dependencies: ["TestSupport"]),
    ]
)
