#!/usr/bin/env bash
# PreToolUse hook: refuse any tool call that would read .devcontainer/.env.
#
# That file is the devcontainer's credential store — gitignored, loaded into the
# container via docker-compose `env_file`, and holding live agent API tokens. It
# has no business reaching a model's context, so this hook denies the call
# outright rather than injecting advice.
#
# Unlike the informational hooks here (ameba-review.sh, agent-apropos hook post),
# this one FAILS CLOSED: it is a guard, and a guard that goes quiet when jq is
# missing is worse than no guard. When the payload cannot be parsed it falls back
# to a raw substring check on the whole hook input and still denies.
set -uo pipefail
export LC_ALL=C

# The one path this hook protects, as it appears relative to the repo root.
SECRET_REL=".devcontainer/.env"

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

# Emit the PreToolUse deny decision and stop. Falling back to exit 2 (with the
# reason on stderr) keeps the denial working when jq cannot build the JSON.
deny() {
  if command -v jq >/dev/null 2>&1 && jq -n --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null; then
    exit 0
  fi
  printf '%s\n' "$1" >&2
  exit 2
}

reason="$SECRET_REL holds live agent credentials for the devcontainer and is off limits. \
Read .devcontainer/docker-compose.yml or .devcontainer/initialize.sh to see which keys it is expected to define."

# No jq means no structured view of the payload. Fall back to matching the raw
# input so a missing dependency cannot silently disable the guard.
if ! command -v jq >/dev/null 2>&1; then
  case "$input" in
    *"$SECRET_REL"*) deny "$reason" ;;
  esac
  exit 0
fi

# Collapse `//` and `/./` and drop a leading `./`, so `./.devcontainer/.env` and
# `/repo//./.devcontainer/.env` both compare equal to the plain relative form.
normalize() {
  local p="$1"
  while [ "$p" != "${p//\/\//\/}" ]; do p="${p//\/\//\/}"; done
  while [ "$p" != "${p//\/.\//\/}" ]; do p="${p//\/.\//\/}"; done
  printf '%s' "${p#./}"
}

is_secret_path() {
  case "$(normalize "$1")" in
    "$SECRET_REL"|*/"$SECRET_REL") return 0 ;;
  esac
  return 1
}

# File-addressing tools (Read, Edit, Write, Grep, NotebookEdit) name their target
# in one of these fields; whichever is present is checked the same way.
for field in file_path path notebook_path; do
  target="$(printf '%s' "$input" | jq -r --arg f "$field" '.tool_input[$f] // empty' 2>/dev/null || true)"
  [ -n "$target" ] || continue
  is_secret_path "$target" && deny "$reason"
done

# Bash names its target inside a shell string, so the check is necessarily a
# textual one: any command mentioning the path is refused. The trailing boundary
# keeps siblings like .devcontainer/.envrc and .devcontainer/.env.example free.
command_text="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
if [ -n "$command_text" ] && [[ $command_text =~ \.devcontainer/\.env([^[:alnum:]_.-]|$) ]]; then
  deny "$reason"
fi

exit 0
