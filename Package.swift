// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CtrlKD",
    // Deliberate floor (Jon's ruling 2026-08-17): the engine is pure Swift
    // stdlib — no Foundation, no frameworks, and it deliberately avoids
    // stdlib calls gated above this (see StyleLibrary's hand-rolled
    // contains). macOS 10.15 is the oldest target with the Swift
    // concurrency-capable runtime story and covers 2019-era Intel Macs;
    // the app consumes this package at its own (higher) floor.
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "CtrlKD", targets: ["CtrlKD"]),
    ],
    targets: [
        // b24 round 21b/21c/21d: real zlib (libz), for byte-exact DEFLATE parity with
        // Python's own `zlib.compress` (the b24 PIX wave's embedded-image streams —
        // RTF `\pict`, HTML data URIs, PDF FlateDecode — must match the ctrl-kd
        // oracle's manifest byte-for-byte, not merely decode to the same pixels).
        // Ships as part of the base system on every platform this package targets
        // (macOS's SDK, every Linux distribution's libc-adjacent tier) — a system
        // library link, not a "framework dependency" in the sense the CtrlKD target's
        // own no-Foundation ruling is about.
        //
        // NO MODULE AT ALL (round 21d): round 21c's real C target (`CZlibShim`) still
        // gave Xcode a package module to hand to a consumer, and job 363 found that
        // failure is DETERMINISTIC for a `.bundle` product (SoftReturnImporter, the
        // mdimporter) with explicit modules off — Xcode never supplies a package
        // C-target's module there, module map or not. The fix that leaves nothing for
        // Xcode to mishandle: no C target, no module, no header — just this linker
        // flag plus three C symbol declarations directly in `Deflate.swift`.
        //
        // `.enableExperimentalFeature("Extern")` (round 21e): an Apple-official
        // researcher, citing Swift's own `UnderscoredAttributes.md` reference,
        // corrected round 21d's `@_silgen_name` choice — `@_silgen_name` assumes
        // SWIFT ABI (name-mangled symbol matching) and is documented as unsuitable
        // for a plain C function; `@_extern(c:)` is the supported mechanism for
        // exactly this. `@_extern(c:)` needs this flag on Swift 6.3.3 (confirmed:
        // fails to parse without it, on this machine, both Linux compiler
        // invocations). Empirically verified the flag does NOT propagate to a
        // consumer: a downstream target — including a `.testTarget` reaching the
        // declaration through `@testable import`, this package's own exact shape —
        // built and ran correctly with ZERO flags of its own, in two isolated
        // throwaway packages built specifically to test this before adopting it here
        // (not assumed from the flag's general reputation). No module is produced
        // either way (the property that actually fixed job 360/361/363), so there is
        // no structural reason for Xcode's own SPM integration to treat a per-target
        // `swiftSettings` entry differently than `swift build` already does — but
        // that specific claim is confirmed by the app's own pin job against a real
        // Xcode build, not by this Linux machine. See `Deflate.swift`'s own doc
        // comment for the full account, including why `@_silgen_name` remains a
        // defensible fallback in principle (the Swift stdlib itself carries ~200
        // permanent fixed-C-symbol `@_silgen_name` uses) and why two other
        // alternatives were rejected outright.
        .target(name: "CtrlKD",
               swiftSettings: [.enableExperimentalFeature("Extern")],
               linkerSettings: [.linkedLibrary("z", .when(platforms: [.macOS, .linux])),
                                .linkedLibrary("zs", .when(platforms: [.windows]))]),
        // Everything `sr` does except talk to the OS: argument parsing, the diagnose
        // report, the conversion loop. Split out from the executable so the tests can
        // call it directly — an executable target's code cannot be imported.
        .target(
            name: "SoftReturnCLI",
            dependencies: ["CtrlKD"],
            exclude: ["Resources/SampleDocuments/README.md"],
            resources: [
                // S1 (parity with the ctrl-kd flag of the same name): the four
                // public-domain WordStar sample documents, bundled so `--samples DIR`
                // can write them out without touching the network or the app's own
                // (private-vault-adjacent) resources tree. Canonical copies —
                // `Sources/SoftReturnCLI/Resources/SampleDocuments/README.md` documents
                // provenance and says where the app-side twin lives.
                .copy("Resources/SampleDocuments/LYING.WS"),
                .copy("Resources/SampleDocuments/OCAPTAIN.WS"),
                .copy("Resources/SampleDocuments/TWAINLET.WS"),
                .copy("Resources/SampleDocuments/WARPRAYR.WS"),
            ]
        ),
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
                // The layout byte-parity guard (LayoutByteParityTests.swift): a
                // synthetic WS5+ fixture plus the PYTHON ORACLE'S OWN layout JSON,
                // committed verbatim — regenerate from ctrl-kd, never by hand.
                .copy("Resources/layout-parity-fixture.ws"),
                .copy("Resources/layout-parity-default.json"),
                .copy("Resources/layout-parity-modern-comments.json"),
                .copy("Fixtures/notes-vectors-1.2.0.json"),
            ],
            // PixTests.swift reaches Deflate.swift's own zlib symbol declarations via
            // `@testable import CtrlKD` (verified: no `swiftSettings` of its own
            // needed for that, per `Package.swift`'s own comment on the `CtrlKD`
            // target) — this test target links libz directly too regardless, rather
            // than relying on CtrlKD's own link requirement propagating transitively.
            linkerSettings: [.linkedLibrary("z", .when(platforms: [.macOS, .linux])),
                             .linkedLibrary("zs", .when(platforms: [.windows]))]
        ),
    ]
)
