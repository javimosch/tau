#!/usr/bin/env python3
"""Validate `tau setup --json` NDJSON output against the checked-in schema.

schema/tau-setup.schema.json describes every line the stream can emit —
{"step":"init",...}, {"step":"completions",...}, {"step":"clients",...},
{"step":"doctor",...} step events, the removal-mode {"step":"remove_clients",
...} event (`tau setup --remove`/`--uninstall`), and the terminal
{"step":"setup",...,"done":true} verdict. This script validates each line
against the schema and asserts the stream invariants a per-line schema
cannot express:

  - the step events appear exactly once, in a fixed order — either the
    install sequence (init -> completions -> clients -> doctor) or the
    removal sequence (remove_clients alone)
  - exactly one verdict event (step "setup") and it is the last line
  - "done" is true on the verdict only — no earlier line may carry it
  - the stream is non-empty

Usage:

    tau setup --json --offline | python3 scripts/check-setup-schema.py -
    python3 scripts/check-setup-schema.py out.ndjson
    python3 scripts/check-setup-schema.py --schema other.json out.ndjson

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
SCHEMA_JSON = ROOT / "schema" / "tau-setup.schema.json"

STEP_ORDER = ["init", "completions", "clients", "doctor"]
REMOVE_ORDER = ["remove_clients"]


def fail(msg):
    print(f"check-setup-schema: {msg}", file=sys.stderr)
    sys.exit(2)


def validate_stream(text, schema):
    """Validate a whole NDJSON stream. Returns a list of error strings."""
    errors = []
    defs = schema.get("$defs", {})
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines:
        return ["stream is empty — expected step events and a verdict line"]

    events = []
    for i, line in enumerate(lines, 1):
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError as e:
            errors.append(f"line {i}: not valid JSON: {e}")

    for i, ev in enumerate(events, 1):
        validate(ev, schema, defs, f"line {i}", errors)

    # Stream invariants a per-line schema cannot express.
    steps = [ev.get("step") for ev in events if isinstance(ev, dict)]
    if steps not in (STEP_ORDER + ["setup"], REMOVE_ORDER + ["setup"]):
        errors.append(
            f"step sequence {steps!r} — expected {STEP_ORDER + ['setup']!r} "
            f"or {REMOVE_ORDER + ['setup']!r} "
            "(one event per step, fixed order, verdict last)"
        )

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
            fail("usage: check-setup-schema.py [--schema FILE] [NDJSON|-]")
        schema_path = Path(argv[1])
        argv = argv[2:]
    src = argv[0] if argv else "-"
    if len(argv) > 1:
        fail("usage: check-setup-schema.py [--schema FILE] [NDJSON|-]")

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
            print(f"check-setup-schema: {e}", file=sys.stderr)
        print(f"check-setup-schema: {len(errors)} validation error(s)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
