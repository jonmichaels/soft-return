#import <CoreFoundation/CFPlugInCOM.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#import <os/log.h>
#import <stdio.h>
#import <unistd.h>

#import "SoftReturnImporter-Swift.h"

// job-115: entry/exit + returned-bool logging around the one call `mdworker`/`mdimport`
// actually make. Same subsystem as `ImporterCore.swift`'s `Logger` so `log show --predicate
// 'subsystem == "me.beforeti.softreturn.importer"'` shows the whole call, C and Swift sides
// together, in order.
static os_log_t SRImporterLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("me.beforeti.softreturn.importer", "glue");
    });
    return log;
}

// Testing-only seam (job-115): lets the executed-path test harness
// (`MDImporterTestHarness.m`) force `SRImporterCore`'s pageCount stage to fail from OUTSIDE
// this bundle, without linking (or importing) its Swift module -- resolved via `dlsym`, the
// same by-name resolution CFPlugIn itself uses to find `SoftReturnImporterFactory` below.
// Exported with plain C linkage so `dlsym(RTLD_DEFAULT, "SRImporterSetForcedPageCountFailureForTesting")`
// can find it once this bundle is loaded in-process. `mdworker` never calls this.
void SRImporterSetForcedPageCountFailureForTesting(Boolean value) {
    [SRImporterCore setForcedPageCountFailureForTesting:value];
}

/// THE CLASSIC APPLE MDIMPORTER SHAPE (job-132 rewrite): job-131 proved by byte comparison that
/// the previous `kSRMDImporterInterfaceID` here (8B08C4B0-415B-11D8-B3F9-0003936726FC) was
/// fabricated -- it's `kMDImporterTypeID` with its last byte flipped from 0xBF to 0xB0, not a
/// real Apple constant. Real `mdimport`/`mdworker` QueryInterface for the real
/// `kMDImporterInterfaceID` or `kMDImporterURLInterfaceID` and got E_NOINTERFACE from that
/// fabricated id, so this plugin was never actually invoked outside our own test harness, which
/// queried the same fabricated id and was therefore structurally blind to the bug.
///
/// <CoreServices/CoreServices.h> (imported above) pulls in Metadata.framework's MDImporter.h,
/// which IS present in the current SDK (confirmed by reading it directly at
/// .../CoreServices.framework/.../Metadata.framework/Headers/MDImporter.h), so this now uses
/// Apple's own `kMDImporterInterfaceID` / `kMDImporterURLInterfaceID` / `kMDImporterTypeID`
/// macros directly instead of redefining them.
///
/// Apple's header declares TWO separate one-function interfaces, not one combined struct:
/// `MDImporterInterfaceStruct` (kMDImporterInterfaceID) has only `ImporterImportData` (a path),
/// and `MDImporterURLInterfaceStruct` (kMDImporterURLInterfaceID) has only
/// `ImporterImportURLData` (a URL) -- both at the same vtable slot (index 3, right after the
/// IUNKNOWN_C_GUTS triplet). A caller that queries the URL interface will call that slot
/// expecting a URL-taking function; handing back a combined vtable with the file function sitting
/// in that slot would be an ABI mismatch. So this plugin now models each as its own sub-interface
/// with its own correctly-shaped vtable, both backed by the same instance/refcount.

// This plugin's OWN factory UUID -- the same one `Info.plist`'s `CFPlugInFactories` key maps to
// `SoftReturnImporterFactory` (6C1B0F62-6E1D-4B0F-9B0E-6D9C0A4F2E51). CFPlugInAddInstanceForFactory/
// CFPlugInRemoveInstanceForFactory need THIS id, not the interface id -- CFPlugIn tracks
// per-factory instance counts to decide when a load-on-demand bundle can be safely unloaded, and
// the factory function itself (`CFPlugInFactoryFunction`) is never handed its own UUID as an
// argument, so it has to be a compile-time constant matching the Info.plist entry exactly.
#define kSRMDImporterFactoryID CFUUIDGetConstantUUIDWithBytes(NULL, \
    0x6C, 0x1B, 0x0F, 0x62, 0x6E, 0x1D, 0x4B, 0x0F, 0x9B, 0x0E, 0x6D, 0x9C, 0x0A, 0x4F, 0x2E, 0x51)

typedef struct {
    IUNKNOWN_C_GUTS;
    Boolean (*GetMetadataForFile)(void *thisInterface, CFMutableDictionaryRef attributes,
                                   CFStringRef contentTypeUTI, CFStringRef pathToFile);
} SRMDImporterFileInterfaceStruct;

typedef struct {
    IUNKNOWN_C_GUTS;
    Boolean (*GetMetadataForURL)(void *thisInterface, CFMutableDictionaryRef attributes,
                                  CFStringRef contentTypeUTI, CFURLRef url);
} SRMDImporterURLInterfaceStruct;

typedef struct SRImporterPluginType SRImporterPluginType;

// Each sub-interface begins with its own vtable pointer at offset 0 (so it's independently a
// valid COM/CFPlugIn "this" pointer for its interface) followed by a back-pointer to the shared
// owning instance, so QueryInterface/AddRef/Release reached through EITHER sub-interface can
// recover the one shared refcount. Both sub-structs have an identical {vtable ptr, owner ptr}
// layout, so `SRSubInterfaceHeader` below is used purely to read `owner` back out generically.
typedef struct {
    SRMDImporterFileInterfaceStruct *conduit;
    SRImporterPluginType *owner;
} SRFileSubInterface;

typedef struct {
    SRMDImporterURLInterfaceStruct *conduit;
    SRImporterPluginType *owner;
} SRURLSubInterface;

typedef struct {
    void *conduit;
    SRImporterPluginType *owner;
} SRSubInterfaceHeader;

struct SRImporterPluginType {
    SRFileSubInterface fileInterface;
    SRURLSubInterface urlInterface;
    CFUUIDRef factoryID;
    UInt32 refCount;
};

// Spotlight attribute keys, as literal string constants rather than pulled from a header:
// the attribute name IS the string (e.g. an attribute set via CFSTR("kMDItemTextContent") is
// indistinguishable, on the wire, from one set via the SDK's own `kMDItemTextContent` constant
// -- both are just that string). Sidesteps the same header-availability question as the UUIDs
// above.
static CFStringRef const kSRMDItemTitle = CFSTR("kMDItemTitle");
static CFStringRef const kSRMDItemTextContent = CFSTR("kMDItemTextContent");
static CFStringRef const kSRMDItemNumberOfPages = CFSTR("kMDItemNumberOfPages");
static CFStringRef const kSRMDItemKeywords = CFSTR("kMDItemKeywords");

// Cheap permanent diagnostic (job-129): every invocation drops a marker in the temp dir so a
// human (or test) can prove mdworker/mdimport actually reached this code, without depending on
// log redirection or Console access. NSTemporaryDirectory() is the one place writable from
// inside the mdworker sandbox. Must never affect the import outcome -- every failure here is
// swallowed.
static void SRWriteInvocationMarker(NSString *incomingPath) {
    @try {
        NSString *fileName = [NSString stringWithFormat:@"sr-importer-invoked-%d.txt", getpid()];
        NSString *markerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
        FILE *f = fopen(markerPath.fileSystemRepresentation, "a");
        if (f != NULL) {
            fprintf(f, "%s %s\n", incomingPath.UTF8String ?: "",
                    [[NSDate date] description].UTF8String ?: "");
            fclose(f);
        }
    } @catch (__unused NSException *exception) {
        // Ignored intentionally -- see comment above.
    }
}

static Boolean SRGetMetadataForURL(void *thisInterface, CFMutableDictionaryRef attributes,
                                    CFStringRef contentTypeUTI, CFURLRef url) {
    @autoreleasepool {
        NSURL *nsURL = (__bridge NSURL *)url;
        SRWriteInvocationMarker(nsURL.path);
        os_log(SRImporterLog(), "GetMetadataForURL enter: %{public}@ (uti=%{public}@)",
               nsURL.path, (__bridge NSString *)contentTypeUTI);

        NSDictionary<NSString *, id> *result =
            [SRImporterCore attributesForFileAtURL:nsURL];
        if (result == nil) {
            os_log_error(SRImporterLog(), "GetMetadataForURL exit: %{public}@ -> NO (no attributes)",
                         nsURL.path);
            return NO;
        }

        NSString *title = result[@"title"];
        NSString *textContent = result[@"textContent"];
        NSNumber *pageCount = result[@"pageCount"];
        NSArray<NSString *> *keywords = result[@"keywords"];

        if (title != nil) {
            CFDictionarySetValue(attributes, kSRMDItemTitle, (__bridge CFStringRef)title);
        }
        if (textContent != nil) {
            CFDictionarySetValue(attributes, kSRMDItemTextContent, (__bridge CFStringRef)textContent);
        }
        if (pageCount != nil) {
            CFDictionarySetValue(attributes, kSRMDItemNumberOfPages, (__bridge CFNumberRef)pageCount);
        }
        if (keywords != nil) {
            CFDictionarySetValue(attributes, kSRMDItemKeywords, (__bridge CFArrayRef)keywords);
        }

        os_log(SRImporterLog(), "GetMetadataForURL exit: %{public}@ -> YES (keys=%{public}@)",
               nsURL.path, result.allKeys);
        return YES;
    }
}

// The classic pair Spotlight has always called one of: `GetMetadataForFile` (a path) predates
// `GetMetadataForURL` and is kept here as a thin alias onto it, per job-101's brief, rather than
// reimplementing the read.
static Boolean SRGetMetadataForFile(void *thisInterface, CFMutableDictionaryRef attributes,
                                     CFStringRef contentTypeUTI, CFStringRef pathToFile) {
    os_log(SRImporterLog(), "GetMetadataForFile enter: %{public}@ (path variant, delegating to URL variant)",
           (__bridge NSString *)pathToFile);
    NSURL *url = [NSURL fileURLWithPath:(__bridge NSString *)pathToFile];
    return SRGetMetadataForURL(thisInterface, attributes, contentTypeUTI, (__bridge CFURLRef)url);
}

static ULONG SRAddRef(void *thisInterface) {
    SRImporterPluginType *owner = ((SRSubInterfaceHeader *)thisInterface)->owner;
    owner->refCount += 1;
    return owner->refCount;
}

static void SRDeallocPlugin(SRImporterPluginType *thisInstance);

static ULONG SRRelease(void *thisInterface) {
    SRImporterPluginType *owner = ((SRSubInterfaceHeader *)thisInterface)->owner;
    owner->refCount -= 1;
    if (owner->refCount == 0) {
        SRDeallocPlugin(owner);
        return 0;
    }
    return owner->refCount;
}

// Answers the two REAL Apple interfaces (job-132) -- the fabricated single UUID this used to
// check is gone. `kMDImporterURLInterfaceID` and `kMDImporterInterfaceID` come straight from
// <CoreServices/CoreServices.h>'s Metadata.framework/MDImporter.h, imported above. Each is handed
// back as its own correctly-shaped sub-interface (see the struct comment above); IUnknown queries
// are answered with whichever sub-interface was asked through, which is a valid identity choice
// since both share the same owning instance and refcount.
static HRESULT SRQueryInterface(void *thisInterface, REFIID iid, LPVOID *ppv) {
    SRImporterPluginType *owner = ((SRSubInterfaceHeader *)thisInterface)->owner;
    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(interfaceID, kMDImporterURLInterfaceID)) {
        SRAddRef(&owner->urlInterface);
        *ppv = &owner->urlInterface;
        result = S_OK;
    } else if (CFEqual(interfaceID, kMDImporterInterfaceID)) {
        SRAddRef(&owner->fileInterface);
        *ppv = &owner->fileInterface;
        result = S_OK;
    } else if (CFEqual(interfaceID, IUnknownUUID)) {
        SRAddRef(thisInterface);
        *ppv = thisInterface;
        result = S_OK;
    } else {
        *ppv = NULL;
    }
    CFRelease(interfaceID);
    return result;
}

static SRMDImporterFileInterfaceStruct sSRFileInterfaceFtbl = {
    NULL,
    SRQueryInterface,
    SRAddRef,
    SRRelease,
    SRGetMetadataForFile,
};

static SRMDImporterURLInterfaceStruct sSRURLInterfaceFtbl = {
    NULL,
    SRQueryInterface,
    SRAddRef,
    SRRelease,
    SRGetMetadataForURL,
};

static SRImporterPluginType *SRAllocPlugin(CFUUIDRef factoryID) {
    SRImporterPluginType *newPlugin = (SRImporterPluginType *)malloc(sizeof(SRImporterPluginType));
    newPlugin->fileInterface.conduit = &sSRFileInterfaceFtbl;
    newPlugin->fileInterface.owner = newPlugin;
    newPlugin->urlInterface.conduit = &sSRURLInterfaceFtbl;
    newPlugin->urlInterface.owner = newPlugin;
    newPlugin->factoryID = (CFUUIDRef)CFRetain(factoryID);
    CFPlugInAddInstanceForFactory(factoryID);
    newPlugin->refCount = 1;
    return newPlugin;
}

static void SRDeallocPlugin(SRImporterPluginType *thisInstance) {
    CFUUIDRef factoryID = thisInstance->factoryID;
    free(thisInstance);
    if (factoryID != NULL) {
        CFPlugInRemoveInstanceForFactory(factoryID);
        CFRelease(factoryID);
    }
}

// The one symbol `Info.plist`'s `CFPlugInFactories` names -- CFPlugIn resolves it by that
// string, dlsym-style, once dynamic registration (`CFPlugInDynamicRegistration` = NO) has told
// it exactly which type this factory answers for. Named + exported to match the canonical shape
// every shipping CFPlugIn importer uses (job-153 Part E.b, copied from
// docs/reference/spotlight-schemas/libreoffice-main.m lines ~190-205) -- our own factory UUID
// (kSRMDImporterFactoryID above) is unchanged, only the symbol name and export attribute move
// to match the template.
__attribute__ ((visibility("default")))
void *
MetadataImporterPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    if (!CFEqual(typeID, kMDImporterTypeID)) {
        return NULL;
    }
    SRImporterPluginType *plugin = SRAllocPlugin(kSRMDImporterFactoryID);
    return &plugin->urlInterface;
}
