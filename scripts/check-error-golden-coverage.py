#!/usr/bin/env python3
"""Gate: every stable error code in docs/errors.md is golden-exercised.

docs/errors.md is generated from the Spec catalog in src/errors.zig and
declares the stable exit-code contract. This checker fails when a catalog
code is exercised by no golden test, where "exercised" means either:

  - a tests/golden/*.{stdout,stderr} snapshot pins an
    {"err":{"code":N,...}} envelope byte-for-byte, or
  - a golden_check / golden_check_n / golden_ug call in scripts/smoke.sh
    asserts <want-exit> = N (covers silent exit paths, which pin an empty
    stdout/stderr pair plus the status).

Platform-only codes cannot produce a platform-universal golden — 111
(unimplemented) is emitted solely by Windows builds (acp daemon commands,
`tau upgrade`), so no committed snapshot can assert it on every OS. Each
PLATFORM_ONLY entry must instead be pinned by a platform-gated contract
assertion in scripts/smoke.sh that greps the emitted "code":N; deleting
that assertion trips this gate the same way a missing golden does.

Usage:

    python3 scripts/check-error-golden-coverage.py
        [--catalog PATH] [--golden-dir PATH] [--smoke PATH]

Exit codes: 0 = full coverage, 1 = coverage gap (each printed to stderr),
2 = usage/IO error. Stdlib only — paths resolve relative to the script,
so it runs from any cwd; the path overrides exist so the smoke harness can
prove the gate fails closed on staged fixtures.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# First-column exit codes in any errors.md table row: `| `106` | ...`.
# The catalog table carries the stable contract; the silent-exit table
# repeats a subset of the same codes, so a doc-wide scan covers both.
CATALOG_ROW = re.compile(r"^\|\s*`(\d+)`\s*\|", re.MULTILINE)

# golden_check / golden_check_n / golden_ug all take <name> <want-exit>
# as their first two arguments on the call line. Other golden_* helpers
# (golden_file, _golden_stream, _golden_env, ...) take paths, not a
# status, and are deliberately not matched — an unlisted helper that
# asserts an exit code must be added here so coverage stays honest.
WANT_EXIT = re.compile(
    r"\b(?:golden_check|golden_check_n|golden_ug)\s+\S+\s+(\d+)\b"
)

# A real {"err":{...}} envelope inside a golden stream. Anchoring on the
# `{"err"` key keeps catalog-listing output ({"errors":[...]}) and prose
# mentions of a code from counting as coverage.
ENVELOPE_CODE = re.compile(r'\{"err":\{"code":(\d+)')

# Exit codes emitted only on one OS, so no committed golden can pin them
# on every platform. Each must be grepped out of a live run by a
# platform-gated contract assertion in the smoke script.
PLATFORM_ONLY = {
    111: "Windows-only emitters (acp daemon commands, tau upgrade)",
}


def catalog_codes(catalog: Path):
    if not catalog.is_file():
        raise OSError(f"catalog not found: {catalog}")
    text = catalog.read_text(encoding="utf-8")
    codes = {int(m) for m in CATALOG_ROW.findall(text)}
    if not codes:
        raise OSError(f"no `| `<code>` |` rows parsed from {catalog}")
    return codes


def golden_envelope_codes(golden_dir: Path):
    if not golden_dir.is_dir():
        raise OSError(f"golden directory not found: {golden_dir}")
    codes = set()
    for f in sorted(golden_dir.iterdir()):
        if f.suffix not in (".stdout", ".stderr") or not f.is_file():
            continue
        codes.update(int(m) for m in ENVELOPE_CODE.findall(f.read_text(encoding="utf-8")))
    return codes


def smoke_want_exits(smoke: Path):
    if not smoke.is_file():
        raise OSError(f"smoke script not found: {smoke}")
    text = smoke.read_text(encoding="utf-8")
    return {int(m) for m in WANT_EXIT.findall(text)}, text


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--catalog", type=Path, default=ROOT / "docs" / "errors.md")
    ap.add_argument("--golden-dir", type=Path, default=ROOT / "tests" / "golden")
    ap.add_argument("--smoke", type=Path, default=ROOT / "scripts" / "smoke.sh")
    args = ap.parse_args(argv)

    try:
        wanted = catalog_codes(args.catalog)
        envelope = golden_envelope_codes(args.golden_dir)
        exits, smoke_text = smoke_want_exits(args.smoke)
    except OSError as e:
        print(f"check-error-golden-coverage: {e}", file=sys.stderr)
        return 2

    covered = envelope | exits
    problems = []
    for code in sorted(wanted):
        if code in covered:
            continue
        if code in PLATFORM_ONLY:
            if f'"code":{code}' not in smoke_text:
                problems.append(
                    f"catalog code {code} ({PLATFORM_ONLY[code]}) has no golden "
                    f"(expected: platform-gated) and no '\"code\":{code}' contract "
                    "assertion in scripts/smoke.sh"
                )
            continue
        problems.append(
            f"catalog code {code} is exercised by no golden test — add a "
            "golden_check* case asserting that exit or a tests/golden "
            "snapshot pinning its {\"err\":...} envelope"
        )

    for p in problems:
        print(f"check-error-golden-coverage: {p}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
