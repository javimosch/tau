#!/bin/sh
# generate-winget-manifest.sh — render the winget package manifest for a tau release.
#
#   scripts/generate-winget-manifest.sh --version 0.5.0 --sums dist/SHA256SUMS.txt --output-dir dist/winget
#
# Reads the tau-windows-x86_64.zip digest out of the SHA256SUMS.txt manifest
# the release workflow publishes and emits the three-file winget manifest
# (version / installer / default-locale) that microsoft/winget-pkgs expects
# under manifests/j/javimosch/tau/<version>/.
#
# winget publishes to the community microsoft/winget-pkgs repo via a fork + PR
# (driven by `wingetcreate`), not an owned tap repo like Homebrew — the release
# workflow validates + uploads this manifest as an artifact for manual
# submission, and submits automatically when WINGET_PKGS_TOKEN is configured.
#
# Options:
#   --version X.Y.Z     release version (a leading v is stripped)
#   --sums FILE         SHA256SUMS.txt manifest produced by the release job
#   --output-dir DIR    write the manifest files into DIR (required)
#   -h, --help          show this help

set -eu

REPO="javimosch/tau"
PKG_ID="javimosch.tau"
VERSION=""
SUMS=""
OUTDIR=""

usage() {
  cat <<'EOF'
generate-winget-manifest.sh — render the winget package manifest for a tau release.

  scripts/generate-winget-manifest.sh --version 0.5.0 --sums dist/SHA256SUMS.txt --output-dir dist/winget

Options:
  --version X.Y.Z     release version (a leading v is stripped)
  --sums FILE         SHA256SUMS.txt manifest produced by the release job
  --output-dir DIR    write the manifest files into DIR (required)
  -h, --help          show this help
EOF
}

fail() { echo "generate-winget-manifest.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)     [ $# -ge 2 ] || fail "--version requires a value";     VERSION="$2"; shift 2 ;;
    --sums)        [ $# -ge 2 ] || fail "--sums requires a value";        SUMS="$2";    shift 2 ;;
    --output-dir)  [ $# -ge 2 ] || fail "--output-dir requires a value";  OUTDIR="$2";  shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$VERSION" ] || fail "--version is required"
[ -n "$SUMS" ]    || fail "--sums is required"
[ -n "$OUTDIR" ]  || fail "--output-dir is required"
[ -f "$SUMS" ]    || fail "checksum manifest not found: $SUMS"

case "$VERSION" in v*) VERSION="${VERSION#v}" ;; esac
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$' \
  || fail "malformed --version: $VERSION (expected X.Y.Z)"

# sha_for <asset> — same contract as generate-homebrew-formula.sh: tolerates
# the optional ./ prefix sha256sum emits, fails closed on a missing entry.
sha_for() {
  line=$(grep -E " (\./)?$1\$" "$SUMS" || true)
  [ -n "$line" ] || fail "$1 is not listed in $SUMS"
  echo "$line" | awk '{print $1}'
}

SHA_WIN_X64=$(sha_for tau-windows-x86_64.zip)
URL="https://github.com/$REPO/releases/download/v$VERSION/tau-windows-x86_64.zip"

mkdir -p "$OUTDIR" || fail "cannot create output dir $OUTDIR"

cat > "$OUTDIR/$PKG_ID.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.version.1.9.0.schema.json
PackageIdentifier: $PKG_ID
PackageVersion: $VERSION
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.9.0
EOF

cat > "$OUTDIR/$PKG_ID.installer.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.installer.1.9.0.schema.json
PackageIdentifier: $PKG_ID
PackageVersion: $VERSION
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
- RelativeFilePath: tau.exe
  PortableCommandAlias: tau
Installers:
- Architecture: x64
  InstallerUrl: $URL
  InstallerSha256: $SHA_WIN_X64
ManifestType: installer
ManifestVersion: 1.9.0
EOF

cat > "$OUTDIR/$PKG_ID.locale.en-US.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.defaultLocale.1.9.0.schema.json
PackageIdentifier: $PKG_ID
PackageVersion: $VERSION
PackageLocale: en-US
Publisher: javimosch
PackageName: tau
License: MIT
ShortDescription: Non-interactive, agent-first AI CLI with JSON-first output
ManifestType: defaultLocale
ManifestVersion: 1.9.0
EOF

echo "generate-winget-manifest.sh: wrote 3 manifest files to $OUTDIR (tau $VERSION)" >&2
