# Air-gapped install & upgrade

Install or upgrade tau on machines with no outbound connectivity — while
keeping the full checksum + signature verification story from
[VERIFYING.md](VERIFYING.md) intact on both sides of the gap.

The installers never need github.com specifically — they fetch from a
directory tree shaped like the releases URL space. Stage that tree on a
connected host, carry it across on removable media, and point the
installer at it with `TAU_BASE_URL`. Checksums and cosign signatures
verify fully offline; the GitHub attestation API is the only layer that
cannot cross the gap.

Every command in this guide is drift-checked in CI:
`scripts/check-airgapped-doc.py` cross-checks the recipes below against
both installers and the release workflow, then replays the offline
install end-to-end on a staged mirror. The release pipeline runs it as a
publish gate, so these steps cannot silently go stale.

## What crosses the gap

| File | Purpose | Verifies offline? |
|------|---------|-------------------|
| `tau-<os>-<arch>.tar.gz` | the binary | — |
| `SHA256SUMS.txt` | integrity manifest | yes (`sha256sum -c`) |
| `<asset>.sigstore.json` | cosign signature bundle | yes (`cosign verify-blob`) |
| `SHA256SUMS.txt.sigstore.json` | signature on the manifest itself | yes |
| `<asset>.sbom.json` | contents audit (optional) | yes (hash-match) |
| `install.sh` / `install.ps1` | the installer | — |

## Step 1 — stage on a connected host

The mirror layout must match what the installer resolves:
`<base>/download/v<version>/<file>` for a pinned release, or
`<base>/latest/download/<file>` to track latest. Pinning is recommended —
the same recipe doubles as the upgrade path later. Pick a release that
ships the verification assets — releases cut before the signing pipeline
(≤ v0.4.0) have no `SHA256SUMS.txt` or `.sigstore.json` to mirror.

```bash
VER=0.5.0
mkdir -p mirror/download/v$VER
cd mirror/download/v$VER
curl -fsSLO https://github.com/javimosch/tau/releases/download/v$VER/tau-linux-x86_64.tar.gz
curl -fsSLO https://github.com/javimosch/tau/releases/download/v$VER/SHA256SUMS.txt
curl -fsSLO https://github.com/javimosch/tau/releases/download/v$VER/tau-linux-x86_64.tar.gz.sigstore.json
curl -fsSLO https://github.com/javimosch/tau/releases/download/v$VER/SHA256SUMS.txt.sigstore.json
```

### Verify provenance while still connected

`gh attestation verify` calls the GitHub API — it cannot run on the
air-gapped side. If your policy requires SLSA provenance, run it here,
before transfer:

```bash
gh attestation verify tau-linux-x86_64.tar.gz --repo javimosch/tau
```

## Step 2 — carry it across

Copy `mirror/`, plus `install.sh` (or `install.ps1`), to the removable
media. Checksums and signatures cover file contents, so a bit-exact copy
is all that matters — nothing executes during transport.

## Step 3 — verify on the air-gapped host

Everything in this step needs zero connectivity. Run it from the staged
release directory (`mirror/download/v<ver>/`).

Checksum — proves the archive arrived intact:

```bash
grep ' tau-linux-x86_64.tar.gz$' SHA256SUMS.txt | sha256sum -c -
```

Signature — proves the exact bytes were produced by tau's release
workflow. The bundle embeds the Fulcio certificate and the Rekor
transparency-log entry, so `cosign verify-blob` needs no network:

```bash
cosign verify-blob \
  --bundle tau-linux-x86_64.tar.gz.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/javimosch/tau/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  tau-linux-x86_64.tar.gz
```

Strongest offline chain — verify the manifest's own signature first, then
every archive checked against `SHA256SUMS.txt` is anchored to a
workflow-signed file:

```bash
cosign verify-blob \
  --bundle SHA256SUMS.txt.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/javimosch/tau/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  SHA256SUMS.txt
```

No cosign on the target? It is a single static binary — copy it across
the gap alongside the mirror.

## Step 4 — install offline

`TAU_BASE_URL` re-roots the installer at your mirror. `file://` URLs work
because install.sh fetches with curl and install.ps1 resolves `file:`
URIs via `System.Uri`:

```bash
TAU_BASE_URL="file:///media/usb/mirror" sh install.sh --version 0.5.0
```

With signature verification layered on (fails closed — no cosign, no
bundle, or a failed verify all abort the install):

```bash
TAU_BASE_URL="file:///media/usb/mirror" TAU_VERIFY_SIGSTORE=1 sh install.sh --version 0.5.0
```

Windows:

```powershell
$env:TAU_BASE_URL = 'file:///D:/mirror'
$env:TAU_VERIFY_SIGSTORE = '1'
.\install.ps1 -Version 0.5.0
```

The installer fails closed exactly as it does online: a missing
`SHA256SUMS.txt`, a missing manifest entry, a checksum mismatch, a
missing bundle, or a failed verify all abort the install.

`TAU_SKIP_CHECKSUM=1` is not a trust path — in an air-gapped environment
the staged mirror *is* your whole supply chain. Keep verification on.

## Step 5 — upgrade

An air-gapped upgrade is the same flow pinned to the new version: stage
`download/v<new>/` on the connected host, carry it across, re-run the
installer with `--version <new>` — it replaces the binary in place. Keep
the previous mirror tree if you want a rollback path.

Any built-in online upgrade path fetches release metadata from GitHub and
cannot run without connectivity — the staged-mirror install is its
offline equivalent.

## Failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `download failed` | mirror layout wrong — the installer resolves `<base>/download/v<ver>/<asset>` (or `latest/download/` without `--version`) | restage the exact layout from step 1 |
| `could not download SHA256SUMS.txt` | manifest missing from the same directory as the asset | restage it — do not bypass |
| `checksum verification failed` | media corruption or a swapped file on the mirror | re-copy from the source; if it persists, treat the mirror as poisoned |
| `could not download <asset>.sigstore.json` | bundle wasn't staged (only checked with `TAU_VERIFY_SIGSTORE=1`) | copy it across the gap |
| `sigstore signature verification failed` | the bytes were not signed by tau's release workflow | do not run the asset |

## See also

- [VERIFYING.md](VERIFYING.md) — the full trust-layer reference (checksum
  → signature → SLSA provenance → SBOM) and what each layer proves
- `install.sh --help` — every `TAU_*` override the installer honors
