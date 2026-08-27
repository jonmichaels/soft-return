import Foundation

/// The `SoftReturnDiagnostics` module (job 219, Jon's ruling 2026-08-11 — findings B6-B9 of
/// `docs/AUDIT-findings.md`): every file in this `SoftReturn/Diagnostics/` group is bespoke
/// investigation instrumentation (a raw `AEInstallEventHandler` tap, registry/self-test probes,
/// a breadcrumb trail) built across jobs 143-218 to chase the field -1708/-file-access bugs.
/// None of it may run unannounced in the shipping app — "the shipping app must run APPLE'S
/// native paths — no interceptors, no probes, no bespoke instrumentation in release" — so every
/// entry point in this module is gated behind this ONE switch, not a flag per tool (the old
/// `SR_AE_SELFTEST`/`SR_BACKFILL_SELFTEST`/`aeDiagnostics.enabled` knobs are gone, folded in
/// here).
///
/// Most files in this module are ALSO wrapped in `#if DEBUG` — this gate alone does not remove
/// their symbols from a Release binary, only their runtime effect, and job 219 requires both
/// (a `strings` check on the Release binary must show neither the tap class name nor any
/// worker-machine path). `AppleEventLifecycleBreadcrumbs` is the one exception: its `record`
/// calls are reached from `ConvertCommand`, which ships in Release, so that file stays compiled
/// in every configuration and relies on this gate alone (see that file's header).
///
/// Foundation-only, no AppKit — this is the part of the module the brief asks to be reusable by
/// an iOS adoption of `SoftReturnDiagnostics` later; nothing here is AppKit- or macOS-bound.
enum SRDiagnosticsGate {
    /// Same name for both the environment variable and the `UserDefaults.standard` key, per the
    /// brief's own example (`SRDiagnostics=1`-style). The defaults key exists for two callers
    /// that can't (or shouldn't have to) set an environment variable: a human running
    /// `defaults write me.beforeti.softreturn SRDiagnostics -bool YES` against an already-built
    /// field binary, and tests that need to activate recording explicitly instead of relying on
    /// it being on by default — see `AppleEventLifecycleBreadcrumbsTests`.
    static let defaultsKey = "SRDiagnostics"
    private static let environmentKey = "SRDiagnostics"

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if environment[environmentKey] == "1" { return true }
        return defaults.bool(forKey: defaultsKey)
    }
}
