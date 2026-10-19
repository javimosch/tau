# e2e-first-run.ps1 — clean-environment first-run e2e (Windows).
#
# Mirrors e2e-first-run.sh: drives `tau setup --yes --offline` and
# `tau doctor --offline --selftest` in a scratch HOME with every credential
# source scrubbed, against a tau.exe installed through install.ps1 so the
# whole install → onboard → verify chain is exercised end to end.
#
#   1. setup --yes --offline  unattended onboarding; a fake key stands in for
#                             a user who already exported one (the api_key
#                             check only tests resolution, not validity).
#   2. doctor --selftest      fully credential-free: asserts the selftest
#                             check row reports "ok" — the feature's promise.
#                             The verdict exits non-zero here because api_key
#                             fails honestly, so the assertion is on the check
#                             row, not the exit code.
#   3. doctor --selftest      with the fake key resolved: exit 0 required.
#
# Usage: pwsh -File scripts/e2e-first-run.ps1 -Tau <path-to-tau.exe> [-HomeDir <scratch>]
param(
    [Parameter(Mandatory = $true)][string]$Tau,
    [string]$HomeDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("tau-first-run-" + [System.IO.Path]::GetRandomFileName()))
)
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    [Console]::Error.WriteLine("e2e-first-run: FAIL — $Message")
    exit 1
}

New-Item -ItemType Directory -Force $HomeDir | Out-Null
$env:HOME = $HomeDir
foreach ($k in 'XIAOMI_API_KEY','PIZIG_API_KEY','OPENAI_API_KEY','DEEPSEEK_API_KEY','OPENCODE_API_KEY','TAU_API_KEY') {
    Remove-Item "env:$k" -ErrorAction SilentlyContinue
}

Write-Host "e2e-first-run: home=$HomeDir bin=$Tau"

# ── 1. Unattended onboarding ───────────────────────────────────────────────
$env:XIAOMI_API_KEY = 'fake-ci'
& $Tau setup --yes --offline > "$HomeDir\setup.ndjson"
if ($LASTEXITCODE -ne 0) { Fail "tau setup --yes --offline exited $LASTEXITCODE" }
if (-not (Test-Path "$HomeDir\.config\tau\config.json")) { Fail "setup did not scaffold $HomeDir\.config\tau\config.json" }
$verdict = Get-Content "$HomeDir\setup.ndjson" | Select-Object -Last 1
foreach ($needle in '"step":"setup"','"ok":true','"yes":true','"non_interactive":true') {
    if ($verdict -notlike "*$needle*") { Fail "setup verdict missing $needle — $verdict" }
}
Write-Host "e2e-first-run: setup --yes --offline ok (config scaffolded, verdict ok)"

# ── 2. Credential-free selftest ────────────────────────────────────────────
Remove-Item env:XIAOMI_API_KEY
& $Tau doctor --offline --selftest > "$HomeDir\doctor-keyless.json" 2> "$HomeDir\doctor-keyless.err"
$rc = $LASTEXITCODE
if (-not (Select-String -Path "$HomeDir\doctor-keyless.json" -Pattern '"name":"selftest","status":"ok"' -SimpleMatch -Quiet)) {
    Get-Content "$HomeDir\doctor-keyless.json","$HomeDir\doctor-keyless.err" -ErrorAction SilentlyContinue |
        ForEach-Object { [Console]::Error.WriteLine($_) }
    Fail "keyless selftest check did not report ok (exit $rc)"
}
Write-Host "e2e-first-run: credential-free doctor --selftest reports ok (verdict exit=$rc, expected non-zero with no key)"

# ── 3. Green report with a resolvable key ──────────────────────────────────
$env:XIAOMI_API_KEY = 'fake-ci'
& $Tau doctor --offline --selftest > "$HomeDir\doctor-keyed.json"
if ($LASTEXITCODE -ne 0) { Fail "keyed tau doctor --offline --selftest exited $LASTEXITCODE" }
Write-Host "e2e-first-run: keyed doctor --selftest verdict ok"

Write-Host "e2e-first-run: PASS"
