import Foundation

/// The private-corpus contract of `docs/TESTING.md`, in one place.
///
/// Three environment variables arm the gated tests. Each is read as `NAME`, then as
/// `TEST_RUNNER_NAME` (what `xcodebuild test` forwards into a test host), and an empty value
/// counts as unset. One trailing `/` is dropped.
///
/// - Unarmed (variable unset): the test is a recorded Skip whose reason names the variable
///   (`skipReason(for:)`). Never a failure.
/// - Armed but incomplete (variable set, the file or directory it should hold is not there):
///   the test fails loudly (`MissingFixture`, thrown). Never a Skip.
public struct Corpus: Sendable {
    public enum Variable: String, CaseIterable, Sendable {
        /// Root of the private corpus clone (`jon-floppies/`, `ws7-private/`, `sawyer/`, ...).
        case privateCorpus = "CTRLKD_PRIVATE_CORPUS"
        /// Top directory of the Sawyer WordStar archive.
        case sawyerArchive = "CTRLKD_SAWYER_ARCHIVE"
        /// ctrl-kd's `src/` directory (the Python engine's checkout is its parent).
        case ctrlkdSrc = "CTRLKD_SRC"
    }

    /// Armed but incomplete: the variable names a place that lacks `path`.
    public struct MissingFixture: Error, CustomStringConvertible {
        public let variable: Variable
        public let root: String
        public let path: String

        public init(_ variable: Variable, root: String, path: String) {
            self.variable = variable
            self.root = root
            self.path = path
        }

        public var description: String {
            "\(variable.rawValue)=\(root) is set but \(path) is missing from that copy."
        }
    }

    private let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// The process's own environment.
    public static let current = Corpus(environment: ProcessInfo.processInfo.environment)

    // MARK: Instance API

    /// The variable's value, or nil when unset or empty.
    public func path(_ variable: Variable) -> String? {
        for key in [variable.rawValue, "TEST_RUNNER_" + variable.rawValue] {
            if let raw = environment[key], !raw.isEmpty {
                let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    public func isArmed(_ variable: Variable) -> Bool { path(variable) != nil }

    /// The skip reason every trait for this variable cites: one shape, naming the variable.
    public func skipReason(for variable: Variable) -> String {
        "gated: \(variable.rawValue) unset — see docs/TESTING.md"
    }

    /// The top directory of the Sawyer archive a test reads (it holds `CONVERT.WS`, `ARTICLES/`,
    /// `INSET/` directly): `CTRLKD_SAWYER_ARCHIVE` when set, otherwise the corpus clone's own
    /// vendored copy, `<CTRLKD_PRIVATE_CORPUS>/sawyer`, so arming the corpus alone is enough to
    /// run the curated Sawyer subset. Nil when neither variable is set.
    public var sawyerArchiveRoot: String? {
        if let archive = path(.sawyerArchive) { return archive }
        return path(.privateCorpus).map { $0 + "/sawyer" }
    }

    /// ctrl-kd's checkout root. `CTRLKD_SRC` names the `src/` directory; either it or its
    /// parent is accepted, and the parent is returned.
    public var ctrlkdCheckoutRoot: String? {
        guard let src = path(.ctrlkdSrc) else { return nil }
        let url = URL(fileURLWithPath: (src as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        return url.lastPathComponent == "src" ? url.deletingLastPathComponent().path : url.path
    }

    // MARK: Process-wide conveniences

    /// `CTRLKD_SAWYER_ARCHIVE`, or "" when unset. Only meaningful behind an armed trait: a
    /// path built from "" is a bug in the test's gating.
    public static var sawyerArchivePath: String { current.path(.sawyerArchive) ?? "" }

    /// `CTRLKD_PRIVATE_CORPUS`, or "" when unset. Same rule as `sawyerArchivePath`.
    public static var privateCorpusPath: String { current.path(.privateCorpus) ?? "" }

    /// The error for a Sawyer-archive file that should be there and is not.
    public static func missingSawyerFixture(path: String) -> MissingFixture {
        MissingFixture(.sawyerArchive, root: sawyerArchivePath, path: path)
    }

    public static var sawyerArchiveArmed: Bool { current.isArmed(.sawyerArchive) }
    public static var privateCorpusArmed: Bool { current.isArmed(.privateCorpus) }

    public static var sawyerArchiveSkipReason: String { current.skipReason(for: .sawyerArchive) }
    public static var privateCorpusSkipReason: String { current.skipReason(for: .privateCorpus) }
}
