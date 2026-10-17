# 0025 — A replace preview over the line limit counts on, up to a bound, and offers a rerun

Date: 2026-10-17
Status: accepted

## Context

A search stops at `quarry-grep-max-lines` kept lines (50,000), and
`C-c C-c` refuses a truncated preview because only what is shown would
be written. The refusal could not say whether raising the limit would
help: the search stopped, so the number of kept lines in the tree was
unknown. Up to about 100,000 kept lines a raised limit is cheap
(architecture, "Cost of large change sets"); above that, narrowing is
the way (README, "Large replacements").

Options for learning the total: a second count-only request when
`C-c C-c` is pressed (a delay at the moment of the question, and a
second walk); counting in the same search after the cap, without
sending lines, for every search (a capped ordinary search would walk the
whole tree); the same, but only when asked for, and only up to a bound.

## Decision

Chosen by the author on 2026-10-17: the third.

- A `(:search)` may carry `:count-up-to N`. When the cap is reached, the
  search sends nothing more but goes on counting kept lines, with the
  same filters, until the walk ends or the count reaches `N`. The
  summary then has `:total`, the count, at most `N`.
- Elisp sends it for previews only (a search with a template), with `N`
  one more than `quarry-grep-replace-max-lines` (100,000), so a `:total`
  of at most that option is exact and a larger one means "more".
- `C-c C-c` on a truncated preview with an exact `:total` asks whether to
  search again with a limit of `:total`. That limit belongs to the search
  value, like the template, and does not change the option.

## Consequences

- An ordinary search and the live grep are as before: they never send
  `:count-up-to`.
- A truncated preview finishes later: it walks the rest of the tree, or
  up to the bound. The lines arrive as before; only the summary waits.
  `C-c C-k` during the count cancels the search, and a cancelled preview
  cannot be applied anyway.
- The extra work is bounded by `N` kept lines when the tree has more,
  but a tree with few kept lines beyond the cap is walked to its end.
- An older module ignores the unknown field and sends no `:total`; the
  refusal is then the one from before.
- The count is a snapshot. When files change before the rerun, the rerun
  may be truncated again and the question comes again.
