#!/usr/bin/env bash
# e2e-upgrade-rollback.sh — mocked-release `tau upgrade`/rollback e2e.
#
# Stages a fake release server on file:// and drives the whole self-update
# contract end to end with REAL tau binaries at two different versions:
#
#   1. Build a "next release" binary — a scratch copy of the source tree with
#      only src/version.zig bumped to 99.9.9, compiled by `zig build`. This is
#      what makes the version transition observable: the installed binary
#      itself reports the new version, and post-upgrade checks run on a real
#      tau, not a stub.
#   2. Stage <srv>/download/v0.4.0 and <srv>/download/v99.9.9 release trees
#      (asset tar.gz + SHA256SUMS.txt), a release.json pointing at v99.9.9,
#      and a changelog — the same file:// stubs the upgrade smoke uses.
#   3. Install the "current" release (0.4.0 = the binary under test) through
#      install.sh itself, into a scratch DEST.
#   4. Seed a scratch HOME with a JSONC config carrying comments, snapshot
#      its bytes, then run `<dest>/tau upgrade --yes` against the stubs.
#   5. Assert the transition: report status upgraded, `--version` now says
#      99.9.9, config.json is byte-identical, and `tau doctor --offline
#      --selftest` on the upgraded binary goes green.
#   6. Roll back by re-running install.sh at the older pinned version — the
#      exact mechanism `tau upgrade` uses internally (`sh install.sh
#      --version <tag> --dir <dest>`), since upgrade only ever moves forward.
#      Assert the version flips back, config is still untouched, doctor still
#      green.
#
# Usage: scripts/e2e-upgrade-rollback.sh <path-to-tau> [scratch-dir]
#   <path-to-tau>   tau binary playing the role of the installed 0.4.0
#   [scratch-dir]   work area (default: mktemp -d)
#
# Requires: zig (builds the 99.9.9 payload), curl, tar, sha256sum|shasum.
set -euo pipefail

TAU="${1:?usage: e2e-upgrade-rollback.sh <path-to-tau> [scratch-dir]}"
WORK="${2:-$(mktemp -d)}"
mkdir -p "$WORK"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FH="$WORK/home"
DEST="$WORK/bin"
SRV="$WORK/srv/download"
NEWVER="99.9.9"

fail() {
  echo "e2e-upgrade-rollback: FAIL — $*" >&2
  exit 1
}

for tool in zig curl tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not on PATH"
done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
  || fail "no sha256sum/shasum on PATH"
[ -x "$TAU" ] || fail "tau binary not executable: $TAU"

# The "current" release is whatever the binary under test reports — deriving
# it keeps the driver honest across version bumps instead of pinning 0.4.0.
OLDVER="$("$TAU" --version)"
OLDVER="${OLDVER#tau }"
case "$OLDVER" in
  *[!0-9.]*|"") fail "cannot derive installed version from '$TAU --version'" ;;
esac

case "$(uname -s)" in
  Linux)  asset_os=linux ;;
  Darwin) asset_os=macos ;;
  *)      fail "unsupported OS $(uname -s) — tau upgrade is POSIX-only" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)   asset_arch=x86_64 ;;
  aarch64|arm64)  asset_arch=aarch64 ;;
  *)              fail "unsupported arch $(uname -m)" ;;
esac
ASSET="tau-$asset_os-$asset_arch.tar.gz"

# tau invocations run under env -i with an explicit whitelist so ambient
# credentials, proxies, and TAU_* overrides cannot leak into the run.
clean_env() {
  env -i PATH="$PATH" HOME="$FH" TMPDIR="${TMPDIR:-/tmp}" "$@"
}

echo "e2e-upgrade-rollback: work=$WORK bin=$TAU asset=$ASSET"

# ── 1. Build the mocked "next release" binary ───────────────────────────────
SRC99="$WORK/src-$NEWVER"
mkdir -p "$SRC99"
cp "$ROOT/build.zig" "$SRC99/"
cp -r "$ROOT/src" "$ROOT/completions" "$SRC99/"
# Only the version constant changes — every other byte of the release is the
# real product, so post-upgrade doctor/selftest exercise genuine behavior.
sed -i "s/^pub const version = \".*\";$/pub const version = \"$NEWVER\";/" \
  "$SRC99/src/version.zig"
grep -q "\"$NEWVER\"" "$SRC99/src/version.zig" || fail "version bump did not apply"
(cd "$SRC99" && zig build) || fail "zig build of the $NEWVER payload failed"
NEWBIN="$SRC99/zig-out/bin/tau"
[ -x "$NEWBIN" ] || fail "payload binary missing at $NEWBIN"
[ "$("$NEWBIN" --version)" = "tau $NEWVER" ] \
  || fail "payload --version is '$("$NEWBIN" --version)', want 'tau $NEWVER'"
echo "e2e-upgrade-rollback: built mocked v$NEWVER payload"

# ── 2. Stage the release server ──────────────────────────────────────────────
mkdir -p "$SRV/v$OLDVER/pkg" "$SRV/v$NEWVER/pkg"
cp "$TAU" "$SRV/v$OLDVER/pkg/tau" && chmod +x "$SRV/v$OLDVER/pkg/tau"
cp "$NEWBIN" "$SRV/v$NEWVER/pkg/tau" && chmod +x "$SRV/v$NEWVER/pkg/tau"
tar -czf "$SRV/v$OLDVER/$ASSET" -C "$SRV/v$OLDVER/pkg" tau
tar -czf "$SRV/v$NEWVER/$ASSET" -C "$SRV/v$NEWVER/pkg" tau
for v in "v$OLDVER" "v$NEWVER"; do
  (cd "$SRV/$v" && \
    { sha256sum "$ASSET" 2>/dev/null || shasum -a 256 "$ASSET"; } > SHA256SUMS.txt)
done
printf '{"tag_name":"v%s","name":"mocked newer release"}' "$NEWVER" > "$WORK/release.json"
cat > "$WORK/changelog.md" <<EOF
# Changelog

## [$NEWVER] - 2027-01-01

### Added
- mocked e2e feature

## [$OLDVER] - 2026-06-12

### Added
- already installed
EOF

# ── 3. Scratch HOME with a commented JSONC config ───────────────────────────
mkdir -p "$FH/.config/tau" "$DEST"
cat > "$FH/.config/tau/config.json" <<'EOF'
{
  // primary provider — comment must survive the upgrade
  "provider": "xiaomi",
  "model": "mimo-v2.5",
  /* block comment: pinned output mode */
  "mode": "json",
  "temperature": 0.4
}
EOF
chmod 600 "$FH/.config/tau/config.json"

# ── 4. Install the "current" release via the real installer ─────────────────
clean_env TAU_BASE_URL="file://$WORK/srv" \
  sh "$ROOT/install.sh" --version "$OLDVER" --dir "$DEST" >"$WORK/install-old.log" 2>&1 \
  || { cat "$WORK/install-old.log" >&2; fail "install.sh --version $OLDVER failed"; }
[ "$(clean_env "$DEST/tau" --version)" = "tau $OLDVER" ] \
  || fail "installed --version is '$(clean_env "$DEST/tau" --version)', want 'tau $OLDVER'"
grep -q "checksum verified" "$WORK/install-old.log" \
  || fail "install.log missing 'checksum verified'"
echo "e2e-upgrade-rollback: installed v$OLDVER via install.sh (checksum verified)"

cp "$FH/.config/tau/config.json" "$WORK/config.before"

# ── 5. tau upgrade --yes against the mocked release ─────────────────────────
clean_env \
  TAU_UPDATE_URL="file://$WORK/release.json" \
  TAU_INSTALL_URL="file://$ROOT/install.sh" \
  TAU_CHANGELOG_URL="file://$WORK/changelog.md" \
  TAU_BASE_URL="file://$WORK/srv" \
  "$DEST/tau" upgrade --yes >"$WORK/upgrade.json" 2>"$WORK/upgrade.err" \
  || { cat "$WORK/upgrade.json" "$WORK/upgrade.err" >&2; fail "tau upgrade --yes exited $?"; }
grep -q '"status":"upgraded"' "$WORK/upgrade.json" \
  || { cat "$WORK/upgrade.json" >&2; fail "upgrade report missing status:upgraded"; }
grep -q '"update_available":true' "$WORK/upgrade.json" \
  || fail "upgrade report missing update_available:true"
grep -q "installed tau $NEWVER -> $DEST/tau" "$WORK/upgrade.json" \
  || fail "upgrade report missing detail 'installed tau $NEWVER -> $DEST/tau'"
grep -q "\"changelog\":\[{\"version\":\"$NEWVER\"" "$WORK/upgrade.json" \
  || fail "upgrade report missing mocked changelog entries"
echo "e2e-upgrade-rollback: tau upgrade --yes reported status:upgraded"

# ── 6. Version transition ────────────────────────────────────────────────────
[ "$(clean_env "$DEST/tau" --version)" = "tau $NEWVER" ] \
  || fail "post-upgrade --version is '$(clean_env "$DEST/tau" --version)', want 'tau $NEWVER'"
clean_env "$DEST/tau" version --json | grep -q "\"version\":\"$NEWVER\"" \
  || fail "post-upgrade version --json does not report $NEWVER"
echo "e2e-upgrade-rollback: version transition $OLDVER -> $NEWVER verified"

# ── 7. Config byte-preservation ──────────────────────────────────────────────
cmp -s "$WORK/config.before" "$FH/.config/tau/config.json" \
  || fail "config.json bytes changed across upgrade"
echo "e2e-upgrade-rollback: config.json byte-identical after upgrade"

# ── 8. Green doctor on the upgraded binary ──────────────────────────────────
clean_env XIAOMI_API_KEY=fake-ci "$DEST/tau" doctor --offline --selftest \
  >"$WORK/doctor-upgraded.json" \
  || { cat "$WORK/doctor-upgraded.json" >&2; fail "post-upgrade tau doctor exited $?"; }
grep -q '"ok":true' "$WORK/doctor-upgraded.json" \
  || { cat "$WORK/doctor-upgraded.json" >&2; fail "post-upgrade doctor verdict not ok"; }
grep -q '"name":"selftest","status":"ok"' "$WORK/doctor-upgraded.json" \
  || fail "post-upgrade selftest row not ok"
echo "e2e-upgrade-rollback: post-upgrade doctor green"

# ── 9. Rollback: re-install the older pinned release ────────────────────────
# `tau upgrade` only ever moves forward, so a rollback is the same mechanism
# it uses internally — install.sh --version <older> — run directly.
clean_env TAU_BASE_URL="file://$WORK/srv" \
  sh "$ROOT/install.sh" --version "$OLDVER" --dir "$DEST" >"$WORK/install-rollback.log" 2>&1 \
  || { cat "$WORK/install-rollback.log" >&2; fail "rollback install.sh --version $OLDVER failed"; }
[ "$(clean_env "$DEST/tau" --version)" = "tau $OLDVER" ] \
  || fail "post-rollback --version is '$(clean_env "$DEST/tau" --version)', want 'tau $OLDVER'"
grep -q "checksum verified" "$WORK/install-rollback.log" \
  || fail "rollback install.log missing 'checksum verified'"
cmp -s "$WORK/config.before" "$FH/.config/tau/config.json" \
  || fail "config.json bytes changed across rollback"
echo "e2e-upgrade-rollback: rollback $NEWVER -> $OLDVER verified (checksum verified, config intact)"

# ── 10. Doctor still green after rollback ───────────────────────────────────
clean_env XIAOMI_API_KEY=fake-ci "$DEST/tau" doctor --offline --selftest \
  >"$WORK/doctor-rollback.json" \
  || { cat "$WORK/doctor-rollback.json" >&2; fail "post-rollback tau doctor exited $?"; }
grep -q '"ok":true' "$WORK/doctor-rollback.json" \
  || fail "post-rollback doctor verdict not ok"
echo "e2e-upgrade-rollback: post-rollback doctor green"

echo "e2e-upgrade-rollback: PASS"
