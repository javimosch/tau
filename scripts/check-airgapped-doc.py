#!/usr/bin/env python3
# check-airgapped-doc.py — drift-check the commands in AIRGAPPED.md.
#
# AIRGAPPED.md tells users how to install and upgrade tau on hosts with no
# outbound connectivity: stage a mirror tree shaped like the releases URL
# space, verify checksum + cosign signature offline, then point the
# installer at the mirror with TAU_BASE_URL. Those recipes are only
# trustworthy while they match what the installers and the release
# pipeline actually do — a renamed env var, a changed URL layout, or a
# widened certificate-identity regexp silently breaks the guide.
#
# This script extracts every fenced command block from AIRGAPPED.md and
# cross-checks it against the sources of truth:
#
#   .github/workflows/release.yml  — the asset matrix + signing identity
#   install.sh / install.ps1       — the installers and their env contract
#   VERIFYING.md                   — the trust-layer doc this guide extends
#
# Static checks pin the mirror layout against the installers' URL
# construction, every TAU_* env var the doc names against the installers,
# the cosign --certificate-identity-regexp / --certificate-oidc-issuer
# quartet (doc + workflow + both installers must agree byte-for-byte), the
# documented asset names against the release matrix, and the gh
# attestation recipe's --repo. Executable checks then replay the
# offline-safe recipes verbatim on a staged file:// mirror: the checksum
# pipeline, the real install.sh end-to-end (asserting it installs and
# reports the checksum verified), and the fail-closed paths the doc
# promises (missing manifest aborts; TAU_VERIFY_SIGSTORE=1 without a
# staged bundle aborts).
#
# Exit 0 when every check passes, 1 on the first category with failures.
# stdlib-only, like the sibling generator scripts.

import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "AIRGAPPED.md")
VERIFYING = os.path.join(ROOT, "VERIFYING.md")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "release.yml")
INSTALL_SH = os.path.join(ROOT, "install.sh")
INSTALL_PS1 = os.path.join(ROOT, "install.ps1")
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
    for path in (DOC, VERIFYING, WORKFLOW, INSTALL_SH, INSTALL_PS1):
        ok(os.path.relpath(path, ROOT) + " exists", os.path.isfile(path))
    if failures:
        for name in passes:
            print(f"ok   {name}")
        for name in failures:
            print(f"FAIL {name}")
        print(f"\n{len(passes)} passed, {len(failures)} failed")
        return 1

    doc = open(DOC, encoding="utf-8").read()
    ver_doc = open(VERIFYING, encoding="utf-8").read()
    wf = open(WORKFLOW, encoding="utf-8").read()
    ish = open(INSTALL_SH, encoding="utf-8").read()
    ps1 = open(INSTALL_PS1, encoding="utf-8").read()

    blocks = extract_blocks(doc)
    ok("AIRGAPPED.md has fenced command blocks", len(blocks) >= 4, f"found {len(blocks)}")
    cmds = command_lines(blocks)

    # ── mirror layout vs the installers' URL construction ────────────────
    # The staged tree only works because install.sh resolves
    #   $BASE/download/v$VERSION/$ASSET   (pinned)
    #   $BASE/latest/download/$ASSET      (latest)
    # and install.ps1 resolves the same two paths. Pin both sides.
    ok("install.sh resolves download/v<version>", "$BASE/download/v$VERSION/" in ish)
    ok("install.sh resolves latest/download", "$BASE/latest/download/" in ish)
    ok("install.ps1 resolves download/v<version>", "$Base/download/v$Version/" in ps1)
    ok("install.ps1 resolves latest/download", "$Base/latest/download/" in ps1)
    ok("doc stages a download/v<ver> mirror dir",
       re.search(r"mkdir -p\s+mirror/download/v\$?VER|mirror/download/v<", doc) is not None)
    ok("doc explains the latest/download alternative", "latest/download" in doc)

    # ── env-var contract: every TAU_* the doc names must exist ──────────
    doc_env = sorted(set(re.findall(r"\bTAU_[A-Z_]+\b", doc)))
    ok("doc names installer env overrides", len(doc_env) >= 3, f"got {doc_env}")
    for var in doc_env:
        ok(f"install.sh honors {var}", var in ish)
    for var in sorted(set(re.findall(r"\$env:(TAU_[A-Z_]+)\b", doc))):
        ok(f"install.ps1 honors {var}", var in ps1)

    # ── install recipe shape: TAU_BASE_URL=<file://...> + --version ─────
    install_cmds = [c for c in cmds if "install.sh" in c]
    ok("doc shows an offline install.sh recipe", len(install_cmds) >= 2,
       f"got {install_cmds}")
    for c in install_cmds:
        ok("install recipe re-roots via file:// TAU_BASE_URL",
           'TAU_BASE_URL="file://' in c, c)
        ok("install recipe pins --version", "--version" in c, c)
    ps_install = [c for c in cmds if "install.ps1" in c]
    ok("doc shows an offline install.ps1 recipe", len(ps_install) >= 1)
    for c in ps_install:
        ok("install.ps1 recipe pins -Version", "-Version" in c, c)

    # ── cosign recipe — the four-source contract ────────────────────────
    cosign_cmds = [c for c in cmds if c.startswith("cosign verify-blob")]
    ok("doc shows cosign verify-blob recipes", len(cosign_cmds) >= 2,
       f"got {len(cosign_cmds)}")
    ok("doc verifies the manifest's own signature too",
       any("SHA256SUMS.txt.sigstore.json" in c for c in cosign_cmds))
    for cosign_cmd in cosign_cmds:
        ident = re.search(r"--certificate-identity-regexp '([^']+)'", cosign_cmd)
        issuer = re.search(r"--certificate-oidc-issuer '([^']+)'", cosign_cmd)
        bundle = re.search(r"--bundle (\S+\.sigstore\.json)", cosign_cmd)
        ok("cosign recipe pins --certificate-identity-regexp", ident is not None, cosign_cmd[:60])
        ok("cosign recipe pins --certificate-oidc-issuer", issuer is not None, cosign_cmd[:60])
        ok("cosign recipe verifies a .sigstore.json bundle", bundle is not None, cosign_cmd[:60])
        if ident:
            ok("install.sh uses the doc's identity regexp", ident.group(1) in ish)
            ok("install.ps1 uses the doc's identity regexp", ident.group(1) in ps1)
            ok("workflow self-verify uses the doc's identity regexp",
               f"--certificate-identity-regexp '{ident.group(1)}'" in wf)
            ok("identity regexp names the release workflow",
               r"\.github/workflows/release\.yml" in ident.group(1))
            ok("identity regexp names this repo", f"github\\.com/{REPO}" in ident.group(1))
            ok("identity regexp anchors tag refs", "@refs/tags/v" in ident.group(1))
        if issuer:
            ok("install.sh uses the doc's OIDC issuer", issuer.group(1) in ish)
            ok("install.ps1 uses the doc's OIDC issuer", issuer.group(1) in ps1)
            ok("workflow uses the doc's OIDC issuer", issuer.group(1) in wf)

    # ── provenance recipe is pinned to the connected-host side ──────────
    attest = [c for c in cmds if c.startswith("gh attestation verify")]
    ok("doc shows a gh attestation verify recipe", len(attest) >= 1)
    for c in attest:
        ok("attestation recipe pins --repo " + REPO, f"--repo {REPO}" in c, c)
    ok("doc warns attestation cannot run air-gapped",
       re.search(r"cannot run on the\s+air-gapped|needs? (network|connectivity)", doc,
                 re.IGNORECASE) is not None)

    # ── asset names vs the release matrix ────────────────────────────────
    matrix_assets = set()
    for m in re.finditer(r"artifact:\s*([a-z0-9_-]+),\s*ext:\s*(tar\.gz|zip)\s*\}", wf):
        matrix_assets.add(f"tau-{m.group(1)}.{m.group(2)}")
    ok("workflow matrix parses to asset names", len(matrix_assets) >= 5,
       f"got {sorted(matrix_assets)}")
    doc_assets = set(re.findall(r"tau-(?:linux|macos|windows)-(?:x86_64|aarch64)\.(?:tar\.gz|zip)", doc))
    for a in sorted(doc_assets):
        ok(f"doc asset {a} is produced by the matrix", a in matrix_assets)

    # ── doc↔doc and doc↔installer cross-links ───────────────────────────
    ok("AIRGAPPED.md links VERIFYING.md", "VERIFYING.md" in doc)
    ok("VERIFYING.md links AIRGAPPED.md", "AIRGAPPED.md" in ver_doc)

    # ── no unhandled command categories ──────────────────────────────────
    known = (
        "VER=", "mkdir ", "cd ", "curl ", "grep ", "sha256sum", "shasum",
        "cosign ", "gh attestation", "TAU_BASE_URL=", "TAU_VERIFY_SIGSTORE=",
        "$env:TAU_", ".\\install.ps1", "sh install.sh", "python3 -",
    )
    for c in cmds:
        ok("command category is drift-checked: " + c[:60], c.startswith(known))

    # ── executable replay: stage a mirror and run the doc's steps ───────
    sha256sum = shutil.which("sha256sum")
    sha_args = [sha256sum] if sha256sum else None
    if not sha256sum:
        shasum = shutil.which("shasum")
        sha_args = [shasum, "-a", "256"] if shasum else None
    ok("a sha256 tool exists for the replay", sha_args is not None)

    asset = "tau-linux-x86_64.tar.gz"
    ver = "0.0.0"
    tmp = tempfile.mkdtemp(prefix="airgap-doc-")
    try:
        mirror = os.path.join(tmp, "mirror")
        stage = os.path.join(mirror, "download", f"v{ver}")
        os.makedirs(stage)
        fixture = os.path.join(stage, asset)
        payload = os.path.join(tmp, "tau")
        with open(payload, "wb") as f:
            f.write(b"#!/bin/sh\necho tau fixture\n")
        os.chmod(payload, 0o755)
        with tarfile.open(fixture, "w:gz") as tf:
            tf.add(payload, arcname="tau")
        digest = subprocess.run(sha_args + [fixture], capture_output=True,
                                text=True, check=True).stdout.split()[0]
        sums_path = os.path.join(stage, "SHA256SUMS.txt")
        with open(sums_path, "w") as f:
            f.write(f"{digest}  {asset}\n")

        # replay the doc's checksum pipeline verbatim in the staged dir
        grep_cmd = next((c for c in cmds if "sha256sum -c" in c and "grep" in c), None)
        ok("doc shows a grep|sha256sum -c recipe", grep_cmd is not None)
        if grep_cmd and sha256sum:
            r = subprocess.run(grep_cmd, shell=True, cwd=stage,
                               capture_output=True, text=True)
            ok("doc checksum recipe verifies a staged archive", r.returncode == 0,
               r.stderr.strip() or r.stdout.strip())

        # replay the doc's offline install: install.sh + file:// mirror.
        # run() is a tiny env-prefixed subprocess wrapper so the assertions
        # below pin the doc's contract, not a paraphrase of it.
        def run(env, *args):
            e = dict(os.environ)
            e.update(env)
            return subprocess.run(list(args), env=e, capture_output=True, text=True)

        dest = os.path.join(tmp, "bin")
        r = run({"TAU_BASE_URL": "file://" + mirror},
                "sh", INSTALL_SH, "--version", ver, "--dir", dest)
        ok("install.sh installs from the staged file:// mirror",
           r.returncode == 0, (r.stderr + r.stdout).strip())
        ok("install.sh reports the checksum verified on the staged mirror",
           "checksum verified" in r.stdout + r.stderr)
        installed = os.path.join(dest, "tau")
        ok("install.sh left a tau binary in --dir",
           os.path.isfile(installed) and
           os.stat(installed).st_mode & stat.S_IXUSR)

        # fail-closed replay 1: the doc promises a missing manifest aborts
        os.remove(sums_path)
        r = run({"TAU_BASE_URL": "file://" + mirror},
                "sh", INSTALL_SH, "--version", ver, "--dir", dest)
        ok("missing SHA256SUMS.txt aborts as the doc claims",
           r.returncode != 0 and "SHA256SUMS.txt" in r.stderr,
           (r.stderr + r.stdout).strip())

        # fail-closed replay 2: TAU_VERIFY_SIGSTORE=1 with no staged bundle
        # aborts (no cosign -> 'requires cosign'; cosign -> 'could not
        # download' the missing bundle; either way the install dies).
        with open(sums_path, "w") as f:
            f.write(f"{digest}  {asset}\n")
        r = run({"TAU_BASE_URL": "file://" + mirror,
                 "TAU_VERIFY_SIGSTORE": "1"},
                "sh", INSTALL_SH, "--version", ver, "--dir", dest)
        ok("TAU_VERIFY_SIGSTORE=1 without a staged bundle aborts",
           r.returncode != 0, (r.stderr + r.stdout).strip())
        ok("sigstore abort names the missing prerequisite",
           re.search(r"cosign|sigstore\.json", r.stderr) is not None,
           r.stderr.strip())
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
