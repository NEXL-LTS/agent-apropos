---
paths: ["src/agent_apropos/git.cr"]
contents: ['status.*--porcelain|removed_paths|tracked_removal_status']
---

# `git status --porcelain -z` field order is reversed from the human format

**Rule:** When touching how `Git::Real#removed_paths` parses
`git status --porcelain -z`, keep the field order straight: every record is
`<XY><space><path>`, NUL-terminated. For an ordinary add, modify, or delete,
that's the whole record — one field. For a rename or copy (`XY` carries `R`
or `C`), the record is **two** consecutive NUL-terminated fields: the
**destination** path first (the one with the `<XY>` prefix), then the bare
**source** path second, with no status prefix of its own. This is the
reverse of the non-`-z`, human-readable `orig -> new` order. Both `R` and `C`
consume this same two-field shape — but only a rename's source vanished; a
copy's source is left in place (confirmed empirically: with `diff.renames`
or `status.renames` set to `copies`, modifying a tracked file while adding a
new file that matches its *old* content reports the modified file as `M`,
still present, and the new file as `C` naming it as the source — so a `C`
record's second field must be consumed and discarded, never added to
`removed`). A rename or copy whose *destination* is itself then deleted from
the worktree (`XY` is `RD` or `CD`) reports that destination path — the
first field — as removed too, on top of whatever the source rule above adds.

`--untracked-files=no` stays on the invocation: the untracked walk is the
expensive part of `status`, and an untracked path is invisible to git and so
can never be a tracked removal.

`tracked_removal_status?` treats these `XY` codes, and no others, as "the
tracked path is gone from disk" for a **single**-field record (`XY` is
neither `R` nor `C`):

| State | `XY` | Why |
| --- | --- | --- |
| Unstaged worktree delete | `<space>D` | still in the index, gone on disk |
| Staged delete (`git rm`) | `D<space>` | `git rm` removes the worktree file as part of the same operation, so the worktree column reads unchanged rather than `D` |
| Staged add, then deleted from worktree | `AD` | the `D` in the worktree column is what matters; the index column is incidental |

A rename or copy's own worktree-delete case (`RD`/`CD`) is handled inside the
rename/copy branch itself, not by `tracked_removal_status?` — it checks the
same `D` worktree column directly against the record's first field.

**Why:** This field order was confirmed empirically against a real repository,
not from `git-status(1)` prose alone — it's easy to get backwards, and
getting it backwards silently reports the surviving new path as "removed"
instead of the vanished old one, which is exactly the bug this feature exists
to avoid.

**Watch out:** A `git status` state with none of the codes above (e.g.
`<space>M`, an ordinary modification) leaves the file on disk and must not be
treated as a removal.

## Verify

- A change to the rename/copy branch of `parse_removed_records` keeps
  consuming the field *after* the `R`/`C` record, whether the status is `R`
  or `C`, not just `R`.
- Only `R`'s second field (the source) is added to `removed`; `C`'s second
  field is consumed but never added — a copy's source stays on disk.
- `RD`/`CD` (the record's own worktree column reads `D`) adds the record's
  *own* path (the first field) to `removed`, in addition to whatever the
  source rule above adds.
- `tracked_removal_status?` still recognizes exactly ` D`, `D `, and `AD`
  (via its `D` worktree check) as removals, and nothing else.
- `spec/agent_apropos/git_spec.cr`'s real-repo removal specs still pass.
