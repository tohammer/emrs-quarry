# 0012 — The grep result buffer is its own mode built on text properties

Date: 2026-10-10
Status: accepted

## Context

rg.el derives its result mode from `compilation-mode`: the process output
is inserted as text, ANSI colours are stripped by regexp in a filter, and
`compilation-mode` finds file names and line numbers by regexp again.
That work is unnecessary here, because the service delivers each match as
a structured value. The buffer also needs things `compilation-mode` does
not offer: a block of filter lines that point can enter, and file blocks
that fold.

Emacs 31 has `grep-edit-mode` for editing results, but it reads
`compilation-message` properties and so needs a `compilation-mode` buffer.

## Decision

`quarry-grep-mode` derives from `special-mode`. Every inserted line
carries text properties that say what it is (filter, file heading, match
with file and line number). Visiting, `next-error`, folding, the filter
commands and the wgrep integration read these properties and never parse
buffer text.

## Consequences

- Inserting results costs one `insert` and a few property changes per
  line, measured at about 6 µs per line in batch Emacs.
- `next-error` and `previous-error` work through `next-error-function`.
  Commands that exist only for compilation buffers do not; the ones worth
  having (next and previous file) are written here.
- `grep-edit-mode` cannot be used. Editing goes through wgrep (ADR 0013).
- The buffer layout is ours to keep stable; tests address lines by
  property, not by column.
