#!/usr/bin/env bash
#
# (Re)create one wired, git-initialized copy of e2e/project per CLI agent
# under /tmp/agent-apropos-manual/<agent>/, for manually driving a live agent
# by hand (interactively, or with its own -p/exec flag) instead of through
# bats. See README.md in this directory for how to actually run each one.
#
# Mirrors what e2e/tests/helpers.bash's new_sample("with") + agent-apropos generate
# do for the live bats suite, but persists the copies under a stable /tmp path
# instead of a throwaway bats temp dir, so they survive between manual runs.
#
# Conventions live INSIDE each copy this time, under a freshly random,
# non-descriptive folder name (never "docs"/"conventions"/anything else that
# reads as "look here") — a deliberately different isolation strategy from
# the live bats suite's (conventions_dir pointing at a real path *outside*
# the repo). That "outside the repo" framing, tried first in this rig, had a
# real downside: a citation like `Convention (../../conventions/foo.md):`
# told Claude in plain text that the source was outside its own repository,
# and at least one live run flagged that — combined with the AGENTS.md/
# CLAUDE.md note asking it to trust exactly such a citation — as a textbook
# prompt-injection pattern, and refused to apply the convention. Putting the
# docs inside the repo removes that specific "outside my repository" signal;
# the random folder name is what keeps them from being casually stumbled on
# by an agent's own directory listing / exploration, same intent as the
# outside-the-repo approach, different mechanism.
#
# The `conventions_dir` pointer itself lives at `.cache/agent-apropos.yml`,
# not a root-level `agent-apropos.yml` — an undocumented fallback location
# `Config` (src/agent_apropos/config.cr) checks only when the root file is
# absent. A root-level `agent-apropos.yml` is a plain, ordinary-looking file
# a curious agent's own exploration readily finds and reads (observed live
# with OpenCode: `ls` the repo root, `cat agent-apropos.yml`, then `cat` the
# random folder's contents directly) — handing it the exact location of the
# hidden docs regardless of how obscure the folder name is. `.cache/` reads
# as machine-generated, disposable output, so a config file there draws far
# less of that curiosity. This is an experiment scoped to this manual rig
# only — e2e/conventions/, e2e/project/, and the live bats suite's own
# with/without logic (e2e/tests/helpers.bash) are untouched; they still use a
# root-level agent-apropos.yml pointing outside the repo. Re-run any time
# e2e/conventions/ or e2e/project/ changes to pick up the edits (this also
# reshuffles the random folder name).

set -euo pipefail

command -v openssl >/dev/null 2>&1 || {
  echo "error: openssl is required (used to name the per-run conventions folder) but not found on PATH" >&2
  exit 1
}

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$E2E_DIR/.." && pwd)"
AGENT_APROPOS_BIN="$REPO_ROOT/bin/agent-apropos"
MANUAL_DIR="/tmp/agent-apropos-manual"

# A fresh, non-descriptive folder name each run — 12 lowercase hex chars, no
# dictionary word, nothing suggesting "rules" or "conventions".
CONVENTIONS_FOLDER="$(openssl rand -hex 6)"
echo "Conventions folder this run: $CONVENTIONS_FOLDER"

[ -x "$AGENT_APROPOS_BIN" ] || ( cd "$REPO_ROOT" && make release >/dev/null )

# Wire every supported tool into e2e/project/ itself first (same prep step
# e2e/run.sh does), so each per-agent copy below starts fully wired
# regardless of which agents happen to be installed on this machine.
"$AGENT_APROPOS_BIN" init --tool claude --tool opencode --tool gemini --tool copilot --tool codex \
  --claude-symlink --allow-outside-repo --repo-root "$E2E_DIR/project" >/dev/null
"$AGENT_APROPOS_BIN" generate --allow-outside-repo --repo-root "$E2E_DIR/project" >/dev/null

AGENTS=(claude opencode copilot codex gemini)
for agent in "${AGENTS[@]}"; do
  dir="$MANUAL_DIR/$agent"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -r "$E2E_DIR/project/." "$dir"/

  # e2e/project/agent-apropos.yml (committed source, `conventions_dir:
  # ../conventions`) came along with the cp -r above — meaningless once
  # copied here, and Config checks the root-level file BEFORE the
  # .cache/agent-apropos.yml fallback below, so it would otherwise shadow
  # it outright. Remove it: no root-level config file at all for this rig.
  rm -f "$dir/agent-apropos.yml"

  # Copy the actual convention docs INSIDE this copy, under the random
  # folder name, and point conventions_dir at it as a plain relative path —
  # no more pointing outside the repo (see the file header for why). The
  # pointer itself goes in .cache/agent-apropos.yml (the undocumented
  # fallback location).
  cp -r "$E2E_DIR/conventions" "$dir/$CONVENTIONS_FOLDER"
  mkdir -p "$dir/.cache"
  echo "conventions_dir: $CONVENTIONS_FOLDER" > "$dir/.cache/agent-apropos.yml"

  (
    cd "$dir"
    git init -q .
    git config user.email manual-test@example.com
    git config user.name manual-test
    git add -A
    git commit -qm sample
  ) >/dev/null

  # Regenerate the trigger index against the rewritten conventions_dir — the
  # copied .cache/agent-apropos/index.json still has doc paths relative to
  # e2e/project's own location and would otherwise silently fail to read any
  # rule body (matching still works off the cached glob patterns, but
  # injected content comes up empty).
  "$AGENT_APROPOS_BIN" generate --repo-root "$dir" >/dev/null
done

echo "Wired manual-test copies:"
for agent in "${AGENTS[@]}"; do
  echo "  $MANUAL_DIR/$agent"
done
