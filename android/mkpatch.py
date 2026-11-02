"""Make an update patch: old APK + patch -> new APK (applied on the phone by Patch.kt).

Runs inside the timeline-diff image (build.sh):  python mkpatch.py OLD.apk NEW.apk OUT.patch
Format (all integers big-endian int64):
  "TLPATCH1" | new size | control count | then three zlib streams, each prefixed with its length:
  controls (x, y, z per entry), diff bytes, extra bytes.
For each control: add x diff bytes to x old bytes, copy y extra bytes, then move the old position by z (bsdiff).
"""
import struct, sys, zlib
import bsdiff4.core


def make(old: bytes, new: bytes) -> bytes:
    controls, diff, extra = bsdiff4.core.diff(old, new)
    ctrl = b"".join(struct.pack(">qqq", x, y, z) for x, y, z in controls)
    out = [b"TLPATCH1", struct.pack(">qq", len(new), len(controls))]
    for part in (ctrl, diff, extra):
        z = zlib.compress(part, 9)
        out += [struct.pack(">q", len(z)), z]
    return b"".join(out)


if __name__ == "__main__":
    old, new, dst = sys.argv[1:4]
    with open(old, "rb") as f: o = f.read()
    with open(new, "rb") as f: n = f.read()
    with open(dst, "wb") as f: f.write(make(o, n))
