#!/usr/bin/env python3
"""Validate a single JSON document against a checked-in tau schema.

The single-object stdout contracts — `tau config show [--json]`,
`tau config validate [--json]`, `tau version [--verbose|--check] [--json]` —
are pinned by schema/tau-*.schema.json files. This script parses the whole
input as one JSON value and validates it against the given schema (stream
surfaces like `tau doctor --json` use check-doctor-schema.py instead).

Usage:

    tau config show --json | python3 scripts/check-cli-schema.py --schema schema/tau-config-show.schema.json -
    python3 scripts/check-cli-schema.py --schema schema/tau-version.schema.json out.json

Exit codes: 0 = valid document, 1 = validation failures (each printed to
stderr), 2 = usage/IO/schema error. Stdlib only — paths resolve relative to
the script, so it runs from any cwd.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from jsonschema_lite import validate  # noqa: E402


def fail(msg):
    print(f"check-cli-schema: {msg}", file=sys.stderr)
    sys.exit(2)


def main():
    argv = sys.argv[1:]
    if argv[:1] != ["--schema"] or len(argv) < 3:
        fail("usage: check-cli-schema.py --schema FILE [JSON|-]")
    schema_path = Path(argv[1])
    src = argv[2]
    if len(argv) > 3:
        fail("usage: check-cli-schema.py --schema FILE [JSON|-]")

    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        fail(f"cannot read schema {schema_path}: {e}")

    try:
        text = sys.stdin.read() if src == "-" else Path(src).read_text(encoding="utf-8")
    except OSError as e:
        fail(f"cannot read JSON from {src}: {e}")

    try:
        doc = json.loads(text)
    except json.JSONDecodeError as e:
        print(f"check-cli-schema: input is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)

    errors = []
    validate(doc, schema, schema.get("$defs", {}), "$", errors)
    if errors:
        for e in errors:
            print(f"check-cli-schema: {e}", file=sys.stderr)
        print(f"check-cli-schema: {len(errors)} validation error(s)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
