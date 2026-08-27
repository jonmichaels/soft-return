import AppKit

/// The entry point, written out rather than synthesized.
///
/// Experiment (job 148, -1708 investigation): calls `NSApplicationMain` instead of
/// `NSApplication.shared.run()`. `NSApplicationMain` still needs the delegate attached
/// BEFORE it runs — `NSApplication.shared` is a singleton, so accessing `.shared` here and
/// setting its delegate before the call means `NSApplicationMain` picks up the same instance
/// and delegate rather than creating a fresh one. There is no `NSMainNibFile` in Info.plist,
/// so `NSApplicationMain` skips nib loading and proceeds straight to
/// `applicationWillFinishLaunching`/`applicationDidFinishLaunching` exactly as `run()` did.
///
/// The delegate is held in a top-level binding so it lives as long as the process —
/// `NSApplication.delegate` is a weak reference, and a delegate created inline would be
/// deallocated immediately, putting us right back to no callbacks.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate

NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
