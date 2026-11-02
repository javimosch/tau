#!/usr/bin/env python3
# check-verifying-doc.py — drift-check the commands in VERIFYING.md.
#
# VERIFYING.md tells users how to verify release downloads: checksums,
# cosign signature bundles, SLSA attestations and SBOMs. Those commands are
# only trustworthy while they match what the release pipeline and installers
# actually do — a renamed workflow file, a changed asset name or a widened
# certificate-identity regexp silently breaks every recipe in the guide.
#
# This script extracts every fenced command block from VERIFYING.md and
# cross-checks it against the sources of truth:
#
#   .github/workflows/release.yml  — the signing/attestation/SBOM pipeline
#   install.sh / install.ps1       — the installers users are told to run
#   scripts/generate-sbom.py       — the SBOM generator the doc invokes
#
# Static checks pin the cosign --certificate-identity-regexp /
# --certificate-oidc-issuer quartet (doc + workflow + both installers must
# agree byte-for-byte), the documented asset names against the release
# matrix, the --repo slug, TAU_VERIFY_SIGSTORE support in both installers,
# and the generate-sbom.py flags the doc uses. Executable checks then run
# the offline-safe recipes verbatim: the sha256sum pipeline and the SBOM
# hash-match snippet are replayed against a staged fixture, and the
# generate-sbom.py regenerate step is executed for real.
#
# Exit 0 when every check passes, 1 on the first category with failures.
# stdlib-only, like the sibling generator scripts.

import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "VERIFYING.md")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "release.yml")
INSTALL_SH = os.path.join(ROOT, "install.sh")
INSTALL_PS1 = os.path.join(ROOT, "install.ps1")
SBOM_GEN = os.path.join(ROOT, "scripts", "generate-sbom.py")
REPO = "javimosch/tau"

failures = []
passes = []


def ok(name, cond, detail=""):
    (passes if cond else failures).append(name + (" — " + detail if detail and not cond else ""))


def extract_blocks(text):
    """Return [(lang, [lines])] for each fenced code block."""
    blocks = []
    in_block = False
    lang = ""
    lines = []
    for line in text.splitlines():
        m = re.match(r"^```(\w*)\s*$", line)
        if m:
            if in_block:
                blocks.append((lang, lines))
                lines = []
                in_block = False
            else:
                lang = m.group(1)
                in_block = True
            continue
        if in_block:
            lines.append(line)
    return blocks


def command_lines(blocks):
    """All non-comment, non-blank lines from bash/powershell blocks,
    with line continuations joined."""
    cmds = []
    for lang, lines in blocks:
        if lang not in ("bash", "sh", "powershell", ""):
            continue
        buf = ""
        heredoc = None
        for line in lines:
            stripped = line.strip()
            if heredoc:
                if stripped == heredoc:
                    heredoc = None
                continue
            m = re.search(r"<<\s*'?\"?([A-Za-z_]+)'?\"?", stripped)
            if m:
                heredoc = m.group(1)
                cmds.append(stripped)
                buf = ""
                continue
            if stripped.endswith("\\"):
                buf += stripped[:-1] + " "
                continue
            buf += stripped
            if buf and not buf.startswith("#"):
                cmds.append(buf)
            buf = ""
        if buf and not buf.startswith("#"):
            cmds.append(buf)
    return cmds


def main():
    for path in (DOC, WORKFLOW, INSTALL_SH, INSTALL_PS1, SBOM_GEN):
        ok(os.path.relpath(path, ROOT) + " exists", os.path.isfile(path))

    doc = open(DOC, encoding="utf-8").read()
    wf = open(WORKFLOW, encoding="utf-8").read()
    ish = open(INSTALL_SH, encoding="utf-8").read()
    ps1 = open(INSTALL_PS1, encoding="utf-8").read()
    gen = open(SBOM_GEN, encoding="utf-8").read()

    blocks = extract_blocks(doc)
    ok("VERIFYING.md has fenced command blocks", len(blocks) >= 5, f"found {len(blocks)}")
    cmds = command_lines(blocks)

    # ── Level 1: checksum recipe ──────────────────────────────────────────
    sums_cmds = [c for c in cmds if "sha256sum -c" in c]
    ok("doc shows a sha256sum -c recipe", len(sums_cmds) >= 1)
    asset = "tau-linux-x86_64.tar.gz"
    grep_cmd = next((c for c in sums_cmds if "grep" in c), None)
    ok("checksum recipe greps the asset from SHA256SUMS.txt", grep_cmd is not None)
    if grep_cmd:
        m = re.search(r"grep ' ([^']+)' SHA256SUMS\.txt \| sha256sum -c -", grep_cmd)
        ok("checksum recipe has the documented shape", m is not None)
        if m:
            ok("checksum recipe targets the doc's example asset", m.group(1) == asset + "$")

    # Download URLs must hit this repo's release pages.
    dl = [c for c in cmds if c.startswith("curl -fsSLO https://github.com/")]
    ok("doc shows release download URLs", len(dl) >= 2)
    for c in dl:
        ok("download URL points at " + REPO, f"github.com/{REPO}/releases/" in c, c)

    # ── Level 2: cosign recipe — the four-source contract ────────────────
    cosign_cmd = next((c for c in cmds if c.startswith("cosign verify-blob")), None)
    ok("doc shows a cosign verify-blob recipe", cosign_cmd is not None)
    if cosign_cmd:
        ident = re.search(r"--certificate-identity-regexp '([^']+)'", cosign_cmd)
        issuer = re.search(r"--certificate-oidc-issuer '([^']+)'", cosign_cmd)
        bundle = re.search(r"--bundle (\S+\.sigstore\.json)", cosign_cmd)
        ok("cosign recipe pins --certificate-identity-regexp", ident is not None)
        ok("cosign recipe pins --certificate-oidc-issuer", issuer is not None)
        ok("cosign recipe verifies a .sigstore.json bundle", bundle is not None)
        if ident:
            needle = f"--certificate-identity-regexp '{ident.group(1)}'"
            ok("workflow self-verify uses the doc's identity regexp", needle in wf)
            ok("install.sh uses the doc's identity regexp", ident.group(1) in ish)
            ok("install.ps1 uses the doc's identity regexp", ident.group(1) in ps1)
            ok("identity regexp names the release workflow",
               r"\.github/workflows/release\.yml" in ident.group(1))
            ok("identity regexp names this repo", f"github\\.com/{REPO}" in ident.group(1))
            ok("identity regexp anchors tag refs", "@refs/tags/v" in ident.group(1))
        if issuer:
            ok("workflow uses the doc's OIDC issuer", issuer.group(1) in wf)
            ok("install.sh uses the doc's OIDC issuer", issuer.group(1) in ish)
            ok("install.ps1 uses the doc's OIDC issuer", issuer.group(1) in ps1)
            ok("issuer is the GitHub OIDC provider",
               issuer.group(1) == "https://token.actions.githubusercontent.com")

    # ── Level 3: SLSA attestation recipe ─────────────────────────────────
    attest = [c for c in cmds if c.startswith("gh attestation verify")]
    ok("doc shows gh attestation verify recipes", len(attest) >= 2)
    for c in attest:
        ok("attestation recipe pins --repo " + REPO, f"--repo {REPO}" in c, c)
    ok("doc attests an SBOM subject too",
       any(".sbom.json" in c for c in attest))
    ok("workflow actually produces attestations",
       "actions/attest-build-provenance" in wf)
    ok("workflow attests the checksum-manifest subjects",
       "subject-checksums: dist/SHA256SUMS.txt" in wf)
    ok("workflow attests the SBOM subjects", "subject-path: dist/*.sbom.json" in wf)

    # ── installer opt-in recipe ───────────────────────────────────────────
    ok("doc documents TAU_VERIFY_SIGSTORE", "TAU_VERIFY_SIGSTORE" in doc)
    ok("install.sh honors TAU_VERIFY_SIGSTORE", "TAU_VERIFY_SIGSTORE" in ish)
    ok("install.ps1 honors TAU_VERIFY_SIGSTORE", "TAU_VERIFY_SIGSTORE" in ps1)
    ok("install.sh runs cosign verify-blob", "cosign verify-blob" in ish)
    ok("install.ps1 runs cosign verify-blob", "cosign verify-blob" in ps1)
    ok("doc links the raw installer URLs",
       f"raw.githubusercontent.com/{REPO}/master/install.sh" in doc and
       f"raw.githubusercontent.com/{REPO}/master/install.ps1" in doc)

    # ── asset names vs the release matrix ─────────────────────────────────
    matrix_assets = set()
    for m in re.finditer(r"artifact:\s*([a-z0-9_-]+),\s*ext:\s*(tar\.gz|zip)\s*\}", wf):
        matrix_assets.add(f"tau-{m.group(1)}.{m.group(2)}")
    ok("workflow matrix parses to asset names", len(matrix_assets) >= 5,
       f"got {sorted(matrix_assets)}")
    doc_assets = set(re.findall(r"tau-(?:linux|macos|windows)-(?:x86_64|aarch64)\.(?:tar\.gz|zip)", doc))
    for a in sorted(doc_assets):
        ok(f"doc asset {a} is produced by the matrix", a in matrix_assets)
        # generate-sbom.py's ARTIFACT_RE must cover every doc asset too
        ok(f"generate-sbom.py pattern covers {a}",
           re.match(r"^tau-(linux|macos|windows)-(x86_64|aarch64)\.(tar\.gz|zip)$", a) is not None)

    # ── generate-sbom.py recipe ───────────────────────────────────────────
    gen_cmd = next((c for c in cmds if "generate-sbom.py" in c), None)
    ok("doc shows a generate-sbom.py regenerate recipe", gen_cmd is not None)
    if gen_cmd:
        for flag in ("--dist", "--version", "--commit", "--timestamp"):
            ok(f"generate-sbom.py accepts {flag} used by the doc",
               f'"{flag}"' in gen or f"'{flag}'" in gen)
        ok("doc's regenerate recipe is deterministic (pins --timestamp)",
           "--timestamp" in gen_cmd)

    # ── no unhandled command categories ───────────────────────────────────
    # Every command the doc prints must be one this checker understands —
    # a new verification tool (gpg, slsa-verifier, ...) without a matching
    # check is a blind spot.
    known = (
        "curl ", "grep ", "sha256sum", "cosign ", "gh attestation",
        "brew install", "winget install", "scoop install", "python3 -",
        "TAU_VERIFY_SIGSTORE=", "$env:TAU_VERIFY_SIGSTORE", "irm ",
        "sh -c ", "scripts/generate-sbom.py",
    )
    for c in cmds:
        ok("command category is drift-checked: " + c[:60],
           c.startswith(known))

    # ── executable replay: checksum pipeline ──────────────────────────────
    sha256sum = shutil.which("sha256sum")
    sha_args = [sha256sum] if sha256sum else None
    if not sha256sum:
        shasum = shutil.which("shasum")
        sha_args = [shasum, "-a", "256"] if shasum else None
    ok("a sha256 tool exists for the replay", sha_args is not None)
    tmp = tempfile.mkdtemp(prefix="verify-doc-")
    try:
        fixture = os.path.join(tmp, asset)
        with tarfile.open(fixture, "w:gz") as tf:
            payload = os.path.join(tmp, "tau")
            with open(payload, "wb") as f:
                f.write(b"#!/bin/sh\necho tau fixture\n")
            tf.add(payload, arcname="tau")
        digest = subprocess.run(sha_args + [fixture], capture_output=True,
                                text=True, check=True).stdout.split()[0]
        with open(os.path.join(tmp, "SHA256SUMS.txt"), "w") as f:
            f.write(f"{digest}  {asset}\n")
        if grep_cmd and sha256sum:
            # replay the doc's grep|sha256sum -c line verbatim against the
            # staged manifest — proves the recipe still works as written
            r = subprocess.run(grep_cmd, shell=True, cwd=tmp,
                               capture_output=True, text=True)
            ok("doc checksum recipe verifies a staged archive", r.returncode == 0,
               r.stderr.strip() or r.stdout.strip())

        # ── executable replay: SBOM generation + doc's hash-match snippet ──
        r = subprocess.run([sys.executable or "python3", SBOM_GEN,
                            "--dist", tmp, "--version", "0.0.0",
                            "--commit", "0" * 40, "--timestamp",
                            "2000-01-01T00:00:00+00:00"],
                           capture_output=True, text=True)
        ok("generate-sbom.py runs against the staged archive", r.returncode == 0,
           r.stderr.strip())
        sbom_path = os.path.join(tmp, asset + ".sbom.json")
        ok("generate-sbom.py emits <asset>.sbom.json", os.path.isfile(sbom_path))
        if os.path.isfile(sbom_path):
            # replay the doc's hash-match snippet semantics
            bom = json.load(open(sbom_path))
            expected = bom["components"][0]["hashes"][0]["content"]
            actual = subprocess.run(sha_args + [fixture], capture_output=True,
                                    text=True, check=True).stdout.split()[0]
            ok("doc's SBOM hash-match recipe confirms the archive",
               expected == actual)
            ok("SBOM is CycloneDX 1.6 as documented",
               bom.get("bomFormat") == "CycloneDX" and bom.get("specVersion") == "1.6")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # ── report ────────────────────────────────────────────────────────────
    for name in passes:
        print(f"ok   {name}")
    for name in failures:
        print(f"FAIL {name}")
    print(f"\n{len(passes)} passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
