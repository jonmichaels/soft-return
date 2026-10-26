import Testing
import TestSupport

/// The two corpus gates as Swift Testing traits. The armed check and the skip reason both come
/// from `TestSupport.Corpus`; this file only adapts the reason's type (`.enabled(if:_:)` takes
/// a `Comment`, and a `String` does not convert), which is why `TestSupport` itself, with no
/// `Testing` import, cannot offer them.
extension Trait where Self == ConditionTrait {
    /// Runs only with `CTRLKD_SAWYER_ARCHIVE` set; otherwise a recorded Skip naming it.
    static var requiresSawyerArchive: Self {
        .enabled(if: Corpus.sawyerArchiveArmed, Comment(rawValue: Corpus.sawyerArchiveSkipReason))
    }

    /// Runs only with `CTRLKD_PRIVATE_CORPUS` set; otherwise a recorded Skip naming it.
    static var requiresPrivateCorpus: Self {
        .enabled(if: Corpus.privateCorpusArmed, Comment(rawValue: Corpus.privateCorpusSkipReason))
    }
}
