#!/bin/sh
# generate-scoop-manifest.sh — render the Scoop app manifest for a tau release.
#
#   scripts/generate-scoop-manifest.sh --version 0.5.0 --sums dist/SHA256SUMS.txt --output tau.json
#
# Reads the tau-windows-x86_64.zip digest out of the SHA256SUMS.txt manifest
# the release workflow publishes and emits the Scoop bucket manifest
# (bucket/tau.json) for the javimosch/scoop-bucket repository — so
# `scoop bucket add javimosch https://github.com/javimosch/scoop-bucket` +
# `scoop install tau` track releases without install.ps1.
#
# Options:
#   --version X.Y.Z   release version (a leading v is stripped)
#   --sums FILE       SHA256SUMS.txt manifest produced by the release job
#   --output FILE     write the manifest to FILE (default: stdout)
#   -h, --help        show this help

set -eu

REPO="javimosch/tau"
VERSION=""
SUMS=""
OUTPUT=""

usage() {
  cat <<'EOF'
generate-scoop-manifest.sh — render the Scoop app manifest for a tau release.

  scripts/generate-scoop-manifest.sh --version 0.5.0 --sums dist/SHA256SUMS.txt [--output tau.json]

Options:
  --version X.Y.Z   release version (a leading v is stripped)
  --sums FILE       SHA256SUMS.txt manifest produced by the release job
  --output FILE     write the manifest to FILE (default: stdout)
  -h, --help        show this help
EOF
}

fail() { echo "generate-scoop-manifest.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || fail "--version requires a value"; VERSION="$2"; shift 2 ;;
    --sums)    [ $# -ge 2 ] || fail "--sums requires a value";    SUMS="$2";    shift 2 ;;
    --output)  [ $# -ge 2 ] || fail "--output requires a value";  OUTPUT="$2";  shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$VERSION" ] || fail "--version is required"
[ -n "$SUMS" ]    || fail "--sums is required"
[ -f "$SUMS" ]    || fail "checksum manifest not found: $SUMS"

case "$VERSION" in v*) VERSION="${VERSION#v}" ;; esac
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$' \
  || fail "malformed --version: $VERSION (expected X.Y.Z)"

sha_for() {
  line=$(grep -E " (\./)?$1\$" "$SUMS" || true)
  [ -n "$line" ] || fail "$1 is not listed in $SUMS"
  echo "$line" | awk '{print $1}'
}

SHA_WIN_X64=$(sha_for tau-windows-x86_64.zip)
URL="https://github.com/$REPO/releases/download/v$VERSION/tau-windows-x86_64.zip"
AUTOUPDATE_URL="https://github.com/$REPO/releases/download/v\$version/tau-windows-x86_64.zip"

emit() {
  cat <<EOF
{
    "version": "$VERSION",
    "description": "Non-interactive, agent-first AI CLI with JSON-first output",
    "homepage": "https://github.com/$REPO",
    "license": "MIT",
    "architecture": {
        "64bit": {
            "url": "$URL",
            "hash": "sha256:$SHA_WIN_X64"
        }
    },
    "bin": "tau.exe",
    "checkver": {
        "github": "https://github.com/$REPO"
    },
    "autoupdate": {
        "architecture": {
            "64bit": {
                "url": "$AUTOUPDATE_URL"
            }
        }
    }
}
EOF
}

if [ -n "$OUTPUT" ]; then
  emit > "$OUTPUT" || fail "cannot write manifest to $OUTPUT"
  echo "generate-scoop-manifest.sh: wrote $OUTPUT (tau $VERSION)" >&2
else
  emit
fi
