#!/usr/bin/env python3
"""Validate `tau doctor --json` NDJSON output against the checked-in schema.

schema/tau-doctor.schema.json describes every line the stream can emit —
{"check":{...},"done":false} events, {"fix":{...},"done":false} events under
--fix, and the terminal {"ok":...,"done":true} verdict. This script validates
each line against the schema and asserts the stream invariants a schema
per-line cannot express:

  - every line is exactly one of the three event types
  - "done" is false on all but the last line and true on the last
  - the last line is the verdict event
  - the stream is non-empty

Usage:

    tau doctor --json --offline | python3 scripts/check-doctor-schema.py -
    python3 scripts/check-doctor-schema.py out.ndjson
    python3 scripts/check-doctor-schema.py --schema other.json out.ndjson

Exit codes: 0 = valid stream, 1 = validation failures (each printed to
stderr), 2 = usage/IO/schema error. Stdlib only — paths resolve relative to
the script, so it runs from any cwd.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from jsonschema_lite import validate  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_JSON = ROOT / "schema" / "tau-doctor.schema.json"


def fail(msg):
    print(f"check-doctor-schema: {msg}", file=sys.stderr)
    sys.exit(2)


def validate_stream(text, schema):
    """Validate a whole NDJSON stream. Returns a list of error strings."""
    errors = []
    defs = schema.get("$defs", {})
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines:
        return ["stream is empty — expected at least a verdict line"]

    events = []
    for i, line in enumerate(lines, 1):
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError as e:
            errors.append(f"line {i}: not valid JSON: {e}")

    for i, ev in enumerate(events, 1):
        validate(ev, schema, defs, f"line {i}", errors)

    # Stream invariants a per-line schema cannot express.
    for i, ev in enumerate(events[:-1], 1):
        if isinstance(ev, dict) and ev.get("done") is True:
            errors.append(f"line {i}: done:true before the end of the stream")
    verdict = events[-1]
    if isinstance(verdict, dict):
        if verdict.get("done") is not True:
            errors.append(f"line {len(events)}: last line lacks done:true — stream truncated?")
        verdict_errors = []
        validate(verdict, defs.get("verdict_event", {}), defs, f"line {len(events)}", verdict_errors)
        for e in verdict_errors:
            errors.append(f"{e} (last line must be the verdict event)")
    return errors


def main():
    argv = sys.argv[1:]
    schema_path = SCHEMA_JSON
    if argv[:1] == ["--schema"]:
        if len(argv) < 3:
            fail("usage: check-doctor-schema.py [--schema FILE] [NDJSON|-]")
        schema_path = Path(argv[1])
        argv = argv[2:]
    src = argv[0] if argv else "-"
    if len(argv) > 1:
        fail("usage: check-doctor-schema.py [--schema FILE] [NDJSON|-]")

    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        fail(f"cannot read schema {schema_path}: {e}")

    try:
        text = sys.stdin.read() if src == "-" else Path(src).read_text(encoding="utf-8")
    except OSError as e:
        fail(f"cannot read NDJSON from {src}: {e}")

    errors = validate_stream(text, schema)
    if errors:
        for e in errors:
            print(f"check-doctor-schema: {e}", file=sys.stderr)
        print(f"check-doctor-schema: {len(errors)} validation error(s)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
