#!/usr/bin/env bash
#
# agent-apropos end-to-end test runner.
#
# Runs the layered bats suite in e2e/tests/. It proves, per layer, that agent-apropos
# delivers its convention and steers a real CLI agent run — see e2e/README.md.
#
# `bats` and the bats-support/bats-assert libraries are provided by the
# devcontainer image (.devcontainer/Dockerfile); BATS_LIB_PATH points at them.
#
# Usage:
#   bash e2e/run.sh                        # run the whole suite
#   bash e2e/run.sh --filter 'Layer 2'     # extra flags pass through to bats
#
# Live checks skip cleanly when a given CLI agent is unavailable, so this is
# safe to run anywhere the image provides bats.
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$E2E_DIR/.." && pwd)"
AGENT_APROPOS_BIN="$REPO_ROOT/bin/agent-apropos"

# bats resolves `bats_load_library` via BATS_LIB_PATH. The devcontainer image
# sets it (ENV), but default it to the image's install location too, so the suite
# runs even when that env var is not exported into the current shell.
export BATS_LIB_PATH="${BATS_LIB_PATH:-/usr/local/lib/bats}"

if ! command -v bats >/dev/null 2>&1; then
  echo "!! bats not found on PATH."
  echo "!! It ships in the devcontainer image (.devcontainer/Dockerfile) — rebuild it,"
  echo "!! or install bats-core + bats-support + bats-assert to run this suite."
  exit 127
fi

# e2e/project/.claude, .opencode, .gemini, .github/hooks, .codex, and
# CLAUDE.md are generated, not committed (see its .gitignore) — regenerate
# them here so the fixture is always wired for every agent before bats copies
# it per test, regardless of whether this machine has
# claude/opencode/gemini/copilot/codex installed (helpers.bash's
# require_live_<x> is what decides whether the *live* tests run; the wiring
# itself must exist either way). `--tool` is used explicitly rather than left
# to auto-detect for exactly that reason. `--claude-symlink` matters here:
# unlike OpenCode, Gemini, Copilot CLI, and Codex CLI, Claude Code does not
# fall back to AGENTS.md when no CLAUDE.md is reachable anywhere in the
# directory hierarchy, so without the symlink the live Claude tests would run
# with zero Layer 1 context. `--allow-outside-repo` is required because
# `project/agent-apropos.yml` deliberately points `conventions_dir` at
# `../conventions`, outside the sample repo (see e2e/README.md) — `Config`
# refuses to resolve an escaping conventions_dir without it (see
# docs/conventions/ for why), and passing it to `init` also bakes it into the
# hook commands `init` wires into `project/.claude` etc., so the live
# hook invocations below can keep resolving that same out-of-tree directory.
# All commands are idempotent.
[ -x "$AGENT_APROPOS_BIN" ] || ( cd "$REPO_ROOT" && make release >/dev/null )
"$AGENT_APROPOS_BIN" init --tool claude --tool opencode --tool gemini --tool copilot --tool codex \
  --claude-symlink --allow-outside-repo --repo-root "$E2E_DIR/project" >/dev/null
"$AGENT_APROPOS_BIN" generate --allow-outside-repo --repo-root "$E2E_DIR/project" >/dev/null

exec bats "$@" "$E2E_DIR/tests"
