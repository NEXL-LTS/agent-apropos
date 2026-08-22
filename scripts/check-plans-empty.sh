#!/usr/bin/env bash
# Fail if any plan document is committed under docs/plans/.
#
# Plans are working documents: one is written, implemented, and then deleted in
# the PR that lands the work. Left in the tree they rot — a stale plan describes
# a design the merged code has already moved past, and neither a contributor nor
# an agent reading the repo can tell it from a current one.
#
# Only *tracked* files count. An in-progress plan sitting untracked in a working
# tree is the normal case while planning, and the local gate must not fight it;
# what is gated is what gets committed.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
tracked="$(git -C "$root" ls-files -- docs/plans)"

if [ -n "$tracked" ]; then
  {
    echo "error: docs/plans/ must be empty, but these plans are committed:"
    printf '%s\n' "$tracked" | sed 's/^/  /'
    echo "Delete the plan in the PR that implements it."
  } >&2
  exit 1
fi
