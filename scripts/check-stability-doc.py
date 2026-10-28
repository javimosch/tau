#!/usr/bin/env python3
"""Verify docs/stability.md stays aligned with the shipped contract.

docs/stability.md is a hand-written policy document, so it cannot be
regenerated — but its claims can be checked against the tree:

  - every exit code in the src/errors.zig Spec catalog is mentioned in
    the doc (the catalog table names them)
  - every file under schema/ is named in the doc (a stable surface must
    not ship an unannounced schema)
  - every relative link the doc makes to docs/, schema/, or scripts/
    resolves to a file that exists
  - the contract's required sections are present

Usage:

    python3 scripts/check-stability-doc.py

Exit codes: 0 = doc is in sync, 1 = drift found (each failure printed to
stderr), 2 = usage/IO error. Stdlib only — paths resolve relative to the
script, so it runs from any cwd.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOC = ROOT / "docs" / "stability.md"
ERRORS_ZIG = ROOT / "src" / "errors.zig"
SCHEMA_DIR = ROOT / "schema"

REQUIRED_SECTIONS = [
    "## Stable contract",
    "## Informational surfaces",
    "## Internal surfaces",
    "## Deprecation policy",
    "## Rules for building automation",
]


def main():
    problems = []

    if not DOC.is_file():
        print("check-stability-doc: docs/stability.md missing", file=sys.stderr)
        return 1
    text = DOC.read_text(encoding="utf-8")

    for section in REQUIRED_SECTIONS:
        if section not in text:
            problems.append(f"missing required section heading '{section}'")

    # Every catalog exit code must be named in the doc.
    if ERRORS_ZIG.is_file():
        for m in re.finditer(r"\.code = (\d+)", ERRORS_ZIG.read_text(encoding="utf-8")):
            code = m.group(1)
            if f"`{code}`" not in text:
                problems.append(f"error catalog code {code} not mentioned in docs/stability.md")
    else:
        problems.append("src/errors.zig missing — cannot verify catalog codes")

    # Every checked-in schema is a stable surface and must be named.
    if SCHEMA_DIR.is_dir():
        for schema in sorted(SCHEMA_DIR.glob("*.json")):
            if schema.name not in text:
                problems.append(f"schema/{schema.name} not named in docs/stability.md")

    # Every relative link the doc makes must resolve.
    for m in re.finditer(r"\]\(([^)#\s]+)(?:#[^)]+)?\)", text):
        target = m.group(1)
        if "://" in target or target.startswith("mailto:"):
            continue
        resolved = (DOC.parent / target).resolve()
        if not resolved.exists():
            problems.append(f"broken link target: {target}")

    if problems:
        for p in problems:
            print(f"check-stability-doc: {p}", file=sys.stderr)
        return 1
    print("check-stability-doc: docs/stability.md is in sync")
    return 0


if __name__ == "__main__":
    sys.exit(main())
