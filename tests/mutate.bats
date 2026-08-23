#!/usr/bin/env bats
#
# Tests for scripts/mutate.sh — the diff-scoped mutation gate.
#
# Each case builds a throwaway git repo in the test tmpdir and runs the real
# script inside it (the script resolves its own root with `git rev-parse`, so it
# operates on that repo, not this one). The mutation engine, the Crystal
# toolchain and `timeout` are replaced by stubs on PATH, so the suite is offline,
# deterministic, and about the runner's decisions rather than about whether a
# real mutant happened to die.

bats_require_minimum_version 1.5.0

bats_load_library bats-support
bats_load_library bats-assert

SCRIPT_UNDER_TEST() { printf '%s' "$BATS_TEST_DIRNAME/../scripts/mutate.sh"; }

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export STUB_LOG="$BATS_TEST_TMPDIR/crystal.log"
  : >"$STUB_LOG"

  make_stubs
  make_repo
}

# --- stubs -----------------------------------------------------------------

# The engine: replaces one line at a time with a marker line, honouring
# --lines and --mutantDir the way universalmutator does.
make_stubs() {
  mkdir -p "$STUBS"

  cat >"$STUBS/mutate" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
source=""; mdir="."; lines=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mutantDir) mdir="$2"; shift 2 ;;
    --lines) lines="$2"; shift 2 ;;
    --only | --cmd) shift 2 ;;
    -*) shift ;;
    *) source="$1"; shift ;;
  esac
done
[ -n "$lines" ] && cp "$lines" "$STUB_LINES_SEEN"
base="$(basename "${source%.cr}")"
total="$(wc -l <"$source")"
n=0
for line in $(seq 1 "$total"); do
  if [ -n "$lines" ] && ! grep -qx "[[:space:]]*$line[[:space:]]*" "$lines"; then continue; fi
  awk -v l="$line" -v text="${STUB_MUTANT_TEXT:-MUTANT}" \
    'NR == l { print text; next } { print }' "$source" >"$mdir/$base.mutant.$n.cr"
  echo "PROCESSING MUTANT: $line: original  ==>  ${STUB_MUTANT_TEXT:-MUTANT}...VALID"
  n=$((n + 1))
done
STUB

  # The toolchain: `tool format -` always parses; `spec` decides kill vs survive
  # from a marker in the (possibly mutated) source, so a case can arrange either
  # outcome without a compiler.
  cat >"$STUBS/crystal" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$STUB_LOG"
case "${1:-}" in
  tool) cat >/dev/null; exit 0 ;;
  spec) ;;
  *) exit 0 ;;
esac

source_text="$(cat src/lib/*.cr 2>/dev/null || true)"

if [ -n "${STUB_INTERRUPT_ON_MUTANT:-}" ] && [[ "$source_text" == *MUTANT* ]]; then
  kill -INT "$PPID"
  sleep 5
  exit 0
fi

if [ -n "${STUB_RED_BASELINE:-}" ]; then exit 1; fi
[[ "$source_text" == *MUTANT* ]] || exit 0

# A bare `crystal spec` is the whole suite; `crystal spec <file>` is a sibling.
if [ "$#" -eq 1 ]; then
  [ -n "${STUB_FULL_SUITE_KILLS:-}" ] && exit 1
  exit 0
fi
[ -n "${STUB_SIBLING_SURVIVES:-}" ] && exit 0
exit 1
STUB

  cat >"$STUBS/timeout" <<'STUB'
#!/usr/bin/env bash
# A mutant that never terminates: only the mutated run hangs, so the baseline
# still passes and the case is about scoring, not about aborting.
if [ -n "${STUB_MUTANT_TIMES_OUT:-}" ] && grep -q MUTANT src/lib/*.cr 2>/dev/null; then
  exit 124
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    -*) shift ;;
    *) shift; break ;;
  esac
done
exec "$@"
STUB

  chmod +x "$STUBS/mutate" "$STUBS/crystal" "$STUBS/timeout"
  export STUB_LINES_SEEN="$BATS_TEST_TMPDIR/lines-seen"
}

# --- fixture repo ----------------------------------------------------------

make_repo() {
  mkdir -p "$REPO/src/lib" "$REPO/spec/lib" "$REPO/tool/mutate" "$REPO/docs"
  git -C "$REPO" init --quiet
  git -C "$REPO" config user.email 'test@example.com'
  git -C "$REPO" config user.name 'Test'

  cat >"$REPO/src/lib/thing.cr" <<'CR'
def widen(value)
  value + 1
end
CR
  printf 'it works\n' >"$REPO/spec/lib/thing_spec.cr"
  # The sibling for the file case 3 adds later, so that case's diff is the new
  # source file alone and R17's spec-change widening stays out of it.
  printf 'it works\n' >"$REPO/spec/lib/fresh_spec.cr"
  printf 'a ==> b\n' >"$REPO/tool/mutate/crystal.rules"
  : >"$REPO/tool/mutate/ignore.txt"
  : >"$REPO/tool/mutate/no-spec.txt"
  : >"$REPO/tool/mutate/backfill.txt"
  printf '# docs\n' >"$REPO/docs/readme.md"

  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m 'base'
  BASE="$(git -C "$REPO" rev-parse HEAD)"
}

commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "${1:-change}"
}

run_gate() {
  cd "$REPO"
  PATH="$STUBS:$PATH" run --separate-stderr bash "$(SCRIPT_UNDER_TEST)" "$@"
}

spec_runs() { grep -c '^spec' "$STUB_LOG" || true; }

# --- scope -----------------------------------------------------------------

@test "a diff touching only documentation exits 0 without running a spec" {
  printf '# docs, revised\n' >"$REPO/docs/readme.md"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_output --partial 'nothing to mutate'
  assert_equal "$(spec_runs)" "0"
}

@test "a diff that only deletes source lines exits 0" {
  printf 'def widen(value)\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_output --partial 'nothing to mutate'
}

@test "a newly added source file has every one of its lines mutated" {
  printf 'one\ntwo\nthree\n' >"$REPO/src/lib/fresh.cr"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_equal "$(tr -d ' \n' <"$STUB_LINES_SEEN")" "123"
}

@test "a changed source line is mutated and a killed mutant passes the gate" {
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_output --partial '1 mutants generated, 1 killed, 0 surviving'
  assert_equal "$(tr -d ' \n' <"$STUB_LINES_SEEN")" "2"
}

# --- survivors -------------------------------------------------------------

@test "a surviving mutant fails the gate and names the mutation" {
  export STUB_SIBLING_SURVIVES=1
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all

  run_gate --base "$BASE"

  assert_failure 1
  [[ "$stderr" == *'src/lib/thing.cr:2'* ]] || fail "expected the report to name the line: $stderr"
  [[ "$stderr" == *'value + 2'* ]] || fail "expected the report to show the original: $stderr"
  [[ "$stderr" == *'MUTANT'* ]] || fail "expected the report to show the mutation: $stderr"
}

@test "a mutant killed only by the full suite is scored killed, not reported" {
  export STUB_SIBLING_SURVIVES=1 STUB_FULL_SUITE_KILLS=1
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_output --partial '1 killed, 0 surviving'
}

@test "a mutant whose spec run times out is counted as killed" {
  export STUB_SIBLING_SURVIVES=1 STUB_MUTANT_TIMES_OUT=1
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_output --partial '1 killed, 0 surviving'
}

@test "a spec target that fails on unmutated source aborts with its own error" {
  export STUB_RED_BASELINE=1
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all

  run_gate --base "$BASE"

  assert_failure 2
  [[ "$stderr" == *'does not pass against unmutated source'* ]] ||
    fail "expected the red-baseline error: $stderr"
}

@test "the source file is restored when the run is interrupted mid-mutant" {
  export STUB_INTERRUPT_ON_MUTANT=1
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all
  before="$(cat "$REPO/src/lib/thing.cr")"

  run_gate --base "$BASE"

  assert_equal "$(cat "$REPO/src/lib/thing.cr")" "$before"
}

# --- ignore list -----------------------------------------------------------

@test "a survivor matching a reviewed ignore-list entry passes the gate" {
  export STUB_SIBLING_SURVIVES=1
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  printf 'src/lib/thing.cr\t1\tvalue + 2\tMUTANT\tcannot change observable behaviour\n' \
    >"$REPO/tool/mutate/ignore.txt"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_output --partial '0 surviving'
}

@test "an ignore-list entry suppresses only the occurrence it names" {
  export STUB_SIBLING_SURVIVES=1
  printf 'def widen(value)\n  value + 2\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  printf 'src/lib/thing.cr\t1\tvalue + 2\tMUTANT\treviewed: the first one only\n' \
    >"$REPO/tool/mutate/ignore.txt"
  commit_all

  run_gate --base "$BASE"

  assert_failure 1
  assert_equal "$(grep -c 'src/lib/thing.cr:' <<<"$stderr")" "1"
  [[ "$stderr" == *'src/lib/thing.cr:3'* ]] || fail "expected the unreviewed occurrence: $stderr"
}

@test "an ignore-list entry whose original text is gone is reported as stale" {
  printf 'src/lib/thing.cr\t1\tvalue + 999\tMUTANT\tno longer present\n' \
    >"$REPO/tool/mutate/ignore.txt"
  commit_all

  run_gate --base "$BASE"

  assert_failure 2
  [[ "$stderr" == *'no longer matches any line'* ]] || fail "expected a stale-entry error: $stderr"
}

# --- reviewed lists --------------------------------------------------------

@test "a tracked source file with neither sibling spec nor exemption fails the run" {
  printf 'lonely\n' >"$REPO/src/lib/orphan.cr"
  commit_all

  run_gate --base "$BASE"

  assert_failure 2
  [[ "$stderr" == *'src/lib/orphan.cr has no sibling spec'* ]] ||
    fail "expected the missing-sibling error: $stderr"
}

@test "a reviewed exemption stands in for a missing sibling spec" {
  printf 'lonely\n' >"$REPO/src/lib/orphan.cr"
  printf 'src/lib/orphan.cr\tno mutable construct\n' >"$REPO/tool/mutate/no-spec.txt"
  commit_all

  run_gate --base "$BASE"

  assert_success
}

@test "an exemption naming a file that is no longer tracked is reported as stale" {
  printf 'src/lib/gone.cr\tdeleted last week\n' >"$REPO/tool/mutate/no-spec.txt"
  commit_all

  run_gate --base "$BASE"

  assert_failure 2
  [[ "$stderr" == *'no longer a tracked source file'* ]] || fail "expected a stale-exemption error: $stderr"
}

@test "a backfill-list entry naming a module that no longer exists is reported as stale" {
  printf 'src/lib/gone.cr\n' >"$REPO/tool/mutate/backfill.txt"
  commit_all

  run_gate --base "$BASE"

  assert_failure 2
  [[ "$stderr" == *'no longer exists'* ]] || fail "expected a stale-backfill error: $stderr"
}

@test "a module with no sibling spec falls back to the whole suite" {
  printf 'lonely\n' >"$REPO/src/lib/orphan.cr"
  printf 'src/lib/orphan.cr\tdeclaration only\n' >"$REPO/tool/mutate/no-spec.txt"
  commit_all

  run_gate --base "$BASE"

  assert_success
  grep -qx 'spec' "$STUB_LOG" || fail "expected a bare 'crystal spec' run: $(cat "$STUB_LOG")"
}

# --- spec-file changes (R17) -----------------------------------------------

@test "changing a backfilled module's spec mutates that module in full" {
  printf 'it works, harder\n' >"$REPO/spec/lib/thing_spec.cr"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_output --partial 'src/lib/thing.cr (whole file)'
  assert_output --partial '3 mutants generated'
}

@test "changing an un-backfilled module's spec generates no mutants" {
  printf 'src/lib/thing.cr\n' >"$REPO/tool/mutate/backfill.txt"
  printf 'it works, harder\n' >"$REPO/spec/lib/thing_spec.cr"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_output --partial 'nothing to mutate'
}

@test "the modules still awaiting a backfill are named in the report" {
  printf 'src/lib/thing.cr\n' >"$REPO/tool/mutate/backfill.txt"
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all

  run_gate --base "$BASE"

  assert_success
  assert_output --partial 'not yet backfilled to 100%: src/lib/thing.cr'
}

# --- base ref --------------------------------------------------------------

@test "no pull-request base ref is a distinct error, not an empty line set" {
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all
  unset GITHUB_BASE_REF

  run_gate

  assert_failure 2
  [[ "$stderr" == *'no base ref'* ]] || fail "expected the missing-base error: $stderr"
}

@test "GITHUB_BASE_REF supplies the base when no --base is passed" {
  git -C "$REPO" branch base-branch "$BASE"
  git -C "$REPO" update-ref refs/remotes/origin/base-branch "$BASE"
  printf 'def widen(value)\n  value + 2\nend\n' >"$REPO/src/lib/thing.cr"
  commit_all
  export GITHUB_BASE_REF=base-branch

  run_gate

  assert_success
  assert_output --partial '1 mutants generated'
}

@test "an explicit file argument mutates it in full, ignoring the diff" {
  run_gate src/lib/thing.cr

  assert_success
  assert_output --partial 'src/lib/thing.cr (whole file)'
  assert_output --partial '3 mutants generated'
}
