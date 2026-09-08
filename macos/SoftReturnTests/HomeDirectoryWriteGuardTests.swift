import Foundation
import Testing

/// Planning #191 regression guard, redesigned to be cheap regardless of how much content sits
/// under Jon's real folders. The original design snapshotted every file's modification time
/// under seven real content folders before the suite ran and diffed against a second full
/// snapshot after — cheap in principle, but "stat every file under ~/Pictures and ~/Music"
/// took 2889s (48 min) on Jon's actual Mac. That cost was NOT disk I/O: Documents, Desktop,
/// Downloads, Pictures, Movies, and Music are TCC-protected on macOS, and first access to one
/// of them from a non-interactive process pops a permission dialog and blocks until a human
/// clicks it — this guard was, unattended, waiting on a modal it could never see.
///
/// Two changes fix this:
///
/// 1. Watched roots are now only `~/Dropbox` (not TCC-protected), `~/projects` (minus this
///    repo's own checkout and build-output directories — a normal build/test run legitimately
///    writes there), and non-hidden files directly in `$HOME` itself. The six TCC-protected
///    folders are no longer watched by either this guard or `test-isolation-gate.sh` — a write
///    landing in one of them would itself trigger the same blocking dialog, which is the
///    alarm. See `docs/TESTING.md`.
/// 2. No baseline snapshot at all: the first test records a marker (`Date()`, backed by a real
///    temp file) instead of walking anything, and the second does exactly ONE pass over the
///    watched roots, comparing each regular file's `contentModificationDate` and
///    `creationDate` against the marker. Package/library bundles (`.photoslibrary`, `.app`,
///    `.xcodeproj`, …) are never descended into — Dropbox can and does hold these, and their
///    internal metadata churn is exactly the cost this redesign exists to avoid; nothing this
///    app writes lands inside one.
///
/// A watched root that doesn't exist on this machine is skipped, and named as skipped. A root
/// that DOES exist but can't be enumerated (permissions, anything) is a FAILURE naming that
/// root — this guard must never read "couldn't check" as "clean". Every run prints which roots
/// were actually walked.
///
/// `~/Dropbox` gets a narrower offender rule than `~/projects` and `$HOME`'s top level (see
/// `isDropboxConversionSibling`): Jon's own edits on other devices sync into Dropbox during a
/// run, and a blanket "any new file" rule would flag his own work. Only a new/modified file
/// whose extension matches this app's conversion output AND has a same-stem `.ws`/`.WS`
/// sibling counts — that shape is specific to `BesideSourceWriter`, not to Jon's file sync.
///
/// `.serialized` plus deliberately name-ordered `@Test` functions (`aBaseline...` sorts before
/// `zFinalCheck...`) makes the marker recording the first thing this suite runs and the final
/// check the last — Swift Testing schedules a `.serialized` suite's tests one at a time, in
/// the stable order it discovers them, which for plain alphabetical names is name order.
/// Neither test is `@MainActor`; this only ever touches the filesystem and
/// `nonisolated(unsafe)` static storage, guarded by `.serialized` the same way
/// `UpdateCheckerTests`' `RecordingURLProtocol` subclasses guard their own shared static state.
@Suite(.serialized)
struct HomeDirectoryWriteGuardTests {
    /// Package/library bundle extensions to never descend into, matched case-insensitively.
    /// Kept in sync with the equivalent list in `macos/scripts/test-isolation-gate.sh`.
    private static let skippedPackageExtensions: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "app", "framework",
        "xcodeproj", "xcworkspace", "xcresult", "band", "logicx",
        "imovielibrary", "fcpbundle",
    ]

    /// Extensions this app's own beside-source conversion output (`BesideSourceWriter`) can
    /// produce next to a `.ws`/`.WS` source, matched case-insensitively. Kept in sync with
    /// `DROPBOX_CONVERTED_EXTS` in `test-isolation-gate.sh`.
    private static let dropboxConvertedExtensions: Set<String> = [
        "rtf", "pdf", "txt", "docx", "html", "htm", "md", "odt",
    ]

    /// True if `url` looks like this app's own beside-source conversion output landing next
    /// to a `.ws`/`.WS` document that synced into Dropbox from another device during a run —
    /// Jon's own edits produce exactly this shape on his other machines and must not be
    /// flagged. Requires BOTH: an extension in `dropboxConvertedExtensions` (case-insensitive)
    /// AND a sibling file in the same directory named the same stem plus `.ws` or `.WS`. Also
    /// matches macOS's "name 2.rtf" / "name 3.rtf" duplicate-file naming: a trailing
    /// " <digits>" is stripped from the stem before the sibling check. Lists the candidate's
    /// directory once, rather than probing for `.ws` then `.WS` with two separate stats.
    private static func isDropboxConversionSibling(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, dropboxConvertedExtensions.contains(ext) else { return false }

        var stem = url.deletingPathExtension().lastPathComponent
        if let range = stem.range(of: #" [0-9]+$"#, options: .regularExpression) {
            stem.removeSubrange(range)
        }

        let dir = url.deletingLastPathComponent()
        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return false }
        let wsName = "\(stem).ws"
        let wsNameUpper = "\(stem).WS"
        return siblings.contains { $0.lastPathComponent == wsName || $0.lastPathComponent == wsNameUpper }
    }

    /// This file's own path, used to find the repo root the same way `test-isolation-gate.sh`
    /// derives `REPO_ROOT` from its own script location — so a build/test run writing inside
    /// this checkout is never mistaken for a stray write.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HomeDirectoryWriteGuardTests.swift -> SoftReturnTests/
            .deletingLastPathComponent() // SoftReturnTests/ -> macos/
            .deletingLastPathComponent() // macos/ -> repo root
            .standardizedFileURL
    }

    /// Result of checking one watched root. `.failedUnreadable` is deliberately NOT the same
    /// as "walked with zero offenders" — a root this guard couldn't read must never look clean.
    private enum RootOutcome {
        case walked(offenders: [String])
        case skippedAbsent
        case failedUnreadable
    }

    /// One pass over `root`, skipping hidden entries and package bundles (never descending
    /// into them), returning every regular file whose content-modification or creation date is
    /// newer than `marker` AND for which `isOffender` returns true. `extraSkip` additionally
    /// prunes directories the caller wants excluded entirely (used for this repo's own
    /// checkout and `DerivedData` under `~/projects`). `isOffender` narrows which newer files
    /// actually count (used to apply `isDropboxConversionSibling` under `~/Dropbox`); it
    /// defaults to "every newer file counts", the behavior for `~/projects` and `$HOME`.
    private static func offendersUnderRoot(
        _ root: URL, newerThan marker: Date,
        extraSkip: (URL) -> Bool = { _ in false },
        isOffender: (URL) -> Bool = { _ in true }
    ) -> RootOutcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .skippedAbsent
        }
        // A directory that exists but can't even be listed (permissions, or anything else)
        // must never read as "zero offenders" — that's indistinguishable from clean.
        guard (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) != nil else {
            return .failedUnreadable
        }

        var enumerationFailed = false
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .creationDateKey, .isRegularFileKey, .isDirectoryKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                enumerationFailed = true
                return true // keep going so we still report every offender we CAN see
            }
        ) else { return .failedUnreadable }

        var offenders: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .creationDateKey, .isRegularFileKey, .isDirectoryKey,
            ]) else { continue }
            if values.isDirectory == true {
                let extension_ = url.pathExtension.lowercased()
                if skippedPackageExtensions.contains(extension_)
                    || extraSkip(url.standardizedFileURL) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let modifiedIsNew = (values.contentModificationDate.map { $0 > marker }) ?? false
            let createdIsNew = (values.creationDate.map { $0 > marker }) ?? false
            if (modifiedIsNew || createdIsNew), isOffender(url) {
                offenders.append(url.path)
            }
        }
        return enumerationFailed ? .failedUnreadable : .walked(offenders: offenders)
    }

    /// Non-recursive: files directly in `home` (no subdirectories), hidden files excluded —
    /// mirrors `test-isolation-gate.sh`'s `-maxdepth 1` sweep of `$HOME` itself.
    private static func offendersDirectlyIn(_ home: URL, newerThan marker: Date) -> RootOutcome {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .creationDateKey, .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return .failedUnreadable }

        var offenders: [String] = []
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey, .creationDateKey, .isRegularFileKey,
                  ]),
                  values.isRegularFile == true
            else { continue }
            let modifiedIsNew = (values.contentModificationDate.map { $0 > marker }) ?? false
            let createdIsNew = (values.creationDate.map { $0 > marker }) ?? false
            if modifiedIsNew || createdIsNew {
                offenders.append(url.path)
            }
        }
        return .walked(offenders: offenders)
    }

    /// Shared between the two `@Test` functions below — Swift Testing gives each `@Test` its
    /// own struct instance, so this cannot be an instance property. Safe only because
    /// `.serialized` guarantees these two tests never run concurrently with each other or
    /// with themselves.
    nonisolated(unsafe) private static var markerDate: Date?
    nonisolated(unsafe) private static var markerFileURL: URL?

    @Test func aBaselineSnapshotsHomeDirectoryModificationTimes() throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeDirectoryWriteGuardTests-\(UUID().uuidString)")
        try Data().write(to: markerURL)
        Self.markerFileURL = markerURL
        Self.markerDate = (try? markerURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()
    }

    @Test func zFinalCheckNoHomeDirectoryFileWasCreatedOrModified() throws {
        defer {
            if let markerFileURL = Self.markerFileURL {
                try? FileManager.default.removeItem(at: markerFileURL)
            }
        }
        let marker = try #require(Self.markerDate,
                                   "baseline test did not run before this one — .serialized ordering is broken")

        let home = FileManager.default.homeDirectoryForCurrentUser
        let dropbox = home.appendingPathComponent("Dropbox", isDirectory: true)
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let repoRoot = Self.repoRoot

        var offenders: [String] = []
        var walkedRoots: [String] = []
        var skippedRoots: [String] = []
        var unreadableRoots: [String] = []

        func handle(_ outcome: RootOutcome, label: String) {
            switch outcome {
            case .walked(let rootOffenders):
                walkedRoots.append(label)
                offenders.append(contentsOf: rootOffenders)
            case .skippedAbsent:
                skippedRoots.append(label)
            case .failedUnreadable:
                unreadableRoots.append(label)
            }
        }

        handle(
            Self.offendersUnderRoot(
                dropbox, newerThan: marker, isOffender: Self.isDropboxConversionSibling
            ),
            label: dropbox.path
        )
        handle(
            Self.offendersUnderRoot(projects, newerThan: marker, extraSkip: { url in
                url == repoRoot || url.lastPathComponent == "DerivedData"
            }),
            label: projects.path
        )
        handle(Self.offendersDirectlyIn(home, newerThan: marker), label: "\(home.path) (top level only)")

        // Printed on every run, pass or fail, so a green suite is never mistaken for full
        // coverage it didn't actually have.
        print("HomeDirectoryWriteGuardTests coverage — walked: \(walkedRoots), " +
              "skipped (absent): \(skippedRoots), unreadable: \(unreadableRoots)")

        for root in unreadableRoots {
            Issue.record("guard coverage lost: \(root) exists but could not be enumerated")
        }

        #expect(offenders.sorted().isEmpty,
                "this test run created or modified files under a watched root: \(offenders.sorted())")
    }
}
