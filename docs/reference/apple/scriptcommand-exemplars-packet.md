# NSScriptCommand — how WORKING scriptable apps shape their commands

Exemplar packet for finding F (the -1708 lead). Read from real source
2026-08-11: NetNewsWire (github.com/Ranchero-Software/
NetNewsWire, Mac/Scripting/*.swift) + the Skim/qwen/Gemini research.

## THE RULE every working app follows (and we broke)
Override ONLY `performDefaultImplementation()`. Do NOT override
`execute()`, `receiversSpecifier`, or `suspendExecution()`. Cocoa's own
`execute()` is what packages the return value into the reply — intercept
it and the reply can come back empty (-1708 to the caller).

## What performDefaultImplementation RETURNS (Cocoa-packagable only)
- NetNewsWire AppDelegate+Scriptability.swift:187-191 —
  `override func performDefaultImplementation() -> Any? {
     guard let result = super.performDefaultImplementation() else {
       return false as NSNumber }
     return result }`
  → returns `false as NSNumber` (a primitive Cocoa packages natively) or
  super's result. NEVER a custom-record NSDictionary.
- Author/Article/Feed/Folder/Account +Scriptability: return
  `objectSpecifier` / `scriptObjectSpecifier` (NSScriptObjectSpecifier)
  for "make/new" commands.
- Return shapes proven packagable: object specifiers, NSNumber, NSString,
  file URLs / lists (NSURL), boolean. NOT custom sdef record dicts
  (job 207 proved Cocoa has no auto-packaging for those).

## ASYNC result — the sanctioned pattern (if ever needed)
NetNewsWire Feed+Scriptability.swift:128-138 —
  `command.suspendExecution()`  ... later ...
  `command.resumeExecution(withResult: scriptableFeed.objectSpecifier)`
  (or `resumeExecution(withResult: nil)`). You call these; you do NOT
  override them.

## Reading the incoming event (allowed, non-intercepting)
NSScriptCommand+NetNewsWire.swift: read `self.appleEvent`,
`paramDescriptor(forKeyword:)`, `attributeDescriptor(forKeyword:"subj")`
to inspect insertion location / subject. Reading is fine; overriding the
execution/reply methods is not.

## Consequence for Soft Return (finding F)
ConvertCommand/DiagnoseCommand/ImportPageSettingsCommand must override
ONLY performDefaultImplementation, returning the job-216 shapes (file
list / text) which ARE packagable. Remove the execute()/
receiversSpecifier/suspendExecution overrides from the shipping commands
entirely; any diagnostic instrumentation goes in a DEBUG-only subclass.
