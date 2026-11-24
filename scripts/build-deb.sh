#!/bin/sh
# build-deb.sh — build a .deb package for tau.
#
#   scripts/build-deb.sh --binary zig-out/bin/tau --version 0.5.0 --arch amd64 \
#       --output dist/tau_0.5.0_amd64.deb
#
# Emits a Debian binary package installable via `apt install ./tau_…_.deb` or
# `dpkg -i`. A .deb is just an ar archive holding debian-binary +
# control.tar.gz + data.tar.gz, so this builds it with shell + ar + tar +
# gzip — no dpkg-dev dependency. Requires GNU tar for the deterministic
# --sort/--mtime flags (the release workflow builds on Linux). The payload
# is /usr/bin/tau only, matching install.sh.
#
# Options:
#   --binary PATH     the built tau executable (required)
#   --version X.Y.Z   package version; a leading v is stripped (required)
#   --arch ARCH       Debian arch: amd64 or arm64 (required)
#   --output FILE     write the .deb to FILE (required)
#   -h, --help        show this help

set -eu

BINARY=""
VERSION=""
ARCH=""
OUTPUT=""

usage() {
  cat <<'EOF'
build-deb.sh — build a .deb package for tau.

  scripts/build-deb.sh --binary zig-out/bin/tau --version 0.5.0 --arch amd64 --output dist/tau_0.5.0_amd64.deb

Options:
  --binary PATH     the built tau executable (required)
  --version X.Y.Z   package version; a leading v is stripped (required)
  --arch ARCH       Debian arch: amd64 or arm64 (required)
  --output FILE     write the .deb to FILE (required)
  -h, --help        show this help
EOF
}

fail() { echo "build-deb.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --binary)  [ $# -ge 2 ] || fail "--binary requires a value";  BINARY="$2";  shift 2 ;;
    --version) [ $# -ge 2 ] || fail "--version requires a value"; VERSION="$2"; shift 2 ;;
    --arch)    [ $# -ge 2 ] || fail "--arch requires a value";    ARCH="$2";    shift 2 ;;
    --output)  [ $# -ge 2 ] || fail "--output requires a value";  OUTPUT="$2";  shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$BINARY" ]  || fail "--binary is required"
[ -n "$VERSION" ] || fail "--version is required"
[ -n "$ARCH" ]    || fail "--arch is required"
[ -n "$OUTPUT" ]  || fail "--output is required"
[ -f "$BINARY" ]  || fail "binary not found: $BINARY"
command -v ar >/dev/null 2>&1 || fail "ar not found (install binutils)"

case "$VERSION" in v*) VERSION="${VERSION#v}" ;; esac
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$' \
  || fail "malformed --version: $VERSION (expected X.Y.Z)"

case "$ARCH" in
  amd64|arm64) ;;
  *) fail "unsupported --arch: $ARCH (expected amd64 or arm64)" ;;
esac

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# data.tar.gz — the installed payload, /usr/bin/tau owned by root.
mkdir -p "$STAGE/root/usr/bin"
cp "$BINARY" "$STAGE/root/usr/bin/tau"
chmod 755 "$STAGE/root" "$STAGE/root/usr" "$STAGE/root/usr/bin" "$STAGE/root/usr/bin/tau"

# Deterministic archives: fixed mtime, numeric root ownership, sorted names.
tar -czf "$STAGE/data.tar.gz" -C "$STAGE/root" \
  --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner .

# control.tar.gz — package metadata + payload checksums.
SIZE_KB="$(du -sk "$STAGE/root/usr/bin/tau" | cut -f1)"
mkdir -p "$STAGE/control"
cat > "$STAGE/control/control" <<EOF
Package: tau
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Installed-Size: $SIZE_KB
Maintainer: javimosch <noreply@github.com>
Homepage: https://github.com/javimosch/tau
Description: agent-first AI CLI
 tau is a non-interactive, JSON-first command-line AI client designed
 for agent use: deterministic output, stable exit codes, and a
 documented tool-calling loop.
EOF
if command -v md5sum >/dev/null 2>&1; then
  ( cd "$STAGE/root" && md5sum usr/bin/tau ) > "$STAGE/control/md5sums"
else
  # macOS md5 prints just the digest.
  ( cd "$STAGE/root" && printf '%s  usr/bin/tau\n' "$(md5 -q usr/bin/tau)" ) > "$STAGE/control/md5sums"
fi

tar -czf "$STAGE/control.tar.gz" -C "$STAGE/control" \
  --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner .

# .deb = ar archive: debian-binary, control.tar.gz, data.tar.gz. Member
# names must be bare, so archive inside the staging dir then move out.
printf '2.0\n' > "$STAGE/debian-binary"
mkdir -p "$(dirname "$OUTPUT")"
( cd "$STAGE" && ar rc .pkg.deb debian-binary control.tar.gz data.tar.gz )
mv "$STAGE/.pkg.deb" "$OUTPUT"

echo "built $OUTPUT"
