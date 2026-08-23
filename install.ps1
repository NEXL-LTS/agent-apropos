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

# The default is a script block, not a value: computing it eagerly would abort
# the run when it cannot be computed (an absent LOCALAPPDATA on a service
# account) even though the caller had overridden it and never needed it.
function Get-Setting {
    param([string] $Name, [scriptblock] $Default)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    return & $Default
}

# Windows PowerShell 5.1 leaves SecurityProtocol at the .NET default, which on a
# host without SchUseStrongCrypto is TLS 1.0/1.1 — and GitHub requires 1.2, so
# the download would fail with an SSL error the generic network message would
# misattribute. pwsh 7 already negotiates 1.2+, so this only adds 1.2 where it
# is missing.
function Enable-Tls12 {
    try {
        $current = [Net.ServicePointManager]::SecurityProtocol
        if (-not ($current -band [Net.SecurityProtocolType]::Tls12)) {
            [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
        }
    } catch {
        # A runtime that does not expose the setting already negotiates its own.
    }
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
        Enable-Tls12
        Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
    }
}

$repo = Get-Setting 'AGENT_APROPOS_REPO' { 'NEXL-LTS/agent-apropos' }
$version = Get-Setting 'AGENT_APROPOS_VERSION' { 'latest' }
$binDir = Get-Setting 'AGENT_APROPOS_BIN_DIR' {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Die 'LOCALAPPDATA is not set, so there is no default install directory — set AGENT_APROPOS_BIN_DIR to a writable directory.'
    }
    Join-Path $env:LOCALAPPDATA 'agent-apropos\bin'
}

# --- Platform gate -----------------------------------------------------------
# Windows ships a fully static x86_64 .exe. arm64 is deferred behind it, so an
# arm64 host is told to build rather than handed an x86_64 binary.
if (-not (@($env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432) -contains 'AMD64')) {
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
    # Staged, not installed in place: the binary is smoke-tested where it will
    # live (so it is tested across the same filesystem and policy as the real
    # target) but under a temporary name, and only replaces the target once it
    # has run. A binary that cannot execute therefore leaves any working
    # installation exactly as it was, which is what failing closed means here.
    $target = Join-Path $binDir 'agent-apropos.exe'
    # The staging name must keep .exe LAST. Given a path whose extension is not
    # an executable one, PowerShell does not run it as a program and does not
    # error either — it hands the file to the shell as a document, so nothing
    # executes, no output appears, and $LASTEXITCODE is never set. The earlier
    # `$target.new` therefore failed the smoke test below on every platform run,
    # no matter how sound the binary was.
    $staged = Join-Path $binDir 'agent-apropos.new.exe'
    try {
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        Copy-Item -LiteralPath $downloaded -Destination $staged -Force
    } catch {
        Die "failed to install to $binDir (set AGENT_APROPOS_BIN_DIR to a writable directory). ($($_.Exception.Message))"
    }

    # Cleared first so "never set" is distinguishable from "set to 0" — that is
    # the signature of a staged file the shell refused to execute, and reporting
    # it as an exit code would misdescribe it.
    $why = $null
    $global:LASTEXITCODE = $null
    try {
        & $staged --version | Out-Null
        if ($null -eq $LASTEXITCODE) {
            $ran = $false
            $why = "$staged was not executed as a program at all"
        } else {
            $ran = ($LASTEXITCODE -eq 0)
            if (-not $ran) { $why = "exit code $LASTEXITCODE" }
        }
    } catch {
        $ran = $false
        $why = $_.Exception.Message
    }
    if (-not $ran) {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        Die "the downloaded binary failed to run, so nothing was installed (wrong architecture, a corrupt download, or a blocked file). Any existing $target is untouched. ($why)"
    }

    try {
        Move-Item -LiteralPath $staged -Destination $target -Force
    } catch {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        Die "failed to replace $target — it may be running. Close any agent-apropos process and re-run. ($($_.Exception.Message))"
    }
    Write-Host ">> installed agent-apropos to $target"

    $onPath = ($env:PATH -split ';' | Where-Object { $_ -and (($_.TrimEnd('\')) -ieq $binDir.TrimEnd('\')) })
    if (-not $onPath) {
        Write-Host ">> note: $binDir is not on your PATH. Add it for this session:"
        Write-Host "     `$env:PATH = `"$binDir;`$env:PATH`""
        Write-Host '   ...and permanently, for future sessions:'
        Write-Host "     [Environment]::SetEnvironmentVariable('Path', `"$binDir;`" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')"
    }

    & $target --version
    if ($LASTEXITCODE -ne 0) {
        Die "installed binary at $target failed to run — the install is broken (wrong architecture or a corrupt download)."
    }
    Write-Host ">> done. Run 'agent-apropos help' for the mental model, or 'agent-apropos init' to bootstrap a repo."
} finally {
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}
