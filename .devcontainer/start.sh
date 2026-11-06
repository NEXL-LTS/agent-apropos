#!/bin/bash
# Build, start and attach to the dev container from a plain terminal.
#   --rebuild  rebuild the image from scratch (also how Claude Code gets upgraded)
#   --docker   privileged mode with nested Docker; see compose.docker.yml first
#   -- CMD...  run CMD in the container instead of bash, e.g. -- claude --resume
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

rebuild=false
docker_mode=false
command=(bash)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rebuild) rebuild=true ;;
        --docker) docker_mode=true ;;
        --)
            shift
            if [ "$#" -gt 0 ]; then command=("$@"); fi
            break
            ;;
        *) echo "Usage: $(basename "$0") [--rebuild] [--docker] [-- CMD [ARG...]]" >&2; exit 64 ;;
    esac
    shift
done

# One container per checkout: key the compose project to the checkout path, so
# two checkouts never share (or recreate) each other's container. The name also
# differs from the one VS Code generates, so the two never disturb each other.
checkout_slug="$(printf '%s' "$(basename "$PROJECT_ROOT")" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')"
checkout_digest="$(printf '%s' "$PROJECT_ROOT" | cksum | cut -d ' ' -f 1)"
COMPOSE_PROJECT="agent-apropos-${checkout_slug}-${checkout_digest}"
SERVICE="app"
# docker-compose.yml mounts .git/hooks and .git/config read-only, which needs a
# real .git directory; in a worktree .git is a file pointing elsewhere.
if [ ! -d "$PROJECT_ROOT/.git" ]; then
    echo -e "${RED}$PROJECT_ROOT/.git is not a directory (a git worktree?). The dev container needs a regular clone.${NC}" >&2
    exit 1
fi

# ── Git identity: the container sees .git/config, not your ~/.gitconfig ─────
identity_changed=false
for key in user.name user.email; do
    if [ -n "$(git -C "$PROJECT_ROOT" config --local --get "$key" || true)" ]; then
        continue
    fi
    if [ ! -t 0 ]; then
        echo -e "${YELLOW}$key is not set in this repo's .git/config: commits inside the container will fail.${NC}"
        continue
    fi
    default="$(git -C "$PROJECT_ROOT" config --global --get "$key" || true)"
    read -r -p "Git $key for this repo${default:+ [$default]}: " value
    value="${value:-$default}"
    if [ -z "$value" ]; then
        echo -e "${RED}$key is required for commits inside the container.${NC}" >&2
        exit 1
    fi
    git -C "$PROJECT_ROOT" config --local "$key" "$value"
    identity_changed=true
done

COMPOSE=(docker compose -p "$COMPOSE_PROJECT"
    -f "$SCRIPT_DIR/docker-compose.yml"
    -f "$SCRIPT_DIR/compose.ssh.yml")
if [ "$docker_mode" = true ]; then
    COMPOSE+=(-f "$SCRIPT_DIR/compose.docker.yml")
fi

USER_UID="$(id -u)"
USER_GID="$(id -g)"
if [ "$USER_UID" -eq 0 ] || [ "$USER_GID" -eq 0 ]; then
    echo -e "${YELLOW}Running as root: building the image for UID/GID 1000:1000 instead, so the image's root user is not remapped.${NC}"
    USER_UID=1000
    USER_GID=1000
fi
export USER_UID USER_GID

# ── SSH: make sure a host agent is running and holds a key ───────────────────
# ssh-add -l exits 0 (has keys), 1 (no keys) or 2 (no agent reachable).
agent_status() { local s=0; ssh-add -l >/dev/null 2>&1 || s=$?; echo "$s"; }

if [ -z "${SSH_AUTH_SOCK:-}" ] || [ "$(agent_status)" -eq 2 ]; then
    # No session agent: use one at a fixed path, so later runs find it again
    # instead of starting an agent per run.
    SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-$HOME/.ssh}/agent-apropos-ssh-agent.sock"
    export SSH_AUTH_SOCK
    if [ "$(agent_status)" -eq 2 ]; then
        rm -f "$SSH_AUTH_SOCK"
        ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null
        echo -e "${GREEN}Started ssh-agent on ${SSH_AUTH_SOCK}${NC}"
    fi
fi
if [ "$(agent_status)" -eq 1 ]; then
    echo -e "${GREEN}The ssh-agent holds no keys; loading your default key...${NC}"
    if ! ssh-add; then
        echo -e "${RED}ssh-add failed. Load a key yourself (ssh-add <path>) and rerun.${NC}" >&2
        exit 1
    fi
fi
export HOST_SSH_AUTH_SOCK="$SSH_AUTH_SOCK"

GH_ENV_FILE="$HOME/.config/NEXL-LTS/agent-apropos/gh.env"
if [ ! -f "$GH_ENV_FILE" ]; then
    echo -e "${YELLOW}No $GH_ENV_FILE (GH_TOKEN=...): gh inside the container will be unauthenticated.${NC}"
elif [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    echo -e "${YELLOW}GH_TOKEN/GITHUB_TOKEN in this shell isn't passed in; the container uses $GH_ENV_FILE.${NC}"
fi

if [ "$docker_mode" = true ]; then
    echo -e "${YELLOW}--docker: the container runs PRIVILEGED. With dockerd inside, it is not a boundary between Claude and this host.${NC}"
fi

# ── Build and start ──────────────────────────────────────────────────────────
if [ "$rebuild" = true ]; then
    echo -e "${GREEN}Rebuilding the image from scratch...${NC}"
    "${COMPOSE[@]}" build --pull --no-cache
    "${COMPOSE[@]}" up --detach --force-recreate
else
    # --build is a cache hit unless the Dockerfile changed; `up` recreates the
    # container only when its image or config changed (e.g. toggling --docker).
    up_args=(--detach --build)
    # git rewrote .git/config as a new file; a running container's bind mount
    # still shows the old one until it's recreated.
    if [ "$identity_changed" = true ]; then
        up_args+=(--force-recreate)
    fi
    "${COMPOSE[@]}" up "${up_args[@]}"
fi

if [ "$docker_mode" = true ]; then
    echo -e "${GREEN}Waiting for dockerd inside the container...${NC}"
    timeout=90
    until "${COMPOSE[@]}" exec -T "$SERVICE" docker info &>/dev/null; do
        timeout=$((timeout - 1))
        if [ "$timeout" -le 0 ]; then
            echo -e "${RED}dockerd did not start within 90s. Recent container logs:${NC}" >&2
            "${COMPOSE[@]}" logs --tail 40 "$SERVICE" >&2 || true
            exit 1
        fi
        sleep 1
    done
fi

"${COMPOSE[@]}" exec -T --user vscode "$SERVICE" .devcontainer/postStartCommand.sh

# %q so the line stays copy-pasteable from a checkout path containing spaces.
printf -v stop_command '%q ' "${COMPOSE[@]}"
echo -e "${GREEN}The container outlives this shell: rerun this script to get back in.${NC}"
echo -e "${GREEN}Stop it with: ${stop_command}down${NC}"

# Herdr can't see the agent inside the container, only `docker compose`, so
# name it on this host-side process. Set only for agents, never for a shell.
case "$(basename "${command[0]}")" in
    claude) export HERDR_AGENT=claude ;;
esac
exec "${COMPOSE[@]}" exec --user vscode "$SERVICE" "${command[@]}"
