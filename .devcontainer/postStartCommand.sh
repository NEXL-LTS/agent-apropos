#!/usr/bin/env bash
# Runs as vscode on every container start, from both VS Code and start.sh.
# Everything here is idempotent: the Claude config dir is a volume that
# outlives containers, so this script meets its own earlier output.
set -euo pipefail

config_dir="${CLAUDE_CONFIG_DIR:?CLAUDE_CONFIG_DIR is set in the Dockerfile}"

# Permission prompts off by default. This is the container's own Claude config,
# so the host's settings are untouched. Only the one key is set, leaving any
# other settings you have added in the volume alone.
settings="${config_dir}/settings.json"
[ -s "${settings}" ] || echo '{}' > "${settings}"
jq '.permissions.defaultMode = "bypassPermissions"' "${settings}" > "${settings}.tmp"
mv "${settings}.tmp" "${settings}"

# Project dependencies and the agent-apropos binary the edit-time hooks call.
# Each step is skipped when its inputs hash the same as the last run, so a plain
# restart costs nothing. The hashes live in the container, not the checkout.
state_dir="${HOME}/.cache/devcontainer-setup"
mkdir -p "${state_dir}"
cd /workspace

# run_if_changed NAME CMD FILES...: run CMD when FILES' contents changed.
run_if_changed() {
  local name="$1" cmd="$2"; shift 2
  local want have=""
  want="$(cat "$@" | sha256sum | cut -d' ' -f1)"
  [ -f "${state_dir}/${name}" ] && have="$(cat "${state_dir}/${name}")"
  if [ "${want}" != "${have}" ]; then
    echo "devcontainer: ${name}"
    eval "${cmd}"
    echo "${want}" > "${state_dir}/${name}"
  fi
}

run_if_changed shards "shards install" shard.yml shard.lock
run_if_changed npm "npm ci" package.json package-lock.json
# Source hash rather than lockfiles: the binary is a build of the checkout itself.
run_if_changed install "make install" Makefile shard.yml $(git ls-files 'src/*.cr')

# Status, so a missing credential shows up now rather than mid-task.
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  echo "No SSH agent forwarded: git push over SSH will not work."
else
  agent_status=0
  ssh-add -l >/dev/null 2>&1 || agent_status=$?
  case "${agent_status}" in
    0) ;;
    1) echo "SSH agent reachable but holds no keys: run 'ssh-add' on the host." ;;
    *) echo "SSH agent socket is dead (host agent restarted?): run .devcontainer/start.sh --rebuild." ;;
  esac
fi

if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  echo "Neither GH_TOKEN nor GITHUB_TOKEN is set: gh (PRs, issues) is unauthenticated. Put GH_TOKEN=... in ~/.config/NEXL-LTS/agent-apropos/gh.env on the host and rerun start.sh."
fi

if [ ! -s "${config_dir}/.credentials.json" ]; then
  echo "Claude is not logged in yet: run 'claude' and log in once; the login persists across rebuilds."
fi
