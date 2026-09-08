import Foundation
@testable import SoftReturn

/// Planning #191 (incident): the macOS test suite, run as Jon, replayed a real recorded Apple
/// Event whose `keyDirectObject` named a real file under Jon's home and wrote an RTF beside
/// it. The fix is never reading a real personal file (or the private `TestDocs/` corpus) from
/// a test that doesn't need to — the four bundled, pristine public-domain samples
/// (`SoftReturn/Resources/SampleDocuments/`, `SampleDocuments.items(bundle:)`) are already
/// shipped in the app bundle for exactly this "a person can convert something real" purpose,
/// so tests can borrow the same documents instead of reaching for `TestDocs/` or a real file.
///
/// This is the ONE shared helper every such test routes through: copy a named bundled sample
/// into a temp directory the CALLER creates and removes (same convention as every existing
/// `freshTempDir`-shaped helper in this target — this type owns none of that lifecycle),
/// never touching the bundled original.
enum BundledSampleFixture {
    enum FixtureError: Error {
        case sampleNotBundled(String)
    }

    /// Copies the bundled sample named `name` (matched case-insensitively against
    /// `SampleDocuments.items(bundle:)`'s own filenames, e.g. `"OCAPTAIN.WS"`) into
    /// `directory`, which must already exist, and returns the copy's URL.
    @discardableResult
    static func copy(_ name: String, into directory: URL, bundle: Bundle = .main) throws -> URL {
        guard let item = SampleDocuments.items(bundle: bundle).first(where: {
            $0.url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw FixtureError.sampleNotBundled(name)
        }
        let destination = directory.appendingPathComponent(item.url.lastPathComponent)
        try FileManager.default.copyItem(at: item.url, to: destination)
        return destination
    }
}
