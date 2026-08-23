#!/usr/bin/env bats
#
# Tests for tool/mutate/crystal.rules — the repo-owned operator set the
# mutation gate generates from.
#
# Unlike tests/mutate.bats, this suite drives the real engine and the real
# compiler: the thing under test is what the rules actually produce against
# Crystal source, which a stub could only restate. It is therefore minutes, not
# seconds, and deliberately sits outside `make check` (see the Makefile).

bats_require_minimum_version 1.5.0

bats_load_library bats-support
bats_load_library bats-assert

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  RULES="$ROOT/tool/mutate/crystal.rules"
  FIXTURE_DIR="$BATS_TEST_TMPDIR/fixture"
  OUT="$BATS_TEST_TMPDIR/mutants"
  mkdir -p "$FIXTURE_DIR" "$OUT"

  command -v mutate >/dev/null 2>&1 ||
    fail "the mutation engine is not on PATH; see tool/mutate/requirements.txt"
}

# Generate every mutant for $1 (a file written into the fixture dir), with no
# validity check, and leave them in $OUT. Generation alone is instant; the
# compile gate is what costs, and only one case pays for it.
generate() {
  local fixture="$FIXTURE_DIR/$1"
  rm -f "$OUT"/*.cr
  run mutate "$fixture" --only "$RULES" --mutantDir "$OUT" --noCheck --noFastCheck
  assert_success
  refute_output --partial 'FAILED TO COMPILE RULE'
  refute_output --partial 'DOES NOT MATCH EXPECTED FORMAT'
  refute_output --partial 'WARNING: Applying mutation raised'
}

mutants() { cat "$OUT"/*.cr; }

@test "every rules line the engine parses is a rule the engine accepts" {
  cat >"$FIXTURE_DIR/plain.cr" <<'CR'
def plain(value)
  value + 1
end
CR
  generate plain.cr
}

@test "each comparison and logical operator gets its counterpart" {
  cat >"$FIXTURE_DIR/ops.cr" <<'CR'
def ops(a, b)
  a && b
  a || b
  a < b
  a <= b
  a == b
  a != b
end
CR
  generate ops.cr
  local all
  all="$(mutants)"

  assert_regex "$all" 'a \|\| b'
  assert_regex "$all" 'a && b'
  assert_regex "$all" 'a > b'
  assert_regex "$all" 'a >= b'
  assert_regex "$all" 'a != b'
  assert_regex "$all" 'a == b'
}

@test "a return guard gets a guard-removal mutant" {
  cat >"$FIXTURE_DIR/guard.cr" <<'CR'
def guard(values)
  return nil if values.empty?
  values.first
end
CR
  generate guard.cr

  assert_regex "$(mutants)" '# return nil if values.empty\?'
}

@test "no mutant carries a C statement terminator" {
  cat >"$FIXTURE_DIR/loopy.cr" <<'CR'
def loopy(values)
  values.each do |value|
    puts value
  end
end
CR
  generate loopy.cr

  refute_regex "$(mutants)" 'break;'
  refute_regex "$(mutants)" 'continue;'
}

@test "loop control is inserted in Crystal's spelling" {
  cat >"$FIXTURE_DIR/loopy2.cr" <<'CR'
def loopy(values)
  values.each do |value|
    puts value
  end
end
CR
  generate loopy2.cr

  assert_regex "$(mutants)" '^ *break$'
  assert_regex "$(mutants)" '^ *next$'
}

# R2's accounting rule: an operator class is carried across or its absence is
# argued in the file. Enforced at the granularity the engine itself ships —
# one rules file per language — so a new upstream rules file cannot be adopted
# or declined silently.
@test "every rules file the engine ships is accounted for" {
  local python static missing=()
  python="$(head -1 "$(command -v mutate)" | sed 's|^#!||')"
  static="$("$python" -c 'import universalmutator, os; print(os.path.join(os.path.dirname(universalmutator.__file__), "static"))')"
  [ -d "$static" ] || fail "could not locate the engine's shipped rules: $static"

  for file in "$static"/*.rules; do
    grep -q "$(basename "$file")" "$RULES" || missing+=("$(basename "$file")")
  done

  assert_equal "${missing[*]-}" ""
}

@test "every declined operator class states why Crystal has no counterpart" {
  local declined carried
  declined="$(grep -c '^# NO CRYSTAL COUNTERPART' "$RULES")"
  carried="$(grep -c '^# SOURCE:' "$RULES")"

  [ "$declined" -gt 0 ] || fail "expected at least one recorded declination"
  [ "$carried" -gt "$declined" ] || fail "expected more carried classes than declined ones"
}

# The measured compile-gate pass rate. The stock universal rules produce
# C-shaped output that Crystal mostly rejects — 11.0% valid on this module,
# 16 of 145. The floor here is the number the Crystal rules actually deliver,
# with headroom; docs/mutation-testing.md records the current measurement and
# what still holds it down.
@test "the Crystal rules beat the stock rules' compile-gate pass rate" {
  local subject="$ROOT/src/agent_apropos/matcher.cr"
  local log="$BATS_TEST_TMPDIR/gate.log"

  cd "$ROOT"
  run mutate "$subject" --only "$RULES" --mutantDir "$OUT" --noFastCheck \
    --cmd "crystal tool format - < $subject > /dev/null 2>&1 && crystal build --no-codegen $subject > /dev/null 2>&1"
  assert_success
  printf '%s\n' "$output" >"$log"

  local percent
  percent="$(sed -n 's/^Valid Percentage: \([0-9]*\).*/\1/p' "$log" | tail -1)"
  [ -n "$percent" ] || fail "the engine reported no pass rate: $(tail -5 "$log")"

  echo "compile-gate pass rate: ${percent}% (stock universal rules: 11%)"
  [ "$percent" -gt 20 ] || fail "pass rate fell to ${percent}%, at or below the 20% floor"
}
