# Verifying tau releases

Every `v*` GitHub release of tau ships a layered trust story. Pick the level
you need — each layer is independent and strictly stronger than the last.

| Layer | Asset(s) | Proves | Needs |
|-------|----------|--------|-------|
| Checksum | `SHA256SUMS.txt` | The download is intact — not corrupted, not swapped for another file on the release page | `sha256sum`/`shasum` (automatic in `install.sh`/`install.ps1`) |
| Signature | `<asset>.sigstore.json` | The asset was built and signed by `.github/workflows/release.yml` on a `v*` tag of `javimosch/tau` | `cosign` |
| Provenance | repo attestation store | SLSA build provenance: which repo, workflow, ref, and runner produced the asset | `gh` CLI |

All signing is **keyless**: the release job mints a short-lived Fulcio
certificate from its GitHub OIDC identity and records every signature in the
Rekor transparency log. There is no private key to lose, leak, or rotate.

## What a release publishes

For each `v*` tag, `.github/workflows/release.yml` attaches:

- `tau-linux-x86_64.tar.gz`, `tau-linux-aarch64.tar.gz`,
  `tau-macos-x86_64.tar.gz`, `tau-macos-aarch64.tar.gz`,
  `tau-windows-x86_64.zip` — the binaries (each bundles `share/man/…`)
- `SHA256SUMS.txt` — sha256 manifest covering every archive
- `<asset>.sigstore.json` — a cosign **bundle** (signature + Fulcio
  certificate + Rekor log entry) per asset, *including* `SHA256SUMS.txt`
  itself
- SLSA v1 build-provenance attestations for every asset listed in
  `SHA256SUMS.txt`, stored in the repo's attestation store (visible under
  the repo's **Attestations** tab)

The workflow self-verifies every bundle with `cosign verify-blob` before the
release is created, so an unverifiable signature can never reach the release
page.

## Level 1 — checksum (automatic)

`install.sh` and `install.ps1` already do this and **fail closed**: the
install aborts if `SHA256SUMS.txt` is unreachable, the asset is not listed,
or the digest mismatches. To check a manual download yourself:

```bash
curl -fsSLO https://github.com/javimosch/tau/releases/latest/download/tau-linux-x86_64.tar.gz
curl -fsSLO https://github.com/javimosch/tau/releases/latest/download/SHA256SUMS.txt
grep ' tau-linux-x86_64.tar.gz$' SHA256SUMS.txt | sha256sum -c -
```

## Level 2 — signature (cosign)

A signature proves the exact bytes were produced by the release workflow —
not just that the file is intact. Install cosign first:

```bash
brew install cosign                                  # macOS/Linux
winget install Sigstore.Cosign                       # Windows
scoop install cosign                                 # Windows
# or: https://docs.sigstore.dev/cosign/system_config/installation/
```

### One-liner via the installers

`install.sh` / `install.ps1` can run the signature check for you after the
normal checksum verification — it fails closed if cosign is missing, the
bundle is missing, or verification fails:

```bash
TAU_VERIFY_SIGSTORE=1 sh -c "$(curl -fsSL https://raw.githubusercontent.com/javimosch/tau/master/install.sh)"
```

```powershell
$env:TAU_VERIFY_SIGSTORE = '1'
irm https://raw.githubusercontent.com/javimosch/tau/master/install.ps1 | iex
```

### Manual verification

Download the asset and its bundle, then:

```bash
cosign verify-blob \
  --bundle tau-linux-x86_64.tar.gz.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/javimosch/tau/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  tau-linux-x86_64.tar.gz
```

`Verified OK` means:

- the signature is valid for those exact bytes, and
- the signing certificate was issued by Fulcio to the GitHub OIDC identity
  `…/.github/workflows/release.yml@refs/tags/v<version>` of
  `javimosch/tau`, issued by `https://token.actions.githubusercontent.com`, and
- the signature was witnessed in the Rekor public transparency log.

The identity regexp is what stops an attacker from signing a fake release
from *their* repo — do not widen or omit it. `SHA256SUMS.txt` is signed too;
verifying it first (`SHA256SUMS.txt.sigstore.json`) and then checking the
archives against the manifest is a valid alternative flow.

## Level 3 — build provenance (SLSA attestation)

Each archive additionally carries a signed [SLSA](https://slsa.dev) v1
provenance attestation in the repo's GitHub attestation store. Verify it
with the `gh` CLI (works against downloaded files — no bundle needed):

```bash
gh attestation verify tau-linux-x86_64.tar.gz --repo javimosch/tau
```

A passing check prints the attestation's source repository and ref. The
attestation names its subjects by the exact filenames in `SHA256SUMS.txt`,
so `gh` matches the file you downloaded automatically.

## Failure modes, mapped

| Symptom | Means |
|---------|-------|
| `checksum verification failed` | Download corrupted or tampered; or a mirror serving stale files. Do not bypass with `TAU_SKIP_CHECKSUM=1` unless you have another trust path. |
| `could not download <asset>.sigstore.json` | That release predates signing, or the bundle was stripped. Treat the asset as unauthenticated. |
| `signature verification failed` / `cosign verify-blob` errors | The asset was **not** produced by tau's release workflow — do not run it. |
| `gh attestation verify` finds no attestation | Same conclusion as a missing bundle: the asset is not covered by release provenance. |
