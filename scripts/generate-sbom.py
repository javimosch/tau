#!/usr/bin/env python3
# generate-sbom.py — emit a CycloneDX SBOM per release archive.
#
#   scripts/generate-sbom.py --dist dist --version 0.5.0 --commit <sha>
#   scripts/generate-sbom.py --dist dist --outdir sbom --dry-run
#
# For every tau-<os>-<arch>.{tar.gz,zip} in --dist this writes a sibling
# <asset>.sbom.json: a CycloneDX 1.6 document describing the archive, the
# files inside it (each hashed), the release it belongs to, and the build
# toolchain. tau has no third-party runtime dependencies (a freestanding
# Zig binary + generated man pages), so the SBOM's real payload is
# "exactly which bytes shipped" — the archive hash and its member listing.
#
# Output is deterministic: the document timestamp comes from --timestamp /
# $SOURCE_DATE_EPOCH (the release workflow passes the tag's commit date)
# and the serial number is a uuid5 of <repo>@<version>/<asset>, so the same
# inputs always produce byte-identical SBOMs.
#
# The release workflow (release job) signs every .sbom.json with cosign,
# attests it with actions/attest-build-provenance, and publishes it next to
# the archive — see docs/verifying-releases.md.
#
# Options:
#   --dist DIR      directory holding the release archives (default: dist/)
#   --outdir DIR    where to write .sbom.json files (default: same as --dist)
#   --version V     release version, with or without leading v (default:
#                   parsed from src/version.zig)
#   --commit SHA    commit the release was built from (default: `git rev-parse
#                   HEAD`, "unknown" outside a checkout)
#   --timestamp TS  ISO-8601 timestamp for metadata.timestamp (default:
#                   $SOURCE_DATE_EPOCH if set, else current UTC time)
#   --dry-run       print what would be generated, write nothing
#   -h, --help      show this help

import argparse
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import uuid
import zipfile
from datetime import datetime, timezone


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "javimosch/tau"
REPO_URL = f"https://github.com/{REPO}"
SPEC_VERSION = "1.6"
GENERATOR_VERSION = "1"
ZIG_VERSION = "0.16.0"
ARTIFACT_RE = re.compile(r"^tau-(linux|macos|windows)-(x86_64|aarch64)\.(tar\.gz|zip)$")
# artifact name → zig target triple (mirrors the build matrix in release.yml)
ZIG_TARGETS = {
    "linux-x86_64": "x86_64-linux-gnu",
    "linux-aarch64": "aarch64-linux-gnu",
    "macos-x86_64": "x86_64-macos",
    "macos-aarch64": "aarch64-macos",
    "windows-x86_64": "x86_64-windows-gnu",
}


def die(msg):
    print(f"generate-sbom.py: error: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def archive_members(path):
    """List (name, size, sha256) for regular-file members of a tar.gz or zip."""
    members = []
    if path.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            for info in sorted(z.infolist(), key=lambda i: i.filename):
                if info.is_dir():
                    continue
                members.append((info.filename, info.file_size, sha256_bytes(z.read(info))))
    else:
        with tarfile.open(path, "r:gz") as t:
            for m in sorted(t.getmembers(), key=lambda m: m.name):
                if not m.isfile():
                    continue
                data = t.extractfile(m).read()
                members.append((m.name, m.size, sha256_bytes(data)))
    return members


def parse_version():
    if not hasattr(parse_version, "_default"):
        try:
            with open(os.path.join(ROOT, "src", "version.zig")) as f:
                m = re.search(r'version\s*=\s*"([^"]+)"', f.read())
                parse_version._default = m.group(1) if m else None
        except OSError:
            parse_version._default = None
    return parse_version._default


def resolve_timestamp(arg):
    if arg:
        ts = arg.strip()
        if ts.isdigit():
            return datetime.fromtimestamp(int(ts), timezone.utc).isoformat().replace("+00:00", "Z")
        # accept ISO-8601; normalize trailing Z/offset
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch and epoch.isdigit():
        return datetime.fromtimestamp(int(epoch), timezone.utc).isoformat().replace("+00:00", "Z")
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def build_bom(asset, asset_path, version, commit, timestamp):
    """One CycloneDX document per archive."""
    artifact_key = asset.rsplit(".tar.gz", 1)[0].rsplit(".zip", 1)[0].removeprefix("tau-")
    zig_target = ZIG_TARGETS.get(artifact_key, "unknown")
    ext = "zip" if asset.endswith(".zip") else "tar.gz"

    archive_ref = f"archive:{asset}"
    member_components = []
    member_refs = []
    for name, size, digest in archive_members(asset_path):
        ref = f"{archive_ref}#{name}"
        member_refs.append(ref)
        member_components.append({
            "type": "file",
            "bom-ref": ref,
            "name": name,
            "hashes": [{"alg": "SHA-256", "content": digest}],
            "properties": [
                {"name": "tau:size_bytes", "value": str(size)},
                {"name": "tau:contained_in", "value": asset},
            ],
        })

    serial = uuid.uuid5(uuid.NAMESPACE_URL, f"{REPO_URL}@{version}/{asset}")
    return {
        "$schema": f"http://cyclonedx.org/schema/bom-{SPEC_VERSION}.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": SPEC_VERSION,
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "timestamp": timestamp,
            "tools": {
                "components": [
                    {
                        "type": "application",
                        "name": "generate-sbom.py",
                        "version": GENERATOR_VERSION,
                        "externalReferences": [{"type": "build-system", "url": f"{REPO_URL}/blob/{commit}/scripts/generate-sbom.py"}],
                    },
                    {
                        "type": "application",
                        "name": "zig",
                        "version": ZIG_VERSION,
                        "description": f"cross-compiler toolchain (target {zig_target})",
                        "externalReferences": [{"type": "build-system", "url": f"https://ziglang.org/download/{ZIG_VERSION}/"}],
                    },
                ],
            },
            "component": {
                "type": "application",
                "bom-ref": f"pkg:github/{REPO}@{version}",
                "name": "tau",
                "version": version,
                "description": "non-interactive, agent-first AI CLI (Zig, freestanding, no runtime dependencies)",
                "licenses": [{"license": {"id": "MIT"}}],
                "externalReferences": [
                    {"type": "website", "url": REPO_URL},
                    {"type": "vcs", "url": f"{REPO_URL}/tree/{commit}"},
                    {"type": "distribution", "url": f"{REPO_URL}/releases/download/v{version}/{asset}"},
                ],
            },
        },
        "components": [
            {
                "type": "file",
                "bom-ref": archive_ref,
                "name": asset,
                "hashes": [{"alg": "SHA-256", "content": sha256_file(asset_path)}],
                "properties": [
                    {"name": "zig:target", "value": zig_target},
                    {"name": "tau:archive_format", "value": ext},
                    {"name": "tau:release_tag", "value": f"v{version}"},
                ],
            },
            *member_components,
        ],
        "dependencies": [
            {"ref": f"pkg:github/{REPO}@{version}", "dependsOn": [archive_ref]},
            {"ref": archive_ref, "dependsOn": member_refs},
        ],
    }


class Parser(argparse.ArgumentParser):
    # exit 1 like the sibling shell generators, not argparse's default 2
    def error(self, message):
        die(f"{message} (see --help)")


def main():
    ap = Parser(
        prog="generate-sbom.py",
        description="emit a CycloneDX SBOM per release archive (see file header)")
    ap.add_argument("--dist", default="dist", help="directory holding release archives")
    ap.add_argument("--outdir", default=None, help="output dir (default: same as --dist)")
    ap.add_argument("--version", default=None, help="release version (default: src/version.zig)")
    ap.add_argument("--commit", default=None, help="commit sha (default: git rev-parse HEAD)")
    ap.add_argument("--timestamp", default=None, help="ISO-8601 metadata timestamp (default: $SOURCE_DATE_EPOCH or now)")
    ap.add_argument("--dry-run", action="store_true", help="print actions without writing")
    args = ap.parse_args()

    dist = args.dist
    outdir = args.outdir or dist
    if not os.path.isdir(dist):
        die(f"dist dir not found: {dist}")

    assets = sorted(f for f in os.listdir(dist) if ARTIFACT_RE.match(f))
    if not assets:
        die(f"no release archives (tau-<os>-<arch>.tar.gz|zip) in {dist}")

    version = (args.version or parse_version() or "").lstrip("v")
    if not re.match(r"^\d+\.\d+\.\d+(-[0-9A-Za-z.\-]+)?$", version):
        die(f"cannot determine release version (pass --version); got {version!r}")

    commit = args.commit
    if not commit:
        import subprocess
        try:
            commit = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=ROOT,
                capture_output=True, text=True, check=True).stdout.strip()
        except Exception:
            commit = "unknown"

    timestamp = resolve_timestamp(args.timestamp)

    if not args.dry_run:
        os.makedirs(outdir, exist_ok=True)
    for asset in assets:
        bom = build_bom(asset, os.path.join(dist, asset), version, commit, timestamp)
        out = os.path.join(outdir, f"{asset}.sbom.json")
        if args.dry_run:
            n = len(bom["components"])
            print(f"would write {out} ({n} components)")
            continue
        with open(out, "w") as f:
            json.dump(bom, f, indent=2)
            f.write("\n")
        print(f"wrote {out} ({len(bom['components'])} components)")


if __name__ == "__main__":
    main()
