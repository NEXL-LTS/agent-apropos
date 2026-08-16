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

# The path as it appears in a payload, with a trailing boundary that keeps
# siblings like .envrc and .env.example out of the match. Used both for Bash
# command strings and for the jq-less fallback over the whole payload.
SECRET_PATTERN='\.devcontainer/\.env([^[:alnum:]_.-]|$)'

# No jq means no structured view of the payload. Fall back to matching the raw
# input so a missing dependency cannot silently disable the guard. The bound
# match keeps this degraded mode as narrow as the parsed one.
if ! command -v jq >/dev/null 2>&1; then
  [[ $input =~ $SECRET_PATTERN ]] && deny "$reason"
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
# textual one. Three shapes are refused; all three are about the path the command
# would reach, not the program doing the reading, so `sed`, `awk`, `head`, `xxd`,
# an inline `python -c` and anything else are covered by the same rules.
command_text="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$command_text" ] || exit 0

# 1. The path spelled out, absolute or relative.
[[ $command_text =~ $SECRET_PATTERN ]] && deny "$reason"

# 2. The directory entered first, then the file named bare: `cd .devcontainer &&
#    cat .env`. Requiring both halves keeps an unrelated `.env` elsewhere in the
#    repo readable. A leading `/` disqualifies the token, so the `.env.example`
#    and `.devcontainer/.env`-prefixed forms stay with rule 1.
if [[ $command_text =~ \.devcontainer ]] &&
  [[ $command_text =~ (^|[^[:alnum:]_./-])\.env([^[:alnum:]_.-]|$) ]]; then
  deny "$reason"
fi

# 3. A content-wide sweep of the directory, which reads the secret without ever
#    naming it: `grep -r ... .devcontainer/`, `rg ... .devcontainer`, or a glob
#    like `cat .devcontainer/*`. Narrowing the command to a specific file is the
#    intended way through.
if [[ $command_text =~ \.devcontainer ]] &&
  [[ $command_text =~ (grep[^;|]*[[:space:]]-[[:alnum:]]*[rR]|(^|[^[:alnum:]_.-])(rg|ag|ack)([[:space:]]|$)|\.devcontainer/\*) ]]; then
  deny "$reason"
fi

exit 0

exit 0
