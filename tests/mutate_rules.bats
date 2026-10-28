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

# Every line a mutant changed or inserted, one per line, so a case can assert on
# what one rule produced from one source line without the rest of the file.
mutated_lines() {
  local fixture="$FIXTURE_DIR/$1" mutant
  for mutant in "$OUT"/*.cr; do
    diff "$fixture" "$mutant" | sed -n 's/^> //p' || true
  done
}

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

@test "an abstract def's parameter names are never mutated, unlike a concrete def's" {
  cat >"$FIXTURE_DIR/abstract.cr" <<'CR'
abstract class Base
  abstract def diff(repo_root : Path, range : String) : String
  protected abstract def config_content(existing : String?, options : Init::Options) : String

  def concrete(a : Int32, b : Int32) : Int32
    a + b
  end
end
CR
  generate abstract.cr

  refute_regex "$(mutants)" 'abstract def diff\(\s*range'
  refute_regex "$(mutants)" 'abstract def config_content\(\s*options'
  assert_regex "$(mutants)" 'def concrete\(\s*b : Int32,a : Int32\)'
}

@test "a bare return is never rewritten to return nil, which it already is" {
  cat >"$FIXTURE_DIR/bare.cr" <<'CR'
def bare(value)
  puts value
  return
  return # nothing to hand back
end
CR
  generate bare.cr

  run mutated_lines bare.cr
  refute_line --partial 'return nil'
}

@test "a valued or guarded return still gets a return-nil mutant" {
  cat >"$FIXTURE_DIR/valued.cr" <<'CR'
def valued(value)
  return value
end
CR
  cat >"$FIXTURE_DIR/guarded.cr" <<'CR'
def guarded(value)
  return if value
end
CR
  generate valued.cr
  run mutated_lines valued.cr
  assert_line '  return nil'

  generate guarded.cr
  run mutated_lines guarded.cr
  assert_line '  return nil'
}

@test "digits inside an identifier are never treated as a numeric literal" {
  cat >"$FIXTURE_DIR/typed.cr" <<'CR'
def typed(a : Int32) : UInt64
  foo_2 + a
end
CR
  generate typed.cr

  run mutated_lines typed.cr
  refute_line --regexp 'Int(-1|0|1|\(32)'
  refute_line --regexp 'UInt(-1|0|1|\(64)'
  refute_line --regexp 'foo_(-1|0|1|\(2)'
}

@test "every digit run of a numeric literal still gets every literal mutant" {
  cat >"$FIXTURE_DIR/literals.cr" <<'CR'
def literals(a)
  a + 10
  a + 1_000
  a + 0x1F
  a + 1.5
  a + 10_000_i64
end
CR
  generate literals.cr

  run mutated_lines literals.cr
  assert_line '  a + 0'
  assert_line '  a + 1'
  assert_line '  a + -1'
  assert_line '  a + (10+1)'
  assert_line '  a + (10-1)'
  # Runs after a separator, a radix prefix, a decimal point, and an underscore
  # before a suffix: the shipped guard reached each of these.
  assert_line '  a + 1_0'
  assert_line '  a + 0x0F'
  assert_line '  a + 1.0'
  assert_line '  a + 10_1_i64'
}

@test "next before the end of an if with a statement after it is still inserted" {
  cat >"$FIXTURE_DIR/guarded_loop.cr" <<'CR'
def guarded_loop(values)
  values.each do |value|
    if value.empty?
      puts "empty"
    end
    puts value
  end
end
CR
  generate guarded_loop.cr

  # Skips the trailing `puts value` for empty values, so it is not equivalent.
  grep -qzP 'puts "empty"\n      next\n    end\n    puts value' "$OUT"/*.cr ||
    fail "no mutant inserted next as the last statement of the if"
}

@test "swapping two identical items is never generated, being whitespace-only" {
  cat >"$FIXTURE_DIR/same.cr" <<'CR'
def same(a, k)
  Array({String, String})
  {Agents::Agent, String, String}
  qux(a , a)
  bar(k=1, k=2)
  baz(k: 1, k: 2)
end
CR
  generate same.cr

  local mutant
  for mutant in "$OUT"/*.cr; do
    if diff -w -q "$FIXTURE_DIR/same.cr" "$mutant" >/dev/null; then
      fail "whitespace-only mutant: $(diff "$FIXTURE_DIR/same.cr" "$mutant" | sed -n 's/^> //p')"
    fi
  done
}

@test "swapping two different items is still generated" {
  cat >"$FIXTURE_DIR/differ.cr" <<'CR'
def differ(a, b, x, y)
  foo(a, b)
  {x, y}
  [1, 2]
  bar(k=1, j=2)
  baz(k: 1, j: 2)
  Array({Int32, String})
  qux(a, ab)
end
CR
  generate differ.cr

  run mutated_lines differ.cr
  assert_line 'def differ ( b,a, x, y)'
  assert_line '  foo ( b,a)'
  assert_line '   { y,x}'
  assert_line '   [ 2,1]'
  assert_line '  bar( j=1,k=2)'
  assert_line '  baz( j: 1,k: 2)'
  assert_line '  baz ( j: 2,k: 1)'
  assert_line '  Array( { String,Int32})'
  assert_line '  qux ( ab,a)'
}

@test "every rules file the engine ships is accounted for" {
  local python static accounted missing=()
  python="$(head -1 "$(command -v mutate)" | sed 's|^#!||')"
  static="$("$python" -c 'import universalmutator, os; print(os.path.join(os.path.dirname(universalmutator.__file__), "static"))')"
  [ -d "$static" ] || fail "could not locate the engine's shipped rules: $static"

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

# Both sides measured in one run, against the same module and the same gate the
# runner uses, so the comparison cannot drift.
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

  # A stock rate of 0 would satisfy any multiple of itself.
  [ "$stock_rate" -gt 0 ] || fail "the stock-rules baseline measured 0% — the comparison is vacuous"
  [ "$crystal_rate" -ge 20 ] ||
    fail "Crystal rules fell to ${crystal_rate}%, under the 20% floor"
  [ "$crystal_rate" -ge $((stock_rate * 3 / 2)) ] ||
    fail "Crystal rules at ${crystal_rate}% no longer beat stock rules (${stock_rate}%) by half again"
}
