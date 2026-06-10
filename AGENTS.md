# Tau Agent Guide

This guide helps AI agents work with the tau codebase and add new LLM providers.

## Project Overview

Tau is a non-interactive, agent-first AI CLI written in Zig (0.16.0). It's designed for AI agents, not humans, with JSON-first output and deterministic behavior.

## Key Architecture

- **Provider System**: Located in `src/llm/provider.zig`
- **Config**: Located in `src/config.zig` 
- **Main Entry**: `src/main.zig`
- **Agent Loop**: `src/agent.zig`
- **Goal Mode**: `src/goal.zig`

## Adding New LLM Providers

### Step 1: Add Provider to Provider Table

Edit `src/llm/provider.zig` and add a new entry to the `providers` array:

```zig
pub const providers = [_]Provider{
    // ... existing providers ...
    .{
        .name = "provider-name",
        .endpoint = "https://api.example.com/v1/chat/completions",
        .default_model = "default-model-name",
        .env_keys = &.{"PROVIDER_API_KEY"},
        .context_window = 128_000,
    },
};
```

**Provider Fields:**
- `name`: Internal identifier (used in config and CLI args)
- `endpoint`: Full API endpoint URL for chat completions
- `default_model`: Default model to use if none specified
- `env_keys`: Array of environment variable names to check for API keys
- `context_window`: Model context window size in tokens (for compaction threshold)
- `builtin_key`: Optional hardcoded key (avoid for security)

### Step 2: Update Config File

Create or update `~/.config/tau/config.json` to use the new provider:

```json
{
  "provider": "provider-name",
  "model": "model-name",
  "api_key": "your-api-key-here"
}
```

**Config Fields:**
- `provider`: Must match a provider name from the provider table
- `model`: Specific model to use (or omit for provider default)
- `api_key`: API key (optional if using env var)

### Step 3: Build and Test

```bash
# Build tau
zig build

# Test the new provider
./zig-out/bin/tau --mode text "Say hello from new provider"
```

### Step 4: Debug Mode

If authentication fails, use debug mode to see the actual error:

```bash
./zig-out/bin/tau --debug --mode text "Test message"
```

## Provider Discovery from Other Tools

When syncing providers from other AI tools (OpenCode, Paseo, etc.):

1. **Find the provider config**: Look for JSON config files in the tool's config directory
2. **Extract key information**: 
   - API endpoint URL
   - Default model name
   - Authentication method
   - Environment variable names
3. **Map to tau structure**: Convert the external config to tau's Provider struct
4. **Test authentication**: Verify the API key works with tau's HTTP client

## Common Provider Patterns

### OpenAI-Compatible APIs

Most modern LLM providers use OpenAI-compatible APIs:

```zig
.{
    .name = "provider-name",
    .endpoint = "https://api.provider.com/v1/chat/completions",
    .default_model = "model-name",
    .env_keys = &.{"PROVIDER_API_KEY"},
    .context_window = 128_000,
}
```

### Custom Endpoints

Some providers use non-standard endpoints:

```zig
.{
    .name = "custom-provider",
    .endpoint = "https://custom.example.com/api/v1/generate",
    .default_model = "custom-model",
    .env_keys = &.{"CUSTOM_API_KEY"},
    .context_window: 256_000,
}
```

## API Key Resolution Order

Tau resolves API keys in this order:

1. Explicit `--api-key` CLI flag
2. Config file `api_key` field
3. Provider-specific environment variable (from `env_keys`)
4. Global `TAU_API_KEY` environment variable
5. Provider `builtin_key` (avoid using)

## Context Windows

Set appropriate context windows for compaction threshold:

- Small models: 32K-65K tokens
- Medium models: 128K-200K tokens  
- Large models: 256K-1M tokens

## Testing Checklist

- [ ] Provider added to `src/llm/provider.zig`
- [ ] Config created/updated in `~/.config/tau/config.json`
- [ ] `zig build` succeeds
- [ ] Basic test: `./zig-out/bin/tau --mode text "hello"`
- [ ] Tool calling test: `./zig-out/bin/tau --tools bash "echo test"`
- [ ] Debug mode shows no auth errors
- [ ] Context window is appropriate for model

## Troubleshooting

### Auth Failed (exit code 106)
- Check API key is correct
- Verify environment variable name matches `env_keys`
- Ensure endpoint URL is correct

### HTTP Request Failed (exit code 110)
- Check network connectivity
- Verify endpoint is accessible
- Use `--debug` flag to see actual error

### Timeout (exit code 105)
- Increase timeout with `--timeout-ms`
- Check if provider is experiencing issues
- Try a simpler model

## Existing Providers Reference

Current providers in tau:

| Provider | Default Model | Context Window | Env Var |
|----------|---------------|---------------|---------|
| xiaomi | mimo-v2.5 | 256K | XIAOMI_API_KEY |
| openai | gpt-4o-mini | 128K | OPENAI_API_KEY |
| deepseek | deepseek-chat | 65K | DEEPSEEK_API_KEY |
| opencode-go | deepseek-v4-flash | 204K | OPENCODE_API_KEY |

## File Size Limits

Keep source files under 500 LOC per global rules. If a file exceeds this limit, split or refactor it.