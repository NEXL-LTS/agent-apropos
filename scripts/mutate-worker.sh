#!/usr/bin/env bash
# Mutation-testing worker: generates and tests every mutant for one source
# file (optionally restricted to a set of lines), inside whatever directory
# it is run from. scripts/mutate.sh is the public entry point; it invokes
# this script once per shard (directly in the repo root for a small target,
# or once per parallel worktree for a large one) and aggregates the results
# this script prints on stdout. Not meant to be run by hand.
#
# Usage: mutate-worker.sh <source-file> [<lines-file>]
#
# Must be run with the repo root (or a worktree of it) as the current
# directory. Prints, on stdout:
#   COUNTS<TAB><generated><TAB><valid><TAB><killed><TAB><timed_out>
#   SURVIVOR<TAB><src:line><TAB><original><TAB><mutated>   (zero or more)
set -euo pipefail

RULES="tool/mutate/crystal.rules"
IGNORE_FILE="tool/mutate/ignore.json"

MUTANT_SIBLING_TIMEOUT=30
MUTANT_SUITE_TIMEOUT=180
BASELINE_SPEC_TIMEOUT=900

die() {
  echo "error: $*" >&2
  exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: mutate-worker.sh <source-file> [<lines-file>]"
src="$1"
lines_file="${2:-}"

# `join` rather than `@tsv`, which would escape the backslash in a folded `\n`.
# Crystal source carries no tabs — the formatter forbids them — so a real tab is
# an unambiguous delimiter for these single-line fields.
records() { jq -r "$2 | join(\"\t\")" "$1"; }

field() { printf '%s' "$1" | cut -d'	' -f"$2"; }

sibling_spec_for() {
  local src="$1"
  printf 'spec/%s_spec.cr' "${src#src/}" | sed 's/\.cr_spec\.cr$/_spec.cr/'
}

spec_target_for() {
  local spec
  spec="$(sibling_spec_for "$1")"
  [ -f "$spec" ] && { printf '%s' "$spec"; return 0; }
  printf 'spec'
}

ignored_mutant() {
  local path="$1" occurrence="$2" original="$3" mutated="$4" entry
  while IFS= read -r entry; do
    [ "$(field "$entry" 1)" = "$path" ] || continue
    [ "$(field "$entry" 2)" = "$occurrence" ] || continue
    [ "$(field "$entry" 3)" = "$original" ] || continue
    [ "$(field "$entry" 4)" = "$mutated" ] || continue
    return 0
  done < <(records "$IGNORE_FILE" '.equivalent[] | [.path, (.occurrence|tostring), .original, .mutated]')
  return 1
}

mutant_line_from_log() {
  local log="$1" mutant="$2"
  sed -n "s|^PROCESSING MUTANT: \([0-9]*\):.*\[written to ${mutant//|/\|}\].*|\1|p" "$log" | head -n1
}

# Fallback only. Wrong for an insertion mutant whose inserted line equals the one
# below it, which is why the log is preferred.
mutant_line() {
  awk 'NR == FNR { original[FNR] = $0; next }
       $0 != original[FNR] { print FNR; exit }' "$1" "$2"
}

# Inserted lines fold onto one, so an ignore-list key stays one record.
mutant_text() {
  local source="$1" mutant="$2" line="$3" span
  span=$(($(wc -l <"$mutant") - $(wc -l <"$source") + 1))
  sed -n "${line},$((line + span - 1))p" "$mutant" |
    awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); printf "%s%s", sep, $0; sep = "\\n" }'
}

trimmed_line() {
  sed -n "${2}p" "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

occurrence_index() {
  awk -v target="$2" 'NR <= target { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line)
                                     if (NR == target) want = line
                                     lines[NR] = line }
                      END { for (i = 1; i <= target; i++) if (lines[i] == want) n++; print n }' "$1"
}

workdir="$(mktemp -d)"
restore_list="$workdir/restore"
: >"$restore_list"

# Every step is non-fatal and the original status is restored: under `set -e` one
# failed `cp` would abort the loop, leaving later files still holding a mutant.
restore_sources() {
  local status=$?
  local src backup
  while IFS=$'\t' read -r src backup; do
    if [ -f "$backup" ]; then cp "$backup" "$src" || echo "error: could not restore $src from $backup" >&2; fi
  done <"$restore_list" || true
  rm -rf "$workdir" || true
  # The engine leaves these in the working tree. Unquoted: quoting them would
  # hand `rm` the literal pattern and clean nothing.
  rm -f .tmp_mutant.*.cr .um.mutant_output.* 2>/dev/null || true
  find src -name '*.um.backup.*' -delete 2>/dev/null || true
  exit "$status"
}

interrupt() {
  local status="$1"
  if [ -n "$spec_leader" ]; then kill -KILL -- -"$spec_leader" 2>/dev/null || true; fi
  exit "$status"
}
spec_leader=""

trap restore_sources EXIT
trap 'interrupt 130' INT
trap 'interrupt 143' TERM

protect() {
  local src="$1" backup
  backup="$workdir/backup/$src"
  mkdir -p "$(dirname "$backup")"
  cp "$src" "$backup"
  printf '%s\t%s\n' "$src" "$backup" >>"$restore_list"
  printf '%s' "$backup"
}

# A red tree would score every survivor killed. Checked once, on first need.
full_suite_checked=""
ensure_full_suite_green() {
  [ -z "$full_suite_checked" ] || return 0
  full_suite_checked="yes"
  local src backup
  while IFS=$'\t' read -r src backup; do
    cp "$backup" "$src"
  done <"$restore_list"
  run_spec spec "$BASELINE_SPEC_TIMEOUT" ||
    die "crystal spec does not pass against unmutated source; fix the suite before running the gate"
}

# `crystal spec` execs a separate binary, which a timeout aimed at its direct
# child would leave running — hence the session, and the group kill.
# Set by run_spec: whether the timeout ended the run, however it had to. GNU
# timeout exits 124 when SIGTERM was enough and 137 when the process ignored it
# and --kill-after had to SIGKILL, so the status alone is not the signal.
spec_timed_out=""

run_spec() {
  local target="$1" limit="${2:-}" status=0
  local -a command=(crystal spec)
  spec_timed_out=""
  if [ "$target" = "spec" ]; then
    limit="${limit:-$MUTANT_SUITE_TIMEOUT}"
  else
    limit="${limit:-$MUTANT_SIBLING_TIMEOUT}"
    command+=("$target")
  fi

  setsid timeout --kill-after=5s "$limit" "${command[@]}" >/dev/null 2>&1 &
  spec_leader=$!
  wait "$spec_leader" || status=$?
  kill -KILL -- -"$spec_leader" 2>/dev/null || true
  spec_leader=""
  case "$status" in
    124 | 137) spec_timed_out="yes" ;;
  esac
  return "$status"
}

# `crystal build` on the spec directory fails with "Is a directory", which the
# engine reads as "does not compile" — every mutant discarded, module ungated.
ENTRY_POINT="src/agent_apropos.cr"

compile_gate_cmd() {
  local source="$1" target="$2"
  [ "$target" = "spec" ] && target="$ENTRY_POINT"
  printf 'crystal tool format - < %q > /dev/null 2>&1 && crystal build --no-codegen %q > /dev/null 2>&1' \
    "$source" "$target"
}

survivors=()
generated=0
valid=0
killed=0
timed_out=0

spec_target="$(spec_target_for "$src")"

if [ "$spec_target" = "spec" ]; then
  ensure_full_suite_green
else
  run_spec "$spec_target" "$BASELINE_SPEC_TIMEOUT" ||
    die "$spec_target does not pass against unmutated source; fix the suite before running the gate"
fi

mutant_dir="$workdir/mutants/$src"
mkdir -p "$mutant_dir"

backup="$(protect "$src")"

gen_args=("$src" --only "$RULES" --mutantDir "$mutant_dir" --noFastCheck
  --cmd "$(compile_gate_cmd "$src" "$spec_target")")
[ -n "$lines_file" ] && gen_args+=(--lines "$lines_file")

# The exit status alone is not enough: a missing rules file makes the engine
# print COULD NOT FIND RULE FILE and exit 0.
engine_status=0
mutate "${gen_args[@]}" >"$mutant_dir/generate.log" 2>&1 || engine_status=$?
cp "$backup" "$src"

[ "$engine_status" -eq 0 ] ||
  die "the mutation engine exited $engine_status on $src; see $mutant_dir/generate.log"
grep -q 'MUTANTS GENERATED BY RULES' "$mutant_dir/generate.log" ||
  die "the mutation engine generated nothing on $src; see $mutant_dir/generate.log"
! grep -qE 'COULD NOT FIND RULE FILE|FAILED TO COMPILE RULE|WARNING: Applying mutation raised|DOES NOT MATCH EXPECTED FORMAT' \
  "$mutant_dir/generate.log" ||
  die "$RULES did not load cleanly; see $mutant_dir/generate.log"

generated=$((generated + $(grep -c '^PROCESSING MUTANT:' "$mutant_dir/generate.log" || true)))

for mutant in "$mutant_dir"/*.cr; do
  [ -f "$mutant" ] || continue

  line="$(mutant_line_from_log "$mutant_dir/generate.log" "$mutant")"
  [ -n "$line" ] || line="$(mutant_line "$backup" "$mutant")"
  [ -n "$line" ] || continue
  original="$(trimmed_line "$backup" "$line")"
  mutated="$(mutant_text "$backup" "$mutant" "$line")"
  occurrence="$(occurrence_index "$backup" "$line")"

  valid=$((valid + 1))
  cp "$mutant" "$src"
  status=0
  run_spec "$spec_target" || status=$?
  [ -n "$spec_timed_out" ] && timed_out=$((timed_out + 1))
  if [ "$status" -eq 0 ]; then
    # The sibling run over-reports: a mutant killed only by a non-sibling spec
    # survives it. Nothing wider to ask when the sibling WAS the whole suite.
    cp "$backup" "$src"
    ensure_full_suite_green
    cp "$mutant" "$src"
    suite_status=0
    if [ "$spec_target" != "spec" ]; then
      run_spec spec || suite_status=$?
      [ -n "$spec_timed_out" ] && timed_out=$((timed_out + 1))
    fi
    if [ "$suite_status" -eq 0 ]; then
      cp "$backup" "$src"
      if ignored_mutant "$src" "$occurrence" "$original" "$mutated"; then
        killed=$((killed + 1))
      else
        survivors+=("$src:$line	$original	$mutated")
      fi
    else
      cp "$backup" "$src"
      killed=$((killed + 1))
    fi
  else
    cp "$backup" "$src"
    killed=$((killed + 1))
  fi
done

cp "$backup" "$src"

printf 'COUNTS\t%s\t%s\t%s\t%s\n' "$generated" "$valid" "$killed" "$timed_out"
if [ "${#survivors[@]}" -gt 0 ]; then
  printf 'SURVIVOR\t%s\n' "${survivors[@]}"
fi
