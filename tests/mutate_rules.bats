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

  # The pass-rate case mutates a real source file in place: the engine swaps
  # each mutant in, runs the gate, and swaps the original back. A case that ends
  # between those two steps would leave a mutant in the working tree, so keep
  # our own copy and put it back whatever happens.
  SUBJECT="src/agent_apropos/matcher.cr"
  cp "$ROOT/$SUBJECT" "$BATS_TEST_TMPDIR/subject.bak"
}

teardown() {
  if [ -f "$BATS_TEST_TMPDIR/subject.bak" ]; then
    cp "$BATS_TEST_TMPDIR/subject.bak" "$ROOT/$SUBJECT"
  fi
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

# The whole-number percentage of generated mutants that survive the compile
# gate, for one subject and one gate command. Extra arguments select the rule
# set; with none, the engine loads its own shipped defaults.
pass_rate() {
  local subject="$1" gate="$2"
  shift 2
  rm -f "$OUT"/*.cr
  mutate "$subject" --mutantDir "$OUT" --noFastCheck --cmd "$gate" "$@" |
    sed -n 's/^Valid Percentage: \([0-9]*\).*/\1/p' | tail -1
}

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

  grep -qE '^[[:space:]]+break$' "$OUT"/*.cr || fail "no mutant inserted a bare break"
  grep -qE '^[[:space:]]+next$' "$OUT"/*.cr || fail "no mutant inserted a bare next"
}

# R2's accounting rule: an operator class is carried across or its absence is
# argued in the file. Enforced at the granularity the engine itself ships —
# one rules file per language — so a new upstream rules file cannot be adopted
# or declined silently.
@test "every rules file the engine ships is accounted for" {
  local python static accounted missing=()
  python="$(head -1 "$(command -v mutate)" | sed 's|^#!||')"
  static="$("$python" -c 'import universalmutator, os; print(os.path.join(os.path.dirname(universalmutator.__file__), "static"))')"
  [ -d "$static" ] || fail "could not locate the engine's shipped rules: $static"

  # Match inside an accounting block, not anywhere in the file: a bare substring
  # would let a filename mentioned in passing stand in for a decision about it.
  for file in "$static"/*.rules; do
    accounted="$(awk -v want="$(basename "$file")" '
      /^# (SOURCE|NO CRYSTAL COUNTERPART)/ { block = 1 }
      /^[^#]/ { block = 0 }
      block && index($0, want) { found = 1 }
      END { print found + 0 }' "$RULES")"
    [ "$accounted" = "1" ] || missing+=("$(basename "$file")")
  done

  assert_equal "${missing[*]-}" ""
}

# The accounting was done against one engine version. An upgrade can add or
# change an operator class, and nothing in the rules file would notice — so pin
# the version the accounting describes.
@test "the installed engine is the version the accounting was done against" {
  local pinned installed
  pinned="$(sed -n 's/^universalmutator==\([0-9.]*\).*/\1/p' "$ROOT/tool/mutate/requirements.txt")"
  [ -n "$pinned" ] || fail "could not read the pinned engine version"

  local engine_python
  engine_python="$(head -1 "$(command -v mutate)" | sed 's|^#!||')"
  installed="$("$engine_python" -c 'import importlib.metadata as m; print(m.version("universalmutator"))')"

  assert_equal "$installed" "$pinned"
}

@test "every declined operator class states why Crystal has no counterpart" {
  local declined carried
  declined="$(grep -c '^# NO CRYSTAL COUNTERPART' "$RULES")"
  carried="$(grep -c '^# SOURCE:' "$RULES")"

  [ "$declined" -gt 0 ] || fail "expected at least one recorded declination"
  [ "$carried" -gt "$declined" ] || fail "expected more carried classes than declined ones"
}

# The reason the rules file exists: the engine's stock rules are C-shaped, so
# most of what they generate is not Crystal and dies at the compile gate — every
# rejected mutant is a compile spent for nothing. Both sides are measured here
# in the same run, against the same module and the same gate the runner uses
# (scripts/mutate.sh), so the comparison cannot drift into comparing two
# different things. docs/mutation-testing.md records the current numbers.
@test "the Crystal rules beat the stock rules' compile-gate pass rate" {
  local subject="$SUBJECT"
  local spec_target="spec/agent_apropos/matcher_spec.cr"
  local gate crystal_rate stock_rate

  cd "$ROOT"
  gate="crystal tool format - < $subject > /dev/null 2>&1"
  gate="$gate && crystal build --no-codegen $spec_target > /dev/null 2>&1"

  crystal_rate="$(pass_rate "$subject" "$gate" --only "$RULES")"
  stock_rate="$(pass_rate "$subject" "$gate")"

  echo "compile-gate pass rate: Crystal rules ${crystal_rate}%, stock rules ${stock_rate}%" >&3

  # An absolute floor as well as the ratio: a stock rate of 0 would satisfy any
  # multiple of itself, so the relative test alone can pass over a broken run.
  [ "$stock_rate" -gt 0 ] || fail "the stock-rules baseline measured 0% — the comparison is vacuous"
  [ "$crystal_rate" -ge 20 ] ||
    fail "Crystal rules fell to ${crystal_rate}%, under the 20% floor"
  [ "$crystal_rate" -ge $((stock_rate * 3 / 2)) ] ||
    fail "Crystal rules at ${crystal_rate}% no longer beat stock rules (${stock_rate}%) by half again"
}
