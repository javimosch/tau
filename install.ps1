# install.ps1 — install a prebuilt tau binary on Windows (no Zig toolchain required).
#
#   irm https://raw.githubusercontent.com/javimosch/tau/master/install.ps1 | iex
#   .\install.ps1 -Version 0.5.0          # or: --version 0.5.0 / --version=0.5.0
#
# Options (both -name and --name forms are accepted, values via space, =, or :):
#   -Version X.Y.Z    install a specific release (default: latest)
#   -Dir DIR          install into DIR (default: $env:LOCALAPPDATA\Programs\tau)
#   -DryRun           print the resolved platform/URL/plan and exit 0
#   -Help             show this help
#
# Environment overrides:
#   TAU_VERSION       same as -Version
#   TAU_INSTALL_DIR   same as -Dir
#   TAU_ARCH          override CPU detection (x86_64|amd64|aarch64|arm64)
#   TAU_BASE_URL      override the releases base URL — useful for testing
#                     installs against a staging dir (file://…) or mirror
#   TAU_SKIP_CHECKSUM set to 1 to skip SHA256 verification (NOT recommended —
#                     verification is what protects you from tampered or
#                     corrupted downloads)
#
# Release assets are produced by .github/workflows/release.yml and named
# tau-windows-<arch>.zip alongside a SHA256SUMS.txt manifest. Verification is
# mandatory by default: the install aborts if the manifest is unreachable, the
# asset is not listed in it, or the digest mismatches (fail closed).

$ErrorActionPreference = 'Stop'

$Repo    = 'javimosch/tau'
$Base    = if ($env:TAU_BASE_URL) { $env:TAU_BASE_URL } else { "https://github.com/$Repo/releases" }
$Version = $env:TAU_VERSION
if ($env:TAU_INSTALL_DIR) { $Dest = $env:TAU_INSTALL_DIR }
elseif ($env:LOCALAPPDATA) { $Dest = Join-Path $env:LOCALAPPDATA 'Programs\tau' }
else { $Dest = Join-Path $HOME 'tau\bin' }
$DryRun  = $false
$ShowHelp = $false

function Usage {
    @'
install.ps1 — install a prebuilt tau binary on Windows (no Zig toolchain required).

  irm https://raw.githubusercontent.com/javimosch/tau/master/install.ps1 | iex
  .\install.ps1 -Version 0.5.0          # or: --version 0.5.0 / --version=0.5.0

Options (both -name and --name forms are accepted):
  -Version X.Y.Z    install a specific release (default: latest)
  -Dir DIR          install into DIR (default: $env:LOCALAPPDATA\Programs\tau)
  -DryRun           print the resolved platform/URL/plan and exit 0
  -Help             show this help

Environment overrides:
  TAU_VERSION       same as -Version
  TAU_INSTALL_DIR   same as -Dir
  TAU_ARCH          override CPU detection (x86_64|amd64|aarch64|arm64)
  TAU_BASE_URL      override the releases base URL (test/staging/mirror)
  TAU_SKIP_CHECKSUM set to 1 to skip SHA256 verification (not recommended)
'@
}

function Fail([string]$Message) {
    # throw (not exit) so `irm … | iex` installs surface the error without
    # killing the user's interactive shell.
    [Console]::Error.WriteLine("install.ps1: $Message")
    throw "install.ps1: $Message"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
# Manual loop (not a param() block) so the exact install.sh flag contract —
# --version 1.2.3, --version=1.2.3, --dry-run — binds identically. PowerShell
# does not map double-dash args onto switch parameters.
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = $args[$i]
    if ($a -match '^-{1,2}([A-Za-z][A-Za-z0-9-]*)([:=](.*))?$') {
        $name = $Matches[1].ToLowerInvariant()
        $hasInline = $null -ne $Matches[2] -and $Matches[2].Length -gt 0
        $inline = if ($hasInline) { $Matches[3] } else { $null }
        switch ($name) {
            { $_ -in 'version' } {
                if ($hasInline) { $Version = $inline }
                elseif ($i + 1 -lt $args.Count) { $Version = $args[++$i] }
                else { Fail "--version requires a value (e.g. --version 0.5.0)" }
            }
            { $_ -in 'dir' } {
                if ($hasInline) { $Dest = $inline }
                elseif ($i + 1 -lt $args.Count) { $Dest = $args[++$i] }
                else { Fail "--dir requires a path" }
            }
            { $_ -in 'dryrun', 'dry-run' } { $DryRun = $true }
            { $_ -in 'h', 'help' } { $ShowHelp = $true }
            default { Fail "unknown option '$a' (try --help)" }
        }
    } else {
        Fail "unknown option '$a' (try --help)"
    }
}
if ($ShowHelp) { Usage; return }

# ── Platform detection ───────────────────────────────────────────────────────
$rawArch = if ($env:TAU_ARCH) { $env:TAU_ARCH }
           else { [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }

switch ($rawArch.ToLowerInvariant()) {
    { $_ -in 'x64', 'x86_64', 'amd64' }     { $Arch = 'x86_64' }
    { $_ -in 'arm64', 'aarch64' }           { $Arch = 'aarch64' }
    default { Fail "unsupported architecture '$rawArch' — prebuilt binaries exist for x86_64 only" }
}
if ($Arch -ne 'x86_64') {
    Fail "unsupported architecture '$rawArch' — prebuilt Windows binaries exist for x86_64 only; build from source instead (see README.md 'Build & Install')"
}

$Platform = "windows-$Arch"
$Asset    = "tau-$Platform.zip"
$Sums     = 'SHA256SUMS.txt'

# ── Version resolution ───────────────────────────────────────────────────────
if ($Version -and $Version.StartsWith('v')) { $Version = $Version.Substring(1) }
if ($Version) {
    if ($Version -notmatch '^[0-9.]+$') {
        Fail "invalid --version '$Version' (expected a dotted triple like 0.5.0)"
    }
    $AssetUrl   = "$Base/download/v$Version/$Asset"
    $SumsUrl    = "$Base/download/v$Version/$Sums"
    $ReleaseDesc = "v$Version"
} else {
    $AssetUrl   = "$Base/latest/download/$Asset"
    $SumsUrl    = "$Base/latest/download/$Sums"
    $ReleaseDesc = 'latest'
}

Write-Host "install.ps1: platform=$Platform release=$ReleaseDesc dest=$Dest"
Write-Host "install.ps1: url=$AssetUrl"

if ($DryRun) {
    Write-Host "install.ps1: dry-run — would download, verify, and install 'tau.exe' into $Dest"
    return
}

# ── Download + verify ────────────────────────────────────────────────────────
# Save-RemoteFile fetches $Url to $OutFile. file:// URLs are resolved through
# System.Uri so the TAU_BASE_URL staging trick works on every pwsh host.
function Save-RemoteFile([string]$Url, [string]$OutFile) {
    $uri = [System.Uri]$Url
    if ($uri.Scheme -eq 'file') {
        Copy-Item -LiteralPath $uri.LocalPath -Destination $OutFile -Force -ErrorAction Stop
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    }
}

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tau-install-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null
try {
    try {
        Save-RemoteFile $AssetUrl (Join-Path $Tmp $Asset)
    } catch {
        Fail "download failed — check that release $ReleaseDesc ships $Asset ($AssetUrl)"
    }

    if ($env:TAU_SKIP_CHECKSUM -eq '1') {
        [Console]::Error.WriteLine('install.ps1: warning: TAU_SKIP_CHECKSUM=1 — installing WITHOUT integrity verification')
    } else {
        # Fail closed: a missing manifest means the binary cannot be proven
        # intact, so the install aborts rather than silently trusting it.
        try {
            Save-RemoteFile $SumsUrl (Join-Path $Tmp $Sums)
        } catch {
            Fail "could not download $Sums for $ReleaseDesc — refusing to install an unverified binary (set TAU_SKIP_CHECKSUM=1 to bypass)"
        }

        $entry = Get-Content -LiteralPath (Join-Path $Tmp $Sums) |
            Where-Object { $_ -match " (\./)?$([regex]::Escape($Asset))$" } |
            Select-Object -First 1
        if (-not $entry) {
            Fail "$Asset is not listed in $Sums for $ReleaseDesc — refusing to install an unverified binary"
        }
        $expected = ($entry -split '\s+')[0]

        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Tmp $Asset)).Hash
        if ($actual -ne $expected.ToUpperInvariant()) {
            Fail "checksum verification failed for $Asset — the download is corrupted or tampered; aborting"
        }
        Write-Host "install.ps1: checksum verified against $Sums"
    }

    Expand-Archive -LiteralPath (Join-Path $Tmp $Asset) -DestinationPath $Tmp -Force
    $exe = Join-Path $Tmp 'tau.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Fail "archive did not contain a 'tau.exe' binary"
    }

    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    try {
        Copy-Item -LiteralPath $exe -Destination (Join-Path $Dest 'tau.exe') -Force -ErrorAction Stop
    } catch {
        Fail "cannot write $Dest\tau.exe — check permissions or choose another -Dir"
    }

    Write-Host "install.ps1: installed tau -> $Dest\tau.exe"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $onPath = ($userPath -split ';') -contains $Dest
    if (-not $onPath) {
        [Console]::Error.WriteLine("install.ps1: note: $Dest is not on your user PATH — add it with:")
        [Console]::Error.WriteLine("    [Environment]::SetEnvironmentVariable('Path', `"$Dest;`" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')")
    }

    if ($env:OS -eq 'Windows_NT') {
        try {
            $v = & (Join-Path $Dest 'tau.exe') --version 2>$null
            if ($LASTEXITCODE -eq 0 -and $v) { Write-Host $v }
        } catch { }
    }
} finally {
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
