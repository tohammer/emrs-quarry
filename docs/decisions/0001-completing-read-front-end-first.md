# 0001 — A completing-read table first, consult later

Date: 2026-10-06
Status: accepted

## Context

projdex answers fuzzy queries from a Rust index. Two front ends were
compared:

- **A plain `completing-read` table.** Each keystroke calls `emrs-call-sync`
  with the query. Works with every completion UI and can replace
  `project-find-file` through a key remap; easy to test
  with ERT. But it is synchronous, needs a pass-through completion style so
  Emacs does not re-filter and re-sort the ranked results, needs caching per
  input because UIs call the table several times per keystroke, and uses
  no emrs stream for queries (the only stream is `(:files)` for
  `project-files`).
- **A consult async source.** Debounced, cancelled per keystroke, results
  streamed incrementally; never blocks Emacs and is usable during indexing.
  But it depends on consult's internal async API (`consult--async-*`,
  reworked in consult 2.0), does not back `project-find-file`, and is harder
  to test.

## Decision

Version 1 ships the `completing-read` table with a pass-through completion
style (ADR 0002) in the command `projdex-find-file`, which `projdex-mode`
puts in place of `project-find-file` with a key remap. The Lisp core that talks to the
module is asynchronous and independent of any UI, so a consult adapter can
be added later as an optional file without changing the core.

## Consequences

- `project-read-file-name-function` cannot be used to hook in:
  `project-find-file` computes the complete file list with `project-files`
  before calling it, which is the slow part. (Corrected 2026-10-09; the
  first version of this ADR named that hook.)

- Per-keystroke latency through `emrs-call-sync` is the key performance
  target of version 1.
- Superseded queries are cancelled only when the UI abandons the call
  non-locally (for example icomplete's `while-no-input`); there is no
  stream per query in version 1.
- The consult adapter is in the backlog.
