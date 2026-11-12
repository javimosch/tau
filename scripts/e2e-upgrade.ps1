# e2e-upgrade.ps1 — pinned-install → upgrade → doctor-clean e2e (Windows).
#
# Mirrors e2e-upgrade.sh. `tau upgrade` is POSIX-only by design: on Windows
# it exits 111 and tells the user to re-run install.ps1. The driver therefore
# exercises the documented Windows upgrade path end to end against a fully
# staged, file:// release tree — no network access required:
#
#   1. install.ps1 -Version 0.3.9     pinned older install through the
#                                     versioned release path
#                                     ($TAU_BASE_URL/download/v<ver>/<asset>),
#                                     checksum-verified like a real install.
#   2. tau setup --client zed         wire a client entry whose command is the
#                                     installed binary's absolute path, so the
#                                     post-upgrade doctor run proves wiring
#                                     survives the binary swap.
#   3. tau.exe upgrade                pins the Windows contract: exit 111 with
#                                     an unimplemented envelope naming
#                                     install.ps1 as the update path.
#   4. install.ps1 -Version 99.9.9    the documented Windows upgrade: re-run
#                                     the installer at the newer tag into the
#                                     same dir, checksum-verified.
#   5. tau doctor --offline --selftest
#                                     post-upgrade health: a keyed run must
#                                     go green (exit 0) and the zed wiring
#                                     row must still verify ok.
#
# The release payload is the just-built binary itself — the v99.9.9 tag is
# what a real release would ship, so the post-upgrade binary is a real tau
# that can run doctor, not a stub.
#
# Usage: pwsh -File scripts/e2e-upgrade.ps1 -Tau <built-tau.exe> [-WorkDir <scratch>]
param(
    [Parameter(Mandatory = $true)][string]$Tau,
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("tau-upgrade-" + [System.IO.Path]::GetRandomFileName()))
)
$ErrorActionPreference = 'Stop'

$Old = '0.3.9'
$New = '99.9.9'
$Asset = 'tau-windows-x86_64.zip'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) {
    [Console]::Error.WriteLine("e2e-upgrade: FAIL — $Message")
    exit 1
}

New-Item -ItemType Directory -Force $WorkDir | Out-Null
$env:HOME = Join-Path $WorkDir 'home'
New-Item -ItemType Directory -Force $env:HOME | Out-Null
foreach ($k in 'XIAOMI_API_KEY','PIZIG_API_KEY','OPENAI_API_KEY','DEEPSEEK_API_KEY','OPENCODE_API_KEY','TAU_API_KEY','TAU_VERIFY_SIGSTORE') {
    Remove-Item "env:$k" -ErrorAction SilentlyContinue
}

Write-Host "e2e-upgrade: work=$WorkDir src=$Tau asset=$Asset"

# ── Stage the release tree ────────────────────────────────────────────────
# Both versions carry the real binary as payload; only the tag differs. The
# layout matches what install.ps1 fetches: download/v<ver>/<asset> +
# download/v<ver>/SHA256SUMS.txt ('<hash>  <name>', ASCII).
$pkg = Join-Path $WorkDir 'pkg'
New-Item -ItemType Directory -Force $pkg | Out-Null
Copy-Item $Tau (Join-Path $pkg 'tau.exe')
foreach ($v in @($Old, $New)) {
    $dir = Join-Path $WorkDir 'srv' 'download' "v$v"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Compress-Archive (Join-Path $pkg 'tau.exe') (Join-Path $dir $Asset) -Force
    $h = (Get-FileHash -Algorithm SHA256 (Join-Path $dir $Asset)).Hash.ToLower()
    Set-Content -Path (Join-Path $dir 'SHA256SUMS.txt') -Value "$h  $Asset" -Encoding ASCII
}
Set-Content -Path (Join-Path $WorkDir 'release.json') -Value "{`"tag_name`":`"v$New`",`"name`":`"newer`"}" -Encoding ASCII
$env:TAU_BASE_URL = 'file:///' + (Resolve-Path (Join-Path $WorkDir 'srv')).Path.Replace('\','/')

$binDir = Join-Path $WorkDir 'bin'
$TauExe = Join-Path $binDir 'tau.exe'

# ── 1. Pinned older install ───────────────────────────────────────────────
# install.ps1 Fail()s via throw (not exit) so irm|iex stays safe — a failed
# install surfaces here as a caught error, not an exit code.
try {
    & (Join-Path $RepoRoot 'install.ps1') -Version $Old -Dir $binDir *> (Join-Path $WorkDir 'install.log')
} catch {
    Fail "install.ps1 -Version $Old failed: $_"
}
if (-not (Test-Path $TauExe)) { Fail "pinned install did not produce $TauExe" }
if (-not (Select-String -Path (Join-Path $WorkDir 'install.log') -Pattern 'checksum verified' -SimpleMatch -Quiet)) {
    Fail "pinned install did not verify the checksum"
}
& $TauExe --version | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "pinned binary does not run" }
Write-Host "e2e-upgrade: pinned install v$Old ok ($TauExe)"

# ── 2. Wire a client against the installed path ───────────────────────────
# setup writes command=<absolute exe path> — the very file the upgrade swaps
# — so the post-upgrade doctor row proves wiring survives.
$env:XIAOMI_API_KEY = 'fake-ci'
& $TauExe setup --yes --offline --client zed > (Join-Path $WorkDir 'setup-zed.ndjson')
if ($LASTEXITCODE -ne 0) { Fail "tau setup --yes --offline --client zed exited $LASTEXITCODE" }
$zedCfg = Join-Path $env:HOME '.config' 'zed' 'settings.json'
if (-not (Test-Path $zedCfg)) { Fail "setup --client zed did not write $zedCfg" }
if (-not (Select-String -Path $zedCfg -Pattern 'tau.exe' -SimpleMatch -Quiet)) {
    Fail "zed wiring does not reference the installed binary"
}
Write-Host "e2e-upgrade: client wiring points at the installed path"

# ── 3. tau.exe upgrade pins the Windows contract ──────────────────────────
# POSIX-only by design: exit 111 with an unimplemented envelope that names
# install.ps1 as the way forward.
& $TauExe upgrade > (Join-Path $WorkDir 'upgrade.json') 2> (Join-Path $WorkDir 'upgrade.err')
$rc = $LASTEXITCODE
if ($rc -ne 111) { Fail "tau upgrade on Windows exited $rc (want 111 unimplemented)" }
if (-not (Select-String -Path (Join-Path $WorkDir 'upgrade.err') -Pattern 'install.ps1' -SimpleMatch -Quiet)) {
    Get-Content (Join-Path $WorkDir 'upgrade.err') | ForEach-Object { [Console]::Error.WriteLine($_) }
    Fail "upgrade envelope does not name install.ps1 as the update path"
}
Write-Host "e2e-upgrade: tau upgrade reports the install.ps1 path (exit 111)"

# ── 4. Documented Windows upgrade: re-run install.ps1 at the newer tag ────
try {
    & (Join-Path $RepoRoot 'install.ps1') -Version $New -Dir $binDir *> (Join-Path $WorkDir 'upgrade-install.log')
} catch {
    Fail "install.ps1 -Version $New failed: $_"
}
if (-not (Select-String -Path (Join-Path $WorkDir 'upgrade-install.log') -Pattern 'checksum verified' -SimpleMatch -Quiet)) {
    Fail "upgrade install did not verify the checksum"
}
if (-not (Test-Path $TauExe)) { Fail "upgrade left no binary at $TauExe" }
Write-Host "e2e-upgrade: install.ps1 -Version $New upgraded in place (checksum verified)"

# ── 5. Post-upgrade doctor clean ──────────────────────────────────────────
# Keyed, offline: every check must report ok and the verdict exits 0. The
# client_zed row is the keep-state assertion — wiring written in step 2 must
# still verify against the swapped binary at the same path.
& $TauExe doctor --offline --selftest > (Join-Path $WorkDir 'doctor.json')
if ($LASTEXITCODE -ne 0) {
    Get-Content (Join-Path $WorkDir 'doctor.json') | ForEach-Object { [Console]::Error.WriteLine($_) }
    Fail "post-upgrade tau doctor exited $LASTEXITCODE"
}
foreach ($needle in '"name":"selftest","status":"ok"','"name":"client_zed","status":"ok"') {
    if (-not (Select-String -Path (Join-Path $WorkDir 'doctor.json') -Pattern $needle -SimpleMatch -Quiet)) {
        Get-Content (Join-Path $WorkDir 'doctor.json') | ForEach-Object { [Console]::Error.WriteLine($_) }
        Fail "post-upgrade doctor missing $needle"
    }
}
Write-Host "e2e-upgrade: post-upgrade doctor clean (exit 0, client_zed wiring still ok)"

Write-Host "e2e-upgrade: PASS"
