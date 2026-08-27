import Foundation

/// Job 207 (-1708, continuing 143-199): builds the hand-typed `NSAppleEventDescriptor`
/// records `SoftReturn.sdef`'s custom `<record-type>`s require for a command's `<result>`.
///
/// Job 199's field breadcrumbs showed `ConvertCommand` running clean end-to-end
/// (constructed → executeCommand-entered → pdi-entered → executeCommand-returned,
/// `scriptErrorNumber=none`) while the real sender still received -1708. Job 207's own
/// reproduction (`ConvertCommandReceiverDispatchTests.replyResultDescriptorForA
/// PlainDictionaryReturn`/`...AtLayer2`/`realFieldEventReplyResultDescriptorAtLayer2`) showed
/// why: the reply's `keyAEResult` comes back completely ABSENT, at every reachable dispatch
/// layer including a replay of the real field-captured bytes, even though dispatch status
/// and the reply's error keys are clean. Cocoa's own reply-packaging code apparently has no
/// general coercion from an arbitrary `NSDictionary` (what `performDefaultImplementation()`
/// used to return) to a *custom* sdef record type — it silently drops the result instead of
/// erroring. Every command whose sdef `<result>` is one of `SoftReturn.sdef`'s own
/// `<record-type>`s (`conversion result`/`SRrc`, `diagnosis`/`SRrd`, `page settings`/`SRrp`)
/// must instead hand Cocoa an already-typed `NSAppleEventDescriptor` — this is the one place
/// that happens, so no command grows its own copy of the retyping trick.
enum ScriptingRecordBuilder {
    /// Builds a record retyped to `code` (an sdef `<record-type code="...">`) with each
    /// property set by its own sdef property code: build a plain `typeAERecord`, set its
    /// keyed properties, then `coerce(toDescriptorType:)` to the target type.
    ///
    /// `coerce(toDescriptorType:)`, not a manual `NSAppleEventDescriptor(descriptorType:
    /// data:)` reinterpretation of the raw bytes (the trick `ConvertCommandReceiverDispatch
    /// Tests.wholeApplicationSpecifier()`, job 185, used for `typeObjectSpecifier` — but that
    /// code was only ever WRITTEN into an event attribute, never read back). Job 207's own
    /// `ScriptingRecordBuilderTests.manualRetypingBreaksPropertyReadAccessButCoercionDoesNot`
    /// proved empirically that the manual/`data:` route produces a descriptor with
    /// `isRecordDescriptor == false` and every `forKeyword` lookup returning `nil` — Cocoa
    /// does not treat an arbitrary four-char type tag as "record-like" just because its bytes
    /// happen to be AERecord-shaped (the header's own `isRecordDescriptor` doc comment says as
    /// much: "may have a descriptorType other than typeAERecord... such as
    /// typeObjectSpecifier" — an explicit, presumably short, allowlist of known record-like
    /// types, not "any type tag"). `coerce(toDescriptorType:)` goes through the real AE
    /// coercion machinery instead and keeps the record readable under its new type.
    static func record(code: String, properties: [(code: String, value: NSAppleEventDescriptor)]) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        for (propertyCode, value) in properties {
            record.setDescriptor(value, forKeyword: ScriptingCodes.fourCharCode(propertyCode))
        }
        return record.coerce(toDescriptorType: ScriptingCodes.fourCharCode(code))!
    }

    /// Builds a `typeAEList` from `values`, preserving order — needed for `diagnosis`'s "dot
    /// commands" property (`SRrd`'s `SRd3`, sdef: "Dot commands observed, in file order").
    /// `ScriptingRecordBuilderTests.listPreservesInsertionOrder` empirically confirms the
    /// index scheme below against the real Cocoa Scripting runtime (00-METHOD: platform
    /// index semantics aren't documented in `NSAppleEventDescriptor.h`'s
    /// `insertDescriptor:atIndex:` declaration, so this is proven by a passing test, not
    /// assumed) rather than trusting this codebase's existing single-item-list call sites,
    /// which never exercised order with more than one real item.
    static func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (offset, value) in values.enumerated() {
            list.insert(value, at: offset + 1)
        }
        return list
    }
}
