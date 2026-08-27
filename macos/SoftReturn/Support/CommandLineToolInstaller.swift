import Foundation

/// App ▸ Command Line Tool… (job 264, `cli-marked-method`).
///
/// Replaces job 259's (b14) `SMAppService`/`LaunchDaemon` privileged-helper install. Ruled dead
/// by design, not fixable (Jon, 2026-08-12: "CLI install RULED: the Marked method") — every real
/// registration probe job 259/261 ran against the actual sandboxed, Developer-ID-signed app
/// returned `SMAppServiceErrorDomain` code 22, and job 261's follow-up traced that to macOS
/// 14.2's sandbox-parity rule: a sandboxed app's helper is held to the same container
/// restrictions as the app itself, so it can never actually reach `/usr/local/bin` no matter
/// what an admin approves in System Settings. There is no privileged-install path left to try —
/// `AuthorizationExecuteWithPrivileges` was already ruled out before job 259 (sandbox-forbidden),
/// and `sudo`/sudo-adjacent APIs are unavailable to a sandboxed process by construction.
///
/// The Marked method: stop trying to install anything from inside the sandbox, and instead point
/// the user at the three ways developer tools actually document this — Homebrew, a signed
/// installer package, or a manual copy — from an in-app help page. See
/// `CLIHelpWindowController` for the page itself; this enum keeps only the two pieces of pure
/// logic that page's Manual section reuses from the old flow (job 218/253's `installCommand`,
/// unit-tested since before this rewrite) plus the bundled-binary lookup (job 248).
enum CommandLineToolInstaller {
    static let defaultDestinationPath = "/usr/local/bin/sr"

    /// The exact command shown in the Manual section. A pure function so the quoting/shape can
    /// be unit tested without a Finder panel or a pasteboard.
    ///
    /// Job 278: a REAL multi-line shell command — backslash continuations at argument
    /// boundaries — not one long line. What `copyManualCommand(_:)` puts on the pasteboard is
    /// this exact string, so a paste into Terminal must already be valid shell, continuation
    /// backslashes and all, not something that only reads well wrapped on screen.
    static func installCommand(bundledPath: String, destinationPath: String = defaultDestinationPath) -> String {
        let source = shellQuoted(bundledPath)
        let destination = shellQuoted(destinationPath)
        return [
            "sudo cp \(source) \\",
            "  \(destination) \\",
            "  && sudo chmod 755 \(destination)",
        ].joined(separator: "\n")
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The bundled `sr` this app ships (job 248's build phase). `nil` only for a build that
    /// skipped that script phase — there is no such shipping build, but `CLIHelpWindowController`
    /// still handles the absence rather than force-unwrapping it.
    static func bundledExecutableURL() -> URL? {
        Bundle.main.url(forAuxiliaryExecutable: "sr") ?? Bundle.main.url(forResource: "sr", withExtension: nil)
    }
}
