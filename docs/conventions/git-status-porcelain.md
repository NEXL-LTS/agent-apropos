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
reverse of the non-`-z`, human-readable `orig -> new` order. A removal cares
about the source path — the one that vanished — so the parser consumes both
fields and keeps the second, never the first.

`--untracked-files=no` stays on the invocation: the untracked walk is the
expensive part of `status`, and an untracked path is invisible to git and so
can never be a tracked removal.

`tracked_removal_status?` treats these `XY` codes, and no others, as "the
tracked path is gone from disk":

| State | `XY` | Why |
| --- | --- | --- |
| Unstaged worktree delete | `<space>D` | still in the index, gone on disk |
| Staged delete (`git rm`) | `D<space>` | `git rm` removes the worktree file as part of the same operation, so the worktree column reads unchanged rather than `D` |
| Staged add, then deleted from worktree | `AD` | the `D` in the worktree column is what matters; the index column is incidental |

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
  consuming the field *after* the `R`/`C` record, not the `R`/`C` record's
  own path.
- `tracked_removal_status?` still recognizes exactly ` D`, `D `, and `AD`
  (via its `D` worktree check) as removals, and nothing else.
- `spec/agent_apropos/git_spec.cr`'s real-repo removal specs still pass.
