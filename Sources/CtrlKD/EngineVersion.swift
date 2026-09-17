// The engine's version — the ONE literal, read by everything that shows it: the `sr`
// banner (`srVersion` in SoftReturnCLI re-exports it), the Mac About window and the
// iPhone Settings footer (both link CtrlKD; the iPhone cannot link SoftReturnCLI, and its
// hand-copied "4.2.0" literal disagreed with the shipping engine on 2026-09-16 — the
// footer test caught it, which is the whole point of holding every surface to this symbol).
// The release driver (tools/release.py, `--step bump`) rewrites this line and nothing else.

/// The engine's own version string, numeric (`"4.3.0"`); surfaces that display it add the
/// leading `v` themselves.
public let engineVersion = "4.5.0"
