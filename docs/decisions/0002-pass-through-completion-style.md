# 0002 — Rust ranks; a pass-through completion style keeps that ranking

Date: 2026-10-09
Status: accepted; the way the style is enforced is superseded by 0005

## Context

`completing-read` normally filters and sorts candidates with the user's
`completion-styles` (basic, flex, orderless, ...). projdex already matches
and ranks in Rust with nucleo. If Emacs filtered again, it could drop or
reorder results (nucleo's fuzzy matches are not all accepted by other
styles) and would spend Lisp time per keystroke on up to `projdex-limit`
candidates. Many orderless users set `completion-category-defaults` to nil,
so registering a default for a category alone is not reliable.

## Decision

projdex registers a completion style `projdex` that passes the input to the
table unchanged and returns the table's result as is. `projdex-find-file`
let-binds `completion-category-overrides` so that its category
(`project-file`) uses only that style for the duration of the prompt
(that alone does not restrict the styles; see 0005). The
metadata sets `display-sort-function` and `cycle-sort-function` to
`identity`. The query syntax is nucleo's pattern syntax.

## Consequences

- Inside projdex prompts, the user's completion styles do not apply;
  orderless-like behaviour comes from nucleo's syntax (space-separated terms
  in any order, `^prefix`, `suffix$`, `!negation`, `'exact`). The README
  documents this.
- Other prompts are unaffected, because the override is dynamically bound.
- Match highlighting must come from Rust (match positions), since no Emacs
  style computes it.
