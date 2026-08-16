#!/usr/bin/env bats
#
# Tests for .claude/hooks/deny-secret-read.sh — the PreToolUse guard that
# refuses any tool call reading .devcontainer/.env (the devcontainer's
# gitignored credential store).
#
# Deterministic and offline: the hook only ever inspects the JSON payload on
# stdin, so nothing here touches a real .env, a container, or the network.
#
# The two outcomes under test are "denied" (a PreToolUse deny decision on
# stdout, exit 0) and "allowed" (no output at all, exit 0). A guard that is
# merely quiet is a guard that is off, so every allow case asserts empty output
# and every deny case asserts the decision field itself.

bats_require_minimum_version 1.5.0

bats_load_library bats-support
bats_load_library bats-assert

setup() {
  HOOK="$BATS_TEST_DIRNAME/../deny-secret-read.sh"
}

# Assert the payload was refused: a well-formed PreToolUse deny decision.
assert_denied() {
  assert_success
  assert_equal "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" "PreToolUse"
  assert_equal "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
  refute_output --partial '"permissionDecisionReason":""'
}

# Assert the payload was let through: silence is how a PreToolUse hook abstains.
assert_allowed() {
  assert_success
  assert_output ""
}

read_payload() {
  jq -nc --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p}}'
}

bash_payload() {
  jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

@test "denies a Read of the relative path" {
  run --separate-stderr bash "$HOOK" <<<"$(read_payload '.devcontainer/.env')"
  assert_denied
}

@test "denies a Read of the absolute path" {
  run --separate-stderr bash "$HOOK" <<<"$(read_payload '/home/dev/agent-apropos/.devcontainer/.env')"
  assert_denied
}

@test "denies a Read of a path needing normalization" {
  run --separate-stderr bash "$HOOK" <<<"$(read_payload './repo//./.devcontainer/.env')"
  assert_denied
}

@test "denies an Edit of the secret" {
  run --separate-stderr bash "$HOOK" \
    <<<"$(jq -nc '{tool_name:"Edit",tool_input:{file_path:".devcontainer/.env",old_string:"a",new_string:"b"}}')"
  assert_denied
}

@test "denies a Write to the secret" {
  run --separate-stderr bash "$HOOK" \
    <<<"$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/repo/.devcontainer/.env",content:"x"}}')"
  assert_denied
}

@test "denies a Grep pointed straight at the secret" {
  run --separate-stderr bash "$HOOK" \
    <<<"$(jq -nc '{tool_name:"Grep",tool_input:{pattern:"KEY",path:".devcontainer/.env"}}')"
  assert_denied
}

@test "denies a Bash command that cats the secret" {
  run --separate-stderr bash "$HOOK" <<<"$(bash_payload 'cat .devcontainer/.env')"
  assert_denied
}

@test "denies a Bash command that quotes the secret path" {
  run --separate-stderr bash "$HOOK" <<<"$(bash_payload 'grep KEY "/repo/.devcontainer/.env" | head -1')"
  assert_denied
}

@test "denies a Bash command that sources the secret" {
  run --separate-stderr bash "$HOOK" <<<"$(bash_payload 'set -a; . ./.devcontainer/.env; set +a')"
  assert_denied
}

# The rule is about the path reached, not the program reading it, so every
# stream editor / dumper / inline interpreter falls out of the same check.
@test "denies readers other than cat" {
  local reader
  for reader in \
    "sed -n '1,5p' .devcontainer/.env" \
    "awk -F= '{print \$2}' .devcontainer/.env" \
    "head -5 .devcontainer/.env" \
    "tail -n2 .devcontainer/.env" \
    "less .devcontainer/.env" \
    "xxd .devcontainer/.env" \
    "strings .devcontainer/.env" \
    "od -c .devcontainer/.env" \
    "python3 -c \"print(open('.devcontainer/.env').read())\"" ; do
    run --separate-stderr bash "$HOOK" <<<"$(bash_payload "$reader")"
    assert_denied
  done
}

# Two ways to reach the file without ever spelling its path.
@test "denies entering the directory and naming the file bare" {
  run --separate-stderr bash "$HOOK" <<<"$(bash_payload 'cd .devcontainer && sed -n p .env')"
  assert_denied
}

@test "denies a recursive content sweep of the directory" {
  local sweep
  for sweep in \
    'grep -r ANTHROPIC .devcontainer/' \
    'grep -rn KEY .devcontainer' \
    'rg TOKEN .devcontainer' \
    'cat .devcontainer/*' ; do
    run --separate-stderr bash "$HOOK" <<<"$(bash_payload "$sweep")"
    assert_denied
  done
}

# ...without swallowing ordinary work in that directory.
@test "allows naming a specific non-secret file in the directory" {
  local ok
  for ok in \
    'cat .devcontainer/docker-compose.yml' \
    'grep env_file .devcontainer/docker-compose.yml' \
    'bash .devcontainer/initialize.sh' \
    'ls .devcontainer/' \
    'cd .devcontainer && cat Dockerfile' \
    'cd .devcontainer && cat .env.example' ; do
    run --separate-stderr bash "$HOOK" <<<"$(bash_payload "$ok")"
    assert_allowed
  done
}

@test "allows a bare .env token unrelated to the devcontainer" {
  run --separate-stderr bash "$HOOK" <<<"$(bash_payload 'cd e2e/project && cat .env')"
  assert_allowed
}

# The trailing-boundary check exists so the guard stays narrow: neighbouring
# files in the same directory are ordinary source, not credentials.
@test "allows a Read of a sibling whose name merely starts with .env" {
  run --separate-stderr bash "$HOOK" <<<"$(read_payload '.devcontainer/.envrc')"
  assert_allowed
}

@test "allows a Bash command naming .env.example" {
  run --separate-stderr bash "$HOOK" <<<"$(bash_payload 'cat .devcontainer/.env.example')"
  assert_allowed
}

@test "allows a .env outside .devcontainer" {
  run --separate-stderr bash "$HOOK" <<<"$(read_payload '/repo/e2e/project/.env')"
  assert_allowed
}

@test "allows an unrelated Read" {
  run --separate-stderr bash "$HOOK" <<<"$(read_payload 'src/agent_apropos/cli.cr')"
  assert_allowed
}

@test "allows an unrelated Bash command" {
  run --separate-stderr bash "$HOOK" <<<"$(bash_payload 'make check')"
  assert_allowed
}

@test "allows a tool call with no path-shaped input" {
  run --separate-stderr bash "$HOOK" <<<"$(jq -nc '{tool_name:"TodoWrite",tool_input:{todos:[]}}')"
  assert_allowed
}

@test "tolerates an empty payload" {
  run --separate-stderr bash "$HOOK" </dev/null
  assert_allowed
}

@test "tolerates a payload that is not JSON" {
  run --separate-stderr bash "$HOOK" <<<'not json at all'
  assert_allowed
}

# A PATH holding only `bash` (to launch the hook) and `cat` (its one external
# call), with no jq to parse the payload. The rest is bash builtins.
jqless_path() {
  local stub="$BATS_TEST_TMPDIR/jqless"
  mkdir -p "$stub"
  ln -sf "$(command -v bash)" "$stub/bash"
  ln -sf "$(command -v cat)" "$stub/cat"
  printf '%s' "$stub"
}

# Without jq the hook cannot parse anything, so it must fall back to matching the
# raw payload rather than going quiet — a guard that fails open is not a guard.
# Both the decision and the reason then travel the exit-2 blocking convention.
@test "still denies without jq on PATH" {
  run --separate-stderr env PATH="$(jqless_path)" bash "$HOOK" \
    <<<"$(read_payload '.devcontainer/.env')"
  assert_equal "$status" 2
  assert_output ""
  assert [ -n "$stderr" ]
}

@test "still allows an unrelated call without jq on PATH" {
  run --separate-stderr env PATH="$(jqless_path)" bash "$HOOK" \
    <<<"$(read_payload 'src/agent_apropos/cli.cr')"
  assert_allowed
}

# The fallback matches the whole payload rather than a parsed field, so it is the
# path most at risk of widening into a blunt substring check. Pin the siblings.
@test "still allows .env.example without jq on PATH" {
  run --separate-stderr env PATH="$(jqless_path)" bash "$HOOK" \
    <<<"$(read_payload '.devcontainer/.env.example')"
  assert_allowed
}

@test "still allows .envrc without jq on PATH" {
  run --separate-stderr env PATH="$(jqless_path)" bash "$HOOK" \
    <<<"$(read_payload '.devcontainer/.envrc')"
  assert_allowed
}
