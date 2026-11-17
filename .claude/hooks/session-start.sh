#!/bin/bash
# SessionStart hook for Claude Code cloud sessions: installs the toolchain the
# devcontainer image would otherwise provide (Crystal, bats, the mutation
# engine), the shard and npm dependencies, and the agent-apropos binary the
# edit-time hooks in settings.json call by name. Each install is skipped when
# already done, so resumes and restarts stay fast.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"

# --- System packages: Crystal's link-time libs, bats and its libraries -------
apt_pkgs=(build-essential pkg-config libssl-dev libyaml-dev libpcre2-dev
  libgmp-dev libevent-dev libxml2-dev zlib1g-dev jq bats bats-assert bats-support)
missing=()
for p in "${apt_pkgs[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ "${#missing[@]}" -gt 0 ]; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
fi

# --- Crystal: pinned like the devcontainer and CI (archive version is too old)
CRYSTAL_VERSION=1.20.3
if ! crystal --version 2>/dev/null | grep -q "^Crystal ${CRYSTAL_VERSION} "; then
  case "$(uname -m)" in
    x86_64) arch=x86_64 sha=b62ea25b247713fb63dc992beb459bcad8955465dcc11a181fd224d4ec955a62 ;;
    aarch64 | arm64) arch=aarch64 sha=7fe729a8721401f22d7b4c1342c7599e7754b494a9808d70a8df94bff3579e05 ;;
    *) echo "session-start: unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
  tarball="$(mktemp)"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
    "https://github.com/crystal-lang/crystal/releases/download/${CRYSTAL_VERSION}/crystal-${CRYSTAL_VERSION}-1-linux-${arch}.tar.gz" \
    -o "$tarball"
  echo "${sha}  ${tarball}" | sha256sum -c --quiet -
  rm -rf /opt/crystal && mkdir -p /opt/crystal
  tar -xzf "$tarball" -C /opt/crystal --strip-components=1
  rm -f "$tarball"
  ln -sf /opt/crystal/bin/crystal /opt/crystal/bin/shards /usr/local/bin/
fi

# --- Mutation engine (make mutate), in its own venv like the devcontainer -----
venv=/opt/mutate
venv_hashes="$venv/.session-start.sha256"
if ! sha256sum --check --status "$venv_hashes" 2>/dev/null; then
  rm -f "$venv_hashes"
  python3 -m venv "$venv"
  "$venv/bin/pip" install -q --require-hashes --no-deps -r tool/mutate/requirements.txt
  ln -sf "$venv/bin/mutate" /usr/local/bin/mutate
  sha256sum .claude/hooks/session-start.sh tool/mutate/requirements.txt > "$venv_hashes"
fi

export CRYSTAL_CACHE_DIR="$PWD/.cache/crystal"

# --- Shards (also builds bin/ameba via its postinstall) -----------------------
shard_hashes=lib/.session-start.sha256
if ! sha256sum --check --status "$shard_hashes" 2>/dev/null || [ ! -x bin/ameba ]; then
  rm -f "$shard_hashes"
  shards install
  sha256sum .claude/hooks/session-start.sh shard.yml shard.lock > "$shard_hashes"
fi

# --- npm (remark docs lint, jscpd duplication gate) ---------------------------
npm_hashes=node_modules/.session-start.sha256
if ! sha256sum --check --status "$npm_hashes" 2>/dev/null; then
  rm -f "$npm_hashes"
  npm install --no-audit --no-fund
  sha256sum .claude/hooks/session-start.sh package.json package-lock.json > "$npm_hashes"
fi

# --- agent-apropos on PATH, for the edit-time hooks in .claude/settings.json --
# Rebuilt when any tracked source changes; hash file sits beside the binary.
prefix="$HOME/.local"
bin_hashes="$prefix/bin/.agent-apropos.sha256"
src_hash="$(git ls-files -z src shard.yml shard.lock | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
if [ ! -x "$prefix/bin/agent-apropos" ] || [ "$(cat "$bin_hashes" 2>/dev/null)" != "$src_hash" ]; then
  rm -f "$bin_hashes"
  make install PREFIX="$prefix"
  echo "$src_hash" > "$bin_hashes"
fi

# --- Session environment ------------------------------------------------------
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export BATS_LIB_PATH=/usr/lib/bats"
    echo "export PATH=\"$prefix/bin:\$PATH\""
  } >> "$CLAUDE_ENV_FILE"
fi
