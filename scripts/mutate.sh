#!/usr/bin/env bash
# Mutation-score gate. See docs/mutation-testing.md.
#
# Usage: scripts/mutate.sh [--base <ref>] [<source-file> ...]
#
#   --base <ref>   compare against this ref instead of the PR base
#   <source-file>  mutate in full, ignoring the diff
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

RULES="tool/mutate/crystal.rules"
IGNORE_FILE="tool/mutate/ignore.json"
NO_SPEC_FILE="tool/mutate/no-spec.json"
CLEAN_FILE="tool/mutate/clean.json"

MUTANT_SIBLING_TIMEOUT=30
MUTANT_SUITE_TIMEOUT=180
BASELINE_SPEC_TIMEOUT=900

die() {
  echo "error: $*" >&2
  exit 2
}

base_ref=""
explicit_files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || die "--base needs a ref"
      base_ref="$2"
      shift 2
      ;;
    --base=*)
      base_ref="${1#--base=}"
      shift
      ;;
    -h | --help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      die "unknown option $1"
      ;;
    *)
      explicit_files+=("$1")
      shift
      ;;
  esac
done

command -v mutate >/dev/null 2>&1 ||
  die "the mutation engine is not on PATH; install it with
  python3 -m pip install --require-hashes --no-deps -r tool/mutate/requirements.txt"

for tool in setsid timeout; do
  command -v "$tool" >/dev/null 2>&1 ||
    die "$tool is not on PATH; the mutation gate needs it to bound and reap a mutant's spec run"
done

[ -f "$RULES" ] || die "$RULES is missing; the engine would silently generate nothing without it"

command -v jq >/dev/null 2>&1 || die "jq is not on PATH; the reviewed lists are JSON"

# Up front, because a jq failure inside a process substitution cannot abort the
# run — a malformed list would otherwise read as an empty one.
for list in "$IGNORE_FILE" "$NO_SPEC_FILE" "$CLEAN_FILE"; do
  [ -f "$list" ] || die "$list is missing"
  jq -e . "$list" >/dev/null 2>&1 || die "$list is not valid JSON"
done

# `join` rather than `@tsv`, which would escape the backslash in a folded `\n`.
# Crystal source carries no tabs — the formatter forbids them — so a real tab is
# an unambiguous delimiter for these single-line fields.
records() { jq -r "$2 | join(\"\t\")" "$1"; }

field() { printf '%s' "$1" | cut -d'	' -f"$2"; }

tracked_sources() { git ls-files -- 'src/*.cr'; }

sibling_spec_for() {
  local src="$1"
  printf 'spec/%s_spec.cr' "${src#src/}" | sed 's/\.cr_spec\.cr$/_spec.cr/'
}

stale=()

check_sibling_specs() {
  local src spec entry path exempt
  local -a exempted=()

  while IFS= read -r entry; do
    path="$(field "$entry" 1)"
    exempted+=("$path")
    if ! git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      stale+=("$NO_SPEC_FILE names $path, which is no longer a tracked source file")
    fi
  done < <(records "$NO_SPEC_FILE" '.exempt[] | [.path, .reason]')

  while IFS= read -r src; do
    spec="$(sibling_spec_for "$src")"
    [ -f "$spec" ] && continue
    exempt=""
    for path in ${exempted[@]+"${exempted[@]}"}; do
      [ "$path" = "$src" ] && exempt="yes"
    done
    [ -n "$exempt" ] ||
      stale+=("$src has no sibling spec at $spec and no reviewed exemption in $NO_SPEC_FILE")
  done < <(tracked_sources)
}

# A file counts as clean only if the merge base AND the working tree both say so.
# The base half stops a change adding an entry and spending it in the same
# breath — the claim has not been proved by any run yet, so the file is mutated
# in full, which is what proves it. The working-tree half honours a removal:
# taking a file off the list is how you say it regressed.
verified_clean() {
  [ -n "$base_clean" ] || return 0
  jq -r '.clean[]' "$CLEAN_FILE" | grep -Fxf <(printf '%s\n' "$base_clean") || true
}

load_base_clean() {
  local json
  if json="$(git show "$1:$CLEAN_FILE" 2>/dev/null)" &&
    jq -e . <<<"$json" >/dev/null 2>&1; then
    base_clean="$(jq -r '.clean[]' <<<"$json")"
  else
    base_clean=""
  fi
}

base_clean=""

# The file as committed, not the intersection: a stale entry is stale whether or
# not the base agrees, and this runs before the base list is loaded.
check_clean_list() {
  local path
  while IFS= read -r path; do
    [ -f "$path" ] ||
      stale+=("$CLEAN_FILE names $path, which no longer exists")
  done < <(jq -r '.clean[]' "$CLEAN_FILE")
}

is_clean() {
  local path
  while IFS= read -r path; do
    [ "$path" = "$1" ] && return 0
  done < <(verified_clean)
  return 1
}

check_ignore_list() {
  local entry path occurrence original count
  while IFS= read -r entry; do
    path="$(field "$entry" 1)"
    occurrence="$(field "$entry" 2)"
    original="$(field "$entry" 3)"
    if [ ! -f "$path" ]; then
      stale+=("$IGNORE_FILE names $path, which no longer exists")
      continue
    fi
    count="$(occurrences_of "$original" "$path")"
    [ "$count" -ge "$occurrence" ] ||
      stale+=("$IGNORE_FILE entry for $path occurrence $occurrence no longer matches any line: ${original}")
  done < <(records "$IGNORE_FILE" '.equivalent[] | [.path, (.occurrence|tostring), .original, .mutated]')
}

# Via the environment, not `awk -v`: that expands backslash escapes in the value,
# so a source line containing `\n` would arrive as a real newline.
occurrences_of() {
  WANTED_LINE="$1" awk '{ line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line)
                          if (line == ENVIRON["WANTED_LINE"]) n++ }
                        END { print n + 0 }' "$2"
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

resolve_base() {
  [ -n "$base_ref" ] && { printf '%s' "$base_ref"; return 0; }
  if [ -n "${GITHUB_BASE_REF:-}" ]; then
    printf 'origin/%s' "$GITHUB_BASE_REF"
    return 0
  fi
  local head
  if head="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s' "${head#refs/remotes/}"
    return 0
  fi
  return 1
}

# The flags pin the diff's text shape: an external driver, a textconv filter or
# diff.noprefix would otherwise rewrite what this parser reads.
changed_lines() {
  local merge_base="$1"
  shift
  git diff --unified=0 --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ \
    "$merge_base" -- "$@" |
    awk '
      /^\+\+\+ / { file = substr($0, 7); if ($2 == "/dev/null") file = ""; next }
      /^@@ / && file != "" {
        split($3, hunk, ",")
        start = substr(hunk[1], 2) + 0
        count = (hunk[2] == "" ? 1 : hunk[2] + 0)
        for (i = 0; i < count; i++) print file, start + i
      }
    '
}

diff_names_a_file() {
  local merge_base="$1"
  shift
  git diff --unified=0 --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ \
    "$merge_base" -- "$@" | grep '^+++ b/' >/dev/null
}

changed_files_matching() {
  local merge_base="$1"
  shift
  git diff --name-only --no-ext-diff --diff-filter=d "$merge_base" -- "$@"
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
  local src="$1" backup="$workdir/backup/$src"
  mkdir -p "$(dirname "$backup")"
  cp "$src" "$backup"
  printf '%s\t%s\n' "$src" "$backup" >>"$restore_list"
  printf '%s' "$backup"
}

spec_target_for() {
  local spec
  spec="$(sibling_spec_for "$1")"
  [ -f "$spec" ] && { printf '%s' "$spec"; return 0; }
  printf 'spec'
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
earned=()
generated=0
valid=0
killed=0
timed_out=0

mutate_file() {
  local src="$1" lines_file="${2:-}"
  local spec_target mutant_dir backup line original mutated occurrence
  local -a gen_args=()

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
  local engine_status=0
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
    local status=0
    run_spec "$spec_target" || status=$?
    [ -n "$spec_timed_out" ] && timed_out=$((timed_out + 1))
    if [ "$status" -eq 0 ]; then
      # The sibling run over-reports: a mutant killed only by a non-sibling spec
      # survives it. Nothing wider to ask when the sibling WAS the whole suite.
      cp "$backup" "$src"
      ensure_full_suite_green
      cp "$mutant" "$src"
      local suite_status=0
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
}

check_sibling_specs
check_clean_list
check_ignore_list

if [ "${#stale[@]}" -gt 0 ]; then
  {
    echo "error: the mutation gate's reviewed lists no longer match the tree:"
    printf '  %s\n' "${stale[@]}"
  } >&2
  exit 2
fi

# An empty `target_lines` entry means the whole file.
declare -a targets=()
declare -a target_lines=()

target_index() {
  local i
  for i in "${!targets[@]}"; do
    if [ "${targets[$i]}" = "$1" ]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

add_line_to_target() {
  local file="$1" line="$2" index
  if index="$(target_index "$file")"; then
    [ -n "${target_lines[$index]}" ] &&
      target_lines[index]="${target_lines[$index]} $line"
    return 0
  fi
  targets+=("$file")
  target_lines+=("$line")
}

widen_target_to_whole_file() {
  local file="$1" index
  if index="$(target_index "$file")"; then
    target_lines[index]=""
    return 0
  fi
  targets+=("$file")
  target_lines+=("")
}

if [ "${#explicit_files[@]}" -gt 0 ]; then
  for file in "${explicit_files[@]}"; do
    [ -f "$file" ] || die "$file does not exist"
    targets+=("$file")
    target_lines+=("")
  done
else
  merge_base=""
  if base="$(resolve_base)"; then
    merge_base="$(git merge-base "$base" HEAD 2>/dev/null)" ||
      die "cannot find a merge base between $base and HEAD"
  else
    die "no base ref: pass --base <ref>, or set GITHUB_BASE_REF, or configure origin/HEAD"
  fi

  load_base_clean "$merge_base"

  while IFS=' ' read -r file line; do
    [ -n "$file" ] || continue
    if is_clean "$file"; then
      add_line_to_target "$file" "$line"
    else
      # No proof its untouched lines are pinned, so the whole file is in scope
      # and bringing it to zero survivors is part of this change.
      widen_target_to_whole_file "$file"
    fi
  done < <(changed_lines "$merge_base" 'src/*.cr')

  # `--name-only` bypasses the hunk parser, so disagreement means a broken parse
  # rather than a change that touched nothing.
  if [ -n "$(changed_files_matching "$merge_base" 'src/*.cr')" ] &&
    ! diff_names_a_file "$merge_base" 'src/*.cr'; then
    die "source files changed under src/, but the diff carries no '+++ b/<path>' header for any of
  them, so no line set can be derived. The diff output is not in the form this runner parses —
  check diff.external, GIT_EXTERNAL_DIFF, and any 'diff' gitattribute on those paths."
  fi

  # Deleting an assertion changes no source line, so a changed spec widens the
  # scope to its whole module.
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    module="src/${spec#spec/}"
    module="${module%_spec.cr}.cr"
    [ -f "$module" ] || continue
    widen_target_to_whole_file "$module"
  done < <(changed_files_matching "$merge_base" 'spec/*_spec.cr')
fi

if [ "${#targets[@]}" -eq 0 ]; then
  echo "mutation gate: no changed source lines under src/ — nothing to mutate"
  exit 0
fi

for i in "${!targets[@]}"; do
  file="${targets[$i]}"
  lines="${target_lines[$i]}"
  before="${#survivors[@]}"
  if [ -n "$lines" ]; then
    lines_file="$workdir/lines.$i"
    printf '%s\n' $lines >"$lines_file"
    echo "mutation gate: ${file} ($(wc -w <<<"$lines" | tr -d ' ') changed lines)"
    mutate_file "$file" "$lines_file"
  else
    if is_clean "$file"; then
      echo "mutation gate: ${file} (whole file; its spec changed)"
    else
      echo "mutation gate: ${file} (whole file; no 100% record yet)"
    fi
    mutate_file "$file"
    if [ "${#survivors[@]}" -eq "$before" ] && ! is_clean "$file"; then
      earned+=("$file")
    fi
  fi
done


summary="mutation gate: ${generated} mutants generated, ${valid} compiled, ${killed} killed, ${#survivors[@]} surviving"
[ "$timed_out" -gt 0 ] && summary="$summary (${timed_out} killed by timeout)"
echo "$summary"

# Mostly-timeouts measures a slow machine, not the specs.
if [ "$timed_out" -ge 5 ] && [ $((timed_out * 5)) -gt "$valid" ]; then
  die "${timed_out} of ${valid} mutants died only by timing out; the run is too degraded to trust"
fi

if [ "${#earned[@]}" -gt 0 ] && [ "${#survivors[@]}" -eq 0 ]; then
  echo ""
  echo "These reached a 100% mutation score. Record them in $CLEAN_FILE so the"
  echo "next change to them only pays for its own lines:"
  printf '  %s\n' "${earned[@]}"
fi

if [ "${#survivors[@]}" -gt 0 ]; then
  {
    echo ""
    echo "error: ${#survivors[@]} mutant(s) survived the changed lines."
    echo "A survivor is a suspected bug until you can justify the current behaviour."
    echo "See docs/mutation-testing.md."
    echo ""
    printf '%s\n' "${survivors[@]}" |
      awk -F'\t' '{ printf "  %s\n      was: %s\n      now: %s\n", $1, $2, $3 }'
  } >&2
  exit 1
fi
