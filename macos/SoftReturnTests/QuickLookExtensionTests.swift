import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// THE QUICK LOOK GAP (job-029 debt): the appex has never been proven to render anything.
///
/// The ideal proof is `qlmanage -t`/`-p` against a real Debug build with LaunchServices
/// registration — driving the actual extension through the actual OS machinery. That was
/// attempted first and hangs indefinitely under this sandbox: `xcrun qlmanage -t -s 512 -o
/// <dir> Fixtures/dropped-chapter.ws4` produced zero output (not even an error) and was
/// killed after 20s and, separately, after the full 3600s timeout — a silent sandbox denial,
/// not a working answer to report. `qlmanage -m plugins` also lists only legacy
/// `.qlgenerator` bundles, never the modern App Extension kind ours is, so that path was a
/// dead end even before the hang.
///
/// `SoftReturnTests` cannot import `SoftReturnQuickLook` and instantiate `PreviewProvider`
/// directly either — Tuist's own graph linter refuses it: "Target SoftReturnTests has
/// platforms 'macOS' and product 'unit tests' and depends on target SoftReturnQuickLook of
/// type 'app extension' and platforms 'macOS' which is an invalid or not yet supported
/// combination." (confirmed by actually adding the dependency and running `tuist generate`).
///
/// So this file verifies what IS reachable headlessly, per the debt's own fallback:
///   1. The appex's bundle wiring (`SoftReturnQuickLook/Info.plist`) declares the right
///      extension point, principal class, and content types.
///   2. `PreviewProvider.swift` compiles against the CURRENT CtrlKD API — proven by the fact
///      that `xcodebuild build-for-testing` on this workspace embeds
///      `SoftReturnQuickLook.appex` into `Soft Return.app/Contents/PlugIns` without error
///      (see `ValidateEmbeddedBinary`/`RegisterWithLaunchServices` in any build log for this
///      scheme) — the Tuist constraint above blocks IMPORTING the extension's module from a
///      test, not building it.
///   3. `providePreview(for:)`'s entire body is two calls — `parse(bytes)` then
///      `emitPDF(document, mode: .printed)` — copied verbatim below and run against the real
///      fixture `qlmanage` was going to be pointed at, which is the actual, substantive
///      question ("does it render") minus only the OS/XPC plumbing neither `qlmanage` nor
///      Tuist would let this session drive.
@Suite struct QuickLookExtensionTests {

    /// `SoftReturnQuickLook/Info.plist`'s `NSExtension` dict, read as data rather than
    /// trusted from memory — this is the one artifact that actually governs whether
    /// LaunchServices offers our extension for a file at all.
    @Test func infoPlistDeclaresTheRightExtensionPoint() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoftReturnQuickLook/Info.plist")
        let data = try #require(FileManager.default.contents(atPath: url.path),
                                "SoftReturnQuickLook/Info.plist not found at \(url.path)")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        let ext = try #require(plist["NSExtension"] as? [String: Any],
                               "Info.plist carries no NSExtension dict")
        #expect(ext["NSExtensionPointIdentifier"] as? String == "com.apple.quicklook.preview")
        #expect(ext["NSExtensionPrincipalClass"] as? String == "SoftReturnQuickLook.PreviewProvider")

        let attributes = try #require(ext["NSExtensionAttributes"] as? [String: Any],
                                      "Info.plist carries no NSExtensionAttributes dict")
        let types = try #require(attributes["QLSupportedContentTypes"] as? [String])
        #expect(types == ["me.beforeti.wordstar-document", "me.beforeti.wordstar-pix"],
                "preview claims OUR UTIs and nothing else — Jon ruled 2026-08-08: no hijacking .txt previews")
        #expect(attributes["QLIsDataBasedPreview"] as? Bool == true,
                """
                TRUE = "uses the data-based QLPreviewProvider API", which PreviewProvider is. \
                false shipped in builds a-k and made Apple's view-based wrapper assert \
                (QLPreviewExtensionViewController.m:139, caught live on taco 2026-08-08) — \
                the eternal-spinner root cause. This test asserted the broken value for weeks; \
                it pins the CONSOLE-VERIFIED one now.
                """)
    }

    /// The appex actually exists on disk, embedded where LaunchServices looks for it — the
    /// structural half of "does the extension render": if this bundle isn't there, or isn't
    /// shaped like an extension, nothing else in this file matters. `Bundle.main` is "Soft
    /// Return.app" itself here, the same reliance `everyDeclaredDocumentClassResolves` (this
    /// suite's Info.plist test) makes — these tests run HOSTED inside the real app bundle
    /// (see `RenderProbeTests`'s own doc comment on why).
    @Test func theAppexBundleIsEmbeddedWithTheRightShape() throws {
        let appexURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/SoftReturnQuickLook.appex")
        #expect(FileManager.default.fileExists(atPath: appexURL.path),
                "SoftReturnQuickLook.appex is not embedded in \(Bundle.main.bundleURL.path)")

        let appexPlist = appexURL.appendingPathComponent("Contents/Info.plist")
        #expect(FileManager.default.fileExists(atPath: appexPlist.path),
                "SoftReturnQuickLook.appex has no Info.plist")
        let executable = appexURL.appendingPathComponent("Contents/MacOS/SoftReturnQuickLook")
        #expect(FileManager.default.fileExists(atPath: executable.path),
                "SoftReturnQuickLook.appex has no executable")
    }

    /// `PreviewProvider.providePreview(for:)`'s entire body, run directly: `parse` the real
    /// fixture, `emitPDF` it in Printed mode, and check the result is an actual PDF. This is
    /// the substantive claim "the extension renders this file" minus only the XPC/sandbox
    /// plumbing this session could not drive (see the file's own doc comment).
    @Test func theExtensionsRenderingPathProducesARealPDFForTheFixture() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let bytes = [UInt8](try Data(contentsOf: url))

        let document = try parse(bytes)
        let pdf = Data(emitPDF(document, mode: .printed))

        #expect(!pdf.isEmpty, "emitPDF produced no bytes for dropped-chapter.ws4")
        #expect(pdf.prefix(4) == Data("%PDF".utf8),
                "emitPDF's output does not start with the PDF magic bytes")
    }
}
