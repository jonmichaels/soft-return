#!/usr/bin/env python3
"""Prove a signed Mach-O's embedded entitlements from raw bytes — no macOS needed.

Born 2026-08-13, the morning after 4.0.0b15 shipped with QuickLook dead:
the appexes were re-signed without their entitlements plists, notarization
passed anyway (Apple checks WHO signed, not WHAT entitlements survived),
and nothing in the chain could prove the defect from the dev host. This can.

Usage:
    entitlements_probe.py <binary> [--require KEY] [--forbid KEY]

Walks the (fat or thin) Mach-O, finds LC_CODE_SIGNATURE, parses the code
signature SuperBlob, and extracts the entitlements blobs:
    0xfade7171  XML plist entitlements
    0xfade7172  DER entitlements
Prints per-arch: whether a signature exists, whether entitlement blobs
exist, and every com.apple.* key found. With --require KEY, exits 1
unless EVERY arch slice carries an entitlements blob containing KEY. With
--forbid KEY, exits 1 if ANY arch slice carries KEY. Both may be given
together (require one key, forbid another) — which is what the release
chain uses since job 392's un-sandboxing (app + 2 appexes + mdimporter/sr,
four different shapes now, not one):

    entitlements_probe.py QuickLook.appex/Contents/MacOS/X \\
        --require com.apple.security.app-sandbox
    entitlements_probe.py "Soft Return.app/Contents/MacOS/Soft Return" \\
        --forbid com.apple.security.app-sandbox
    entitlements_probe.py SoftReturnImporter.mdimporter/Contents/MacOS/X
    entitlements_probe.py "Soft Return.app/Contents/MacOS/sr"

Exit codes: 0 ok, 1 requirement not met, 2 parse/IO error.
"""
import re
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
MH_MAGIC = 0xFEEDFACE
MH_CIGAM = 0xCEFAEDFE
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_ENTITLEMENTS_XML = 0xFADE7171
CSMAGIC_ENTITLEMENTS_DER = 0xFADE7172

KEY_RE = re.compile(rb"com\.apple\.[A-Za-z0-9_.-]+")


def slices(data):
    """Yield (arch_offset, arch_size) for each Mach-O slice in the file."""
    (magic,) = struct.unpack_from(">I", data, 0)
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        (n,) = struct.unpack_from(">I", data, 4)
        off = 8
        wide = magic == FAT_MAGIC_64
        rec = ">IIQQI" if wide else ">IIIII"
        rec_len = struct.calcsize(rec)
        for _ in range(n):
            _cpu, _sub, o, s = struct.unpack_from(rec, data, off)[:4]
            yield o, s
            off += rec_len
    else:
        yield 0, len(data)


def code_signature_blob(data, base):
    """Return the raw code-signature superblob bytes for the slice at base, or None."""
    (magic,) = struct.unpack_from("<I", data, base)
    if magic in (MH_MAGIC_64, MH_MAGIC):
        endian = "<"
    elif magic in (MH_CIGAM_64, MH_CIGAM):
        endian = ">"
    else:
        return None
    is64 = magic in (MH_MAGIC_64, MH_CIGAM_64)
    ncmds_off = base + (16 if not is64 else 16)
    (ncmds,) = struct.unpack_from(endian + "I", data, ncmds_off)
    lc_off = base + (28 if not is64 else 32)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(endian + "II", data, lc_off)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from(endian + "II", data, lc_off + 8)
            return data[base + dataoff : base + dataoff + datasize]
        lc_off += cmdsize
    return None


def entitlement_blobs(sig):
    """Yield (magic, payload_bytes) for entitlement blobs in a superblob."""
    if len(sig) < 12:
        return
    magic, _length, count = struct.unpack_from(">III", sig, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        return
    for i in range(count):
        _slot, off = struct.unpack_from(">II", sig, 12 + 8 * i)
        bmagic, blen = struct.unpack_from(">II", sig, off)
        if bmagic in (CSMAGIC_ENTITLEMENTS_XML, CSMAGIC_ENTITLEMENTS_DER):
            yield bmagic, sig[off + 8 : off + blen]


def main():
    args = sys.argv[1:]
    require = None
    forbid = None
    if "--require" in args:
        i = args.index("--require")
        require = args[i + 1].encode()
        del args[i : i + 2]
    if "--forbid" in args:
        i = args.index("--forbid")
        forbid = args[i + 1].encode()
        del args[i : i + 2]
    if len(args) != 1:
        print(__doc__)
        return 2
    try:
        data = open(args[0], "rb").read()
    except OSError as e:
        print(f"error: {e}")
        return 2
    if len(data) < 8:
        print("error: not a Mach-O (too small)")
        return 2

    # Only --require/--forbid violations fail the gate. Missing signature/entitlement
    # blobs are reported either way, but they're not by themselves a failure — job 392's
    # mdimporter/sr shape carries NO entitlements at all, on purpose, and a bare (no-flag)
    # call against that binary must exit 0, not report a phantom "requirement not met".
    violated = False
    any_slice = False
    for n, (off, _size) in enumerate(slices(data)):
        any_slice = True
        sig = code_signature_blob(data, off)
        if sig is None:
            print(f"arch {n}: NO code signature")
            if require:
                violated = True
            continue
        keys = set()
        found_blob = False
        for bmagic, payload in entitlement_blobs(sig):
            found_blob = True
            kind = "xml" if bmagic == CSMAGIC_ENTITLEMENTS_XML else "der"
            for m in KEY_RE.finditer(payload):
                keys.add((kind, m.group().decode()))
        if not found_blob:
            print(f"arch {n}: signature present, NO entitlement blobs")
            if require:
                violated = True
            continue
        shown = sorted({k for _, k in keys})
        print(f"arch {n}: entitlements present: {', '.join(shown) or '(empty)'}")
        if require and not any(k.encode() == require for _, k in keys):
            print(f"arch {n}: MISSING required {require.decode()}")
            violated = True
        if forbid and any(k.encode() == forbid for _, k in keys):
            print(f"arch {n}: FORBIDDEN key present: {forbid.decode()}")
            violated = True
    if not any_slice:
        print("error: no Mach-O slices found")
        return 2
    if require or forbid:
        return 1 if violated else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
