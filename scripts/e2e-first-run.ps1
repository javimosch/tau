# e2e-first-run.ps1 — clean-environment first-run e2e (Windows).
#
# Mirrors e2e-first-run.sh: drives `tau setup --yes --offline`,
# `tau setup --yes --offline --client zed|claude-desktop`, and
# `tau doctor --offline --selftest` in a scratch HOME with every credential
# source scrubbed, against a tau.exe installed through install.ps1 so the
# whole install → onboard → wire → verify chain is exercised end to end on
# real Windows paths.
#
#   1. setup --yes --offline        unattended onboarding; a fake key stands
#                                   in for a user who already exported one
#                                   (the api_key check only tests resolution,
#                                   not validity).
#   2. setup --client …             editor wiring for both config paths: zed
#                                   covers direct-ACP clients
#                                   (agent_servers.tau → tau acp serve),
#                                   claude-desktop covers MCP-bridge clients
#                                   (mcpServers.mcacp + the shared
#                                   ~/.config/mcacp/mcacp.json).
#   3. doctor --selftest            fully credential-free: asserts the
#                                   selftest check row reports "ok" — the
#                                   feature's promise. The verdict exits
#                                   non-zero here because api_key fails
#                                   honestly, so the assertion is on the
#                                   check row, not the exit code.
#   4. doctor --selftest            with the fake key resolved: exit 0
#                                   required, plus the per-client wiring
#                                   rows from step 2 must verify as ok.
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

# Multi-child Join-Path keeps every path correct on both Windows and POSIX
# pwsh — the driver can be verified locally, not just on the Windows runner.
$setupLog        = Join-Path $HomeDir 'setup.ndjson'
$setupZedLog     = Join-Path $HomeDir 'setup-zed.ndjson'
$setupClaudeLog  = Join-Path $HomeDir 'setup-claude.ndjson'
$doctorKeylessLog = Join-Path $HomeDir 'doctor-keyless.json'
$doctorKeylessErr = Join-Path $HomeDir 'doctor-keyless.err'
$doctorKeyedLog  = Join-Path $HomeDir 'doctor-keyed.json'
$configJson      = Join-Path $HomeDir '.config' 'tau' 'config.json'

Write-Host "e2e-first-run: home=$HomeDir bin=$Tau"

# ── 1. Unattended onboarding ───────────────────────────────────────────────
$env:XIAOMI_API_KEY = 'fake-ci'
& $Tau setup --yes --offline > $setupLog
if ($LASTEXITCODE -ne 0) { Fail "tau setup --yes --offline exited $LASTEXITCODE" }
if (-not (Test-Path $configJson)) { Fail "setup did not scaffold $configJson" }
$verdict = Get-Content $setupLog | Select-Object -Last 1
foreach ($needle in '"step":"setup"','"ok":true','"yes":true','"non_interactive":true') {
    if ($verdict -notlike "*$needle*") { Fail "setup verdict missing $needle — $verdict" }
}
Write-Host "e2e-first-run: setup --yes --offline ok (config scaffolded, verdict ok)"

# ── 2. Editor client wiring ────────────────────────────────────────────────
# setup --client resolves every settings path relative to HOME — on this leg
# that's a Windows-style $env:USERPROFILE scratch dir, which is exactly what
# the POSIX legs can't prove.
& $Tau setup --yes --offline --client zed > $setupZedLog
if ($LASTEXITCODE -ne 0) { Fail "tau setup --yes --offline --client zed exited $LASTEXITCODE" }
$clientsStep = Get-Content $setupZedLog |
    Select-String -Pattern '"step":"clients"' -SimpleMatch | Select-Object -Last 1
if (-not $clientsStep) { Fail "clients step event missing in setup --client zed output" }
foreach ($needle in '"status":"installed"','"client":"zed"') {
    if ($clientsStep.Line -notlike "*$needle*") { Fail "clients step missing $needle — $($clientsStep.Line)" }
}
$zedCfg = Join-Path $HomeDir '.config' 'zed' 'settings.json'
if (-not (Test-Path $zedCfg)) { Fail "setup --client zed did not write $zedCfg" }
foreach ($needle in '"agent_servers"','"tau"','"acp"','"serve"','"type": "custom"') {
    if (-not (Select-String -Path $zedCfg -Pattern $needle -SimpleMatch -Quiet)) { Fail "zed settings missing $needle" }
}
Write-Host "e2e-first-run: setup --client zed ok (direct ACP entry installed)"

& $Tau setup --yes --offline --client claude-desktop > $setupClaudeLog
if ($LASTEXITCODE -ne 0) { Fail "tau setup --yes --offline --client claude-desktop exited $LASTEXITCODE" }
$clientsStep = Get-Content $setupClaudeLog |
    Select-String -Pattern '"step":"clients"' -SimpleMatch | Select-Object -Last 1
if (-not $clientsStep) { Fail "clients step event missing in setup --client claude-desktop output" }
foreach ($needle in '"status":"installed"','"client":"claude-desktop"') {
    if ($clientsStep.Line -notlike "*$needle*") { Fail "clients step missing $needle — $($clientsStep.Line)" }
}
$claudeCfg = Join-Path $HomeDir '.config' 'Claude' 'claude_desktop_config.json'
$mcacpCfg  = Join-Path $HomeDir '.config' 'mcacp' 'mcacp.json'
if (-not (Test-Path $claudeCfg)) { Fail "setup --client claude-desktop did not write $claudeCfg" }
foreach ($needle in '"mcpServers"','"mcacp"') {
    if (-not (Select-String -Path $claudeCfg -Pattern $needle -SimpleMatch -Quiet)) { Fail "claude_desktop_config missing $needle" }
}
if (-not (Test-Path $mcacpCfg)) { Fail "setup --client claude-desktop did not write $mcacpCfg" }
foreach ($needle in '"agent_servers"','"tau"') {
    if (-not (Select-String -Path $mcacpCfg -Pattern $needle -SimpleMatch -Quiet)) { Fail "mcacp.json missing $needle" }
}
Write-Host "e2e-first-run: setup --client claude-desktop ok (MCP-bridge entry + mcacp.json installed)"

# ── 3. Credential-free selftest ────────────────────────────────────────────
Remove-Item env:XIAOMI_API_KEY
& $Tau doctor --offline --selftest > $doctorKeylessLog 2> $doctorKeylessErr
$rc = $LASTEXITCODE
if (-not (Select-String -Path $doctorKeylessLog -Pattern '"name":"selftest","status":"ok"' -SimpleMatch -Quiet)) {
    Get-Content $doctorKeylessLog,$doctorKeylessErr -ErrorAction SilentlyContinue |
        ForEach-Object { [Console]::Error.WriteLine($_) }
    Fail "keyless selftest check did not report ok (exit $rc)"
}
Write-Host "e2e-first-run: credential-free doctor --selftest reports ok (verdict exit=$rc, expected non-zero with no key)"

# ── 4. Green report with a resolvable key ──────────────────────────────────
$env:XIAOMI_API_KEY = 'fake-ci'
& $Tau doctor --offline --selftest > $doctorKeyedLog
if ($LASTEXITCODE -ne 0) { Fail "keyed tau doctor --offline --selftest exited $LASTEXITCODE" }
foreach ($needle in '"name":"client_zed","status":"ok"','"name":"client_claude_desktop","status":"ok"') {
    if (-not (Select-String -Path $doctorKeyedLog -Pattern $needle -SimpleMatch -Quiet)) {
        Get-Content $doctorKeyedLog -ErrorAction SilentlyContinue |
            ForEach-Object { [Console]::Error.WriteLine($_) }
        Fail "keyed doctor report missing $needle"
    }
}
Write-Host "e2e-first-run: keyed doctor --selftest verdict ok (client wiring verified)"

Write-Host "e2e-first-run: PASS"
