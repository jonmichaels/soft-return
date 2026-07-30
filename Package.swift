// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CtrlKD",
    products: [
        .library(name: "CtrlKD", targets: ["CtrlKD"]),
    ],
    targets: [
        .target(name: "CtrlKD"),
        // Proof-of-life demo: `swift run ctrlkd-demo` converts synthetic WS4 bytes
        // to Markdown. Not part of the library product.
        .executableTarget(name: "ctrlkd-demo", dependencies: ["CtrlKD"]),
        .testTarget(
            name: "CtrlKDTests",
            dependencies: ["CtrlKD"],
            exclude: ["Resources/README.md"],
            resources: [
                .copy("Resources/job-003-vectors.json"),
                .copy("Resources/job-004-vectors.json"),
                .copy("Resources/job-005-vectors.json"),
                .copy("Resources/job-006-vectors.json"),
                .copy("Resources/job-007-vectors.json"),
                .copy("Resources/job-008-vectors.json"),
                .copy("Resources/job-009-vectors.json"),
                .copy("Resources/job-010-vectors.json"),
            ]
        ),
    ]
)
