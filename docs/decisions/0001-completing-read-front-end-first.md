# 0001: A completing-read table first, consult later

Status: accepted (2026-10-06)

## Context

projdex answers fuzzy queries from a Rust index. Two front ends were
compared:

- **A plain `completing-read` table.** Each keystroke calls `emrs-call-sync`
  with the query. Works with every completion UI and can back
  `project-find-file` via `project-read-file-name-function`; easy to test
  with ERT. But it is synchronous, needs a pass-through completion style so
  Emacs does not re-filter and re-sort the ranked results, needs caching per
  input because UIs call the table several times per keystroke, and uses
  emrs streams only for the initial walk.
- **A consult async source.** Debounced, cancelled per keystroke, results
  streamed incrementally; never blocks Emacs and is usable during indexing.
  But it depends on consult's internal async API (`consult--async-*`,
  reworked in consult 2.0), does not back `project-find-file`, and is harder
  to test.

## Decision

Version 1 ships the `completing-read` table with a pass-through completion
style, hooked into `project-find-file`. The Lisp core that talks to the
module is asynchronous and independent of any UI, so a consult adapter can
be added later as an optional file without changing the core.

## Consequences

- Per-keystroke latency through `emrs-call-sync` is the key performance
  target of version 1.
- Superseded queries are cancelled only when the UI abandons the call
  non-locally (for example icomplete's `while-no-input`); there is no
  stream per query in version 1.
- The consult adapter is in the backlog.
