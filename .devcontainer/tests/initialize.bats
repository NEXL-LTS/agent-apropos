#!/usr/bin/env bats
#
# Tests for .devcontainer/initialize.sh — the host-side initializeCommand that
# pins USER_UID/USER_GID into .devcontainer/.env and makes sure ~/.claude.json
# is a file before docker-compose bind-mounts it.
#
# Deterministic and offline: no containers, no network, no credentials. Unlike
# e2e/tests/*.bats (live CLI agents, opt-in), this suite runs anywhere bats is
# available — it is part of `make check`.
#
# Every test runs the script against a throwaway repo root and a throwaway
# HOME, both under $BATS_TEST_TMPDIR. The script derives its own REPO_ROOT from
# ${BASH_SOURCE[0]}, so copying it into $TMP/repo/.devcontainer/ is what makes
# it operate on the fixture's .env rather than this repo's real one.

# `run --separate-stderr` (used to prove the mismatch warning goes to fd 2)
# needs this declared explicitly.
bats_require_minimum_version 1.5.0

bats_load_library bats-support
bats_load_library bats-assert

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  SCRIPT="$REPO/.devcontainer/initialize.sh"
  ENV_FILE="$REPO/.devcontainer/.env"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$REPO/.devcontainer" "$HOME"
  cp "$BATS_TEST_DIRNAME/../initialize.sh" "$SCRIPT"
}

# The values the script should converge on: this test process's own ids, since
# it stands in for the host user the script is matching the container to.
host_uid() { id -u; }
host_gid() { id -g; }

# Assert the script accepted the .env as already correct: no output on either
# stream, and not one byte rewritten. This is what distinguishes "understood
# the existing value" from "warned about it" or "appended a duplicate".
assert_accepted_unchanged() {
  local before
  before="$(cat "$ENV_FILE")"
  run --separate-stderr bash "$SCRIPT"
  assert_success
  assert_output ""
  assert_equal "$stderr" ""
  assert_equal "$(cat "$ENV_FILE")" "$before"
}

# --- ~/.claude.json -----------------------------------------------------------

@test "creates ~/.claude.json as a file when it is missing" {
  run bash "$SCRIPT"
  assert_success
  assert [ -f "$HOME/.claude.json" ]
}

@test "leaves an existing ~/.claude.json intact rather than truncating it" {
  printf '{"kept":true}\n' > "$HOME/.claude.json"
  run bash "$SCRIPT"
  assert_success
  run cat "$HOME/.claude.json"
  assert_output '{"kept":true}'
}

# The failure this whole step exists to prevent: Docker creates an empty
# directory at the bind-mount source when it is missing, and an earlier failed
# start can leave one behind. `touch` alone would not clear it — on a directory
# touch succeeds and just updates the mtime, so the broken mount would silently
# recur.
@test "replaces an empty ~/.claude.json directory with a file" {
  mkdir "$HOME/.claude.json"
  run bash "$SCRIPT"
  assert_success
  assert [ -f "$HOME/.claude.json" ]
}

# A non-empty directory is somebody's data, not Docker's leftover, so it is
# reported rather than deleted.
@test "warns about a non-empty ~/.claude.json directory instead of deleting it" {
  mkdir "$HOME/.claude.json"
  printf 'mine\n' > "$HOME/.claude.json/keepme"
  run --separate-stderr bash "$SCRIPT"
  assert_success
  assert_regex "$stderr" 'is a non-empty directory'
  assert [ -d "$HOME/.claude.json" ]
  assert_equal "$(cat "$HOME/.claude.json/keepme")" mine
}

# --- creating .env ------------------------------------------------------------

@test "creates .env mode 0600 and pins both ids to the host user" {
  run bash "$SCRIPT"
  assert_success
  assert_output --partial "set USER_UID=$(host_uid)"
  assert_output --partial "set USER_GID=$(host_gid)"
  assert_equal "$(stat -c '%a' "$ENV_FILE")" 600
  run cat "$ENV_FILE"
  assert_line "USER_UID=$(host_uid)"
  assert_line "USER_GID=$(host_gid)"
}

@test "creates .env mode 0600 even under a permissive caller umask" {
  run bash -c "umask 000; bash '$SCRIPT'"
  assert_success
  assert_equal "$(stat -c '%a' "$ENV_FILE")" 600
}

# The `umask 077` at creation is what keeps .env from ever existing as 0666,
# even briefly, on a host with a permissive umask — a real window, since the
# developer's own tokens get added to this file later. The closing `chmod 600`
# would hide a regression there from the test above, so neutralize chmod with a
# no-op shim on PATH and check the mode the file was *born* with.
@test "creates .env 0600 at birth, before the closing chmod" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/chmod"
  chmod +x "$BATS_TEST_TMPDIR/bin/chmod"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "umask 000; bash '$SCRIPT'"
  assert_success
  assert_equal "$(stat -c '%a' "$ENV_FILE")" 600
}

@test "tightens a pre-existing world-readable .env to 0600" {
  printf 'GH_TOKEN=abc\n' > "$ENV_FILE"
  chmod 644 "$ENV_FILE"
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(stat -c '%a' "$ENV_FILE")" 600
}

# --- re-running ---------------------------------------------------------------

@test "is idempotent: a second run says nothing and changes nothing" {
  bash "$SCRIPT"
  local before
  before="$(cat "$ENV_FILE")"
  run --separate-stderr bash "$SCRIPT"
  assert_success
  assert_output ""
  assert_equal "$stderr" ""
  assert_equal "$(cat "$ENV_FILE")" "$before"
}

@test "preserves unrelated entries already in .env" {
  printf 'GH_TOKEN="abc"\nANTHROPIC_API_KEY="sk-xyz"\n' > "$ENV_FILE"
  run bash "$SCRIPT"
  assert_success
  run cat "$ENV_FILE"
  assert_line 'GH_TOKEN="abc"'
  assert_line 'ANTHROPIC_API_KEY="sk-xyz"'
  assert_line "USER_UID=$(host_uid)"
  assert_line "USER_GID=$(host_gid)"
}

@test "does not glue its append onto a last line with no trailing newline" {
  printf 'GH_TOKEN=abc' > "$ENV_FILE"
  run bash "$SCRIPT"
  assert_success
  run cat "$ENV_FILE"
  assert_line 'GH_TOKEN=abc'
  assert_line "USER_UID=$(host_uid)"
  refute_line --partial 'abcUSER_UID'
}

@test "treats a commented-out pin as absent and adds a real one" {
  printf '# USER_UID=4242\n' > "$ENV_FILE"
  run bash "$SCRIPT"
  assert_success
  run cat "$ENV_FILE"
  assert_line '# USER_UID=4242'
  assert_line "USER_UID=$(host_uid)"
}

# --- value normalization ------------------------------------------------------
#
# Compose strips surrounding whitespace and one layer of matching quotes from
# an env_file value, so each of these is the same value the container would
# receive from a bare USER_UID=<n>. A hand-edited .env must not be reported as
# a mismatch, and must not be rewritten.

@test "accepts a double-quoted pin that matches the host" {
  printf 'USER_UID="%s"\nUSER_GID="%s"\n' "$(host_uid)" "$(host_gid)" > "$ENV_FILE"
  assert_accepted_unchanged
}

@test "accepts a single-quoted pin that matches the host" {
  printf "USER_UID='%s'\nUSER_GID='%s'\n" "$(host_uid)" "$(host_gid)" > "$ENV_FILE"
  assert_accepted_unchanged
}

@test "accepts a pin padded with spaces and tabs" {
  printf 'USER_UID=  "%s"  \nUSER_GID=\t%s\t\n' "$(host_uid)" "$(host_gid)" > "$ENV_FILE"
  assert_accepted_unchanged
}

@test "accepts a pin from an .env saved with CRLF endings" {
  printf 'USER_UID=%s\r\nUSER_GID=%s\r\n' "$(host_uid)" "$(host_gid)" > "$ENV_FILE"
  assert_accepted_unchanged
}

# --- genuine mismatch ---------------------------------------------------------

@test "warns on a genuinely different pin, on stderr, without overwriting it" {
  printf 'USER_UID=4242\nUSER_GID=4243\n' > "$ENV_FILE"
  run --separate-stderr bash "$SCRIPT"
  assert_success
  assert_output ""
  assert_regex "$stderr" "pins USER_UID=4242, but your host user is $(host_uid)"
  assert_regex "$stderr" "pins USER_GID=4243, but your host user is $(host_gid)"
  run cat "$ENV_FILE"
  assert_line 'USER_UID=4242'
  assert_line 'USER_GID=4243'
  refute_line "USER_UID=$(host_uid)"
}

@test "reports the unquoted value when a quoted pin genuinely differs" {
  printf 'USER_UID="4242"\nUSER_GID="4243"\n' > "$ENV_FILE"
  run --separate-stderr bash "$SCRIPT"
  assert_success
  assert_regex "$stderr" 'pins USER_UID=4242,'
  refute_regex "$stderr" 'pins USER_UID="4242"'
}

# --- non-Linux hosts ----------------------------------------------------------
#
# Docker Desktop remaps bind-mount ownership to the container user, so pinning
# a UID there is pointless and would only force a rebuild. `uname` is shimmed
# ahead of the real one on PATH to stand in for a macOS host.

@test "on a non-Linux host it touches ~/.claude.json then exits without an .env" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$BATS_TEST_TMPDIR/bin/uname"
  chmod +x "$BATS_TEST_TMPDIR/bin/uname"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPT"
  assert_success
  assert_output ""
  assert [ -f "$HOME/.claude.json" ]
  refute [ -e "$ENV_FILE" ]
}
