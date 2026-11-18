"""A minimal JSON Schema 2020-12 validator (stdlib only).

Shared by scripts/check-doctor-schema.py (NDJSON streams) and
scripts/check-cli-schema.py (single stdout documents). Supported keywords:
$ref (#/$defs/...), oneOf, type, enum, const, required, properties,
additionalProperties, items, minLength, minimum, maximum — everything the
checked-in schema/tau-*.schema.json files use, no more.
"""

TYPE_MAP = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "integer": int,
    "number": (int, float),
    "null": type(None),
}


def type_ok(value, kind):
    # bool is an int subclass in Python — exclude it from integer/number.
    if kind in ("integer", "number") and isinstance(value, bool):
        return False
    expected = TYPE_MAP.get(kind)
    if expected is None:
        return True  # unknown type keyword: treat as unconstrained
    if isinstance(expected, tuple):
        return isinstance(value, expected)
    # A union like ["string", "null"] arrives as a list of kinds — handled by
    # the caller iterating; a bare string kind maps directly.
    return isinstance(value, expected)


def validate(value, schema, defs, path, errors):
    """Validate value against (a subset of) JSON Schema 2020-12."""
    if "$ref" in schema:
        ref = schema["$ref"]
        if not ref.startswith("#/$defs/") or ref[len("#/$defs/"):] not in defs:
            errors.append(f"{path}: unresolvable $ref {ref}")
            return
        schema = defs[ref[len("#/$defs/"):]]

    if "oneOf" in schema:
        matches = 0
        for sub in schema["oneOf"]:
            sub_errors = []
            validate(value, sub, defs, path, sub_errors)
            if not sub_errors:
                matches += 1
        if matches != 1:
            errors.append(f"{path}: matched {matches} of {len(schema['oneOf'])} allowed shapes")
        return

    kind = schema.get("type")
    if isinstance(kind, list):
        if not any(type_ok(value, k) for k in kind):
            errors.append(f"{path}: expected one of {kind}, got {type(value).__name__}")
            return
    elif kind and not type_ok(value, kind):
        errors.append(f"{path}: expected {kind}, got {type(value).__name__}")
        return

    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}, got {value!r}")

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in enum {schema['enum']}")

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: string shorter than minLength {schema['minLength']}")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: {value} below minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: {value} above maximum {schema['maximum']}")

    if isinstance(value, dict):
        for req in schema.get("required", []):
            if req not in value:
                errors.append(f"{path}: missing required key {req!r}")
        props = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for k, v in value.items():
            if k in props:
                validate(v, props[k], defs, f"{path}.{k}", errors)
            elif additional is False:
                errors.append(f"{path}: unexpected key {k!r}")
            elif isinstance(additional, dict):
                validate(v, additional, defs, f"{path}.{k}", errors)

    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            validate(item, schema["items"], defs, f"{path}[{i}]", errors)
