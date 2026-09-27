#!/bin/sh
# install.sh — install a prebuilt tau binary (no Zig toolchain required).
#
#   curl -fsSL https://raw.githubusercontent.com/javimosch/tau/master/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/javimosch/tau/master/install.sh | sh -s -- --version 0.5.0
#
# Options:
#   --version X.Y.Z   install a specific release (default: latest)
#   --dir DIR         install into DIR (default: ~/.local/bin)
#   --dry-run         print the resolved platform/URL/plan and exit 0
#   -h, --help        show this help
#
# Environment overrides:
#   TAU_VERSION       same as --version
#   TAU_INSTALL_DIR   same as --dir
#   TAU_OS            override `uname -s` detection (linux|darwin)
#   TAU_ARCH          override `uname -m` detection (x86_64|aarch64|arm64)
#
# Release assets are produced by .github/workflows/release.yml and named
# tau-<os>-<arch>.tar.gz alongside a SHA256SUMS.txt manifest.

set -eu

REPO="javimosch/tau"
BASE="https://github.com/$REPO/releases"

VERSION="${TAU_VERSION:-}"
DEST="${TAU_INSTALL_DIR:-$HOME/.local/bin}"
DRY_RUN=0
OS_OVERRIDE="${TAU_OS:-}"
ARCH_OVERRIDE="${TAU_ARCH:-}"

usage() {
  cat <<'EOF'
install.sh — install a prebuilt tau binary (no Zig toolchain required).

  curl -fsSL https://raw.githubusercontent.com/javimosch/tau/master/install.sh | sh
  curl -fsSL https://raw.githubusercontent.com/javimosch/tau/master/install.sh | sh -s -- --version 0.5.0

Options:
  --version X.Y.Z   install a specific release (default: latest)
  --dir DIR         install into DIR (default: ~/.local/bin)
  --dry-run         print the resolved platform/URL/plan and exit 0
  -h, --help        show this help

Environment overrides:
  TAU_VERSION       same as --version
  TAU_INSTALL_DIR   same as --dir
  TAU_OS            override `uname -s` detection (linux|darwin)
  TAU_ARCH          override `uname -m` detection (x86_64|aarch64|arm64)
EOF
}

fail() {
  echo "install.sh: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || fail "--version requires a value (e.g. --version 0.5.0)"
      VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#--version=}"; shift ;;
    --dir)
      [ $# -ge 2 ] || fail "--dir requires a path"
      DEST="$2"; shift 2 ;;
    --dir=*) DEST="${1#--dir=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option '$1' (try --help)" ;;
  esac
done

# ── Platform detection ──────────────────────────────────────────────────────
raw_os="${OS_OVERRIDE:-$(uname -s)}"
raw_arch="${ARCH_OVERRIDE:-$(uname -m)}"

case "$(printf '%s' "$raw_os" | tr '[:upper:]' '[:lower:]')" in
  linux)  OS="linux" ;;
  darwin) OS="macos" ;;
  *) fail "unsupported OS '$raw_os' — prebuilt binaries exist for linux and macos only; build from source instead (see README.md 'Build & Install')" ;;
esac

case "$(printf '%s' "$raw_arch" | tr '[:upper:]' '[:lower:]')" in
  x86_64|amd64)   ARCH="x86_64" ;;
  aarch64|arm64)  ARCH="aarch64" ;;
  *) fail "unsupported architecture '$raw_arch' — prebuilt binaries exist for x86_64 and aarch64 only" ;;
esac

PLATFORM="$OS-$ARCH"
ASSET="tau-$PLATFORM.tar.gz"
SUMS="SHA256SUMS.txt"

# ── Version resolution ──────────────────────────────────────────────────────
VERSION="${VERSION#v}"
if [ -n "$VERSION" ]; then
  case "$VERSION" in
    *[!0-9.]*|"") fail "invalid --version '$VERSION' (expected a dotted triple like 0.5.0)" ;;
  esac
  ASSET_URL="$BASE/download/v$VERSION/$ASSET"
  SUMS_URL="$BASE/download/v$VERSION/$SUMS"
  RELEASE_DESC="v$VERSION"
else
  ASSET_URL="$BASE/latest/download/$ASSET"
  SUMS_URL="$BASE/latest/download/$SUMS"
  RELEASE_DESC="latest"
fi

echo "install.sh: platform=$PLATFORM release=$RELEASE_DESC dest=$DEST"
echo "install.sh: url=$ASSET_URL"

if [ "$DRY_RUN" = "1" ]; then
  echo "install.sh: dry-run — would download, verify, and install 'tau' into $DEST"
  exit 0
fi

# ── Download + verify ───────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || fail "curl not found on PATH — install curl or build from source"
command -v tar  >/dev/null 2>&1 || fail "tar not found on PATH"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t tau-install)"
trap 'rm -rf "$TMP"' EXIT INT TERM

curl -fsSL "$ASSET_URL" -o "$TMP/$ASSET" \
  || fail "download failed — check that release $RELEASE_DESC ships $ASSET ($ASSET_URL)"

if curl -fsSL "$SUMS_URL" -o "$TMP/$SUMS" 2>/dev/null; then
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$TMP" && grep " $ASSET\$" "$SUMS" | sha256sum -c - >/dev/null) \
      || fail "checksum verification failed for $ASSET — aborting"
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$TMP" && grep " $ASSET\$" "$SUMS" | shasum -a 256 -c - >/dev/null) \
      || fail "checksum verification failed for $ASSET — aborting"
  else
    echo "install.sh: warning: no sha256sum/shasum available — skipping checksum verification" >&2
  fi
else
  echo "install.sh: warning: $SUMS not published for $RELEASE_DESC — skipping checksum verification" >&2
fi

tar -xzf "$TMP/$ASSET" -C "$TMP" || fail "failed to extract $ASSET"
[ -f "$TMP/tau" ] || fail "archive did not contain a 'tau' binary"

mkdir -p "$DEST" || fail "cannot create install dir $DEST — pass --dir or set TAU_INSTALL_DIR"
install -m 0755 "$TMP/tau" "$DEST/tau" 2>/dev/null \
  || { cp "$TMP/tau" "$DEST/tau" && chmod 0755 "$DEST/tau"; } \
  || fail "cannot write $DEST/tau — check permissions or choose another --dir"

echo "install.sh: installed tau -> $DEST/tau"

case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "install.sh: note: $DEST is not on your PATH — add it with:" >&2
     echo "    export PATH=\"$DEST:\$PATH\"" >&2 ;;
esac

"$DEST/tau" --version 2>/dev/null || true
