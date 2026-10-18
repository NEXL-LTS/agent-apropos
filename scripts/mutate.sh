#!/usr/bin/env bash
# Mutation-score gate. See docs/mutation-testing.md.
#
# Usage: scripts/mutate.sh [--base <ref>] [--jobs <N>] [<source-file> ...]
#
#   --base <ref>   compare against this ref instead of the PR base
#   --jobs <N>     parallel workers for a large target (default: min(nproc, 8))
#   <source-file>  mutate in full, ignoring the diff
#
# Per-file mutation (generate + test every mutant) is delegated to
# scripts/mutate-worker.sh. A target large enough to be worth it is sharded by
# line number across --jobs isolated git worktrees, run concurrently, and the
# results merged; a small target runs through a single worker directly in the
# repo root, unchanged from before this file had a --jobs flag at all.
set -euo pipefail

# Resolved from this file's own location, not the target repo's root: the
# bats suite runs this exact script against a throwaway fixture repo, where
# `git rev-parse --show-toplevel` would point at the fixture, not here.
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="$self_dir/mutate-worker.sh"

root="$(git rev-parse --show-toplevel)"
cd "$root"

RULES="tool/mutate/crystal.rules"
IGNORE_FILE="tool/mutate/ignore.json"
NO_SPEC_FILE="tool/mutate/no-spec.json"
CLEAN_FILE="tool/mutate/clean.json"

# Below this, a target runs through a single worker in $root with no worktree:
# the overhead of `git worktree add` plus a shards symlink is not worth paying
# for a handful of lines, and the vast majority of PR-scoped runs are exactly
# that small.
MIN_LINES_PER_WORKER=15

die() {
  echo "error: $*" >&2
  exit 2
}

default_jobs() {
  local n
  n="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  [ "$n" -gt 8 ] && n=8
  [ "$n" -lt 1 ] && n=1
  printf '%s' "$n"
}

base_ref=""
jobs="$(default_jobs)"
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
    --jobs)
      [ "$#" -ge 2 ] || die "--jobs needs a number"
      jobs="$2"
      shift 2
      ;;
    --jobs=*)
      jobs="${1#--jobs=}"
      shift
      ;;
    -h | --help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
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

case "$jobs" in
  '' | *[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$jobs" -ge 1 ] || die "--jobs must be a positive integer"

command -v mutate >/dev/null 2>&1 ||
  die "the mutation engine is not on PATH; install it with
  python3 -m pip install --require-hashes --no-deps -r tool/mutate/requirements.txt"

for tool in setsid timeout; do
  command -v "$tool" >/dev/null 2>&1 ||
    die "$tool is not on PATH; the mutation gate needs it to bound and reap a mutant's spec run"
done

[ -x "$WORKER" ] || die "$WORKER is missing or not executable"
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

workdir="$(mktemp -d)"
worktrees=()
worker_pids=()
target_seq=0
new_wt=""

remove_worktrees() {
  local wt
  for wt in ${worktrees[@]+"${worktrees[@]}"}; do
    git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  done
  worktrees=()
  git worktree prune 2>/dev/null || true
}

restore_sources() {
  local status=$?
  remove_worktrees
  rm -rf "$workdir" || true
  exit "$status"
}

# A signal caught here does not, by itself, reach a backgrounded worker unless
# the whole process group was signalled (the common case, but not guaranteed)
# — so it is forwarded explicitly. Each worker is a full mutate-worker.sh
# process with its own INT/TERM trap, so this just gets that cleanup started
# rather than doing it here.
interrupt() {
  local status="$1" pid
  for pid in ${worker_pids[@]+"${worker_pids[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  exit "$status"
}

trap restore_sources EXIT
trap 'interrupt 130' INT
trap 'interrupt 143' TERM

# One worktree, detached at HEAD, with the working tree's own dirty state
# replayed on top — a developer running this against a dirty tree gets the
# same mutants a plain (non-parallel) run would. `lib/` is a shards install,
# gitignored and identical for every worker, so it is shared via a symlink
# rather than reinstalled per worktree.
#
# `git diff | apply` covers every tracked file (modified, staged-but-
# uncommitted, deleted, renamed); like `git diff` itself, it has no notion of
# a file that was never `git add`-ed at all. Every untracked-but-not-ignored
# file is therefore copied in directly too — a worker may need any of them
# (a new source file, a new sibling spec for it, a new fixture), not only
# whichever one it was asked to mutate.
#
# Sets $new_wt rather than printing the path: it must run in the current shell
# for `worktrees` to record the worktree for cleanup. The replay uses the same
# pinned diff flags as the parser above and is fatal if it cannot be applied —
# a silent fallback would mutate different source than the non-parallel path.
new_worktree() {
  local idx="$1" wt patch
  wt="$workdir/wt-$target_seq-$idx"
  patch="$workdir/dirty-$target_seq-$idx.patch"
  git worktree add --quiet --detach "$wt" HEAD >/dev/null
  worktrees+=("$wt")
  git diff --binary --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ HEAD >"$patch" ||
    die "could not generate the dirty-tree patch for the parallel workers"
  git -C "$wt" apply --allow-empty "$patch" ||
    die "could not replay the dirty tree into $wt"
  local f
  while IFS= read -r f; do
    mkdir -p "$wt/$(dirname "$f")"
    cp "$root/$f" "$wt/$f"
  done < <(git ls-files --others --exclude-standard)
  ln -s "$root/lib" "$wt/lib" 2>/dev/null || true
  seed_worker_cache "$wt"
  new_wt="$wt"
}

# `crystal spec`/`crystal build` write the compiled binary to a fixed filename
# inside CRYSTAL_CACHE_DIR (e.g. crystal-run-spec.tmp), not one namespaced by
# PID or target — two concurrent invocations sharing a cache dir clobber that
# file (confirmed empirically: one gets "Text file busy", the other "No such
# file or directory", both from the compiler itself, not from mutated code).
# Every worktree therefore gets its own cache dir; seeding it from whatever
# is already warm means a worker still gets the stdlib's cached semantic
# analysis instead of starting stone cold.
seed_worker_cache() {
  local wt="$1" shared="${CRYSTAL_CACHE_DIR:-$HOME/.cache/crystal}" dest="$wt/.mutate-cache"
  mkdir -p "$dest"
  [ -d "$shared" ] && cp -a "$shared/." "$dest/" 2>/dev/null
  true
}

# Splits a whitespace-separated list of line numbers into up to `$2` roughly
# equal, contiguous (by list order, not by line-number gaps) chunks, written
# one per line to files under $workdir named `$1.0`, `$1.1`, ... Prints how
# many chunk files it actually wrote — fewer than `$2` when there are fewer
# lines than workers.
chunk_lines() {
  local -a lines=($1)
  local prefix="$2" want="$3" total="${#lines[@]}" n i start size extra chunk
  n="$want"
  [ "$n" -gt "$total" ] && n="$total"
  [ "$n" -lt 1 ] && n=1
  size=$((total / n))
  extra=$((total % n))
  start=0
  for ((i = 0; i < n; i++)); do
    chunk=$size
    [ "$i" -lt "$extra" ] && chunk=$((chunk + 1))
    printf '%s\n' "${lines[@]:start:chunk}" >"$prefix.$i"
    start=$((start + chunk))
  done
  printf '%s' "$n"
}

survivors=()
generated=0
valid=0
killed=0
timed_out=0

# Parses one worker's COUNTS/SURVIVOR output (file $1, written by run_worker)
# and folds it into the running totals above.
absorb_worker_output() {
  local output="$1" kind
  while IFS=$'\t' read -r kind a b c d; do
    case "$kind" in
      COUNTS)
        generated=$((generated + a))
        valid=$((valid + b))
        killed=$((killed + c))
        timed_out=$((timed_out + d))
        ;;
      SURVIVOR)
        survivors+=("$a	$b	$c")
        ;;
    esac
  done <"$output"
}

run_worker() {
  local dir="$1" src="$2" lines_file="${3:-}" out="$4"
  if [ "$dir" = "$root" ]; then
    (cd "$dir" && "$WORKER" "$src" "$lines_file") >"$out"
  else
    (cd "$dir" && CRYSTAL_CACHE_DIR="$dir/.mutate-cache" "$WORKER" "$src" "$lines_file") >"$out"
  fi
}

# `wc -l` counts newline bytes, undercounting a file whose last line has none
# — real here, since an explicit target (unlike a diff-scoped one) is not
# required to be a tracked, formatter-clean Crystal source. `awk`'s NR counts
# that final line too.
line_count() { awk 'END { print NR }' "$1"; }

mutate_file() {
  local src="$1" lines_file="${2:-}"
  local -a all_lines=()
  local total out

  if [ -z "$lines_file" ]; then
    local n
    n="$(line_count "$src")"
    for ((i = 1; i <= n; i++)); do all_lines+=("$i"); done
  else
    all_lines=($(cat "$lines_file"))
  fi
  total="${#all_lines[@]}"

  if [ "$jobs" -le 1 ] || [ "$total" -lt $((jobs * MIN_LINES_PER_WORKER)) ]; then
    out="$workdir/out.0"
    run_worker "$root" "$src" "$lines_file" "$out"
    absorb_worker_output "$out"
    return 0
  fi

  local chunk_prefix="$workdir/chunk.$(printf '%s' "$src" | tr -c 'A-Za-z0-9' '_')"
  local n
  n="$(chunk_lines "${all_lines[*]}" "$chunk_prefix" "$jobs")"

  target_seq=$((target_seq + 1))
  worker_pids=()
  local -a outs=()
  for ((i = 0; i < n; i++)); do
    local wt out
    new_worktree "$i"
    wt="$new_wt"
    out="$workdir/out.$target_seq.$i"
    outs+=("$out")
    # exec, so $! is the worker itself and interrupt's TERM reaches it.
    (cd "$wt" && CRYSTAL_CACHE_DIR="$wt/.mutate-cache" exec "$WORKER" "$src" "$chunk_prefix.$i") >"$out" &
    worker_pids+=("$!")
  done

  local failed=0 pid
  for pid in "${worker_pids[@]}"; do
    wait "$pid" || failed=1
  done
  worker_pids=()
  [ "$failed" -eq 0 ] || die "a parallel worker on $src failed; see above"
  remove_worktrees

  for out in "${outs[@]}"; do
    absorb_worker_output "$out"
  done
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

earned=()
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
