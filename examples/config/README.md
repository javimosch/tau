# Example `config.json` files

Ready-to-copy examples for `~/.config/tau/config.json`. Every file is optional —
pick one as a starting point:

| File | Shows |
|------|-------|
| `minimal.json` | Just a provider + model default |
| `per-provider-keys.json` | Per-provider API keys via the `keys` map (instead of env vars) |
| `batch.json` | Non-streaming, capped-output setup for scripted/batch use |
| `full.json` | Every supported key with a realistic value |

Usage:

```bash
mkdir -p ~/.config/tau
cp examples/config/minimal.json ~/.config/tau/config.json
# edit values, remove "$schema" if you like — tau ignores unknown keys
```

The `"$schema"` line gives editors autocomplete + validation via
[`config.schema.json`](../../config.schema.json). All shipped examples are
validated against that schema by `scripts/check-config-schema.py` (run by the
`config-schema` smoke group and in CI). See
[docs/configuration.md](../../docs/configuration.md) for the full key reference
and precedence rules.
