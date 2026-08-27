#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads a classic CFPlugIn `.mdimporter` bundle exactly the way `mdimport`/`mdworker` do --
/// `CFPlugInCreate` -> `CFPlugInFindFactoriesForPlugInTypeInPlugIn` ->
/// `CFPlugInInstanceCreate` -> `QueryInterface` for the MDImporter interface -- and calls its
/// real `GetMetadataForURL` (job-101's mandatory executed-path verification: a green build
/// alone proves nothing about whether the plugin actually loads and runs). Independent of
/// `SoftReturnImporter`'s own `MDImporterGlue.m`: this file plays the CLIENT half of the same
/// CFPlugIn handshake, the way a real, separate host process (`mdworker_shared`) would.
@interface MDImporterTestHarness : NSObject

// `failureReason` is deliberately not named/typed `NSError **error` -- that exact shape makes
// Swift's importer rewrite this into a `throws` method and drop the parameter, which is more
// magic than this one-off test harness needs. A plain `NSString **` out-param imports as an
// ordinary optional pointer, no guessing required at the call site.
//
// `forcePageCountFailure` (job-115): when YES, forces `SRImporterCore`'s pageCount stage to
// fail for the duration of this one call, via the `dlsym`-resolved testing seam
// `SRImporterSetForcedPageCountFailureForTesting` -- see `MDImporterGlue.m`. Lets
// `MDImporterExecutedPathTests` prove, through the REAL loaded `.mdimporter`, that
// `kMDItemTextContent` survives a pageCount failure rather than only asserting it against the
// Swift source directly.
+ (nullable NSDictionary<NSString *, id> *)metadataForFileAtURL:(NSURL *)fileURL
                                                importerBundleURL:(NSURL *)bundleURL
                                            forcePageCountFailure:(BOOL)forcePageCountFailure
                                                    failureReason:(NSString * _Nullable * _Nullable)failureReason;

// job-132's negative control, pinning the bug class shut: job-131 found `MDImporterGlue.m`
// answering a FABRICATED interface UUID (8B08C4B0-415B-11D8-B3F9-0003936726FC -- one byte off
// `kMDImporterTypeID`) instead of Apple's real `kMDImporterInterfaceID`/`kMDImporterURLInterfaceID`,
// which is why real `mdimport`/`mdworker` silently never called this plugin. Loads the built
// bundle exactly like `metadataForFileAtURL:...` above, but QueryInterfaces for that SAME old
// fabricated UUID and reports whether it still succeeds. Must return NO now that the glue only
// answers the real Apple interfaces -- if this ever returns YES again, the fabricated-UUID bug
// class has come back.
+ (BOOL)queryInterfaceSucceedsForOldFabricatedUUIDInBundleAtURL:(NSURL *)bundleURL
                                                    failureReason:(NSString * _Nullable * _Nullable)failureReason
    NS_SWIFT_NAME(queryInterfaceSucceedsForOldFabricatedUUID(inBundleAt:failureReason:));

@end

NS_ASSUME_NONNULL_END
