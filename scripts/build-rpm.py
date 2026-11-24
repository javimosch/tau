#!/usr/bin/env python3
# build-rpm.py — build a .rpm package for tau with the Python stdlib only.
#
#   scripts/build-rpm.py --binary zig-out/bin/tau --version 0.5.0 \
#       --arch x86_64 --output dist/tau-0.5.0-1.x86_64.rpm
#   scripts/build-rpm.py --verify dist/tau-0.5.0-1.x86_64.rpm
#
# Emits an RPM v3 package installable via `dnf install ./tau-*.rpm` or
# `rpm -i`. rpmbuild is not always present (e.g. Debian-family CI runners),
# so this writes the format directly: lead + signature header + main header
# + gzip'd SVR4 "newc" cpio payload. The payload is /usr/bin/tau only,
# matching install.sh.
#
# --verify re-parses a built package: checks the lead magic, recomputes the
# signature digests over header+payload, walks the main header tags, gunzips
# the payload, and confirms the cpio member for ./usr/bin/tau matches the
# FILEDIGESTS sha256.

import argparse
import gzip
import hashlib
import os
import re
import struct
import sys

LEAD_MAGIC = b"\xed\xab\xee\xdb"
HEADER_MAGIC = b"\x8e\xad\xe8"

# Header value types (per the RPM format doc).
T_NULL, T_CHAR, T_INT8, T_INT16, T_INT32, T_INT64, T_STRING, T_BIN, T_STRING_ARRAY, T_I18N = range(10)

# Tag/type tables for the headers we emit.
REGION_TAG = 63            # RPMTAG_HEADERIMMUTABLE
SIGTAG_SIZE = 1000         # RPMSIGTAG_SIZE
SIGTAG_MD5 = 1004          # RPMSIGTAG_MD5
SIGTAG_SHA256 = 1006       # RPMSIGTAG_SHA256
SIGTAG_PAYLOADSIZE = 1007  # RPMSIGTAG_PAYLOADSIZE

ALIGN = {T_INT16: 2, T_INT32: 4, T_INT64: 8}


def _pad(size, n):
    return (n - (size % n)) % n


def _encode(value_type, values):
    """Return (blob, count) for a tag's store data."""
    if value_type == T_STRING:
        return values.encode() + b"\x00", 1
    if value_type in (T_STRING_ARRAY, T_I18N):
        return b"".join(v.encode() + b"\x00" for v in values), len(values)
    if value_type == T_BIN:
        return values, len(values)
    if value_type == T_INT16:
        return b"".join(struct.pack(">H", v & 0xFFFF) for v in values), len(values)
    if value_type == T_INT32:
        return b"".join(struct.pack(">I", v & 0xFFFFFFFF) for v in values), len(values)
    raise ValueError(f"unsupported type {value_type}")


def _header(entries):
    """Serialize an RPM header from [(tag, type, values), ...]. Returns bytes."""
    entries = sorted(entries, key=lambda e: e[0])
    index = []
    store = b""
    for tag, vtype, values in entries:
        blob, count = _encode(vtype, values)
        store += b"\x00" * _pad(len(store), ALIGN.get(vtype, 1))
        index.append((tag, vtype, len(store), count))
        store += blob
    out = HEADER_MAGIC + b"\x01" + b"\x00" * 4  # magic + version + reserved
    out += struct.pack(">II", len(index), len(store))
    for tag, vtype, off, count in index:
        out += struct.pack(">IIII", tag, vtype, off, count)
    return out + store


def _region_entry():
    """The immutable-region index entry, stored as a BIN blob in the store."""
    return struct.pack(">IIII", REGION_TAG, T_BIN, 0, 16)


def _cpio_member(name, mode, data=b"", ino=1):
    """One SVR4 newc cpio entry (name without leading slash, e.g. ./usr/bin/tau)."""
    namesize = len(name) + 1
    fields = [
        "070701",
        f"{ino:08x}", f"{mode:08x}", "00000000", "00000000", "00000001",
        "00000000", f"{len(data):08x}", "00000000", "00000000",
        "00000000", "00000000", f"{namesize:08x}", "00000000",
    ]
    entry = "".join(fields).encode() + name.encode() + b"\x00"
    entry += b"\x00" * _pad(len(entry), 4)
    entry += data + b"\x00" * _pad(len(entry) + len(data), 4)
    return entry


def _payload(install_path, data):
    cpio = _cpio_member("." + install_path, 0o100755, data)
    cpio += _cpio_member("TRAILER!!!", 0, b"", ino=0)
    return cpio + b"\x00" * _pad(len(cpio), 512)


def build(binary, version, release, arch):
    with open(binary, "rb") as f:
        data = f.read()
    install_path = "/usr/bin/tau"
    pkg_name = f"tau-{version}-{release}"
    sha256 = hashlib.sha256(data).hexdigest()

    payload = gzip.compress(_payload(install_path, data), compresslevel=9, mtime=0)

    main_tags = [
        (REGION_TAG, T_BIN, _region_entry()),
        (100, T_STRING_ARRAY, ["C"]),                      # HEADERI18NTABLE
        (1000, T_STRING, "tau"),                           # NAME
        (1001, T_STRING, version),                         # VERSION
        (1002, T_STRING, release),                         # RELEASE
        (1004, T_I18N, ["agent-first AI CLI"]),            # SUMMARY
        (1005, T_I18N, ["tau is a non-interactive, JSON-first command-line "
                        "AI client designed for agent use: deterministic "
                        "output, stable exit codes, and a documented "
                        "tool-calling loop."]),            # DESCRIPTION
        (1006, T_INT32, [0]),                              # BUILDTIME
        (1009, T_INT32, [len(data)]),                      # SIZE
        (1014, T_STRING, "MIT"),                           # LICENSE
        (1015, T_STRING, "javimosch <noreply@github.com>"),# PACKAGER
        (1016, T_I18N, ["Applications/System"]),           # GROUP
        (1020, T_STRING, "https://github.com/javimosch/tau"),  # URL
        (1021, T_STRING, "linux"),                         # OS
        (1022, T_STRING, arch),                            # ARCH
        (1028, T_INT32, [len(data)]),                      # FILESIZES
        (1030, T_INT16, [0o100755]),                       # FILEMODES
        (1033, T_INT16, [0]),                              # FILERDEVS
        (1034, T_INT32, [0]),                              # FILEMTIMES
        (1035, T_STRING_ARRAY, [sha256]),                  # FILEDIGESTS
        (1036, T_STRING_ARRAY, [""]),                      # FILELINKTOS
        (1037, T_INT32, [0]),                              # FILEFLAGS
        (1039, T_STRING_ARRAY, ["root"]),                  # FILEUSERNAME
        (1040, T_STRING_ARRAY, ["root"]),                  # FILEGROUPNAME
        (1045, T_INT32, [0xFFFFFFFF]),                     # FILEVERIFYFLAGS
        (1047, T_STRING_ARRAY, ["tau", f"tau({arch.replace('_', '-')})"]),  # PROVIDENAME
        (1048, T_STRING_ARRAY, [f"{version}-{release}"] * 2),                # PROVIDEVERSION
        (1049, T_STRING_ARRAY, ["rpmlib(CompressedFileNames)",
                                "rpmlib(FileDigests)",
                                "rpmlib(PayloadFilesHavePrefix)"]),          # REQUIRENAME
        (1050, T_STRING_ARRAY, ["3.0.4-1", "4.6.0-1", "4.0-1"]),             # REQUIREVERSION
        (1053, T_INT32, [266, 266, 266]),                  # REQUIREFLAGS (LESS|EQUAL|RPMLIB)
        (1095, T_INT32, [1]),                              # FILEDEVICES
        (1096, T_INT32, [1]),                              # FILEINODES
        (1097, T_STRING_ARRAY, [""]),                      # FILELANGS
        (1112, T_INT32, [8, 8]),                           # PROVIDEFLAGS (EQUAL)
        (1117, T_STRING_ARRAY, ["tau"]),                   # BASENAMES
        (1118, T_STRING_ARRAY, ["/usr/bin/"]),             # DIRNAMES
        (1119, T_INT32, [0]),                              # DIRINDEXES
        (1124, T_STRING, "cpio"),                          # PAYLOADFORMAT
        (1125, T_STRING, "gzip"),                          # PAYLOADCOMPRESSOR
        (1126, T_STRING, "9"),                             # PAYLOADFLAGS
        (5011, T_INT32, [8]),                              # FILEDIGESTALGO (SHA256)
    ]
    main_header = _header(main_tags)

    signed = main_header + payload
    sig_tags = [
        (SIGTAG_SIZE, T_INT32, [len(signed)]),
        (SIGTAG_MD5, T_BIN, hashlib.md5(signed).digest()),
        (SIGTAG_SHA256, T_STRING, hashlib.sha256(signed).hexdigest()),
        (SIGTAG_PAYLOADSIZE, T_INT32, [len(gzip.decompress(payload))]),
    ]
    sig_header = _header(sig_tags)
    sig_header += b"\x00" * _pad(96 + len(sig_header), 8)

    lead = LEAD_MAGIC + bytes([3, 0])
    lead += struct.pack(">HH", 0, 1)                      # type=binary, archnum=1 (informational)
    lead += pkg_name.encode()[:65].ljust(66, b"\x00")
    lead += struct.pack(">HH", 1, 5)                      # osnum=linux, signature_type=HEADER+SIG
    lead += b"\x00" * 16
    assert len(lead) == 96

    return lead + sig_header + main_header + payload


# ── verification (re-parse what we wrote) ────────────────────────────────────

def _parse_header(buf, off):
    assert buf[off:off + 3] == HEADER_MAGIC, "bad header magic"
    assert buf[off + 3] == 1, "bad header version"
    nindex, hsize = struct.unpack(">II", buf[off + 8:off + 16])
    store_off = off + 16 + nindex * 16
    tags = {}
    for i in range(nindex):
        tag, vtype, o, count = struct.unpack(">IIII", buf[off + 16 + i * 16:off + 32 + i * 16])
        raw = buf[store_off + o:]
        if vtype == T_STRING:
            tags[tag] = raw.split(b"\x00")[0].decode()
        elif vtype in (T_STRING_ARRAY, T_I18N):
            vals, rest = [], raw
            for _ in range(count):
                s, rest = rest.split(b"\x00", 1)
                vals.append(s.decode())
            tags[tag] = vals
        elif vtype == T_BIN:
            tags[tag] = raw[:count]
        elif vtype == T_INT16:
            tags[tag] = [struct.unpack(">H", raw[j * 2:j * 2 + 2])[0] for j in range(count)]
        elif vtype == T_INT32:
            tags[tag] = [struct.unpack(">I", raw[j * 4:j * 4 + 4])[0] for j in range(count)]
    return tags, store_off + hsize


def _parse_cpio(buf):
    files = {}
    off = 0
    while True:
        assert buf[off:off + 6] == b"070701", f"bad cpio magic at {off}"
        vals = [int(buf[off + 6 + i * 8:off + 14 + i * 8], 16) for i in range(13)]
        namesize, filesize = vals[11], vals[6]
        name = buf[off + 110:off + 110 + namesize - 1].decode()
        off += 110 + namesize
        off += _pad(off, 4)
        files[name] = buf[off:off + filesize]
        off += filesize
        off += _pad(off, 4)
        if name == "TRAILER!!!":
            return files


def verify(path):
    buf = open(path, "rb").read()
    assert buf[:4] == LEAD_MAGIC, "bad lead magic"
    assert buf[4:6] == b"\x03\x00", "unsupported rpm version"
    assert struct.unpack(">H", buf[78:80])[0] == 5, "bad lead signature type"

    sig, sig_end = _parse_header(buf, 96)
    main_off = 96 + (sig_end - 96 + 7) // 8 * 8
    main, main_end = _parse_header(buf, main_off)
    payload = buf[main_end:]

    assert sig[SIGTAG_SIZE][0] == len(buf) - main_off, "sig size mismatch"
    signed = buf[main_off:]
    assert hashlib.md5(signed).digest() == sig[SIGTAG_MD5], "md5 mismatch"
    assert hashlib.sha256(signed).hexdigest() == sig[SIGTAG_SHA256], "sha256 mismatch"
    assert main[100] == ["C"], "bad i18n table"
    assert main[1125] == "gzip", "payload is not gzip"
    files = _parse_cpio(gzip.decompress(payload))
    assert "./usr/bin/tau" in files, "cpio missing ./usr/bin/tau"
    digest = hashlib.sha256(files["./usr/bin/tau"]).hexdigest()
    assert digest == main[1035][0], "file digest mismatch"
    assert sig[SIGTAG_PAYLOADSIZE][0] == len(gzip.decompress(payload)), "payload size mismatch"
    name = f"{main[1000]}-{main[1001]}-{main[1002]}.{main[1022]}"
    print(f"OK: {path} → {name} ({len(files) - 1} payload file(s), /usr/bin/tau sha256 verified)")


def fail(msg):
    print(f"build-rpm.py: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    p = argparse.ArgumentParser(
        description="build (or verify) a .rpm package for tau, stdlib only")
    p.add_argument("--binary", help="the built tau executable")
    p.add_argument("--version", help="package version (leading v stripped)")
    p.add_argument("--release", default="1", help="rpm release (default: 1)")
    p.add_argument("--arch", help="rpm arch: x86_64 or aarch64")
    p.add_argument("--output", help="write the .rpm to FILE")
    p.add_argument("--verify", metavar="FILE", help="verify a built .rpm and exit")
    a = p.parse_args()

    if a.verify:
        try:
            verify(a.verify)
        except (AssertionError, OSError, struct.error, EOFError) as e:
            fail(f"verify failed: {e}")
        return

    for flag in ("binary", "version", "arch", "output"):
        if not getattr(a, flag):
            fail(f"--{flag} is required")
    version = a.version.lstrip("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?", version):
        fail(f"malformed --version: {version} (expected X.Y.Z)")
    if not re.fullmatch(r"[0-9]+", a.release):
        fail(f"malformed --release: {a.release} (expected an integer)")
    if a.arch not in ("x86_64", "aarch64"):
        fail(f"unsupported --arch: {a.arch} (expected x86_64 or aarch64)")
    if not os.path.isfile(a.binary):
        fail(f"binary not found: {a.binary}")

    rpm = build(a.binary, version, a.release, a.arch)
    with open(a.output, "wb") as f:
        f.write(rpm)
    print(f"built {a.output}")


if __name__ == "__main__":
    main()
