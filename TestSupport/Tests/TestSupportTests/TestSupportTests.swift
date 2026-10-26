import Foundation
import Testing
@testable import TestSupport

@Suite struct CorpusTests {
    @Test func unsetAndEmptyAreUnarmed() {
        #expect(!Corpus(environment: [:]).isArmed(.sawyerArchive))
        #expect(!Corpus(environment: ["CTRLKD_SAWYER_ARCHIVE": ""]).isArmed(.sawyerArchive))
        #expect(!Corpus(environment: ["CTRLKD_SAWYER_ARCHIVE": "/"]).isArmed(.sawyerArchive))
    }

    @Test func plainNameWinsOverTheTestRunnerForm() {
        let corpus = Corpus(environment: [
            "CTRLKD_PRIVATE_CORPUS": "/plain",
            "TEST_RUNNER_CTRLKD_PRIVATE_CORPUS": "/forwarded",
        ])
        #expect(corpus.path(.privateCorpus) == "/plain")
    }

    @Test func theTestRunnerFormAloneArms() {
        let corpus = Corpus(environment: ["TEST_RUNNER_CTRLKD_SAWYER_ARCHIVE": "/forwarded/"])
        #expect(corpus.path(.sawyerArchive) == "/forwarded")
    }

    @Test func anEmptyPlainNameFallsThroughToTheTestRunnerForm() {
        let corpus = Corpus(environment: [
            "CTRLKD_SRC": "",
            "TEST_RUNNER_CTRLKD_SRC": "/ck/src",
        ])
        #expect(corpus.path(.ctrlkdSrc) == "/ck/src")
    }

    @Test func skipReasonNamesTheVariable() {
        let corpus = Corpus(environment: [:])
        for variable in Corpus.Variable.allCases {
            #expect(corpus.skipReason(for: variable).contains(variable.rawValue))
        }
    }

    @Test func checkoutRootAcceptsTheSrcDirectoryOrItsParent() {
        #expect(Corpus(environment: ["CTRLKD_SRC": "/ck/src"]).ctrlkdCheckoutRoot == "/ck")
        #expect(Corpus(environment: ["CTRLKD_SRC": "/ck/src/"]).ctrlkdCheckoutRoot == "/ck")
        #expect(Corpus(environment: ["CTRLKD_SRC": "/ck"]).ctrlkdCheckoutRoot == "/ck")
        #expect(Corpus(environment: [:]).ctrlkdCheckoutRoot == nil)
    }

    @Test func theSawyerRootIsTheArchiveThenTheCorpusCopyThenNothing() {
        let both = Corpus(environment: [
            "CTRLKD_SAWYER_ARCHIVE": "/archive/",
            "CTRLKD_PRIVATE_CORPUS": "/corpus",
        ])
        #expect(both.sawyerArchiveRoot == "/archive")
        #expect(Corpus(environment: ["CTRLKD_PRIVATE_CORPUS": "/corpus/"]).sawyerArchiveRoot == "/corpus/sawyer")
        #expect(Corpus(environment: ["TEST_RUNNER_CTRLKD_PRIVATE_CORPUS": "/forwarded"]).sawyerArchiveRoot
                == "/forwarded/sawyer")
        #expect(Corpus(environment: ["CTRLKD_SAWYER_ARCHIVE": ""]).sawyerArchiveRoot == nil)
        #expect(Corpus(environment: [:]).sawyerArchiveRoot == nil)
    }

    @Test func aMissingFixtureNamesTheVariableAndThePath() {
        let message = Corpus.MissingFixture(.sawyerArchive, root: "/a", path: "/a/X.WS").description
        #expect(message.contains("CTRLKD_SAWYER_ARCHIVE"))
        #expect(message.contains("/a/X.WS"))
    }
}

@Suite struct RepoPathsTests {
    @Test func rootHoldsThisPackageAndTheEnginePackage() {
        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: RepoPaths.url("Package.swift").path))
        #expect(fileManager.fileExists(atPath: RepoPaths.url("TestSupport/Package.swift").path))
    }
}

@Suite struct TestScratchTests {
    @Test func theDirectoryExistsInsideAndIsGoneAfter() throws {
        var seen: URL?
        try TestScratch.with(prefix: "TestScratchTests") { dir in
            seen = dir
            try Data("x".utf8).write(to: dir.appendingPathComponent("f"))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("f").path))
        }
        let dir = try #require(seen)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func itIsGoneAfterABodyThatThrows() {
        struct Boom: Error {}
        var seen: URL?
        #expect(throws: Boom.self) {
            try TestScratch.with(prefix: "TestScratchTests") { dir in
                seen = dir
                throw Boom()
            }
        }
        #expect(seen.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func deinitRemovesAndRemoveIsRepeatable() throws {
        var scratch: TestScratch? = try TestScratch(prefix: "TestScratchTests")
        let dir = try #require(scratch?.url)
        scratch?.remove()
        scratch?.remove()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        scratch = try TestScratch(prefix: "TestScratchTests")
        let second = try #require(scratch?.url)
        scratch = nil
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func aReadOnlySubdirectoryDoesNotStrandIt() throws {
        let scratch = try TestScratch(prefix: "TestScratchTests")
        let locked = scratch.url(for: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        scratch.remove()
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path))
    }

    @Test func staleLeftoversAreRemovedAndFreshOnesKept() throws {
        let fileManager = FileManager.default
        let old = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestScratchStaleTests-\(UUID().uuidString)")
        let fresh = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestScratchStaleTests-\(UUID().uuidString)")
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestScratchOtherPrefix-\(UUID().uuidString)")
        for url in [old, fresh, other] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { for url in [old, fresh, other] { try? fileManager.removeItem(at: url) } }
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 60 * 60)],
                                      ofItemAtPath: old.path)
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 60 * 60)],
                                      ofItemAtPath: other.path)

        TestScratch.removeStale(prefix: "TestScratchStaleTests", olderThan: 24 * 60 * 60)

        #expect(!fileManager.fileExists(atPath: old.path), "an old leftover with the prefix survived")
        #expect(fileManager.fileExists(atPath: fresh.path), "a recent directory with the prefix was removed")
        #expect(fileManager.fileExists(atPath: other.path), "a directory with another prefix was removed")
    }

    @Test func processWideScratchesAreDistinctAndExist() throws {
        let first = try TestScratch.processWide(prefix: "TestScratchProcessWideTests")
        let second = try TestScratch.processWide(prefix: "TestScratchProcessWideTests")
        defer { first.remove(); second.remove() }
        #expect(first.url != second.url)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
    }
}
