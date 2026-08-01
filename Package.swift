// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CtrlKD",
    products: [
        .library(name: "CtrlKD", targets: ["CtrlKD"]),
    ],
    targets: [
        .target(name: "CtrlKD"),
        // Everything `sr` does except talk to the OS: argument parsing, the diagnose
        // report, the conversion loop. Split out from the executable so the tests can
        // call it directly — an executable target's code cannot be imported.
        .target(name: "SoftReturnCLI", dependencies: ["CtrlKD"]),
        // The `sr` command-line converter. A thin main over SoftReturnCLI.
        .executableTarget(name: "sr", dependencies: ["SoftReturnCLI"]),
        // Proof-of-life demo: `swift run ctrlkd-demo` converts synthetic WS4 bytes
        // to Markdown. Not part of the library product.
        .executableTarget(name: "ctrlkd-demo", dependencies: ["CtrlKD"]),
        .testTarget(
            name: "CtrlKDTests",
            dependencies: ["CtrlKD", "SoftReturnCLI"],
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
                .copy("Resources/job-011-vectors.json"),
                .copy("Resources/job-012-vectors.json"),
                .copy("Resources/job-013-vectors.json"),
                .copy("Resources/job-014-vectors.json"),
                .copy("Resources/geometry-vectors-2.0.0.json"),
                .copy("Resources/horizontal-vectors-2.0.0.json"),
                .copy("Fixtures/notes-vectors-1.2.0.json"),
            ]
        ),
    ]
)
