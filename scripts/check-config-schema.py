#!/usr/bin/env python3
"""Validate shipped config.json examples against config.schema.json.

Stdlib-only (no jsonschema dependency) so it runs anywhere python3 exists —
locally, in the smoke harness (config-schema group), and in CI.

What it checks:
  1. Every examples/config/*.json file validates against config.schema.json.
  2. JSON objects embedded in shipped docs/scripts (README.md,
     docs/configuration.md, examples/README.md, examples/*.sh) that look like
     tau config files (at least one known config key) also validate.
  3. Drift guards: schema properties must match the FileConfig struct in
     src/configfile.zig, and the provider enum must match the provider table
     in src/llm/provider.zig.

Usage:
  scripts/check-config-schema.py            # validate all shipped examples
  scripts/check-config-schema.py --file X   # validate one file (exit 0/1)

Only a subset of JSON Schema is implemented (type, enum, minimum, maximum,
required, properties, additionalProperties) — enough for config.schema.json.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "config.schema.json"
EXAMPLES_DIR = ROOT / "examples" / "config"
CONFIGFILE_ZIG = ROOT / "src" / "configfile.zig"
PROVIDER_ZIG = ROOT / "src" / "llm" / "provider.zig"

# Text files scanned for embedded config-shaped JSON objects.
TEXT_SOURCES = [
    ROOT / "README.md",
    ROOT / "docs" / "configuration.md",
    ROOT / "examples" / "README.md",
] + sorted((ROOT / "examples").glob("*.sh"))


class Fail(Exception):
    pass


def type_ok(value, t):
    if t == "object":
        return isinstance(value, dict)
    if t == "array":
        return isinstance(value, list)
    if t == "string":
        return isinstance(value, str)
    if t == "boolean":
        return isinstance(value, bool)
    if t == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if t == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if t == "null":
        return value is None
    return True  # unknown type keyword: don't fail


def validate(value, schema, path, errors):
    """Minimal JSON Schema subset validator. Appends human-readable errors."""
    t = schema.get("type")
    if isinstance(t, list):
        if not any(type_ok(value, tt) for tt in t):
            errors.append(f"{path}: expected one of {t}, got {type_name(value)}")
            return
    elif t is not None:
        if not type_ok(value, t):
            errors.append(f"{path}: expected {t}, got {type_name(value)}")
            return

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in enum {schema['enum']}")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: {value} < minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: {value} > maximum {schema['maximum']}")

    if isinstance(value, dict):
        props = schema.get("properties", {})
        for req in schema.get("required", []):
            if req not in value:
                errors.append(f"{path}: missing required key {req!r}")
        for k, v in value.items():
            if k in props:
                validate(v, props[k], f"{path}.{k}", errors)
            else:
                ap = schema.get("additionalProperties", True)
                if ap is False:
                    errors.append(f"{path}: unknown key {k!r}")
                elif isinstance(ap, dict):
                    validate(v, ap, f"{path}.{k}", errors)


def type_name(v):
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, dict):
        return "object"
    if isinstance(v, list):
        return "array"
    if isinstance(v, str):
        return "string"
    if isinstance(v, (int, float)):
        return "number"
    return "null"


def extract_json_objects(text):
    """Yield (lineno, obj) for each top-level {...} that parses to a dict.

    Brace-matches while skipping string literals; skips candidates containing
    shell templating (${...} or backticks) since they can't be parsed anyway.
    """
    objs = []
    depth = 0
    start = None
    in_str = False
    esc = False
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start is not None:
                    cand = text[start : i + 1]
                    lineno = text.count("\n", 0, start) + 1
                    start = None
                    if "${" in cand or "`" in cand:
                        continue
                    try:
                        obj = json.loads(cand)
                    except ValueError:
                        continue
                    if isinstance(obj, dict):
                        objs.append((lineno, obj))
    return objs


def config_keys(schema):
    return set(schema.get("properties", {})) - {"$schema"}


def drift_checks(schema):
    """Schema must stay in sync with FileConfig and the provider table."""
    errors = []
    known = config_keys(schema)

    src = CONFIGFILE_ZIG.read_text()
    m = re.search(r"const FileConfig = struct \{(.*?)\n\};", src, re.S)
    if not m:
        errors.append("drift: FileConfig struct not found in src/configfile.zig")
    else:
        fields = set(re.findall(r"^\s*(\w+)\s*:\s*\?", m.group(1), re.M))
        if fields != known:
            missing = sorted(fields - known)
            extra = sorted(known - fields)
            if missing:
                errors.append(f"drift: schema missing FileConfig keys {missing}")
            if extra:
                errors.append(f"drift: schema keys not in FileConfig {extra}")

    src = PROVIDER_ZIG.read_text()
    m = re.search(r"pub const providers = \[_\]Provider\{(.*?)\n\s*\};", src, re.S)
    if not m:
        errors.append("drift: providers table not found in src/llm/provider.zig")
    else:
        names = re.findall(r'\.name = "([^"]+)"', m.group(1))
        enum = schema["properties"]["provider"]["enum"]
        if sorted(names) != sorted(enum):
            errors.append(
                f"drift: provider enum {sorted(enum)} != provider table {sorted(names)}"
            )
    return errors


def validate_obj(obj, schema, label, failures):
    errors = []
    validate(obj, schema, "$", errors)
    if errors:
        for e in errors:
            failures.append(f"{label}: {e}")
        return False
    return True


def main():
    single = None
    args = sys.argv[1:]
    if args[:1] == ["--file"]:
        if len(args) != 2:
            print("usage: --file PATH", file=sys.stderr)
            return 2
        single = Path(args[1])
    elif args:
        print("usage: check-config-schema.py [--file PATH]", file=sys.stderr)
        return 2

    try:
        schema = json.loads(SCHEMA_PATH.read_text())
    except (OSError, ValueError) as e:
        print(f"FAIL: cannot parse {SCHEMA_PATH.name}: {e}", file=sys.stderr)
        return 1

    if single is not None:
        try:
            obj = json.loads(single.read_text())
        except (OSError, ValueError) as e:
            print(f"FAIL {single}: {e}", file=sys.stderr)
            return 1
        errs = []
        validate(obj, schema, "$", errs)
        for e in errs:
            print(f"FAIL {single}: {e}", file=sys.stderr)
        if not errs:
            print(f"ok {single}: valid against config.schema.json")
        return 0 if not errs else 1

    failures = []
    n_valid = 0
    known = config_keys(schema)

    files = sorted(EXAMPLES_DIR.glob("*.json"))
    if not files:
        failures.append(f"no example configs found in {EXAMPLES_DIR}")
    for f in files:
        try:
            obj = json.loads(f.read_text())
        except ValueError as e:
            failures.append(f"{f.relative_to(ROOT)}: invalid JSON: {e}")
            continue
        if validate_obj(obj, schema, str(f.relative_to(ROOT)), failures):
            n_valid += 1
            print(f"ok {f.relative_to(ROOT)}")

    for src_path in TEXT_SOURCES:
        if not src_path.exists():
            continue
        rel = src_path.relative_to(ROOT)
        for lineno, obj in extract_json_objects(src_path.read_text()):
            if not (set(obj) & known):
                continue  # not config-shaped; not our problem
            label = f"{rel}:{lineno}"
            if validate_obj(obj, schema, label, failures):
                n_valid += 1
                print(f"ok {label}")

    for e in drift_checks(schema):
        failures.append(e)

    if failures:
        for f in failures:
            print(f"FAIL {f}", file=sys.stderr)
        return 1
    print(f"{n_valid} config example(s) valid against config.schema.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
