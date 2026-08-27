import Carbon
import Foundation
import Testing
@testable import SoftReturn

/// Job 207. `ScriptingRecordBuilder` is the one shared place any scripting command builds a
/// reply-packagable record descriptor — see its own doc comment for why this exists.
@Suite struct ScriptingRecordBuilderTests {
    @Test func recordRetypesToTheGivenCodeAndCarriesEachProperty() throws {
        let descriptor = ScriptingRecordBuilder.record(code: "SRrc", properties: [
            (code: "SRc1", value: NSAppleEventDescriptor(int32: 3)),
            (code: "SRc2", value: NSAppleEventDescriptor(int32: 1)),
        ])
        #expect(descriptor.descriptorType == ScriptingCodes.fourCharCode("SRrc"))
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRc1"))?.int32Value == 3)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRc2"))?.int32Value == 1)
    }

    /// Job 207: the empirical finding `ScriptingRecordBuilder.record`'s own doc comment cites
    /// — proved once here, against the real runtime, and kept as a standing regression rather
    /// than trusted from memory (00-METHOD). Job 185's `wholeApplicationSpecifier()` retyping
    /// trick (build a plain record, then `NSAppleEventDescriptor(descriptorType:data:)` under
    /// a new type) was never actually verified for READ access — that record was only ever
    /// WRITTEN into an event attribute. It turns out to break `isRecordDescriptor`/
    /// `forKeyword` entirely; `coerce(toDescriptorType:)` on the same plain record does not.
    /// If this ever starts failing, `ScriptingRecordBuilder.record`'s implementation choice
    /// needs to be revisited, not just this test.
    @Test func manualRetypingBreaksPropertyReadAccessButCoercionDoesNot() throws {
        let plain = NSAppleEventDescriptor.record()
        plain.setDescriptor(NSAppleEventDescriptor(int32: 3), forKeyword: ScriptingCodes.fourCharCode("SRc1"))
        #expect(plain.isRecordDescriptor)
        #expect(plain.forKeyword(ScriptingCodes.fourCharCode("SRc1"))?.int32Value == 3)

        let manualRetype = NSAppleEventDescriptor(
            descriptorType: ScriptingCodes.fourCharCode("SRrc"), data: plain.data)!
        #expect(!manualRetype.isRecordDescriptor,
                "recording current behavior: a manual descriptorType:data: reinterpretation is NOT record-like, even though the bytes are AERecord-shaped")
        #expect(manualRetype.forKeyword(ScriptingCodes.fourCharCode("SRc1")) == nil,
                "recording current behavior: forKeyword on the manually-retyped descriptor returns nil")

        let coerced = try #require(plain.coerce(toDescriptorType: ScriptingCodes.fourCharCode("SRrc")))
        #expect(coerced.isRecordDescriptor)
        #expect(coerced.descriptorType == ScriptingCodes.fourCharCode("SRrc"))
        #expect(coerced.forKeyword(ScriptingCodes.fourCharCode("SRc1"))?.int32Value == 3)
    }

    /// Empirical, not assumed (00-METHOD): `NSAppleEventDescriptor.h`'s
    /// `insertDescriptor:atIndex:` declaration carries no doc comment on index semantics, and
    /// this codebase's only prior multi-item list construction
    /// (`ScriptingFileArgumentTests.urlsDecodesAListOfTypeFileURLDescriptors`) never asserted
    /// order (`.sorted()`/`Set` on the decoded result). `diagnosis`'s "dot commands" property
    /// is documented as "in file order," so order must actually be verified, not guessed.
    @Test func listPreservesInsertionOrder() throws {
        let list = ScriptingRecordBuilder.list([
            NSAppleEventDescriptor(string: "first"),
            NSAppleEventDescriptor(string: "second"),
            NSAppleEventDescriptor(string: "third"),
        ])
        #expect(list.numberOfItems == 3)
        let decoded = (1...3).map { list.atIndex($0)?.stringValue }
        #expect(decoded == ["first", "second", "third"])
    }

    @Test func listOfZeroValuesIsAnEmptyList() throws {
        let list = ScriptingRecordBuilder.list([])
        #expect(list.numberOfItems == 0)
    }
}
