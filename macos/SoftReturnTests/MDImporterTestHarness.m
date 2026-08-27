#import "MDImporterTestHarness.h"
#import <CoreFoundation/CFPlugInCOM.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreServices/CoreServices.h>
#import <dlfcn.h>

// job-132: queries the REAL Apple SDK constants (<CoreServices/CoreServices.h>'s
// Metadata.framework/MDImporter.h, imported above) -- `kMDImporterTypeID`,
// `kMDImporterURLInterfaceID` -- never local literals. job-131 found the previous version of
// this file redeclaring the SAME fabricated interface UUID `MDImporterGlue.m` answered
// (8B08C4B0-415B-11D8-B3F9-0003936726FC), which made this harness structurally blind to the bug:
// it queried for the plugin's own made-up id and of course got it back. Querying the real SDK
// constants is what a genuine `mdimport`/`mdworker` host does.
//
// `kSROldFabricatedInterfaceID` below is kept ONLY for `queryInterfaceSucceedsForOld...`'s
// negative control -- it must now fail.
#define kSROldFabricatedInterfaceID CFUUIDGetConstantUUIDWithBytes(NULL, \
    0x8B, 0x08, 0xC4, 0xB0, 0x41, 0x5B, 0x11, 0xD8, 0xB3, 0xF9, 0x00, 0x03, 0x93, 0x67, 0x26, 0xFC)

// Matches `MDImporterGlue.m`'s `SRMDImporterURLInterfaceStruct` shape exactly: Apple's real
// `MDImporterURLInterfaceStruct` (kMDImporterURLInterfaceID) has exactly one function after
// IUNKNOWN_C_GUTS, taking a CFURLRef -- this is that same shape, redeclared here because a
// CFPlugIn client and the plugin it loads have never needed (or had) a common header: the ABI
// contract IS the UUID + the vtable shape, nothing else.
typedef struct {
    IUNKNOWN_C_GUTS;
    Boolean (*GetMetadataForURL)(void *thisInterface, CFMutableDictionaryRef attributes,
                                  CFStringRef contentTypeUTI, CFURLRef url);
} SRTestMDImporterURLInterfaceStruct;

@implementation MDImporterTestHarness

+ (nullable NSDictionary<NSString *, id> *)metadataForFileAtURL:(NSURL *)fileURL
                                                importerBundleURL:(NSURL *)bundleURL
                                            forcePageCountFailure:(BOOL)forcePageCountFailure
                                                    failureReason:(NSString **)failureReason {
    CFPlugInRef plugin = CFPlugInCreate(kCFAllocatorDefault, (__bridge CFURLRef)bundleURL);
    if (plugin == NULL) {
        if (failureReason) *failureReason = @"CFPlugInCreate returned NULL";
        return nil;
    }

    // job-115: `CFPlugInRef` is toll-free bridged to `CFBundleRef` (see `CFPlugInCOM.h`'s own
    // typedef), so the executable this just loaded is reachable here, before `plugin` is
    // released below -- needed further down to `dlopen(..., RTLD_NOLOAD)` a proper handle onto
    // it, since CFBundle/CFPlugIn loads bundles into a LOCAL dlsym namespace that plain
    // `dlsym(RTLD_DEFAULT, ...)` cannot see into.
    CFURLRef executableURL = CFBundleCopyExecutableURL((CFBundleRef)plugin);
    NSString *executablePath = executableURL ? [(__bridge NSURL *)executableURL path] : nil;
    if (executableURL != NULL) CFRelease(executableURL);

    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kMDImporterTypeID, plugin);
    if (factories == NULL || CFArrayGetCount(factories) == 0) {
        if (factories != NULL) CFRelease(factories);
        CFRelease(plugin);
        if (failureReason) *failureReason = @"no CFPlugInFactories entry for kMDImporterTypeID";
        return nil;
    }
    CFUUIDRef factoryID = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);

    // CFPlugInInstanceCreate hands back the IUnknown interface directly (per its own header
    // comment) -- no separate "get the raw instance out of the wrapper" step, unlike the
    // obsolete CFPlugInInstanceRef-based API this file does NOT use.
    void *rawInstance = CFPlugInInstanceCreate(kCFAllocatorDefault, factoryID, kMDImporterTypeID);
    CFRelease(factories);
    CFRelease(plugin);
    if (rawInstance == NULL) {
        if (failureReason) *failureReason = @"CFPlugInInstanceCreate returned NULL";
        return nil;
    }

    // The real handshake: QueryInterface the raw IUnknown for the REAL Apple URL-based MDImporter
    // interface (kMDImporterURLInterfaceID) -- the same call `mdworker_shared` makes before it
    // will touch GetMetadataForURL at all.
    IUnknownVTbl **iunknown = (IUnknownVTbl **)rawInstance;
    void *importerRaw = NULL;
    HRESULT hr = (*iunknown)->QueryInterface(
        rawInstance, CFUUIDGetUUIDBytes(kMDImporterURLInterfaceID), &importerRaw);
    if (hr != 0 || importerRaw == NULL) {
        (*iunknown)->Release(rawInstance);
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:
                @"QueryInterface for kMDImporterURLInterfaceID failed, HRESULT=%d", (int)hr];
        }
        return nil;
    }

    SRTestMDImporterURLInterfaceStruct **importer = (SRTestMDImporterURLInterfaceStruct **)importerRaw;

    // job-115: the bundle's executable is already loaded in-process (CFPlugInCreate above
    // loaded it to find the factory function) -- `RTLD_NOLOAD` gets a handle onto that SAME
    // already-loaded image, without reloading it, so `dlsym` can resolve this testing-only
    // seam directly against it. Plain `dlsym(RTLD_DEFAULT, ...)` does NOT work here: CFBundle/
    // CFPlugIn loads bundles into a local dlsym namespace, invisible to RTLD_DEFAULT lookups
    // from another image (confirmed by trial -- the symbol resolved fine once looked up
    // through this handle instead).
    typedef void (*SetForcedPageCountFailureFn)(Boolean);
    void *bundleHandle = executablePath != nil
        ? dlopen(executablePath.fileSystemRepresentation, RTLD_NOLOAD)
        : NULL;
    SetForcedPageCountFailureFn setForcedPageCountFailure = bundleHandle != NULL
        ? (SetForcedPageCountFailureFn)dlsym(bundleHandle, "SRImporterSetForcedPageCountFailureForTesting")
        : NULL;
    if (forcePageCountFailure) {
        if (setForcedPageCountFailure == NULL) {
            (*importer)->Release(importerRaw);
            (*iunknown)->Release(rawInstance);
            if (failureReason) {
                *failureReason = @"SRImporterSetForcedPageCountFailureForTesting not found via dlsym";
            }
            return nil;
        }
        setForcedPageCountFailure(true);
    }

    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    Boolean ok = (*importer)->GetMetadataForURL(
        importerRaw, attributes, CFSTR("me.beforeti.wordstar-document"), (__bridge CFURLRef)fileURL);

    // Reset immediately so a forced failure never leaks into a later test sharing this
    // already-loaded, still-resident bundle image.
    if (forcePageCountFailure && setForcedPageCountFailure != NULL) {
        setForcedPageCountFailure(false);
    }

    (*importer)->Release(importerRaw);
    (*iunknown)->Release(rawInstance);

    if (!ok) {
        CFRelease(attributes);
        if (failureReason) *failureReason = @"GetMetadataForURL returned false";
        return nil;
    }

    return CFBridgingRelease(attributes);
}

+ (BOOL)queryInterfaceSucceedsForOldFabricatedUUIDInBundleAtURL:(NSURL *)bundleURL
                                                    failureReason:(NSString **)failureReason {
    CFPlugInRef plugin = CFPlugInCreate(kCFAllocatorDefault, (__bridge CFURLRef)bundleURL);
    if (plugin == NULL) {
        if (failureReason) *failureReason = @"CFPlugInCreate returned NULL";
        return NO;
    }

    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kMDImporterTypeID, plugin);
    if (factories == NULL || CFArrayGetCount(factories) == 0) {
        if (factories != NULL) CFRelease(factories);
        CFRelease(plugin);
        if (failureReason) *failureReason = @"no CFPlugInFactories entry for kMDImporterTypeID";
        return NO;
    }
    CFUUIDRef factoryID = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);

    void *rawInstance = CFPlugInInstanceCreate(kCFAllocatorDefault, factoryID, kMDImporterTypeID);
    CFRelease(factories);
    CFRelease(plugin);
    if (rawInstance == NULL) {
        if (failureReason) *failureReason = @"CFPlugInInstanceCreate returned NULL";
        return NO;
    }

    // The negative control itself: query for the OLD fabricated interface UUID job-131 found
    // `MDImporterGlue.m` answering. The fixed glue no longer recognizes it, so this must now
    // return E_NOINTERFACE -- if it ever returns S_OK again, the fabricated-UUID bug class has
    // come back.
    IUnknownVTbl **iunknown = (IUnknownVTbl **)rawInstance;
    void *interfaceRaw = NULL;
    HRESULT hr = (*iunknown)->QueryInterface(
        rawInstance, CFUUIDGetUUIDBytes(kSROldFabricatedInterfaceID), &interfaceRaw);
    BOOL succeeded = (hr == 0 && interfaceRaw != NULL);
    if (succeeded) {
        IUnknownVTbl **fabricatedInterface = (IUnknownVTbl **)interfaceRaw;
        (*fabricatedInterface)->Release(interfaceRaw);
    }
    (*iunknown)->Release(rawInstance);

    if (failureReason) {
        *failureReason = [NSString stringWithFormat:
            @"QueryInterface for the old fabricated UUID returned HRESULT=%d, interface=%p",
            (int)hr, interfaceRaw];
    }
    return succeeded;
}

@end
