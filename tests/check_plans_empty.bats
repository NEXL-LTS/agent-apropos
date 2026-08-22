#!/usr/bin/env bats
#
# Tests for scripts/check-plans-empty.sh — the gate that keeps plan documents
# from landing on main.
#
# Each case builds a throwaway git repo in the test tmpdir and runs the script
# inside it, so the assertions are about the script's own logic rather than the
# state of this repo (which, by the gate's own rule, is always clean).

bats_require_minimum_version 1.5.0

bats_load_library bats-support
bats_load_library bats-assert

setup() {
  CHECK="$BATS_TEST_DIRNAME/../scripts/check-plans-empty.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/docs/plans"
  git -C "$REPO" init --quiet
  git -C "$REPO" config user.email 'test@example.com'
  git -C "$REPO" config user.name 'Test'
}

# bats runs each test in its own subshell, so the cd is scoped to the case.
run_check() {
  cd "$REPO"
  run --separate-stderr bash "$CHECK"
}

commit_plan() {
  printf '# a plan\n' > "$REPO/docs/plans/$1"
  git -C "$REPO" add "docs/plans/$1"
  git -C "$REPO" commit --quiet -m "add $1"
}

@test "passes when no plan is committed" {
  run_check
  assert_success
  assert_equal "$output" ""
}

@test "fails and names every committed plan" {
  commit_plan 'first-plan.md'
  commit_plan 'second-plan.md'
  run_check
  assert_failure
  [[ "$stderr" == *"first-plan.md"* ]] || fail "expected the message to name first-plan.md: $stderr"
  [[ "$stderr" == *"second-plan.md"* ]] || fail "expected the message to name second-plan.md: $stderr"
}

# The point of gating on tracked files: writing a plan is a normal thing to be
# doing, and `make check` mid-plan must not fail because of it.
@test "ignores an untracked plan in the working tree" {
  printf '# a plan in progress\n' > "$REPO/docs/plans/wip-plan.md"
  run_check
  assert_success
}
