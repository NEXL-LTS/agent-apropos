#!/usr/bin/env sh
# agent-apropos installer — resolves a GitHub release, verifies its checksum, and drops
# the binary on your PATH. Curl-pipe friendly:
#
#   curl -fsSL https://raw.githubusercontent.com/NEXL-LTS/agent-apropos/main/install.sh | sh
#
# Overrides (environment variables):
#   AGENT_APROPOS_VERSION   release tag to install (default: latest)
#   AGENT_APROPOS_BIN_DIR   install directory      (default: $HOME/.local/bin)
#   AGENT_APROPOS_REPO      owner/repo             (default: NEXL-LTS/agent-apropos)
#
# Unlike agent-apropos's hook path, an installer must FAIL CLOSED: any error aborts with
# a non-zero exit and a clear message rather than leaving a half-installed tool.
set -eu

REPO="${AGENT_APROPOS_REPO:-NEXL-LTS/agent-apropos}"
VERSION="${AGENT_APROPOS_VERSION:-latest}"
BIN_DIR="${AGENT_APROPOS_BIN_DIR:-$HOME/.local/bin}"

die() {
  echo "install.sh: $*" >&2
  exit 1
}

# --- Platform gate -----------------------------------------------------------
# Linux ships fully static x86_64/arm64 binaries; macOS ships dynamically linked
# (against system frameworks only — third-party deps are statically linked in)
# arm64/x86_64 binaries. Windows ships a fully static x86_64 .exe, installed by
# install.ps1 from PowerShell rather than by this script.
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux)
    case "$arch" in
      x86_64 | amd64) asset="agent-apropos-linux-x86_64" ;;
      aarch64 | arm64) asset="agent-apropos-linux-arm64" ;;
      *) die "unsupported architecture '$arch'; Linux ships x86_64/arm64 only (build from source: make install)." ;;
    esac
    ;;
  Darwin)
    case "$arch" in
      x86_64) asset="agent-apropos-darwin-x86_64" ;;
      arm64) asset="agent-apropos-darwin-arm64" ;;
      *) die "unsupported architecture '$arch'; macOS ships x86_64/arm64 only (build from source: make install)." ;;
    esac
    ;;
  # Git Bash, MSYS2 and Cygwin all report a Windows-hosted POSIX shell. The
  # native Windows binary exists, but installing it means placing an .exe
  # somewhere the Windows PATH resolves — so name the installer that does that
  # rather than reporting the OS as unsupported.
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    die "this is a Windows-hosted POSIX shell ('$os'); agent-apropos ships a native Windows binary.
Install it from PowerShell instead:
    irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex"
    ;;
  *) die "unsupported OS '$os'; ships Linux, macOS and Windows binaries only (build from source: make install)." ;;
esac

# --- Downloader --------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
else
  die "need curl or wget to download the release."
fi

# --- Checksum verifier -------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum -c "$1" >/dev/null 2>&1; }
elif command -v shasum >/dev/null 2>&1; then
  checksum() { shasum -a 256 -c "$1" >/dev/null 2>&1; }
else
  die "need sha256sum or shasum to verify the download."
fi

# --- Resolve URLs ------------------------------------------------------------
# GitHub redirects .../releases/latest/download/<asset> to the newest release's
# asset, so no API call or token is needed for the default "latest" path.
if [ "$VERSION" = "latest" ]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/$VERSION"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

echo ">> downloading $asset ($VERSION) from $REPO ..."
fetch "$base/$asset" "$tmp/$asset" || die "failed to download $asset — check the version tag and your network."
fetch "$base/$asset.sha256" "$tmp/$asset.sha256" || die "failed to download the checksum file."

echo ">> verifying checksum ..."
( cd "$tmp" && checksum "$asset.sha256" ) || die "checksum verification FAILED — refusing to install a corrupt or tampered binary."

# --- Install -----------------------------------------------------------------
mkdir -p "$BIN_DIR"
install -m 0755 "$tmp/$asset" "$BIN_DIR/agent-apropos" 2>/dev/null \
  || { chmod 0755 "$tmp/$asset" && mv "$tmp/$asset" "$BIN_DIR/agent-apropos"; } \
  || die "failed to install to $BIN_DIR (set AGENT_APROPOS_BIN_DIR to a writable dir, or re-run with sudo)."

echo ">> installed agent-apropos to $BIN_DIR/agent-apropos"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo ">> note: $BIN_DIR is not on your PATH. Add it:"
     echo "     export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# Fail closed: a binary that can't execute (wrong arch, noexec mount, corruption)
# is a broken install, not a success — surface it rather than exiting 0.
"$BIN_DIR/agent-apropos" --version \
  || die "installed binary at $BIN_DIR/agent-apropos failed to run — the install is broken (wrong architecture, a noexec mount, or a corrupt download)."
echo ">> done. Run 'agent-apropos help' for the mental model, or 'agent-apropos init' to bootstrap a repo."
