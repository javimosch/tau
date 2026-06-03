# Piz Roadmap

## Vision

Piz is an agent-first AI CLI tool - a simplified, non-interactive version of pi designed specifically for AI agents rather than human users. While pi provides an interactive TUI experience, piz focuses on programmatic use with JSON output, streaming responses, and semantic exit codes.

## Current State

### ✅ Completed

- **Zig 0.16.0 Compatibility**: All API compatibility issues resolved
- **LLM Integration**: Successfully integrated with xiaomi-custom provider (mimo-v2.5)
- **Agent-First Design**: JSON output, streaming responses, semantic exit codes
- **Self-Describing Schema**: `--help-json` for machine-readable command documentation
- **Configuration**: Hardcoded config with real API credentials
- **Error Handling**: Structured error responses with semantic exit codes

### ⚠️ Known Issues

- ~~**std.process.run**: Zig 0.16.0 process execution API has issues~~ **RESOLVED** — the API works correctly; the failure was a 30s timeout being exceeded by the LLM, surfacing as piz's own `internal_error` (110) exit code. See "Zig 0.16.0 std.process.run Issue" below.
- **No Argument Parsing**: Currently uses hardcoded prompts
- **No Tools System**: Cannot execute terminal commands or web searches
- **No Skills Support**: Cannot load or execute skills from ~/.agents/skills
- **No Configuration Management**: Config is hardcoded in source

## Architecture Overview

### Core Components

```
piz/
├── src/
│   ├── main.zig              # Entry point with std.process.Init
│   ├── config.zig             # Configuration management
│   ├── args.zig               # CLI argument parser
│   ├── llm/
│   │   ├── provider.zig       # LLM provider interface
│   │   └── xiaomi_custom.zig  # xiaomi-custom provider impl
│   ├── tools/
│   │   ├── terminal.zig       # Terminal execution tool
│   │   ├── web_search.zig     # Web search tool
│   │   └── registry.zig       # Tool registry
│   ├── skills/
│   │   ├── loader.zig         # Skill loader from ~/.agents/skills
│   │   ├── executor.zig       # Skill execution engine
│   │   └── parser.zig         # SKILL.md parser
│   └── output/
│       ├── json.zig           # JSON output formatter
│       └── stream.zig         # Streaming response handler
└── docs/
    ├── roadmap.md             # This file
    ├── architecture.md        # Detailed architecture docs
    └── api.md                 # API reference
```

## Critical Issues Blocking Development

### Zig 0.16.0 std.process.run Issue

**Status**: ✅ RESOLVED (2026-06-03)
**Priority**: ~~URGENT~~ Done
**Impact**: Unblocks Phase 2 (Tools System)
**Resolution**: Misdiagnosis. `std.process.run` works correctly in Zig 0.16.0. The
real cause was a **30-second timeout being exceeded by the LLM**: the hardcoded
prompt ("Create a simple HTML landing page…") takes ~34s with the `mimo-v2.5`
reasoning model. `std.process.run` returned `error.Timeout`, which `callLLMAPI`
caught and turned into piz's own `internal_error` exit code (110). The "exit code
110" was piz's semantic exit code, **not** a Zig internal error — the two were
conflated.

#### Root-Cause Evidence

- `std.process.run` with `.timeout = .none` returns the full response (exit 0).
- `std.process.run` with a 30s duration timeout waited *exactly* 30.03s before
  failing — proving the timeout mechanism fires correctly, not prematurely.
- A standalone repro (`sleep 1` with a 30s duration timeout) succeeds, confirming
  the duration-timeout API is sound.
- `curl` with the exact prompt measured **34.42s** wall-clock — over the old 30s
  limit, under the new 120s default.

#### Fix Applied (`src/main.zig`)

- Raised the timeout to a configurable `Config.timeout_ms` (default 120s) sized
  for reasoning-model latency; kept the monotonic (`.awake`) clock.
- Removed debug instrumentation; freed `result.stdout`/`result.stderr` and
  `argv_slice` (DebugAllocator now reports zero leaks).
- Hardened the response parser to skip escaped quotes (`\"`) so JSON-encoded HTML
  content is no longer truncated at the first inner quote.

Result: `piz` now exits 0 with the full streamed response and no leaks.

#### Original Problem Description (for the record)

When using Zig 0.16.0's `std.process.run` API to execute curl commands, the process fails with exit code 110 (internal error). Direct shell execution of the same curl command works perfectly, indicating the issue is specifically with Zig's process execution API.

> Note: the premise above was incorrect — shell `curl` "worked" only because those
> tests used short prompts that finished under 30s. See the resolution above.

#### Current Behavior

```zig
// This fails with exit code 110
const result = std.process.run(gpa, io, .{
    .argv = &[_][]const u8{ "curl", "-s", "-X", "POST", ... },
    .stdout_limit = .unlimited,
    .stderr_limit = .unlimited,
    .timeout = timeout,
});
```

#### Known Working Alternative

```bash
# This works perfectly
curl -s -X POST https://token-plan-ams.xiaomimico.com/v1/chat/completions \
  -H 'Authorization: Bearer tp-ejau4ye7ifigruk0ji0r5xul1nk00vwc9i1m32jdstxpcg52' \
  -H 'Content-Type: application/json' \
  --data-raw '{"model":"mimo-v2.5","messages":[...],"stream":false}'
```

#### Investigation Steps

1. **Test with simpler commands**
   - Try executing basic commands (echo, ls, pwd)
   - Test with different argument combinations
   - Verify the issue is not specific to curl

2. **Check std.Io integration**
   - Verify io parameter is correctly passed
   - Test with different io configurations
   - Check if the issue is with timeout handling

3. **Test different process APIs**
   - Try `std.process.spawn` instead of `std.process.run`
   - Test with `std.Child` (if available in 0.16.0)
   - Compare with supercli-zig's working implementation

4. **Environment investigation**
   - Check if environment variables are being passed correctly
   - Test with minimal environment
   - Verify PATH and other critical variables

5. **API version compatibility**
   - Check Zig 0.16.0 release notes for breaking changes
   - Test with different Zig versions (0.15.0, 0.17.0 if available)
   - Check Zig GitHub issues for similar problems

#### Potential Solutions

##### Option A: Fix std.process.run (Preferred)

**Pros**:
- Clean, in-process execution
- Better control over process lifecycle
- No external dependencies
- Consistent with Zig best practices

**Cons**:
- Requires debugging Zig API
- May need Zig bug fix or workaround
- Time investment uncertain

**Investigation Tasks**:
- [ ] Create minimal reproduction case
- [ ] File Zig issue with full details
- [ ] Test with different Zig versions
- [ ] Compare with supercli-zig working code
- [ ] Try alternative std.process APIs

**Estimated Effort**: 2-5 days (depending on root cause)

##### Option B: Shell Execution Fallback (Immediate)

**Pros**:
- Works immediately
- Proven to work with curl
- Low risk
- Quick implementation

**Cons**:
- Less control over process
- Shell injection risks
- Platform-specific (sh vs cmd.exe)
- Not ideal for production

**Implementation Tasks**:
- [ ] Implement shell execution wrapper
- [ ] Add input sanitization
- [ ] Handle platform differences
- [ ] Add error handling
- [ ] Document as temporary workaround

**Estimated Effort**: 1-2 days

##### Option C: HTTP Client Library (Alternative)

**Pros**:
- No external process execution
- Better HTTP control
- Cross-platform
- More idiomatic

**Cons**:
- Requires HTTP library
- May have Zig 0.16.0 compatibility issues
- Additional dependency
- More complex than curl

**Investigation Tasks**:
- [ ] Evaluate available Zig HTTP libraries
- [ ] Test compatibility with Zig 0.16.0
- [ ] Assess TLS support
- [ ] Evaluate maintenance status

**Estimated Effort**: 3-4 days

#### Decision Framework

**If Option A succeeds within 3 days**: Proceed with std.process.run fix
**If Option A fails after 3 days**: Implement Option B as fallback
**If Option B proves problematic**: Investigate Option C

#### Current Action Plan

1. **Day 1**: Create minimal reproduction, test with simple commands
2. **Day 2**: Compare with supercli-zig, test different process APIs
3. **Day 3**: File Zig issue if needed, evaluate Option B
4. **Day 4-5**: Implement chosen solution

#### Success Criteria

- [x] Can execute curl commands successfully from Zig
- [x] Can capture stdout/stderr correctly
- [x] Can handle timeouts and signals
- [x] Works consistently across multiple runs
- [x] Error handling is robust

#### Related Code

**Current Implementation**: `src/main.zig:callLLMAPI()`
**Reference Implementation**: `~/ai/supercli/supercli-zig-cli/src/executor.zig`
**Zig Documentation**: https://ziglang.org/documentation/0.16.0/std/#std;process

#### Blocking Dependencies

This issue blocks:
- Phase 1.3: Fix std.process.run issues
- Phase 2: Tools System (all tools require process execution)
- Phase 3: Skills System (skills may need tool execution)

#### Progress Tracking

- **Created**: 2025-01-XX
- **Status**: ✅ Resolved
- **Last Updated**: 2026-06-03
- **Resolution**: Not a Zig bug — timeout too short for reasoning-model latency. Fixed by raising default timeout to 120s + parser/leak cleanup.

## Remaining Work

### Phase 1: Foundation (Week 1-2)

#### 1.1 Configuration Management

**Priority**: HIGH
**Status**: Not Started
**Effort**: 2-3 days

**Tasks**:
- [ ] Implement config file loading (`~/.config/piz/config.json`)
- [ ] Support environment variable overrides
- [ ] Add config validation schema
- [ ] Implement config migration/versioning
- [ ] Add `--config` flag for custom config paths

**Config Structure**:
```json
{
  "version": "1.0.0",
  "llm": {
    "provider": "xiaomi-custom",
    "model": "mimo-v2.5",
    "api_key": "env:PIZ_API_KEY",
    "base_url": "https://token-plan-ams.xiaomimico.com/v1",
    "timeout_ms": 30000,
    "max_tokens": 1000000
  },
  "tools": {
    "terminal": {
      "enabled": true,
      "timeout_ms": 15000,
      "allow_dangerous": false
    },
    "web_search": {
      "enabled": true,
      "provider": "brave",
      "timeout_ms": 10000
    }
  },
  "skills": {
    "enabled": true,
    "paths": ["~/.agents/skills", "~/.config/devin/skills"],
    "auto_sync": true
  },
  "output": {
    "default_format": "json",
    "stream": true,
    "pretty": false
  }
}
```

#### 1.2 CLI Argument Parser

**Priority**: HIGH
**Status**: Not Started
**Effort**: 3-4 days

**Tasks**:
- [ ] Implement full argument parser (flags, options, positional args)
- [ ] Add `--prompt` / `-p` for LLM prompts
- [ ] Add `--model` for model selection
- [ ] Add `--provider` for provider selection
- [ ] Add `--tool` flag to enable specific tools
- [ ] Add `--skill` flag to load specific skills
- [ ] Add `--config` flag for custom config
- [ ] Add `--no-stream` flag for non-streaming output
- [ ] Add `--pretty` flag for pretty-printed JSON
- [ ] Implement argument validation

**Usage Examples**:
```bash
piz --prompt "List files in current directory"
piz --prompt "Search for Zig tutorials" --tool web_search
piz --prompt "Deploy to production" --skill deployment
piz --prompt "Analyze logs" --tool terminal --skill log-analysis
```

#### 1.3 Fix std.process.run Issues

**Priority**: ~~CRITICAL~~
**Status**: ✅ Done (2026-06-03)
**Effort**: ~~2-3 days~~ (root cause was a too-short timeout, not the API)

**Tasks**:
- [x] Debug Zig 0.16.0 std.process.run failures — API is sound; 30s timeout was being exceeded
- [x] ~~Try alternative approaches~~ — unnecessary; `std.process.run` works
- [x] ~~Implement fallback to shell execution~~ — unnecessary
- [x] Add comprehensive error handling for process execution
- [x] Add timeout and signal handling — configurable `timeout_ms` (default 120s)
- [ ] Test on macOS (verified on Linux)

**Investigation Areas**:
- Check if issue is with argv construction
- Test with simpler commands (echo, ls)
- Verify std.Io integration
- Check for environment variable issues
- Test with different timeout configurations

### Phase 2: Tools System (Week 3-4)

#### 2.1 Tool Registry and Interface

**Priority**: HIGH
**Status**: Not Started
**Effort**: 3-4 days

**Tasks**:
- [ ] Define tool interface schema
- [ ] Implement tool registration system
- [ ] Add tool discovery and validation
- [ ] Implement tool permission system
- [ ] Add tool dependency management

**Tool Interface**:
```zig
const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: ToolSchema,
    execute: *const fn (context: *Context, args: ToolArgs) !ToolResult,
    requires_permission: bool = false,
    timeout_ms: u32 = 15000,
};

const ToolSchema = struct {
    parameters: []Parameter,
    required: []const []const u8,
};

const ToolResult = union(enum) {
    success: []const u8,
    error: struct {
        code: u8,
        message: []const u8,
    },
};
```

#### 2.2 Terminal Tool

**Priority**: HIGH
**Status**: Not Started
**Effort**: 3-4 days

**Tasks**:
- [ ] Implement terminal command execution
- [ ] Add stdout/stderr capture
- [ ] Implement timeout handling
- [ ] Add working directory support
- [ ] Implement environment variable passing
- [ ] Add permission checks (dangerous commands)
- [ ] Implement command whitelist/blacklist

**Terminal Tool Schema**:
```json
{
  "name": "terminal",
  "description": "Execute terminal commands",
  "schema": {
    "parameters": [
      {
        "name": "command",
        "type": "string",
        "description": "Command to execute",
        "required": true
      },
      {
        "name": "cwd",
        "type": "string",
        "description": "Working directory",
        "required": false
      },
      {
        "name": "timeout_ms",
        "type": "integer",
        "description": "Timeout in milliseconds",
        "required": false,
        "default": 15000
      }
    ]
  },
  "requires_permission": true,
  "dangerous": true
}
```

**Usage**:
```bash
piz --prompt "List all Zig files" --tool terminal
piz --prompt "Run tests" --tool terminal --skill testing
```

#### 2.3 Web Search Tool

**Priority**: MEDIUM
**Status**: Not Started
**Effort**: 2-3 days

**Tasks**:
- [ ] Implement web search client (Brave Search API)
- [ ] Add query construction and escaping
- [ ] Implement result parsing
- [ ] Add caching for repeated queries
- [ ] Add rate limiting
- [ ] Implement fallback to different providers

**Web Search Tool Schema**:
```json
{
  "name": "web_search",
  "description": "Search the web for information",
  "schema": {
    "parameters": [
      {
        "name": "query",
        "type": "string",
        "description": "Search query",
        "required": true
      },
      {
        "name": "num_results",
        "type": "integer",
        "description": "Number of results",
        "required": false,
        "default": 5
      },
      {
        "name": "provider",
        "type": "string",
        "description": "Search provider",
        "required": false,
        "default": "brave"
      }
    ]
  },
  "requires_permission": false
}
```

**Usage**:
```bash
piz --prompt "Find Zig 0.16.0 documentation" --tool web_search
piz --prompt "Search for async await examples" --tool web_search
```

#### 2.4 Tool Execution Engine

**Priority**: HIGH
**Status**: Not Started
**Effort**: 3-4 days

**Tasks**:
- [ ] Implement tool request parsing from LLM responses
- [ ] Add tool call orchestration
- [ ] Implement parallel tool execution
- [ ] Add tool result aggregation
- [ ] Implement tool call retry logic
- [ ] Add tool call logging and debugging

**Tool Call Format**:
```json
{
  "tool_calls": [
    {
      "id": "call_123",
      "tool": "terminal",
      "arguments": {
        "command": "ls -la",
        "cwd": "/home/user/project"
      }
    }
  ]
}
```

### Phase 3: Skills System (Week 5-6)

#### 3.1 Skill Discovery and Loading

**Priority**: HIGH
**Status**: Not Started
**Effort**: 3-4 days

**Tasks**:
- [ ] Implement skill directory scanning (~/.agents/skills)
- [ ] Add SKILL.md parsing
- [ ] Implement skill metadata extraction
- [ ] Add skill dependency resolution
- [ ] Implement skill caching
- [ ] Add skill validation

**Skill Discovery**:
```zig
const Skill = struct {
    name: []const u8,
    path: []const u8,
    metadata: SkillMetadata,
    content: []const u8,
};

const SkillMetadata = struct {
    description: []const u8,
    version: []const u8,
    author: []const u8,
    triggers: [][]const u8,
    tools: [][]const u8,
    permissions: [][]const u8,
};
```

#### 3.2 Skill Execution Engine

**Priority**: HIGH
**Status**: Not Started
**Effort**: 4-5 days

**Tasks**:
- [ ] Implement skill loading and initialization
- [ ] Add skill context management
- [ ] Implement skill instruction injection
- [ ] Add skill tool orchestration
- [ ] Implement skill lifecycle (load, execute, cleanup)
- [ ] Add skill error handling and recovery

**Skill Execution Flow**:
```
1. Parse user prompt
2. Match against skill triggers
3. Load relevant skills
4. Inject skill instructions into LLM context
5. Execute skill with required tools
6. Return structured response
```

#### 3.3 Skill Manager CLI

**Priority**: MEDIUM
**Status**: Not Started
**Effort**: 2-3 days

**Tasks**:
- [ ] Add `piz skills list` command
- [ ] Add `piz skills search <query>` command
- [ ] Add `piz skills load <name>` command
- [ ] Add `piz skills unload <name>` command
- [ ] Add `piz skills sync` command
- [ ] Add `piz skills validate <name>` command

**Usage Examples**:
```bash
piz skills list                    # List all available skills
piz skills search "deployment"     # Search for deployment skills
piz skills load deployment         # Load deployment skill
piz --prompt "Deploy to prod"      # Use loaded skill
```

### Phase 4: Advanced Features (Week 7-8)

#### 4.1 Streaming Tool Results

**Priority**: MEDIUM
**Status**: Not Started
**Effort**: 2-3 days

**Tasks**:
- [ ] Implement real-time tool result streaming
- [ ] Add progress indicators for long-running tools
- [ ] Implement tool result chunking
- [ ] Add tool cancellation support

#### 4.2 Multi-Turn Conversations

**Priority**: MEDIUM
**Status**: Not Started
**Effort**: 3-4 days

**Tasks**:
- [ ] Implement conversation context management
- [ ] Add message history tracking
- [ ] Implement context window management
- [ ] Add conversation summarization
- [ ] Implement session persistence

**Conversation Format**:
```json
{
  "conversation_id": "uuid",
  "messages": [
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "...", "tool_calls": [...]},
    {"role": "tool", "tool_call_id": "...", "content": "..."}
  ]
}
```

#### 4.3 State Management

**Priority**: LOW
**Status**: Not Started
**Effort**: 2-3 days

**Tasks**:
- [ ] Implement key-value state storage
- [ ] Add state persistence to disk
- [ ] Implement state versioning
- [ ] Add state sharing between skills
- [ ] Implement state cleanup and expiration

#### 4.4 Plugin System

**Priority**: LOW
**Status**: Not Started
**Effort**: 4-5 days

**Tasks**:
- [ ] Design plugin interface
- [ ] Implement plugin loading system
- [ ] Add plugin sandboxing
- [ ] Implement plugin dependency management
- [ ] Add plugin marketplace integration

### Phase 5: Polish and Documentation (Week 9-10)

#### 5.1 Testing and Validation

**Priority**: HIGH
**Status**: Not Started
**Effort**: 5-7 days

**Tasks**:
- [ ] Write unit tests for core components
- [ ] Write integration tests for tools
- [ ] Write end-to-end tests for skills
- [ ] Add performance benchmarks
- [ ] Implement stress testing
- [ ] Add security audit

**Test Coverage Goals**:
- Core components: 80%+
- Tools: 90%+
- Skills: 70%+
- Integration: 60%+

#### 5.2 Documentation

**Priority**: HIGH
**Status**: Not Started
**Effort**: 3-4 days

**Tasks**:
- [ ] Write comprehensive API documentation
- [ ] Create user guide with examples
- [ ] Write skill development guide
- [ ] Create tool development guide
- [ ] Add troubleshooting guide
- [ ] Create migration guide from pi

#### 5.3 Performance Optimization

**Priority**: MEDIUM
**Status**: Not Started
**Effort**: 2-3 days

**Tasks**:
- [ ] Profile and optimize hot paths
- [ ] Implement connection pooling for HTTP
- [ ] Add response caching
- [ ] Optimize memory usage
- [ ] Implement lazy loading for skills

#### 5.4 Security Hardening

**Priority**: HIGH
**Status**: Not Started
**Effort**: 3-4 days

**Tasks**:
- [ ] Implement API key encryption
- [ ] Add input validation and sanitization
- [ ] Implement command whitelist for terminal tool
- [ ] Add rate limiting for API calls
- [ ] Implement audit logging
- [ ] Add permission system for dangerous operations

## Release Planning

### v0.2.0 - Foundation (Target: Week 2)

**Features**:
- Configuration management
- CLI argument parser
- Fixed std.process.run issues
- Basic error handling improvements

### v0.3.0 - Tools (Target: Week 4)

**Features**:
- Tool registry and interface
- Terminal tool
- Web search tool
- Tool execution engine

### v0.4.0 - Skills (Target: Week 6)

**Features**:
- Skill discovery and loading
- Skill execution engine
- Skill manager CLI
- Basic skill examples

### v0.5.0 - Advanced (Target: Week 8)

**Features**:
- Streaming tool results
- Multi-turn conversations
- State management
- Performance optimizations

### v1.0.0 - Production Ready (Target: Week 10)

**Features**:
- Comprehensive testing
- Full documentation
- Security hardening
- Plugin system foundation
- Migration guide from pi

## Dependencies and External Services

### Required

- **Zig 0.16.0+**: Core language
- **xiaomi-custom API**: LLM provider (mimo-v2.5)
- **curl**: HTTP client (fallback if std.process.run issues persist)

### Optional

- **Brave Search API**: Web search provider
- **OpenAI API**: Alternative LLM provider
- **Anthropic API**: Alternative LLM provider
- **File system**: For skill loading and state persistence

## Success Criteria

### Functional Requirements

- ✅ Non-interactive, agent-first design
- ✅ JSON output with streaming support
- ✅ Semantic exit codes
- ⬜ Terminal tool execution
- ⬜ Web search capability
- ⬜ Skills system (~/.agents/skills)
- ⬜ Configuration management
- ⬜ Multi-turn conversations

### Non-Functional Requirements

- ✅ Zig 0.16.0 compatibility
- ⬜ <100ms startup time
- ⬜ <2s typical response time
- ⬜ <50MB binary size
- ⬜ 80%+ test coverage
- ⬜ Security audit passed

### User Experience

- ⬜ Clear error messages with recovery suggestions
- ⬜ Comprehensive documentation
- ⬜ Easy skill development
- ⬜ Intuitive CLI interface
- ⬜ Fast and responsive

## Risks and Mitigations

### Technical Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Zig 0.16.0 API instability | High | Medium | Use fallback to shell execution, monitor Zig releases |
| LLM provider rate limits | Medium | High | Implement caching, rate limiting, multiple providers |
| Tool execution security | High | Medium | Whitelist commands, permission system, sandboxing |
| Skill compatibility | Medium | Medium | Version skills, validation, deprecation strategy |

### Project Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Scope creep | High | High | Strict phase gating, MVP focus |
| Resource constraints | Medium | Medium | Prioritize features, extend timeline if needed |
| Adoption barriers | Medium | Low | Comprehensive docs, migration guide, examples |

## Open Questions

1. ~~**std.process.run**: Should we invest more time fixing Zig's process API or accept shell execution as a permanent fallback?~~ **Answered**: `std.process.run` works correctly; no fallback needed. The original failure was a too-short timeout, not an API bug.
2. **Skill Format**: Should we use the existing SKILL.md format or design a new, more structured format?
3. **Tool Discovery**: Should tools be auto-discovered or explicitly registered?
4. **State Management**: Should state be in-memory only or persisted to disk?
5. **Plugin System**: Is a plugin system necessary for v1.0 or can it be deferred?

## Contributing

This roadmap is a living document. As we progress through phases, we'll update priorities and timelines based on learnings and user feedback.

For questions or contributions, please refer to the main project documentation.