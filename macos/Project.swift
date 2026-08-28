import ProjectDescription

let projectSettings: Settings = .settings(
    base: [
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "SWIFT_VERSION": "6.0",
    ],
    configurations: [
        .debug(
            name: "Debug",
            settings: [
                "DEBUG_INFORMATION_FORMAT": "dwarf",
                "ENABLE_TESTABILITY": "YES",
                "GCC_OPTIMIZATION_LEVEL": "0",
                "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
                "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
                "ONLY_ACTIVE_ARCH": "YES",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            ]
        ),
        .release(
            name: "Release",
            settings: [
                // Job 352: the release recipe runs `xcodebuild build` (never `archive`/
                // `install`), and DEPLOYMENT_POSTPROCESSING defaults to NO for that build
                // action — so Xcode's Strip build phase never ran, leaving DWARF/STABS debug-
                // map entries (absolute worker DerivedData paths, e.g. to .o/.swiftmodule
                // intermediates) embedded in all four Xcode-built targets (app, both appexes,
                // mdimporter). These make stripping explicit and unconditional for Release
                // regardless of build action, closing the same class of leak job 310/311
                // fixed for `sr`'s separate SPM build path. STRIP_STYLE is deliberately left
                // unset — forcing "all" project-wide breaks the mdimporter's x86_64 slice
                // (`strip: error: symbols referenced by indirect symbol table entries that
                // can't be stripped`); each target's product-type default (non-global for
                // bundles/appexes, all for the app) already removes the local N_OSO debug-map
                // entries this fix targets.
                "COPY_PHASE_STRIP": "YES",
                "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "ENABLE_NS_ASSERTIONS": "NO",
                "MTL_ENABLE_DEBUG_INFO": "NO",
                "STRIP_INSTALLED_PRODUCT": "YES",
                "SWIFT_COMPILATION_MODE": "wholemodule",
            ]
        ),
    ]
)

let ctrlKDPackage: TargetDependency = .package(product: "CtrlKD")
// Job 532: Sparkle 2.9.6, exact (Jon's ruling: Sparkle IS in b34) -- see `project.packages`
// below for the remote package declaration. App target only; no other target imports Sparkle.
let sparklePackage: TargetDependency = .package(product: "Sparkle")

let appTarget: Target = .target(
    name: "SoftReturn",
    destinations: .macOS,
    product: .app,
    productName: "Soft Return",
    bundleId: "me.beforeti.softreturn",
    deploymentTargets: .macOS("13.0"),
    infoPlist: .file(path: "Info.plist"),
    sources: ["SoftReturn/**/*.swift"],
    resources: [
        "SoftReturn/Resources/Assets.xcassets",
        "SoftReturn/Resources/DocumentIcons/**",
        "SoftReturn/Resources/SoftReturn.sdef",
        // Job 341 (b23, item D): the Icon Composer bundle for the macOS 26+ Liquid Glass
        // icon-rendering path — a project-level `.icon` folder reference (NEVER inside
        // Assets.xcassets), per Ghostty's own shipping project (deployment target 13.0, no
        // legacy .appiconset at all; here the flat AppIcon.appiconset stays too, as the
        // pre-26 fallback — see `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS` below).
        // `.folderReference` alone does not guarantee the pbxproj's file reference carries
        // Xcode's `folder.iconcomposer.icon` lastKnownFileType; `scripts/fix-icon-composer-
        // file-type.sh` patches it deterministically after every `tuist generate` if needed.
        .folderReference(path: "IconAssets/SoftReturn.icon"),
        // Job 306 (b18): Courier Prime, vendored (Vendor/CourierPrime/VENDORED.md, OFL 1.1).
        // Registered `.process`-scope at launch (CourierPrimeFontRegistration.swift), never
        // installed system-wide.
        "Vendor/CourierPrime/*.ttf",
        "Vendor/CourierPrime/OFL.txt",
        // Job 323 (b20 item 6): the About window's License button shows this bundled at
        // Contents/Resources/LICENSE (`Bundle.main.url(forResource: "LICENSE", withExtension:
        // nil)`). Did not exist before this job — added here (MIT, matching the engine
        // repo's own `LICENSE` verbatim, same copyright holder) because the About window's
        // spec assumes one; flagged in the job report for confirmation, not a considered
        // licensing decision. Job 531: LICENSE stayed at the repo root (workshop-vs-app split),
        // one level above Project.swift's own new `macos/` home, hence `../`.
        "../LICENSE",
        // Job 374 (SAMPLES IN-APP): Help ▸ Open Sample Document ▸'s bundled `.WS` files —
        // see `SoftReturn/Support/SampleDocuments.swift` and the folder's own README.
        // `.folderReference` (same mechanism as `IconAssets/SoftReturn.icon` above) so
        // `Bundle.main.url(forResource: "SampleDocuments", withExtension: nil)` resolves a
        // real directory at runtime, not individually-flattened resource files.
        .folderReference(path: "SoftReturn/Resources/SampleDocuments"),
    ],
    // The classic .mdimporter (job-101) is a plain CFPlugIn bundle, not an app extension --
    // Tuist auto-embeds `.appExtension` products into Contents/PlugIns, but a `.bundle`
    // product has no such auto-embed destination, so it needs an explicit Copy Files phase
    // pointed at Contents/Library/Spotlight, the fixed location mdworker/mdimport scan.
    copyFiles: [
        .wrapper(
            name: "Embed Spotlight Importer",
            subpath: "Contents/Library/Spotlight",
            files: [.buildProduct(name: "SoftReturnImporter")]
        ),
    ],
    entitlements: .file(path: "SoftReturn.entitlements"),
    scripts: [
        // Job 248: builds the `sr` CLI (universal, release) from the same pinned CtrlKD
        // SPM checkout this build already resolved, and drops it into Contents/MacOS/ so
        // CommandLineToolInstaller finds it via Bundle.main.url(forAuxiliaryExecutable:).
        // Invoked via `bash "<path>"` (not TargetScript's own path-exec case) so it runs
        // regardless of the file's executable bit. See scripts/build-sr-cli.sh for why the
        // checkout path is derived from $BUILD_DIR instead of hardcoded (two-checkout trap).
        .pre(
            script: "bash \"${SRCROOT}/scripts/build-sr-cli.sh\"",
            name: "Build sr CLI",
            basedOnDependencyAnalysis: false
        ),
    ],
    dependencies: [
        .target(name: "SoftReturnQuickLook"),
        .target(name: "SoftReturnThumbnail"),
        ctrlKDPackage,
        // Job 532: the the internal runbook "FUTURE: Sparkle public-feed cutover" step 6 cashed in --
        // Sparkle now comes from its own SPM package (see `project.packages` below) instead
        // of the job-285 vendored Vendor/Sparkle-2.9.5/Sparkle.framework, which is deleted.
        // Tuist's normal auto-embed (Copy Files + re-sign-on-copy when a sign identity is
        // present) is the correct, standard behavior for a real SPM framework product -- the
        // job-285 manual FRAMEWORK_SEARCH_PATHS/OTHER_LDFLAGS/codeSignOnCopy:false workaround
        // existed only because that was a raw vendored bundle, not a real package dependency.
        sparklePackage,
    ],
    settings: .settings(
        base: [
            // Job 341 (b23, item D): the .icon bundle's own base name — Ghostty's shipping
            // recipe (Xcode 26, deployment target 13.0) points APPICON_NAME at the .icon
            // bundle, not at "AppIcon"; Xcode itself generates the pre-26 fallback rendition
            // ladder from the .icon's own flat layers, so AppIcon.appiconset stays in the
            // catalog (untouched, item A's own art) but is no longer what this key names.
            "ASSETCATALOG_COMPILER_APPICON_NAME": "SoftReturn",
            // Ghostty's recipe: without this, actool tries to fold BOTH the .icon bundle's
            // generated renditions and AppIcon.appiconset's own into one asset, which is the
            // exact failure job 336 hit ("LG bundle blocked by actool"). NO keeps them apart.
            "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "NO",
            "CODE_SIGN_STYLE": "Automatic",
            "COMBINE_HIDPI_IMAGES": "YES",
            "CURRENT_PROJECT_VERSION": "16",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
            "LSApplicationCategoryType": "public.app-category.productivity",
            "MARKETING_VERSION": "4.0.0",
            "PRODUCT_MODULE_NAME": "SoftReturn",
            "SWIFT_EMIT_LOC_STRINGS": "YES",
        ],
        configurations: [
            .debug(name: "Debug", settings: ["CODE_SIGN_ENTITLEMENTS": "SoftReturn-Debug.entitlements"]),
        ]
    )
)

let testsTarget: Target = .target(
    name: "SoftReturnTests",
    destinations: .macOS,
    product: .unitTests,
    bundleId: "me.beforeti.softreturn.tests",
    deploymentTargets: .macOS("13.0"),
    infoPlist: .default,
    sources: ["SoftReturnTests/**/*.swift", "SoftReturnTests/**/*.h", "SoftReturnTests/**/*.m"],
    resources: ["SoftReturnTests/Fixtures/**"],
    dependencies: [
        .target(name: "SoftReturn"),
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        // MDImporterTestHarness.m (job-101's executed-path CFPlugIn client) is Objective-C;
        // this bridging header is what lets MDImporterExecutedPathTests.swift call it.
        "SWIFT_OBJC_BRIDGING_HEADER": "SoftReturnTests/SoftReturnTests-Bridging-Header.h",
    ])
)

let uiTestsTarget: Target = .target(
    name: "SoftReturnUITests",
    destinations: .macOS,
    product: .uiTests,
    bundleId: "me.beforeti.softreturn.uitests",
    deploymentTargets: .macOS("13.0"),
    infoPlist: .default,
    sources: ["SoftReturnUITests/**/*.swift"],
    dependencies: [
        .target(name: "SoftReturn"),
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
    ])
)

let quickLookTarget: Target = .target(
    name: "SoftReturnQuickLook",
    destinations: .macOS,
    product: .appExtension,
    bundleId: "me.beforeti.softreturn.quicklook",
    deploymentTargets: .macOS("13.0"),
    infoPlist: .file(path: "SoftReturnQuickLook/Info.plist"),
    // SpotlightFileIndexer/SpotlightNudge/SpotlightTriggerBreadcrumbs (Foundation+os only, no
    // AppKit) are mirrored in verbatim, not hand-copied like ImportProvider's CtrlKD calls —
    // an appex target can't import the app module, but Tuist can compile the SAME source path
    // into both targets, so there is nothing here to drift out of sync the way a hand copy could.
    sources: ["SoftReturnQuickLook/**/*.swift", "SoftReturn/Support/SpotlightFileIndexer.swift",
              "SoftReturn/Support/SpotlightNudge.swift", "SoftReturn/Support/SpotlightTriggerBreadcrumbs.swift",
              "SoftReturn/Support/SpotlightIndexQueue.swift",
              // Job 203: the QL default-preset preference and the preset registry it reads
              // (`DocumentOperations.PageSettingsPreset`) — both Foundation+CtrlKD only, so
              // they mirror in the same way the four files above already do.
              "SoftReturn/Support/QuickLookPageSettingsPreference.swift",
              "SoftReturn/Operations/DocumentOperations.swift",
              // Job 371 item 0 (PICTURE WIRING): `DocumentOperations.convert` now calls
              // `DocumentPictures.resolve` — same mirror, same reasoning.
              "SoftReturn/Operations/DocumentPictures.swift",
              // Job 247 (ql-native): the native rendering path itself, mirrored the same
              // way — `QuickLookNativeRenderer` and everything it calls
              // (`DocumentRenderer`/`PagedDocumentView`/`PrintedVectorGraphics`/
              // `CanvasColor`/`DocumentState`/`Provenance`/`SettingsStore`), all AppKit +
              // CtrlKD + Foundation only, no app-only type outside this list.
              "SoftReturn/Rendering/QuickLookNativeRenderer.swift",
              "SoftReturn/Rendering/DocumentRenderer.swift",
              "SoftReturn/Rendering/ModernScreenplay.swift",
              "SoftReturn/Rendering/PagedDocumentView.swift",
              "SoftReturn/Rendering/PrintedVectorGraphics.swift",
              // Job 490: `PageTextView.drawPCLGraphics`'s own PCL rectangle port — same
              // mirror, same reasoning as `PrintedVectorGraphics.swift` just above.
              "SoftReturn/Rendering/PrintedPCLGraphics.swift",
              "SoftReturn/Rendering/CanvasColor.swift",
              "SoftReturn/Document/DocumentState.swift",
              "SoftReturn/Document/Provenance.swift",
              "SoftReturn/Settings/SettingsStore.swift",
              // Job 306 (b18): same mirror — QL renders through the Native font mapping
              // (job 247 ruling), so it needs its OWN registration of the bundled faces,
              // same as SoftReturnThumbnail below.
              "SoftReturn/Rendering/CourierPrimeFontRegistration.swift",
              // Job 460: `PagedDocumentView`'s own diagnostic logging (`logPageDiagnostics`)
              // gates on `SRDiagnosticsGate`, the module's ONE switch (see that file's own doc
              // comment: "Foundation-only, no AppKit" — built to be shared exactly like this).
              // Mirrored in the same way every other cross-target dependency of this file
              // already is above, not hand-copied.
              "SoftReturn/Diagnostics/SRDiagnosticsGate.swift"],
    resources: [
        // Job 306 (b18): this appex's own bundle is separate from the host app's — it
        // needs its own copy of the four TTFs to register from.
        "Vendor/CourierPrime/*.ttf",
    ],
    entitlements: .file(path: "SoftReturnQuickLook/SoftReturnQuickLook.entitlements"),
    dependencies: [
        ctrlKDPackage,
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "16",
        "MARKETING_VERSION": "4.0.0",
        "SKIP_INSTALL": "YES",
        // Job 369: explicitly pinned, not a fix by itself — `xcodebuild -showBuildSettings`
        // confirmed this key is absent/unset project-wide (Tuist never sets it, and this
        // Xcode 26/SE-0466 project template default only applies to Xcode's own "New
        // Project" flow), so the QL spinner crash root-caused here was NOT this project-wide
        // default (SE-0466) but SE-0420's per-closure lexical-isolation inheritance inside
        // `ThumbnailProvider.provideThumbnail` (see that file's own job-369 comment for the
        // actual fix). Pinned to `nonisolated` anyway, scoped to just this extension target,
        // so a future Xcode default change can't silently reintroduce the SE-0466 hazard here.
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
    ])
)

let importerTarget: Target = .target(
    name: "SoftReturnImporter",
    destinations: .macOS,
    product: .bundle,
    bundleId: "me.beforeti.softreturn.mdimporter",
    deploymentTargets: .macOS("13.0"),
    infoPlist: .file(path: "SoftReturnImporter/Info.plist"),
    sources: ["SoftReturnImporter/**"],
    // job-153 Part E.a: ships in the built bundle's Resources, same as every reference
    // importer's schema.xml -- Spotlight reads it from there to know which kMDItem keys this
    // importer's UTIs populate.
    resources: [
        "SoftReturnImporter/schema.xml",
    ],
    dependencies: [
        ctrlKDPackage,
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "16",
        "GENERATE_INFOPLIST_FILE": "NO",
        "MARKETING_VERSION": "4.0.0",
        "SKIP_INSTALL": "YES",
        "WRAPPER_EXTENSION": "mdimporter",
        // Xcode auto-injects -lz (CtrlKD's linkedLibrary) for .app/.appExtension
        // consumers but not .bundle products -- mirror it manually; jobs 360-365
        // saga, details in worker memory.
        "OTHER_LDFLAGS": ["-lz"],
    ])
)

let thumbnailTarget: Target = .target(
    name: "SoftReturnThumbnail",
    destinations: .macOS,
    product: .appExtension,
    bundleId: "me.beforeti.softreturn.thumbnail",
    deploymentTargets: .macOS("13.0"),
    infoPlist: .file(path: "SoftReturnThumbnail/Info.plist"),
    // Same mirror as SoftReturnQuickLook — see that target's `sources` comment.
    sources: ["SoftReturnThumbnail/**/*.swift", "SoftReturn/Support/SpotlightFileIndexer.swift",
              "SoftReturn/Support/SpotlightNudge.swift", "SoftReturn/Support/SpotlightTriggerBreadcrumbs.swift",
              "SoftReturn/Support/SpotlightIndexQueue.swift",
              "SoftReturn/Support/QuickLookPageSettingsPreference.swift",
              "SoftReturn/Operations/DocumentOperations.swift",
              // Job 371 item 0 (PICTURE WIRING): `DocumentOperations.convert` now calls
              // `DocumentPictures.resolve` — same mirror, same reasoning.
              "SoftReturn/Operations/DocumentPictures.swift",
              // Job 247 (ql-native): same mirror as SoftReturnQuickLook — see that target's
              // own comment.
              "SoftReturn/Rendering/QuickLookNativeRenderer.swift",
              "SoftReturn/Rendering/DocumentRenderer.swift",
              "SoftReturn/Rendering/ModernScreenplay.swift",
              "SoftReturn/Rendering/PagedDocumentView.swift",
              "SoftReturn/Rendering/PrintedVectorGraphics.swift",
              // Job 490: `PageTextView.drawPCLGraphics`'s own PCL rectangle port — same
              // mirror, same reasoning as `PrintedVectorGraphics.swift` just above.
              "SoftReturn/Rendering/PrintedPCLGraphics.swift",
              "SoftReturn/Rendering/CanvasColor.swift",
              "SoftReturn/Document/DocumentState.swift",
              "SoftReturn/Document/Provenance.swift",
              "SoftReturn/Settings/SettingsStore.swift",
              // Job 306 (b18): same mirror — the thumbnail also renders through the Native
              // font mapping, same reasoning as SoftReturnQuickLook above.
              "SoftReturn/Rendering/CourierPrimeFontRegistration.swift",
              // Job 460: same mirror as SoftReturnQuickLook above — see that target's own
              // comment on why `PagedDocumentView`'s diagnostic logging needs this file too.
              "SoftReturn/Diagnostics/SRDiagnosticsGate.swift"],
    resources: [
        "Vendor/CourierPrime/*.ttf",
    ],
    entitlements: .file(path: "SoftReturnThumbnail/SoftReturnThumbnail.entitlements"),
    dependencies: [
        ctrlKDPackage,
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "16",
        "MARKETING_VERSION": "4.0.0",
        "SKIP_INSTALL": "YES",
        // Job 369: same pin, same reasoning — see `quickLookTarget`'s settings above.
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
    ])
)

let softReturnScheme: Scheme = .scheme(
    name: "SoftReturn",
    shared: true,
    buildAction: .buildAction(targets: ["SoftReturn"]),
    testAction: .targets(
        ["SoftReturnTests", "SoftReturnUITests"],
        configuration: "Debug"
    ),
    runAction: .runAction(configuration: "Debug", executable: "SoftReturn"),
    archiveAction: .archiveAction(configuration: "Release"),
    profileAction: .profileAction(configuration: "Release"),
    analyzeAction: .analyzeAction(configuration: "Debug")
)

let quickLookScheme: Scheme = .scheme(
    name: "SoftReturnQuickLook",
    shared: true,
    buildAction: .buildAction(targets: ["SoftReturnQuickLook"]),
    archiveAction: .archiveAction(configuration: "Release")
)

let thumbnailScheme: Scheme = .scheme(
    name: "SoftReturnThumbnail",
    shared: true,
    buildAction: .buildAction(targets: ["SoftReturnThumbnail"]),
    archiveAction: .archiveAction(configuration: "Release")
)

let importerScheme: Scheme = .scheme(
    name: "SoftReturnImporter",
    shared: true,
    buildAction: .buildAction(targets: ["SoftReturnImporter"]),
    archiveAction: .archiveAction(configuration: "Release")
)

let project = Project(
    name: "SoftReturn",
    packages: [
        .package(path: "../"),
        .package(url: "https://github.com/sparkle-project/Sparkle", .exact("2.9.6")),
    ],
    settings: projectSettings,
    targets: [
        appTarget,
        testsTarget,
        uiTestsTarget,
        quickLookTarget,
        thumbnailTarget,
        importerTarget,
    ],
    schemes: [
        softReturnScheme,
        quickLookScheme,
        thumbnailScheme,
        importerScheme,
    ]
)
