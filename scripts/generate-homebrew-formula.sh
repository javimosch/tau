#!/bin/sh
# generate-homebrew-formula.sh — render the Homebrew formula for a tau release.
#
#   scripts/generate-homebrew-formula.sh --version 0.5.0 --sums dist/SHA256SUMS.txt
#   scripts/generate-homebrew-formula.sh --version 0.5.0 --sums dist/SHA256SUMS.txt --output tau.rb
#
# Reads the four release tarball digests (tau-<os>-<arch>.tar.gz) out of the
# SHA256SUMS.txt manifest the release workflow publishes and emits a Ruby
# formula for the javimosch/homebrew-tap repository (Formula/tau.rb). The
# release workflow calls this after publishing, then pushes the result to the
# tap — so `brew install javimosch/tap/tau` and `brew upgrade tau` track
# releases without install.sh.
#
# Options:
#   --version X.Y.Z   release version (a leading v is stripped)
#   --sums FILE       SHA256SUMS.txt manifest produced by the release job
#   --output FILE     write the formula to FILE (default: stdout)
#   -h, --help        show this help

set -eu

REPO="javimosch/tau"
VERSION=""
SUMS=""
OUTPUT=""

usage() {
  cat <<'EOF'
generate-homebrew-formula.sh — render the Homebrew formula for a tau release.

  scripts/generate-homebrew-formula.sh --version 0.5.0 --sums dist/SHA256SUMS.txt [--output tau.rb]

Options:
  --version X.Y.Z   release version (a leading v is stripped)
  --sums FILE       SHA256SUMS.txt manifest produced by the release job
  --output FILE     write the formula to FILE (default: stdout)
  -h, --help        show this help
EOF
}

fail() { echo "generate-homebrew-formula.sh: $*" >&2; exit 1; }

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

# sha_for <asset> — print the digest for an asset in the manifest. Tolerates
# the optional ./ prefix sha256sum emits; fails closed on a missing entry so a
# formula can never ship a blank checksum.
sha_for() {
  line=$(grep -E " (\./)?$1\$" "$SUMS" || true)
  [ -n "$line" ] || fail "$1 is not listed in $SUMS"
  echo "$line" | awk '{print $1}'
}

SHA_MACOS_ARM=$(sha_for tau-macos-aarch64.tar.gz)
SHA_MACOS_INTEL=$(sha_for tau-macos-x86_64.tar.gz)
SHA_LINUX_INTEL=$(sha_for tau-linux-x86_64.tar.gz)
SHA_LINUX_ARM=$(sha_for tau-linux-aarch64.tar.gz)

emit() {
  cat <<EOF
class Tau < Formula
  desc "Non-interactive, agent-first AI CLI with JSON-first output"
  homepage "https://github.com/$REPO"
  version "$VERSION"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/$REPO/releases/download/v$VERSION/tau-macos-aarch64.tar.gz"
      sha256 "$SHA_MACOS_ARM"
    end
    on_intel do
      url "https://github.com/$REPO/releases/download/v$VERSION/tau-macos-x86_64.tar.gz"
      sha256 "$SHA_MACOS_INTEL"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/$REPO/releases/download/v$VERSION/tau-linux-x86_64.tar.gz"
      sha256 "$SHA_LINUX_INTEL"
    end
    on_arm do
      url "https://github.com/$REPO/releases/download/v$VERSION/tau-linux-aarch64.tar.gz"
      sha256 "$SHA_LINUX_ARM"
    end
  end

  def install
    bin.install "tau"
  end

  test do
    assert_match "tau #{version}", shell_output("#{bin}/tau --version")
  end
end
EOF
}

if [ -n "$OUTPUT" ]; then
  emit > "$OUTPUT" || fail "cannot write formula to $OUTPUT"
  echo "generate-homebrew-formula.sh: wrote $OUTPUT (tau $VERSION)" >&2
else
  emit
fi
