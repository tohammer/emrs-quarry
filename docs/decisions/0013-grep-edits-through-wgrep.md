# 0013 — Editing grep results goes through wgrep, as an optional dependency

Date: 2026-10-10
Status: accepted

## Context

Results must be editable in the result buffer, with the changes written
to the files on an explicit commit. Two existing implementations: the
wgrep package (edit, then commit or abort) and Emacs 31's built-in
`grep-edit-mode` (edits go to the file buffers at once, and it requires a
`compilation-mode` buffer, ADR 0012). A third option is to write an own
edit-and-commit mode.

wgrep is driven by text properties (`wgrep-line-filename`,
`wgrep-line-number`, `wgrep-header`, `wgrep-footer`, `wgrep-ignore`) set
by two functions a mode provides through `wgrep-header&footer-parser` and
`wgrep-results-parser`.

## Decision

quarry integrates wgrep and does not depend on it: the package loads and
searches without wgrep, and the edit command reports that wgrep is needed
when it is missing. The two parser functions translate quarry's own text
properties into wgrep's when edit mode is entered. Lines whose text is
not exactly the file's line (shortened, or with bytes that are not valid
UTF-8) are marked so that wgrep does not edit them.

## Consequences

- Users get the edit, commit and abort behaviour and keys they know from
  rg.el and consult.
- quarry relies on wgrep's property interface. The wgrep tests run only
  when wgrep is on the test load path, like the consult tests.
- Line numbers come from the disk state at search time. Entering edit
  mode checks the files for changes since the search first.
