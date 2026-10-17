# Grep: replace previews over the line limit

Status: approved
Date: 2026-10-17

## Purpose

When a replace preview stops at `quarry-grep-max-lines`, `C-c C-c` is
refused with "narrow the search or raise `quarry-grep-max-lines`". It
cannot tell which of the two helps, because the search stopped and the
number of hits is unknown. This spec makes a truncated preview count the
hits it did not send, up to a bound, so that `C-c C-c` can offer to
search again with a limit that fits. Above the bound it says to narrow
the search instead.

Success: a preview with 73,412 hits under the default limit of 50,000
needs `C-c C-c`, `y`, the wait for the rerun, and `C-c C-c` to apply.
A preview with more than 100,000 hits says so and points to "Large
replacements" in the README. Searches without a template behave and
cost exactly as before.

## Scope

In:

- The service: `:count-up-to` in `(:search)`, `:total` in the summary
  (ADR 0025).
- The result buffer: `:count-up-to` for previews, a search value slot
  for the raised limit, the question in `C-c C-c`, and the total in the
  status line.
- A new option, `quarry-grep-replace-max-lines`.
- README ("Replacing matches", "Large replacements", the options
  table), `docs/architecture/grep.md`, the service's module docs.

Out:

- Counting for searches without a template, and in the live grep.
- Raising the limit of a plain search from the status line. Revisit if
  it is missed; the count would be the same mechanism.
- Raising the limit above `quarry-grep-replace-max-lines` from the
  question. To go above it, set `quarry-grep-max-lines` yourself (README,
  "Large replacements").

## Design

### Service (`src/grep/service.rs`, `src/grep/search.rs`)

- New optional field `:count-up-to`: an integer, nil or missing for no
  counting. It is honoured only when the search is truncated; a value
  at or below `:max-lines` counts nothing beyond the cap.
- At the cap, today, the thread that fills it sets `truncated` and the
  stop flag, and every thread quits. With `:count-up-to`, the cap
  instead switches the search to counting:
  - Nothing more is sent: no file items, no context lines.
  - Each thread goes on through the walk and counts kept lines (the
    primary filter's lines that `Filters::keep_line` keeps, the same
    definition as for the cap) in a second shared counter. That includes
    the rest of the file it was reading when the cap was reached: the
    lines it read but did not deliver count too. So `:total` is the
    number of kept lines in the whole tree, as the cap counts them.
  - Lines are not cut, converted or given replacements while counting;
    only matching and `keep_line` run.
  - The search stops as today (`WalkState::Quit`, the stop flag) when the
    counter reaches `:count-up-to`.
  - Cancellation works as today in both phases.
- The summary gets `:total N` when `:count-up-to` was given and
  `:truncated` is t: the kept lines counted, at most `:count-up-to`. In
  every other case the key is left out, so summaries are as before.
- The module docs give the field, the key, and the rule "`:total` below
  `:count-up-to` is exact; equal to it means at least that many".

### Search value and request (`lisp/quarry-grep.el`)

- `quarry-grep--search` gets a slot `max-lines`: nil, or an integer that
  takes the place of `quarry-grep-max-lines` for this search.
  `quarry-grep--request` sends `:max-lines` from it when set, else from
  the option, as today.
- With a template, the request also sends `:count-up-to` as
  `(1+ quarry-grep-replace-max-lines)`.
- The slot is carried like the template: a filter change, `f`, `d`, `g`
  and the other changes during a preview keep it. Leaving the preview
  (`C-c C-k`) drops both. `C-c <` and `C-c >` move between search
  values, each with its own slot.
- The header line shows nothing new. The status line of a truncated
  preview with `:total` says `Search stopped at 50000 of 73412 lines`,
  or `of more than 100000 lines` when `:total` is above
  `quarry-grep-replace-max-lines`. Without `:total` it is as today.

### `C-c C-c` on a truncated preview

The refusal for a truncated result in `quarry-grep--apply-refusal` is
replaced by the cases below. They are checked where that refusal is
today: after "running", "failed" and "cancelled", before "no match is
switched on".

| `:total` | What `C-c C-c` does |
|---|---|
| at most `quarry-grep-replace-max-lines` | Asks `73412 lines match, over the limit of 50000; search again with a limit of 73412? ` (`y-or-n-p`). Yes sets the slot to `:total` and runs the search (`quarry-grep--change`), with the message `Searching again; press C-c C-c when the search is done`. No does nothing |
| above it | `user-error`: `More than 100000 lines match; narrow the search (README, "Large replacements")` |
| missing (an older module) | The refusal from before |

The message names the limit currently in force (the slot, else the
option) and the total from the summary. In the menu (`?`), the `C-c C-c`
entry is active for a truncated preview with an exact total, since it
asks the question there, and inactive in the other two cases.

### New option

```elisp
(defcustom quarry-grep-replace-max-lines 100000
  "Largest line limit that `quarry-grep-replace-apply' offers to search with.
A replace preview that stops at `quarry-grep-max-lines' counts its
lines up to one more than this, and \\[quarry-grep-replace-apply] offers
to search again with a limit that holds them all."
  :type 'natnum)
```

A value at or below `quarry-grep-max-lines` makes the question never
appear: every truncated preview then counts beyond it and gets the
"narrow the search" answer.

## Error handling

| Situation | What happens |
|---|---|
| The rerun is truncated again (files changed, or the total grew) | Its own `:total`; `C-c C-c` asks again |
| `C-c C-k` while the preview counts | The search is cancelled as today; the preview is refused as cancelled |
| `C-c C-c` while counting | Refused as running, as today; the status line says `Searching…` |
| An older module | No `:total`; the old refusal |
| `quarry-grep-replace-max-lines` set to 0 or below the current limit | The question never appears; the "more than" answer names the option's value |

## Testing

Automated:

- `cargo test` in `src/grep/search.rs` and `service.rs`:
  - a tree with 30 kept lines, `:max-lines 10`, `:count-up-to 100`:
    `:lines 10`, `:truncated t`, `:total 30`, and only 10 kept lines
    delivered;
  - the same with `:count-up-to 20`: `:total 20`, and the walk stops
    early (count files searched against a run without the bound);
  - the kept lines of the file that filled the cap, beyond the cap,
    are counted; lines that a line filter drops are not;
  - without `:count-up-to` or without truncation, no `:total`;
  - cancelling during the count sends no summary.
- ERT (`tests/run-ert.sh`), with a fake stream where the service is not
  needed:
  - the request sends `:count-up-to` only with a template, and
    `:max-lines` from the slot;
  - the slot survives a filter change and `g`, and is dropped by `C-c C-k`;
  - `C-c C-c` with an exact total asks the question; yes reruns with the
    raised limit and the request says so; no sends nothing;
  - `C-c C-c` with a total above the option signals the `user-error`;
    without `:total`, the old refusal;
  - the status line for both kinds of total;
  - a real search through the module: a tree over a small limit, then
    yes, then apply, writes every file.
- `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, and
  the byte-compiler without warnings.

Manual, in the author's setup after rebuilding the module: a preview in
a large tree with a pattern of 60,000 to 90,000 hits; the wait for the
count; yes; the time of the rerun and of the apply.

## Tasks

The branch is based on `grep-replace` and is rebased on `master` after
PR #7 is merged.

- [x] 1. **Service: count beyond the cap.** `:count-up-to`, the counting
  phase, `:total` in the summary, the module docs and the architecture
  paragraph on the cap, with the `cargo test` cases above. *Done when*
  `cargo test`, clippy and fmt pass, and the existing cap tests pass
  unchanged.
- [ ] 2. **Search value, request and status line** (after 1). The
  `max-lines` slot, `:count-up-to` with a template, the option, the
  status line, and their ERT tests. *Done when* `tests/run-ert.sh`
  passes and a request without a template is byte for byte as before.
- [ ] 3. **The question in `C-c C-c`** (after 2). The three cases of the
  table, the menu entry, the real search test, and the README sections
  ("Replacing matches", "Large replacements", the options table). *Done
  when* `tests/run-ert.sh` passes on Emacs 30 and 31 and the README
  describes the question.
- [ ] 4. **Docs wrap-up.** Next-steps says to rebuild the module, the
  spec is set to `implemented`. *Done when* `devflow:doc-checker`
  reports nothing stale.
