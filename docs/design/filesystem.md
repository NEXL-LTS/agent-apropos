# Filesystem::Real implementation notes

Rationale that doesn't fit a spec name or a Crystal identifier, for
`src/agent_apropos/filesystem.cr`.

## `append` opens with `O_NOFOLLOW`

`append` is used only for the best-effort `--verbose` hook log, never for an
artifact whose bytes must be stable (that path goes through `write`'s
atomic temp-file-plus-rename instead). It opens the target with
`LibC::O_NOFOLLOW` rather than checking for a symlink and then opening —
a check-then-open has a TOCTOU window where a symlink can be swapped in
between the check and the open. `O_NOFOLLOW` closes that window by having
the kernel refuse the open atomically (`Errno::ELOOP`) if the target turns
out to be a symlink, so the reported "refuses to append through a symlink"
behavior holds even under a concurrent attacker, not just in the
single-threaded case a spec can express.

This is Unix-only (`LibC::O_NOFOLLOW` assumes POSIX opendir semantics).
Both shipping platforms (Linux, macOS) are Unix, and CI has no Windows leg
to verify a fallback against, so there isn't one — add real Windows
handling, with real Windows CI, when that binary ships (see
`docs/conventions/platform-flags.md`).
