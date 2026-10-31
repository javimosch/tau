#!/usr/bin/env python3
"""Regenerate docs/config.md from the tau config JSON Schema.

The schema emitted by `tau config schema` (generated from FileConfig in
src/configfile.zig via src/configschema.zig) is the single source of truth
for the config file's keys, types, constraints, and descriptions. This
script renders the human-readable key reference so the doc cannot drift:

    python3 scripts/gen-config-doc.py            # rewrite docs/config.md
    python3 scripts/gen-config-doc.py --check    # exit 1 if docs/config.md is stale
    ./zig-out/bin/tau config schema | python3 scripts/gen-config-doc.py - --check

Stdlib only. With no SCHEMA argument the checked-in canonical copy at
schema/tau-config.schema.json is read (it is pinned byte-identical to the
binary's output by the config-schema smoke group, a unit test, and CI);
pass a path or `-` to read a different document / stdin. Paths resolve
relative to the script, so it can run from any cwd.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_JSON = ROOT / "schema" / "tau-config.schema.json"
OUT_MD = ROOT / "docs" / "config.md"

# Nicer sample values for the generated example than the kind defaults.
# Not drift-checked for correctness — only presence — but add an entry when
# adding a FileConfig key so the example stays realistic.
SAMPLE_VALUES = {
    "$schema": "https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json",
    "provider": "openai",
    "model": "gpt-4o-mini",
    "api_key": "sk-...",
    "keys": {"openai": "sk-...", "deepseek": "sk-..."},
    "mode": "json",
    "stream": True,
    "thinking": False,
    "debug": False,
    "temperature": 0.7,
    "max_tokens": 4096,
    "timeout_ms": 120000,
    "context_window": 256000,
    "auto_compact": True,
    "compact_threshold": 0.5,
    "compact_keep_recent_tokens": 20000,
    "goal_max_iterations": 50,
    "goal_max_continues": 500,
}


def fail(msg):
    print(f"gen-config-doc: {msg}", file=sys.stderr)
    sys.exit(2)


def md_cell(text):
    return text.replace("|", "\\|")


def constraints(prop):
    """Render a schema property's non-type keywords as a table cell."""
    parts = []
    if "enum" in prop:
        parts.append("one of " + " \\| ".join(f"`{v}`" for v in prop["enum"]))
    if prop.get("minLength"):
        parts.append("non-empty")
    lo, hi = prop.get("minimum"), prop.get("maximum")
    if lo is not None and hi is not None:
        parts.append(f"`{fmt_num(lo)}..{fmt_num(hi)}`")
    elif lo is not None:
        parts.append(f"`>= {fmt_num(lo)}`")
    elif hi is not None:
        parts.append(f"`<= {fmt_num(hi)}`")
    names = prop.get("propertyNames", {}).get("enum")
    if names:
        parts.append("member names: " + " \\| ".join(f"`{n}`" for n in names))
    extra = prop.get("additionalProperties")
    if isinstance(extra, dict):
        v = "non-empty strings" if extra.get("minLength") else f"`{extra.get('type')}`"
        parts.append(f"values: {v}")
    return "; ".join(parts) if parts else "—"


def fmt_num(n):
    return str(int(n)) if float(n) == int(n) else str(n)


def sample_value(name, prop):
    if name in SAMPLE_VALUES:
        return SAMPLE_VALUES[name]
    if "enum" in prop:
        return prop["enum"][0]
    kind = prop.get("type")
    if kind == "boolean":
        return True
    if kind in ("integer", "number"):
        return prop.get("minimum", 0)
    if kind == "object":
        return {"<name>": "..."}
    return "..."


def render(schema):
    props = schema.get("properties", {})
    if not props:
        fail("schema has no properties — is this the tau config schema?")

    lines = []
    a = lines.append
    a("# tau config file reference")
    a("")
    a("<!-- GENERATED FILE — do not edit by hand.")
    a("     Source of truth: `tau config schema` output (canonical copy:")
    a("     schema/tau-config.schema.json, generated from FileConfig in")
    a("     src/configfile.zig via src/configschema.zig).")
    a("     Regenerate:  python3 scripts/gen-config-doc.py")
    a("     Drift check: python3 scripts/gen-config-doc.py --check")
    a("     (the config-doc smoke group runs the drift check) -->")
    a("")
    a(schema.get("description", "Schema for the tau config file."))
    a("")
    a("This table is generated from that schema, so it cannot drift from the")
    a("keys the loader accepts.")
    a("")
    a("This is the key-by-key reference. For the full configuration guide —")
    a("environment variables, CLI-flag equivalents, and precedence rules — see")
    a("[docs/configuration.md](configuration.md). Resolution model:")
    a("**CLI flags > environment > config file > in-code defaults.**")
    a("")
    a("## Keys")
    a("")
    a("| Key | Type | Constraints | Description |")
    a("|-----|------|-------------|-------------|")
    for name, prop in props.items():
        kind = prop.get("type", "any")
        a(f"| `{name}` | `{kind}` | {constraints(prop)} | {md_cell(prop.get('description', ''))} |")
    a("")
    a("## Example")
    a("")
    a("```jsonc")
    a("{")
    a("  // Every key is optional — set only what you need. JSONC comments")
    a("  // like these are allowed in the real file.")
    items = list(props.items())
    for i, (name, prop) in enumerate(items):
        comma = "," if i != len(items) - 1 else ""
        val = json.dumps(sample_value(name, prop), ensure_ascii=False)
        a(f'  "{name}": {val}{comma}')
    a("}")
    a("```")
    a("")
    a("## Validating and inspecting")
    a("")
    a("- `tau config validate [file]` — reports unknown keys, wrong types, and")
    a("  out-of-range values against this schema (defaults to the real config).")
    a("- `tau config schema` — prints the JSON Schema this table is generated")
    a("  from. The canonical copy editors fetch is checked in at")
    a(f"  [schema/tau-config.schema.json](../schema/tau-config.schema.json);")
    a("  `tau init` writes its URL as the `$schema` key so autocomplete works")
    a("  out of the box — per-editor setup: [docs/editors.md](editors.md).")
    a("  It also prints a one-line `note:` hint on stderr reminding you to")
    a("  add the `$schema` key (stdout stays a pure JSON Schema for piping).")
    a("- **SchemaStore** — the catalog entry submitted to")
    a("  [schemastore.org](https://www.schemastore.org/) is checked in at")
    a("  [schema/schemastore-catalog-entry.json](../schema/schemastore-catalog-entry.json);")
    a("  once it lands upstream, SchemaStore-backed editors match")
    a("  `~/.config/tau/config.json` by path — autocomplete with no `$schema`")
    a("  key or editor setting at all.")
    a("")
    a("## Regenerating")
    a("")
    a("After changing `FileConfig` or its schema metadata in")
    a("`src/configschema.zig`:")
    a("")
    a("```sh")
    a("zig build && ./zig-out/bin/tau config schema > schema/tau-config.schema.json")
    a("python3 scripts/gen-config-doc.py")
    a("```")
    a("")
    a("`--check` regenerates in memory and exits non-zero when this file is")
    a("stale; the `config-doc` smoke group")
    a("(`scripts/smoke.sh --group config-doc`) runs it, and `zig build test`")
    a("asserts every key row and description appears here verbatim.")
    a("")
    return "\n".join(lines)


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv[1:]
    src = "-" if args and args[0] == "-" else (args[0] if args else str(SCHEMA_JSON))

    try:
        raw = sys.stdin.read() if src == "-" else Path(src).read_text(encoding="utf-8")
        schema = json.loads(raw)
    except (OSError, json.JSONDecodeError) as e:
        fail(f"cannot read schema from {src}: {e}")

    rendered = render(schema)

    if check:
        if not OUT_MD.exists():
            fail(f"{OUT_MD.relative_to(ROOT)} missing — run scripts/gen-config-doc.py")
        if OUT_MD.read_text(encoding="utf-8") != rendered:
            print(f"gen-config-doc: {OUT_MD.relative_to(ROOT)} is stale — regenerate: python3 scripts/gen-config-doc.py", file=sys.stderr)
            sys.exit(1)
        return

    OUT_MD.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT_MD.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
