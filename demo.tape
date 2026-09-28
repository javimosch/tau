# tau demo — install through first successful agent run.
# Renders demo/demo.gif, which is embedded in README.md.
#
# Regenerate from the repo root (requires vhs + ttyd + ffmpeg + python3):
#
#     vhs demo.tape
#
# Everything shown runs for real: git clone, zig build, tau itself, and the
# `ls` tool call. The only stub is the provider HTTP leg — tau shells out to
# the `curl` binary on PATH (src/llm/provider.zig), and the hidden setup puts
# demo/fake-curl earlier on PATH so the recording is deterministic and works
# with no API key. To record against a live provider instead, delete the PATH
# override in the hidden block and export a real TAU_API_KEY.

Output demo/demo.gif

Set Shell "bash"
Set FontSize 14
Set Width 1280
Set Height 720
Set TypingSpeed 60ms
Set Theme "Catppuccin Mocha"

# Hidden setup: fresh HOME + a bin/ dir holding the fake curl shim.
Hide
Type "export DEMO_DIR=$(mktemp -d -t tau-demo-XXXXXX)" Enter
Type "export HOME=$DEMO_DIR/home; mkdir -p $HOME $DEMO_DIR/bin" Enter
Type "cp demo/fake-curl $DEMO_DIR/bin/curl && chmod +x $DEMO_DIR/bin/curl" Enter
Type "export PATH=$DEMO_DIR/bin:$PATH" Enter
Type "export PS1='$ '" Enter
Type "cd $DEMO_DIR" Enter
Type "clear" Enter
Show

# 1. Install (clone + build — the only path that needs nothing but Zig).
Type "git clone --depth 1 https://github.com/javimosch/tau.git" Enter
Wait+Screen@60s /Cloning into/
Sleep 3s

Type "cd tau && zig build && echo BUILD-READY" Enter
Wait+Screen@300s /BUILD-READY/
Sleep 1s

# 2. Configure a key (placeholder; any non-empty value reaches the provider).
Type "export TAU_API_KEY=sk-your-key-here" Enter
Sleep 1s

Type "./zig-out/bin/tau --version" Enter
Sleep 1.5s

# 3. First run — human-readable (streamed token by token).
Type "./zig-out/bin/tau --mode text --no-tools 'Say hello in one short sentence.'" Enter
Sleep 7s

# 4. Same call, default JSON envelope (what agents consume — NDJSON stream).
Type "./zig-out/bin/tau --no-tools 'What is tau in one sentence?'" Enter
Sleep 8s

# 5. Tool-calling loop — the model calls ls itself. --debug shows tool I/O.
Type "./zig-out/bin/tau --mode text --no-stream --debug --tools ls 'What is in the src/ directory?'" Enter
Sleep 10s

Type "echo 'docs: github.com/javimosch/tau'" Enter
Sleep 5s
