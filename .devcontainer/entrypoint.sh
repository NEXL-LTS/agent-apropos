#!/bin/bash
set -euo pipefail

# Runs as root so it can start dockerd when asked, then drops to vscode for the
# container's real command. Nested Docker is opt-in: compose.docker.yml sets
# ENABLE_DOCKER=1 together with privileged mode (start.sh --docker).
if [ "${ENABLE_DOCKER:-0}" = 1 ]; then
  containerd > /var/log/containerd.log 2>&1 &
  dockerd > /var/log/dockerd.log 2>&1 &
  timeout=60
  until docker info &>/dev/null; do
    timeout=$((timeout - 1))
    if [ "$timeout" -le 0 ]; then
      echo "ERROR: dockerd did not start within 60s. ENABLE_DOCKER=1 needs a" >&2
      echo "privileged container — start it with .devcontainer/start.sh --docker." >&2
      tail -n 40 /var/log/dockerd.log >&2 || true
      exit 1
    fi
    sleep 1
  done
fi

exec gosu vscode "$@"
