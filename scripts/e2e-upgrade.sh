#!/usr/bin/env bash
# e2e-upgrade.sh — pinned-install → `tau upgrade` → doctor-clean e2e (POSIX).
#
# Drives the documented upgrade path end to end against a fully staged,
# file:// release tree — no network access required:
#
#   1. install.sh --version 0.3.9     pinned older install through the
#                                     versioned release path
#                                     ($TAU_BASE_URL/download/v<ver>/<asset>),
#                                     checksum-verified like a real install.
#   2. tau setup --client zed         wire a client entry whose command is the
#                                     installed binary's absolute path, so the
#                                     post-upgrade doctor run proves wiring
#                                     survives the in-place binary swap.
#   3. tau upgrade --yes              the upgrade itself: update check against
#                                     a file:// release stub (tag v99.9.9 >
#                                     embedded 0.4.0 drives the decision),
#                                     install.sh fetched via file://, asset +
#                                     SHA256SUMS.txt from the staged tree.
#                                     No --dir: the binary upgrades in place.
#   4. tau doctor --offline --selftest
#                                     post-upgrade health: a keyed run must
#                                     go green (exit 0) and the zed wiring
#                                     row must still verify ok.
#
# The release payload is the just-built binary itself — the v99.9.9 tag
# drives the update decision, so the post-upgrade binary is a real tau that
# can run doctor, not a stub.
#
# Usage: scripts/e2e-upgrade.sh <built-tau> [work-dir]
#   <built-tau>  just-built binary staged as the release payload
#   [work-dir]   scratch dir for staging/install/HOME (default: mktemp -d)
set -euo pipefail

TAU_SRC="${1:?usage: e2e-upgrade.sh <built-tau> [work-dir]}"
WORK="${2:-$(mktemp -d)}"
mkdir -p "$WORK"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

OLD=0.3.9
NEW=99.9.9

KEYVARS="XIAOMI_API_KEY PIZIG_API_KEY OPENAI_API_KEY DEEPSEEK_API_KEY OPENCODE_API_KEY TAU_API_KEY"
scrub_env() {
  local args=() k
  for k in $KEYVARS; do args+=(-u "$k"); done
  env "${args[@]}" "$@"
}

fail() {
  echo "e2e-upgrade: FAIL — $*" >&2
  exit 1
}

# ── Platform → asset name (same mapping install.sh uses) ───────────────────
asset_os=""
case "$(uname -s)" in
  Linux)  asset_os=linux ;;
  Darwin) asset_os=macos ;;
esac
asset_arch="$(uname -m)"
case "$asset_arch" in
  amd64) asset_arch=x86_64 ;;
  arm64) asset_arch=aarch64 ;;
esac
case "$asset_arch" in x86_64|aarch64) ;; *) asset_arch="" ;; esac
if [ -z "$asset_os" ] || [ -z "$asset_arch" ]; then
  echo "e2e-upgrade: SKIP — unsupported host platform ($(uname -s)/$(uname -m))"
  exit 0
fi
ASSET="tau-$asset_os-$asset_arch.tar.gz"

echo "e2e-upgrade: work=$WORK src=$TAU_SRC asset=$ASSET"

# ── Stage the release tree ─────────────────────────────────────────────────
# Both versions carry the real binary as payload; only the tag differs. The
# layout matches what install.sh fetches: download/v<ver>/<asset> +
# download/v<ver>/SHA256SUMS.txt.
mkdir -p "$WORK/srv/download/v$OLD" "$WORK/srv/download/v$NEW" "$WORK/pkg"
cp "$TAU_SRC" "$WORK/pkg/tau"
chmod +x "$WORK/pkg/tau"
for v in "$OLD" "$NEW"; do
  tar -czf "$WORK/srv/download/v$v/$ASSET" -C "$WORK/pkg" tau
  (cd "$WORK/srv/download/v$v" && \
    { sha256sum "$ASSET" 2>/dev/null || shasum -a 256 "$ASSET"; } > SHA256SUMS.txt)
done
printf '{"tag_name":"v%s","name":"newer"}' "$NEW" > "$WORK/release.json"
cat > "$WORK/changelog.md" <<EOF
# Changelog

## [$NEW] - 2027-01-01

### Added
- staged upgrade payload

## [0.4.0] - 2026-06-12

### Added
- already installed
EOF
cp "$ROOT/install.sh" "$WORK/install.sh"

FH="$WORK/home"
mkdir -p "$FH"

# ── 1. Pinned older install ────────────────────────────────────────────────
TAU_BASE_URL="file://$WORK/srv" sh "$ROOT/install.sh" --version "$OLD" --dir "$WORK/bin" \
  >"$WORK/install.out" 2>"$WORK/install.err" \
  || { cat "$WORK/install.out" "$WORK/install.err" >&2; fail "install.sh --version $OLD exited $?"; }

TAU="$WORK/bin/tau"
[ -x "$TAU" ] || fail "pinned install did not produce $TAU"
grep -q 'checksum verified' "$WORK/install.err" "$WORK/install.out" 2>/dev/null \
  || grep -q 'checksum verified' "$WORK/install.err" \
  || fail "pinned install did not verify the checksum"
"$TAU" --version >/dev/null 2>&1 || fail "pinned binary does not run"
echo "e2e-upgrade: pinned install v$OLD ok ($TAU)"

# ── 2. Wire a client against the installed path ────────────────────────────
# setup writes command=<absolute exe path> — the very file the in-place
# upgrade swaps — so the post-upgrade doctor row proves wiring survives.
scrub_env XIAOMI_API_KEY=fake-ci HOME="$FH" "$TAU" setup --yes --offline --client zed \
  >"$WORK/setup-zed.ndjson" || fail "tau setup --yes --offline --client zed exited $?"
zed_cfg="$FH/.config/zed/settings.json"
[ -f "$zed_cfg" ] || fail "setup --client zed did not write $zed_cfg"
grep -q "$TAU" "$zed_cfg" || fail "zed wiring does not point at the installed path $TAU"
echo "e2e-upgrade: client wiring points at the installed path"

# ── 3. tau upgrade --yes (in place) ────────────────────────────────────────
# stdin pinned to /dev/null so the confirmation gate can never see a TTY.
set +e
scrub_env env -u TAU_VERIFY_SIGSTORE \
  TAU_UPDATE_URL="file://$WORK/release.json" \
  TAU_INSTALL_URL="file://$WORK/install.sh" \
  TAU_CHANGELOG_URL="file://$WORK/changelog.md" \
  TAU_BASE_URL="file://$WORK/srv" \
  HOME="$FH" \
  sh -c '"$0" upgrade --yes < /dev/null' "$TAU" \
  >"$WORK/upgrade.json" 2>"$WORK/upgrade.err"
rc=$?
set -e
[ "$rc" -eq 0 ] || { cat "$WORK/upgrade.json" "$WORK/upgrade.err" >&2; fail "tau upgrade --yes exited $rc"; }
grep -q '"status":"upgraded"' "$WORK/upgrade.json" \
  || { cat "$WORK/upgrade.json" >&2; fail "upgrade report missing \"status\":\"upgraded\""; }
grep -q 'checksum verified' "$WORK/upgrade.err" \
  || { cat "$WORK/upgrade.err" >&2; fail "upgrade did not checksum-verify the asset"; }
[ -x "$TAU" ] || fail "upgrade left no executable at $TAU"
echo "e2e-upgrade: tau upgrade --yes upgraded in place (status upgraded, checksum verified)"

# ── 4. Post-upgrade doctor clean ───────────────────────────────────────────
# Keyed, offline: every check must report ok and the verdict exits 0. The
# client_zed row is the keep-state assertion — wiring written in step 2 must
# still verify against the swapped binary at the same path.
scrub_env XIAOMI_API_KEY=fake-ci TAU_NO_UPDATE_CHECK=1 HOME="$FH" \
  "$TAU" doctor --offline --selftest >"$WORK/doctor.json" \
  || { cat "$WORK/doctor.json" >&2; fail "post-upgrade tau doctor exited $?"; }
for needle in '"name":"selftest","status":"ok"' '"name":"client_zed","status":"ok"'; do
  grep -q "$needle" "$WORK/doctor.json" \
    || { cat "$WORK/doctor.json" >&2; fail "post-upgrade doctor missing $needle"; }
done
echo "e2e-upgrade: post-upgrade doctor clean (exit 0, client_zed wiring still ok)"

echo "e2e-upgrade: PASS"
