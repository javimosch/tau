#!/usr/bin/env python3
"""Regenerate docs/doctor-json.md from the doctor stream JSON Schema.

schema/tau-doctor.schema.json is the single source of truth for the
`tau doctor --json` NDJSON contract — event types, fields, enums, and
descriptions. This script renders the human-readable reference so the doc
cannot drift:

    python3 scripts/gen-doctor-doc.py            # rewrite docs/doctor-json.md
    python3 scripts/gen-doctor-doc.py --check    # exit 1 if the doc is stale

Stdlib only. The checked-in schema is validated against real
`tau doctor --json` output by scripts/check-doctor-schema.py (the
doctor-schema smoke group and CI run it), so a doc regenerated from a stale
schema is still caught. Paths resolve relative to the script, so it can run
from any cwd.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_JSON = ROOT / "schema" / "tau-doctor.schema.json"
OUT_MD = ROOT / "docs" / "doctor-json.md"

EVENT_ORDER = ["check_event", "fix_event", "verdict_event"]
OBJECT_ORDER = ["check", "fix", "summary", "build"]


def fail(msg):
    print(f"gen-doctor-doc: {msg}", file=sys.stderr)
    sys.exit(2)


def md_cell(text):
    return text.replace("|", "\\|")


def prop_type(name, prop):
    if "$ref" in prop:
        return f"[`{prop['$ref'].split('/')[-1]}`](#{prop['$ref'].split('/')[-1]})"
    if "const" in prop:
        return f"const `{json.dumps(prop['const'])}`"
    kind = prop.get("type", "any")
    if kind == "array" and "$ref" in prop.get("items", {}):
        return f"[`{prop['items']['$ref'].split('/')[-1]}`](#{prop['items']['$ref'].split('/')[-1]})[]"
    return f"`{kind}`"


def enum_cell(prop):
    if "enum" in prop:
        return "one of " + " \\| ".join(f"`{v}`" for v in prop["enum"])
    if "const" in prop:
        return f"always `{json.dumps(prop['const'])}`"
    parts = []
    if prop.get("minLength"):
        parts.append("non-empty")
    if prop.get("minimum") is not None:
        parts.append(f"`>= {prop['minimum']}`")
    return "; ".join(parts) if parts else "—"


def field_table(a, defn):
    """Render a | Field | Type | Values | Description | table for an object def."""
    required = set(defn.get("required", []))
    a("| Field | Type | Values | Description |")
    a("|-------|------|--------|-------------|")
    for name, prop in defn.get("properties", {}).items():
        req = "" if name in required else " (optional)"
        desc = prop.get("description", "")
        if "$ref" in prop:
            # Pull the description from the referenced def's caller context:
            # the property itself usually carries none.
            desc = desc or f"See [{prop['$ref'].split('/')[-1]}](#{prop['$ref'].split('/')[-1]})."
        a(f"| `{name}`{req} | {prop_type(name, prop)} | {enum_cell(prop)} | {md_cell(desc)} |")
    a("")


def heading_name(def_name):
    return def_name.replace("_", " ").replace(" event", " event")


def render(schema):
    defs = schema.get("$defs", {})
    for want in EVENT_ORDER + OBJECT_ORDER:
        if want not in defs:
            fail(f"schema missing $defs.{want} — is this the tau doctor schema?")

    lines = []
    a = lines.append
    a("# `tau doctor --json` output reference")
    a("")
    a("<!-- GENERATED FILE — do not edit by hand.")
    a("     Source of truth: schema/tau-doctor.schema.json (validated against")
    a("     real `tau doctor --json` output by scripts/check-doctor-schema.py).")
    a("     Regenerate:  python3 scripts/gen-doctor-doc.py")
    a("     Drift check: python3 scripts/gen-doctor-doc.py --check")
    a("     (the doctor-schema smoke group runs both checks) -->")
    a("")
    a(schema.get("description", "Schema for `tau doctor --json` output."))
    a("")
    a("## Stream contract")
    a("")
    a("- One JSON object per line (NDJSON), UTF-8, on stdout.")
    a("- `done:false` on every non-terminal line; the last line is always the")
    a("  verdict with `done:true`. A truncated stream is detectable by the")
    a("  missing verdict.")
    a("- The process exit code is unchanged by `--json`: 0 when `ok:true`,")
    a("  1 when `ok:false` — a consumer can wait for the verdict or just check")
    a("  the exit status.")
    a("- `--json` is mutually exclusive with `--report` (Markdown bundle).")
    a("  Without `--json`, doctor prints a single JSON report that reuses the")
    a("  [check](#check), [fix](#fix), [summary](#summary), and")
    a("  [build](#build) object shapes below.")
    a("")
    a("## Event types")
    a("")
    for name in EVENT_ORDER:
        defn = defs[name]
        a(f"### {name}")
        a("")
        a(defn.get("description", ""))
        a("")
        field_table(a, defn)
    a("## Objects")
    a("")
    for name in OBJECT_ORDER:
        defn = defs[name]
        a(f"### {name}")
        a("")
        a(defn.get("description", ""))
        a("")
        field_table(a, defn)
    a("## Example stream")
    a("")
    a("A `--fix --yes` run emits all three event types (check events, fix")
    a("events, then the verdict carrying the fixes array):")
    a("")
    a("```json")
    for name in EVENT_ORDER:
        for ex in defs[name].get("examples", []):
            if name == "verdict_event" and "fixes" not in ex:
                # Show the --fix shape in the example stream.
                ex = dict(ex)
                ex["fixes"] = [defs["fix_event"]["examples"][0]["fix"]]
                order = ["ok", "version", "build", "summary", "fixes", "done"]
                ex = {k: ex[k] for k in order if k in ex}
            a(json.dumps(ex, separators=(",", ":")))
    a("```")
    a("")
    a("## Consuming and validating")
    a("")
    a("- Canonical schema copy:")
    a("  [schema/tau-doctor.schema.json](../schema/tau-doctor.schema.json)")
    a("  (stable raw URL for `$schema` references).")
    a("- `scripts/check-doctor-schema.py` validates a captured stream against")
    a("  it — including the stream invariants a per-line schema cannot express")
    a("  (exactly one terminal `done:true` verdict, all prior lines `done:false`):")
    a("")
    a("  ```sh")
    a("  tau doctor --json --offline | python3 scripts/check-doctor-schema.py -")
    a("  ```")
    a("")
    a("## Regenerating")
    a("")
    a("After changing the event shapes in `src/doctor.zig` or the schema:")
    a("")
    a("```sh")
    a("python3 scripts/gen-doctor-doc.py")
    a("```")
    a("")
    a("`--check` regenerates in memory and exits non-zero when this file is")
    a("stale; the `doctor-schema` smoke group")
    a("(`scripts/smoke.sh --group doctor-schema`) runs it, and `zig build test`")
    a("pins the schema's object shapes to the serialized structs.")
    a("")
    return "\n".join(lines)


def main():
    check = "--check" in sys.argv[1:]
    try:
        schema = json.loads(SCHEMA_JSON.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        fail(f"cannot read {SCHEMA_JSON.relative_to(ROOT)}: {e}")

    rendered = render(schema)

    if check:
        if not OUT_MD.exists():
            fail(f"{OUT_MD.relative_to(ROOT)} missing — run scripts/gen-doctor-doc.py")
        if OUT_MD.read_text(encoding="utf-8") != rendered:
            print(f"gen-doctor-doc: {OUT_MD.relative_to(ROOT)} is stale — regenerate: python3 scripts/gen-doctor-doc.py", file=sys.stderr)
            sys.exit(1)
        return

    OUT_MD.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT_MD.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
