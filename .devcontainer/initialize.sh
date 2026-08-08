#!/usr/bin/env bash
#
# .devcontainer/initialize.sh — runs on the HOST, before the dev container is
# created (devcontainer.json `initializeCommand`). Nothing here runs inside the
# container, so keep it dependency-free: only coreutils and bash.
#
# Idempotent: safe to re-run on every container start.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.devcontainer/.env"

# ── 1. ~/.claude.json ────────────────────────────────────────────────────────
# docker-compose.yml bind-mounts this file into the container. Docker creates a
# *directory* in its place if it does not already exist, which then fails the
# mount, so make sure it is a file first.
#
# A bare `touch` is not enough to guarantee that: on an existing directory touch
# succeeds and merely updates its mtime, so a directory left behind by an
# earlier failed start would survive here and silently get mounted again. Clear
# it explicitly. rmdir (not rm -rf) because the directory Docker creates is
# always empty — anything else is real data this script has no business
# deleting, so say so and leave it alone.
if [[ -d "$HOME/.claude.json" ]]; then
  if ! rmdir "$HOME/.claude.json" 2>/dev/null; then
    echo "devcontainer: WARNING — $HOME/.claude.json is a non-empty directory." >&2
    echo "devcontainer:           Claude Code's config cannot be mounted over it." >&2
    echo "devcontainer:           Move it aside, then rebuild the container." >&2
  fi
fi
touch "$HOME/.claude.json"

# ── 2. Match the container user to the host user ─────────────────────────────
# Only Linux bind mounts pass numeric ownership straight through, so only there
# can the container's `vscode` user end up owning /workspace files as the wrong
# host user. Docker Desktop (macOS/Windows) remaps ownership to the container
# user, so pinning a UID there is unnecessary and would just force a rebuild.
[[ "$(uname -s)" == "Linux" ]] || exit 0

if [[ ! -f "$ENV_FILE" ]]; then
  # May hold tokens later — create it 0600 (umask in a subshell so the caller's
  # umask is untouched).
  ( umask 077; : > "$ENV_FILE" )
fi

# Reduce a raw .env value to what Compose would actually hand the container: it
# trims surrounding whitespace and strips one layer of matching quotes, so a
# hand-edited USER_UID="1000" is the same value as USER_UID=1000 and must not
# be reported as a mismatch. The ${1%$'\r'} additionally tolerates an .env
# saved with CRLF endings, whose values would otherwise carry a trailing CR.
normalize_value() {
  local v="${1%$'\r'}"
  read -r v <<< "$v" || true
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# Set KEY=VALUE if absent; warn rather than overwrite if it is already set to
# something else, since a deliberate override is a legitimate thing to have.
# A commented-out `# USER_UID=1000` does not match, so it is treated as absent.
ensure_var() {
  local key="$1" want="$2" have
  have="$(sed -n "s/^${key}=//p" "$ENV_FILE" | head -n1)"
  have="$(normalize_value "$have")"

  if [[ -z "$have" ]]; then
    # An .env whose last line has no newline would otherwise have our append
    # glued onto it ("GH_TOKEN=xUSER_UID=1000"). $(tail -c1) strips a trailing
    # newline, so a non-empty result means the file does not end in one.
    if [[ -s "$ENV_FILE" && -n "$(tail -c1 "$ENV_FILE")" ]]; then
      printf '\n' >> "$ENV_FILE"
    fi
    printf '%s=%s\n' "$key" "$want" >> "$ENV_FILE"
    echo "devcontainer: set ${key}=${want} in .devcontainer/.env (matches your host user)"
  elif [[ "$have" != "$want" ]]; then
    echo "devcontainer: WARNING — .devcontainer/.env pins ${key}=${have}, but your host user is ${want}." >&2
    echo "devcontainer:           Files written to /workspace will be owned by ${have} on the host." >&2
    echo "devcontainer:           Correct it and rebuild the container unless that is deliberate." >&2
  fi
}

ensure_var USER_UID "$(id -u)"
ensure_var USER_GID "$(id -g)"

chmod 600 "$ENV_FILE"
