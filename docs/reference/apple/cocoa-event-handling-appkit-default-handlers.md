# Documentation packet — AppKit's automatic Apple Event handlers (job 148)
Fetched via WebFetch (renders developer.apple.com/library/archive verbatim) 2026-08-09.
Per the docs-packet rule: quoted content + source + local-header pointers.

## Why this was fetched
Job 148's brief asserted, from an unverified paraphrase of "an Apple archive",
that "For every Cocoa application, the Application Kit automatically installs
event handlers" as grounds for a theory that switching `main.swift` from
`NSApplication.shared.run()` to `NSApplicationMain` might install the missing
generic scripting Apple Event handler and fix the -1708 bug tracked in
[[soft-return-1708-dispatch-investigation]]. Per 00-METHOD ("never generate a
plist key/schema/format from memory — fetch/cite"), the claim was fetched and
checked against its actual source before code was written on top of it.

## Cocoa Event-Handling Guide — "Handling Apple Events in a Cocoa Application"
Source: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ScriptableCocoaApplications/SApps_handle_AEs/SAppsHandleAEs.html

- Exact sentence: "For every Cocoa application, the Application Kit
  automatically installs event handlers for Apple events it knows how to
  handle, including those sent by the Mac OS."
- Scope, made explicit elsewhere in the same document: this covers the
  REQUIRED Apple events sent by the OS — open application, reopen, open
  documents, print documents, open contents, quit — NOT custom/sdef-defined
  events.
- For everything else: "For other Apple events, a scriptable application
  doesn't typically install handlers directly (although it is free to do so)
  because it can use the script command mechanism. That mechanism, which
  automatically installs handlers based on information in the application's
  sdef file..." — i.e. custom sdef commands (like this app's `convert`) are
  NOT covered by the "Application Kit automatically installs" sentence at
  all; they go through `NSScriptSuiteRegistry`'s own separate mechanism.
- The document does not mention `NSApplicationMain` anywhere, and says
  nothing about any difference between `NSApplicationMain` and a hand-rolled
  `NSApplication.shared` + `run()` with respect to when/whether either kind
  of handler gets installed.
- Also notes the intended hook point for an app's OWN custom handlers: "At
  that point [`applicationWillFinishLaunching:`], the Application Kit has
  installed its default event handlers" — again, "default" meaning the
  required-suite ones, not custom sdef commands.

## Verdict for job 148
The premise behind the NSApplicationMain experiment does not hold up under
its own cited source: this document gives no reason to expect
`NSApplicationMain` vs. `run()` to change whether a custom sdef command like
`convert` gets an installed OS-level Apple Event handler. The experiment was
still run (cheap, and explicitly commissioned), and it reproduced -1708
identically to job 147 — consistent with, not contradicted by, this citation.
Do not re-propose "switch to NSApplicationMain" for -1708 without new
evidence; this specific citation has been checked and does not support it.
