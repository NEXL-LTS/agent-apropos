#!/usr/bin/env bash
# Mutation-score gate, scoped to the lines a change touched.
#
# Line coverage proves a line ran. It does not prove anything asserted on what
# the line did, and a spec written to satisfy a coverage gate can execute a line
# while pinning none of its behaviour. This gate closes that hole: it rewrites
# each changed source line into a plausible variant (a "mutant") and fails when
# the specs still pass. A surviving mutant means the behaviour on that line is
# unpinned — and, often enough, that the behaviour itself is wrong.
#
# Same entry point locally (`make mutate`) and in CI, so a contributor sees
# exactly what CI will see.
#
# Usage:
#   scripts/mutate.sh [--base <ref>] [<source-file> ...]
#
#   --base <ref>   compare against this ref instead of the PR base
#   <source-file>  mutate these files in full, ignoring the diff (backfill
#                  sweeps, per R7 — not what CI runs)
#
# See docs/mutation-testing.md for the survivor rule and the ignore-list policy.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

RULES="tool/mutate/crystal.rules"
IGNORE_FILE="tool/mutate/ignore.txt"
NO_SPEC_FILE="tool/mutate/no-spec.txt"
BACKFILL_FILE="tool/mutate/backfill.txt"

# A mutated guard or loop bound can produce a mutant that never terminates. An
# untimed run would hang the job instead of failing it, so every mutant spec run
# is bounded and a timeout counts as killed (KTD5): a spec that hangs on the
# mutant has distinguished it from the original just as surely as one that
# fails. Sized for headroom over a healthy run, not for a slow one: a mutant
# that takes an order of magnitude longer than the original has already
# announced itself.
# Sized against a healthy run of each target — a sibling spec is seconds, the
# whole suite tens of seconds — so a mutant an order of magnitude slower has
# already announced itself.
MUTANT_SIBLING_TIMEOUT=30
MUTANT_SUITE_TIMEOUT=180

# The unmutated baseline is a different question. It must not be declared red
# just because the suite grew, so it gets its own, generous bound.
BASELINE_SPEC_TIMEOUT=900

die() {
  echo "error: $*" >&2
  exit 2
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------

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
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
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

# --------------------------------------------------------------------------
# Reviewed lists
#
# All three are checked-in and reviewed in the PR that changes them. Each is
# also checked for staleness: an entry that no longer describes anything in the
# tree is a silent hole in the gate, so it fails the run rather than lingering.
# --------------------------------------------------------------------------

# Strip comments and blank lines; keep the rest verbatim (fields are tab-separated).
list_entries() {
  [ -f "$1" ] || return 0
  sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1"
}

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
  done < <(list_entries "$NO_SPEC_FILE")

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

# Modules still to be brought to a 100% mutation score, in sweep order. A module
# leaves the list in the PR that backfills it (KTD13), so the list shrinking is
# the progress report.
backfill_pending() { list_entries "$BACKFILL_FILE" | cut -d'	' -f1; }

check_backfill_list() {
  local path
  while IFS= read -r path; do
    [ -f "$path" ] ||
      stale+=("$BACKFILL_FILE names $path, which no longer exists")
  done < <(backfill_pending)
}

backfilled() {
  local path
  while IFS= read -r path; do
    [ "$path" = "$1" ] && return 1
  done < <(backfill_pending)
  return 0
}

# Ignore-list entries are keyed on source path, the original and mutated text,
# and the occurrence index of that original text within the file (KTD3). Mutant
# numbering shifts with rule order and line numbers shift with any edit above
# them, so neither is stable; the text pair alone is stable but not unique, and
# without the occurrence index one reviewed entry would exempt every identical
# line in the file.
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
  done < <(list_entries "$IGNORE_FILE")
}

# How many lines of $2 have exactly $1 as their trimmed text. The wanted text
# goes through the environment rather than `awk -v`, which expands backslash
# escapes in the value it is handed — so a source line containing `\n` would
# arrive as a real newline and match nothing.
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
  done < <(list_entries "$IGNORE_FILE")
  return 1
}

# --------------------------------------------------------------------------
# What to mutate
# --------------------------------------------------------------------------

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

# Per-file changed lines, as "<path> <line>" pairs. Deleted files and pure
# deletions contribute nothing: there is no line left to mutate.
changed_lines() {
  local merge_base="$1"
  shift
  git diff --unified=0 "$merge_base" -- "$@" |
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

changed_files_matching() {
  local merge_base="$1"
  shift
  git diff --name-only --diff-filter=d "$merge_base" -- "$@"
}

# --------------------------------------------------------------------------
# Mutant bookkeeping
# --------------------------------------------------------------------------

# The mutant differs from the source in exactly one replaced line, so the first
# differing line number is the mutated line, and the replacement spans as many
# lines as the mutant gained.
mutant_line() {
  awk 'NR == FNR { original[FNR] = $0; next }
       $0 != original[FNR] { print FNR; exit }' "$1" "$2"
}

# The replacement text, with any inserted lines folded onto one line so the
# ignore-list key stays a single tab-separated record.
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

# --------------------------------------------------------------------------
# Running
# --------------------------------------------------------------------------

workdir="$(mktemp -d)"
restore_list="$workdir/restore"
: >"$restore_list"

# The engine restores the source in a `finally`, which a hard kill bypasses, and
# so does an interrupt between our own copy-in and copy-back. Register every
# file we are about to overwrite and put it back on any exit path, so an
# interrupted run never leaves a mutant in the working tree.
restore_sources() {
  local src backup
  while IFS=$'\t' read -r src backup; do
    if [ -f "$backup" ]; then cp "$backup" "$src"; fi
  done <"$restore_list"
  rm -rf "$workdir"
  # The engine writes its scratch mutant and its own source backup into the
  # working tree and does not always clear them, so a run would otherwise leave
  # untracked files behind for the next `git add` to pick up.
  rm -f .tmp_mutant.*.cr .um.mutant_output.* src/**/*.um.backup.* 2>/dev/null || true
  find src -name '*.um.backup.*' -delete 2>/dev/null || true
}
trap restore_sources EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

protect() {
  local src="$1" backup="$workdir/backup.$(printf '%s' "$src" | tr '/' '_')"
  cp "$src" "$backup"
  printf '%s\t%s\n' "$src" "$backup" >>"$restore_list"
  printf '%s' "$backup"
}

spec_target_for() {
  local spec
  spec="$(sibling_spec_for "$1")"
  [ -f "$spec" ] && { printf '%s' "$spec"; return 0; }
  # No sibling: fall back to the whole suite rather than scoring every mutant
  # killed against nothing. R15's check keeps this to reviewed exemptions.
  printf 'spec'
}

# The full suite is the arbiter for a mutant that survived its sibling spec
# (KTD12) and for a module with no sibling at all, so it has to be green on
# unmutated source before either use — otherwise a red tree would score every
# survivor killed. Checked once, on first need.
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

# `crystal spec` compiles and then execs a separate binary, and a timeout that
# signals only its direct child leaves that binary running: a non-terminating
# mutant would otherwise leak one spinning process per timeout and slowly starve
# the run. Putting the whole thing in its own session means the group can be
# signalled as a unit once it is done, however it ended.
run_spec() {
  local target="$1" limit="${2:-}" status=0
  local -a command=(crystal spec)
  if [ "$target" = "spec" ]; then
    limit="${limit:-$MUTANT_SUITE_TIMEOUT}"
  else
    limit="${limit:-$MUTANT_SIBLING_TIMEOUT}"
    command+=("$target")
  fi

  setsid timeout --kill-after=5s "$limit" "${command[@]}" >/dev/null 2>&1 &
  local leader=$!
  wait "$leader" || status=$?
  kill -KILL -- -"$leader" 2>/dev/null || true
  return "$status"
}

# Two stages, cheapest first. `crystal tool format -` parses without compiling
# (~20ms) and rejects the mutants that are not even syntactically Crystal; the
# no-codegen build of the spec target (~1s) rejects the rest (KTD4). Gating on
# the spec target rather than the binary entry point matters: a mutant the
# binary never instantiates would otherwise reach the kill run and fail to
# compile there, which the run cannot tell apart from being killed.
compile_gate_cmd() {
  printf 'crystal tool format - < %q > /dev/null 2>&1 && crystal build --no-codegen %q > /dev/null 2>&1' \
    "$1" "$2"
}

survivors=()
generated=0
killed=0

mutate_file() {
  local src="$1" lines_file="${2:-}"
  local spec_target mutant_dir backup line original mutated occurrence
  local -a gen_args=()

  spec_target="$(spec_target_for "$src")"

  # A spec target that is already red would score every mutant killed and
  # report a clean gate over a broken tree.
  if [ "$spec_target" = "spec" ]; then
    ensure_full_suite_green
  else
    run_spec "$spec_target" "$BASELINE_SPEC_TIMEOUT" ||
      die "$spec_target does not pass against unmutated source; fix the suite before running the gate"
  fi

  mutant_dir="$workdir/mutants/$(printf '%s' "$src" | tr '/' '_')"
  mkdir -p "$mutant_dir"

  backup="$(protect "$src")"

  gen_args=("$src" --only "$RULES" --mutantDir "$mutant_dir" --noFastCheck
    --cmd "$(compile_gate_cmd "$src" "$spec_target")")
  [ -n "$lines_file" ] && gen_args+=(--lines "$lines_file")

  mutate "${gen_args[@]}" >"$mutant_dir/generate.log" 2>&1 || true
  cp "$backup" "$src"

  generated=$((generated + $(grep -c '^PROCESSING MUTANT:' "$mutant_dir/generate.log" || true)))

  for mutant in "$mutant_dir"/*.cr; do
    [ -f "$mutant" ] || continue

    line="$(mutant_line "$backup" "$mutant")"
    [ -n "$line" ] || continue
    original="$(trimmed_line "$backup" "$line")"
    mutated="$(mutant_text "$backup" "$mutant" "$line")"
    occurrence="$(occurrence_index "$backup" "$line")"

    cp "$mutant" "$src"
    if run_spec "$spec_target"; then
      # Survived its sibling spec. Scoping the kill run to the sibling
      # over-reports and never under-reports, because a mutant killed only by a
      # non-sibling spec survives the narrower run — so re-check against the
      # whole suite before failing the gate (KTD12). A full-suite kill counts.
      cp "$backup" "$src"
      ensure_full_suite_green
      cp "$mutant" "$src"
      if [ "$spec_target" != "spec" ] && run_spec spec; then
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

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

check_sibling_specs
check_backfill_list
check_ignore_list

if [ "${#stale[@]}" -gt 0 ]; then
  {
    echo "error: the mutation gate's reviewed lists no longer match the tree:"
    printf '  %s\n' "${stale[@]}"
  } >&2
  exit 2
fi

declare -a targets=()
declare -a target_lines=()

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

  # Changed source lines (R5, KTD2).
  while IFS=' ' read -r file line; do
    [ -n "$file" ] || continue
    found=""
    for i in "${!targets[@]}"; do
      [ "${targets[$i]}" = "$file" ] && { target_lines[$i]="${target_lines[$i]} $line"; found="yes"; }
    done
    [ -n "$found" ] && continue
    targets+=("$file")
    target_lines+=("$line")
  done < <(changed_lines "$merge_base" 'src/*.cr')

  # A changed spec file for an already-backfilled module widens the scope to
  # that whole module (R17): deleting an assertion changes no source line, so a
  # gate that only sees changed source lines would wave it through.
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    module="src/${spec#spec/}"
    module="${module%_spec.cr}.cr"
    [ -f "$module" ] || continue
    backfilled "$module" || continue
    replaced=""
    for i in "${!targets[@]}"; do
      [ "${targets[$i]}" = "$module" ] && { target_lines[$i]=""; replaced="yes"; }
    done
    [ -n "$replaced" ] && continue
    targets+=("$module")
    target_lines+=("")
  done < <(changed_files_matching "$merge_base" 'spec/*_spec.cr')
fi

if [ "${#targets[@]}" -eq 0 ]; then
  echo "mutation gate: no changed source lines under src/ — nothing to mutate"
  exit 0
fi

for i in "${!targets[@]}"; do
  file="${targets[$i]}"
  lines="${target_lines[$i]}"
  if [ -n "$lines" ]; then
    lines_file="$workdir/lines.$i"
    printf '%s\n' $lines >"$lines_file"
    echo "mutation gate: ${file} ($(wc -w <<<"$lines" | tr -d ' ') changed lines)"
    mutate_file "$file" "$lines_file"
  else
    echo "mutation gate: ${file} (whole file)"
    mutate_file "$file"
  fi
done

pending="$(backfill_pending | tr '\n' ' ')"
[ -n "$pending" ] && echo "mutation gate: not yet backfilled to 100%: ${pending%% }"

echo "mutation gate: ${generated} mutants generated, ${killed} killed, ${#survivors[@]} surviving"

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
