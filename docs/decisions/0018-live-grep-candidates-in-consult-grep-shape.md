# 0018 — The live grep's candidates have consult-grep's shape

Date: 2026-10-12
Status: accepted

## Context

The live search commands show hits as completion candidates through a
step of consult's async pipeline, as the file finder does (ADR 0008).
The candidates need a format, a category, a preview and a way to export
them. Two ways:

- **quarry's own format and category**, with its own preview state and
  its own embark exporter. Independent of consult's grep code; preview
  and export have to be written and registered, and Doom's writable
  export (`+vertico/embark-export-write`), which knows a fixed set of
  categories, needs an override in the user's configuration.
- **The format of `consult-ripgrep`**: `FILE:LINE:TEXT` with the faces
  `consult-file`, `consult-line-number` and `consult-highlight-match`,
  the property `consult--prefix-group` on the file name, and the
  category `consult-grep`.

## Decision

The second, chosen by the author. The step builds candidates in that
shape from the service's file items, and the commands read them with
`consult--grep-state` (preview and jump), `consult--prefix-group`
(grouping by file) and `consult--lookup-member`.

## Consequences

- Preview, grouping, `embark-export` to a `grep-mode` buffer, wgrep on
  that buffer and Doom's `C-c C-e` work as for `consult-ripgrep`,
  without code in quarry.
- quarry depends on more consult internals than ADR 0008 named: the two
  functions above and the way `consult--grep-position` reads a candidate
  (the file name ends at the first change of `face`, the line number at
  the next, and every stretch of the text with a `face` counts as a
  match unless the face list holds `consult-grep-context`). A test feeds
  a candidate the step made to `consult--grep-position`; it runs only
  when `tests/run-ert.sh` finds consult.
- `embark-export` gives a `grep-mode` buffer, not a `*quarry-grep*`
  buffer. The way to the result buffer is a key of its own in the
  prompt, which runs the search again instead of exporting candidates.
- Only the primary filter's matches get `consult-highlight-match`. The
  other include filters' matches get the face list
  `(quarry-grep-match-secondary consult-grep-context)`: the second face
  makes consult leave them out of its matches, so point and the preview
  follow the primary match, as in the result buffer. Where
  `quarry-grep-match-secondary` sets no attribute, that face's (a
  shadowed foreground) shows through.
