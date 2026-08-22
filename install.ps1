#Requires -Version 5.1
<#
    agent-apropos installer for Windows — resolves a GitHub release, verifies its
    checksum, and drops the binary somewhere your PATH can find it. Pipe-friendly:

        irm https://raw.githubusercontent.com/NEXL-LTS/agent-apropos/main/install.ps1 | iex

    Overrides (environment variables, same names as install.sh):
        AGENT_APROPOS_VERSION   release tag to install (default: latest)
        AGENT_APROPOS_BIN_DIR   install directory      (default: %LOCALAPPDATA%\agent-apropos\bin)
        AGENT_APROPOS_REPO      owner/repo             (default: NEXL-LTS/agent-apropos)

    Unlike agent-apropos's hook path, an installer must FAIL CLOSED: any error
    aborts with a non-zero exit and a clear message rather than leaving a
    half-installed tool.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Die {
    param([string] $Message)
    [Console]::Error.WriteLine("install.ps1: $Message")
    exit 1
}

function Get-Setting {
    param([string] $Name, [string] $Default)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

# A file:// URI is copied rather than requested, so the release workflow can
# exercise this script end-to-end against a freshly built artifact with nothing
# but the base URL substituted — the same trick install.sh gets free from curl.
function Get-Remote {
    param([string] $Uri, [string] $Destination)
    $parsed = [Uri] $Uri
    if ($parsed.IsFile) {
        Copy-Item -LiteralPath $parsed.LocalPath -Destination $Destination
    } else {
        Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
    }
}

$repo = Get-Setting 'AGENT_APROPOS_REPO' 'NEXL-LTS/agent-apropos'
$version = Get-Setting 'AGENT_APROPOS_VERSION' 'latest'
$binDir = Get-Setting 'AGENT_APROPOS_BIN_DIR' (Join-Path $env:LOCALAPPDATA 'agent-apropos\bin')

# --- Platform gate -----------------------------------------------------------
# Windows ships a fully static x86_64 .exe. arm64 is deferred behind it, so an
# arm64 host is told to build rather than handed an x86_64 binary.
$architecture = @($env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432) -contains 'AMD64'
if (-not $architecture) {
    Die "unsupported architecture '$env:PROCESSOR_ARCHITECTURE'; Windows ships x86_64 only (build from source: crystal build --release --static src/agent_apropos.cr)."
}
$asset = 'agent-apropos-windows-x86_64.exe'

# --- Resolve URLs ------------------------------------------------------------
# GitHub redirects .../releases/latest/download/<asset> to the newest release's
# asset, so no API call or token is needed for the default "latest" path.
if ($version -eq 'latest') {
    $base = "https://github.com/$repo/releases/latest/download"
} else {
    $base = "https://github.com/$repo/releases/download/$version"
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('agent-apropos-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $downloaded = Join-Path $temp $asset

    Write-Host ">> downloading $asset ($version) from $repo ..."
    try {
        Get-Remote "$base/$asset" $downloaded
    } catch {
        Die "failed to download $asset — check the version tag and your network. ($($_.Exception.Message))"
    }
    try {
        Get-Remote "$base/$asset.sha256" "$downloaded.sha256"
    } catch {
        Die "failed to download the checksum file. ($($_.Exception.Message))"
    }

    # The checksum files are written by sha256sum(1) on the other release legs,
    # so the format is "<hash>  <filename>" — take the hash and ignore the name,
    # which is a local temp path here rather than the recorded one.
    Write-Host '>> verifying checksum ...'
    $expected = ((Get-Content -LiteralPath "$downloaded.sha256" -First 1) -split '\s+')[0]
    if ($expected -notmatch '^[0-9a-fA-F]{64}$') {
        Die "checksum file does not contain a SHA256 digest — refusing to install unverified."
    }
    $actual = (Get-FileHash -LiteralPath $downloaded -Algorithm SHA256).Hash
    if ($actual -ne $expected.ToUpperInvariant()) {
        Die 'checksum verification FAILED — refusing to install a corrupt or tampered binary.'
    }

    # --- Install -------------------------------------------------------------
    $target = Join-Path $binDir 'agent-apropos.exe'
    try {
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        Copy-Item -LiteralPath $downloaded -Destination $target -Force
    } catch {
        Die "failed to install to $binDir (set AGENT_APROPOS_BIN_DIR to a writable directory). ($($_.Exception.Message))"
    }
    Write-Host ">> installed agent-apropos to $target"

    $onPath = ($env:PATH -split ';' | Where-Object { $_ -and (($_.TrimEnd('\')) -ieq $binDir.TrimEnd('\')) })
    if (-not $onPath) {
        Write-Host ">> note: $binDir is not on your PATH. Add it for this session:"
        Write-Host "     `$env:PATH = `"$binDir;`$env:PATH`""
        Write-Host '   ...and permanently, for future sessions:'
        Write-Host "     [Environment]::SetEnvironmentVariable('Path', `"$binDir;`" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')"
    }

    # Fail closed: a binary that cannot execute (wrong architecture, a corrupt
    # download, a blocked file) is a broken install, not a success.
    & $target --version
    if ($LASTEXITCODE -ne 0) {
        Die "installed binary at $target failed to run — the install is broken (wrong architecture or a corrupt download)."
    }
    Write-Host ">> done. Run 'agent-apropos help' for the mental model, or 'agent-apropos init' to bootstrap a repo."
} finally {
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}
