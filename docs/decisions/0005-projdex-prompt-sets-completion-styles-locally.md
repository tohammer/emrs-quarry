# 0005 — The projdex prompt sets `completion-styles` buffer-locally

Date: 2026-10-09
Status: accepted

## Context

ADR 0002 restricted projdex prompts to the `projdex` style by let-binding
`completion-category-overrides`. That does not restrict them: Emacs's
`completion--styles` appends `completion-styles` to the override's styles,
and the next style runs whenever the previous one returns nothing. With
Doom's `(orderless basic)`, a query without matches made orderless ask the
table for the empty prefix; the table ignores `completion-regexp-list`, so
every file was listed. Reported by the user in vertico.

## Decision

`projdex-find-file` keeps the override and additionally sets
`completion-styles` to `(projdex)` with `setq-local` in its minibuffer
(`minibuffer-with-setup-hook`). The table still answers any string it is
given; it does not try to emulate `completion-regexp-list`.

## Consequences

- No other style runs in projdex prompts, also when nothing matches: no
  match shows no candidates.
- The setting is local to the prompt's minibuffer buffer, so recursive and
  later minibuffers keep the user's styles, as before.
- Other callers of `projdex--table` (a future consult source) must
  restrict the styles the same way. The regression test
  `projdex-test-ui-no-match-shows-nothing` uses a style that behaves like
  orderless.
