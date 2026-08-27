import Foundation
import Testing
@testable import SoftReturn

/// Job 264 (`cli-marked-method`): the privileged-install state machine job 259 tested here is
/// gone (see `CommandLineToolInstaller`'s header for the ruling) — what remains is the pure
/// command-string logic the Manual section of `CLIHelpWindowController` reuses unchanged from
/// job 218/253, plus the bundled-binary lookup.
@Suite("CommandLineToolInstaller")
struct CommandLineToolInstallerTests {
    @Test func installCommandQuotesBothPathsAndChainsChmod() {
        let command = CommandLineToolInstaller.installCommand(
            bundledPath: "/Applications/Soft Return.app/Contents/MacOS/sr",
            destinationPath: "/usr/local/bin/sr"
        )
        #expect(command == "sudo cp '/Applications/Soft Return.app/Contents/MacOS/sr' \\\n"
            + "  '/usr/local/bin/sr' \\\n"
            + "  && sudo chmod 755 '/usr/local/bin/sr'")
    }

    @Test func installCommandIsThreeBackslashContinuedLinesAtArgumentBoundaries() {
        let command = CommandLineToolInstaller.installCommand(
            bundledPath: "/Applications/Soft Return.app/Contents/MacOS/sr",
            destinationPath: "/usr/local/bin/sr"
        )
        let lines = command.components(separatedBy: "\n")
        #expect(lines.count == 3, "expected a 3-line continuation, got \(lines.count) lines")
        #expect(lines[0].hasSuffix(" \\"), "line 1 must end in a continuation backslash")
        #expect(lines[1].hasSuffix(" \\"), "line 2 must end in a continuation backslash")
        #expect(!lines[2].hasSuffix("\\"), "the last line must not continue")
        // Pasted verbatim into a shell, the continuations must reassemble into exactly the
        // original single logical command — that's what makes this "real" shell, not prose
        // that merely looks like a command.
        let rejoined = lines
            .map { line in line.hasSuffix(" \\") ? String(line.dropLast(2)) : line }
            .map { line in line.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        #expect(rejoined == "sudo cp '/Applications/Soft Return.app/Contents/MacOS/sr' '/usr/local/bin/sr' "
            + "&& sudo chmod 755 '/usr/local/bin/sr'")
    }

    @Test func installCommandEscapesSingleQuotesInPaths() {
        let command = CommandLineToolInstaller.installCommand(bundledPath: "/tmp/o'brien/sr")
        #expect(command.contains("'/tmp/o'\\''brien/sr'"))
    }

    @Test func installCommandDefaultsToUsrLocalBin() {
        let command = CommandLineToolInstaller.installCommand(bundledPath: "/App.app/Contents/MacOS/sr")
        #expect(command.contains("/usr/local/bin/sr"))
    }

    /// Job 248: the test host IS the app bundle, built by the same Tuist script phase
    /// (`Scripts/build-sr-cli.sh`) that bundles `sr` for every configuration, not only Release.
    @Test func bundledExecutableURLResolvesInTheTestHost() {
        let bundled = CommandLineToolInstaller.bundledExecutableURL()
        #expect(bundled != nil)
        if let bundled {
            #expect(FileManager.default.isExecutableFile(atPath: bundled.path))
        }
    }
}
