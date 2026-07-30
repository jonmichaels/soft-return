// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CtrlKD",
    products: [
        .library(name: "CtrlKD", targets: ["CtrlKD"]),
    ],
    targets: [
        .target(name: "CtrlKD"),
        .testTarget(name: "CtrlKDTests", dependencies: ["CtrlKD"]),
    ]
)
