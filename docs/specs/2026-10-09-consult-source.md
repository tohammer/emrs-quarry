# consult front end

Status: implemented
Date: 2026-10-09

## Purpose

consult users get a project file prompt that never blocks Emacs: each
input goes to the index asynchronously, a superseded query is cancelled,
and results appear and update while the first walk of a large project
still runs. It is an optional file, `lisp/projdex-consult.el`, next to the
`completing-read` front end of version 1 (ADR 0001), and uses
consult's async pipeline with its own step (ADR 0008).

Success: on a project being indexed, the prompt shows files at once and
fills while indexing runs without typing; typing never freezes Emacs;
with orderless as the user's style, a query shows exactly projdex's
results in projdex's order; without consult installed, nothing breaks.

## Scope

In:

- `projdex-consult-find-file`, a command like `projdex-find-file`.
- An option that makes `projdex-mode` remap `project-find-file` to it.
- Re-querying while the instance indexes.
- The probe before the prompt, shared with `projdex-find-file`.
- ERT tests, run when consult is available; README and architecture.

Out:

- A `consult--multi` source (for `consult-buffer-sources`).
- File preview (consult `:state`).
- Visiting a file that is not in the index (`projdex-find-file` allows it
  with `confirm`; here a candidate must be chosen).
- Live updates from watcher changes after indexing has finished.

## Design

### Shared preparation (`projdex.el`)

The steps `projdex-find-file` runs before its prompt become
`projdex--prepare (root &optional no-wait)`: ensure the instance, send
`(:rescan)` when it is not watching, and `projdex--await-first-page`;
with NO-WAIT, a single `(:status)` probe instead of the wait, for a
prompt that refreshes while the index fills. It signals a
`user-error` when the instance cannot be started or failed, which
includes the question whether to build a missing module
(`projdex--offer-build`). Both commands call it before their prompt, so
neither the async step nor a completion table ever starts an instance in
the minibuffer. The backlog paragraph about `projdex--start` asking from
inside the minibuffer is then resolved for both front ends.

### Command selection (`projdex.el`)

`projdex-find-file-command`, a user option with the values
`projdex-find-file` (default) and `projdex-consult-find-file`. The remap
in `projdex-mode-map` is bound to the option's value at load time, and a
variable watcher on the option rebinds it with `keymap-set` on `set`,
`let` and `unlet`, so a plain `setq` takes effect at once, before or
after the mode is enabled. A plain binding, unlike a filtered
`menu-item`, is found by `where-is-internal`, so `C-h w` and `M-x` show
the key. `projdex-consult-find-file` is autoloaded.

### `lisp/projdex-consult.el`

Loads `projdex` and `(require 'consult nil t)`; it does not fail to load
or byte-compile without consult (`declare-function` for what it calls).
`projdex.el` never loads it.

Options (group `projdex`):

- `projdex-consult-input-debounce`, default 0.05 s, and
  `projdex-consult-input-throttle`, default 0.1 s, passed to
  `consult--async-throttle`. consult's own defaults are tuned for
  processes and too slow for a local index.
- `projdex-consult-refresh-interval`, default 0.25 s: the delay between
  re-queries while the instance indexes.

`projdex-consult-find-file (&optional include-all)`:

1. Without consult 2.0 or later (`consult--async-pipeline` not fbound):
   `user-error` that says so.
2. With INCLUDE-ALL or a remote project: `project-find-file`, as in
   `projdex-find-file`.
3. `projdex--prepare root` with NO-WAIT: a single `(:status)` probe that
   reports a failed instance before the prompt, but no wait for a first
   page; the step re-queries while indexing runs.
4. `consult--read` with the pipeline below, `:prompt` like
   `projdex-find-file`'s, `:category 'project-file`, `:sort nil`,
   `:require-match t`, `:history '(:input projdex-consult-history)`,
   `:async-wrap #'identity` (the pipeline is complete; consult's default
   wrapper would add split, indicator and refresh a second time),
   `default-directory` bound to the root.
5. `find-file` of root plus the chosen path (concatenated, not
   `expand-file-name`, as in `projdex-find-file`).

The pipeline:

```elisp
(consult--async-pipeline
 (consult--async-split)                 ; honours consult-async-split-style
 (consult--async-throttle projdex-consult-input-throttle
                          projdex-consult-input-debounce)
 (projdex-consult--async root)          ; the projdex step
 (consult--async-indicator)
 (consult--async-refresh))
```

No `consult--async-min-input`: the empty input lists files, as in
`projdex-find-file`. `consult--async-split` gives the user's completion
styles only the filter part of the input, so they never re-filter
projdex's results (ADR 0008, ADR 0005).

### The projdex step

`projdex-consult--async (root)` returns `(lambda (sink) (lambda (action)
...))`. State: the current input, the pending call, a refresh timer and a
`reported` flag.

| Action | Behaviour |
|---|---|
| string | When it differs from the current input, or a re-query is due: cancel the pending call (`emrs-cancel`) and the timer, send the input with `projdex-query-async root input projdex-limit highlight` (highlight as `projdex-highlight`), send `[indicator running]` to the sink. Pass nothing else on. |
| `cancel` | Cancel the pending call and the timer, pass `cancel` on. |
| `destroy` | Same, pass `destroy` on. |
| anything else | Pass on unchanged. |

When a reply arrives for the pending call (replies of other calls are
ignored): send `flush`, then the candidates as a list (when not empty),
then `[indicator finished]`. Candidates are the paths, copied, with
`projdex--highlight` applied when positions are present — the same
strings `projdex--table` returns. When the reply has `:indexing` true, arm
the timer to resend the current input after
`projdex-consult-refresh-interval`; the re-query replaces the shown
candidates when its reply arrives, so the list does not flicker empty.

The callback runs outside the minibuffer (process filter or timer);
`consult--async-refresh` and the sink's `refresh` handle that.

### Data formats

No new protocol. The step uses the `:query` reply as `projdex-query`
documents it (`:paths :positions :groups :total :indexing`).

## Error handling

- consult missing or older than 2.0: `user-error` from the command;
  loading the file still works.
- Instance cannot start, module missing, instance failed before the
  prompt: `user-error` from `projdex--prepare`, as in `projdex-find-file`.
- Call error during the prompt (instance exited or failed): the step
  shows the error once with `message` (`reported`), sends `flush` and
  `[indicator failed]`, and arms no timer. Later inputs send new queries;
  `projdex--ensure` inside `projdex-query-async` may start a new
  instance. If that start signals, the step catches the error, reports it
  once and shows no candidates.
- A cancelled call (error kind `cancelled`): ignored.
- A call that never answers: the indicator stays "running"; the next
  input cancels it. No timeout.
- Quitting the prompt: `destroy` cancels the pending call and the timer.

## Testing

`tests/projdex-consult-tests.el`, loaded by `tests/run-ert.sh` after the
main suite. The script adds the directories in `PROJDEX_TEST_LOAD_PATH`
(colon-separated, for consult and compat) to `load-path`; every test that
needs consult is skipped (`skip-unless`) when consult 2.0 or later cannot
be loaded, and the script says so. (Implemented: only the command and
end-to-end tests need consult; the step tests run without it.)

Automated:

- The step, driven directly with a recording sink on a real instance:
  an input yields `flush`, the highlighted candidates in projdex's order
  and `[indicator finished]`; an input superseded before its reply yields
  only the second input's candidates, and the first call is cancelled.
- Re-query while indexing: with replies faked to say `:indexing t` a
  number of times, the step re-sends until a reply says `:indexing nil`
  and then stops; `destroy` stops it too.
- Failure: a stopped instance during the prompt reports once and shows
  no candidates.
- End to end through `consult--read` in batch (driven with a timer that
  waits for candidates, since keyboard macros do not let timers run):
  the chosen file is visited and the history keeps the typed input
  (`#main` with the perl style), not the candidate; with a style that behaves like orderless
  (`projdex-test--greedy-*`) and split style `none`, a query without
  matches shows no candidates and one with matches shows projdex's
  results unchanged.
- `projdex--prepare`: the existing `projdex-find-file` tests keep
  passing; the consult command signals the `user-error` for a failed
  root before any prompt, and with `:status` faked to say indexing with
  no files it reaches `consult--read` at once, after exactly one probe.
- Remap: `command-remapping` of `project-find-file` follows
  `projdex-find-file-command` when it is changed with `setq` while the
  mode is on or off, and `where-is-internal` finds a key for the command
  it remaps to.
- Without consult: in a batch Emacs with only projdex and emrs on
  `load-path`, `projdex-consult.el` loads and byte-compiles without
  error, and the command signals the consult `user-error`.

Manual, in Doom with vertico and orderless (not covered by tests):

- On a large tree with a fresh instance, the prompt opens at once and
  the list grows while indexing runs, without typing.
- Fast typing does not stall the cursor; the indicator shows running and
  finished.
- `#query#filter` with the default perl split style filters the results
  locally with orderless.
- `projdex-find-file-command` set to `projdex-consult-find-file`:
  `C-x p f` opens the consult prompt.

## Deviations from the approved version

Changed during implementation and review; the sections above describe
the result.

- `consult--read` gets `:async-wrap #'identity`; without it consult wraps
  the pipeline a second time and the split step fails.
- The remap is a plain binding that a variable watcher keeps in step with
  `projdex-find-file-command` (ADR 0009), not a filtered `menu-item`,
  which `where-is` cannot see.
- The consult command calls `projdex--prepare` with NO-WAIT: one probe,
  no wait for a first page (user decision in the review).
- `cancel` and `destroy` also forget the current input, so the same input
  queries again after consult's throttle cancelled its call.

## Tasks

- [x] 1. `projdex--prepare` and `projdex-find-file-command` in
  `projdex.el`, with the remap kept in step with the option by a
  variable watcher. *Done when*
  `projdex-find-file` uses `projdex--prepare`, all existing ERT tests
  pass, and a new test shows the remap following a `setq` of the option.
- [x] 2. `lisp/projdex-consult.el`: options, the step, the command, loads
  and compiles without consult; `run-ert.sh` loads
  `tests/projdex-consult-tests.el` with `PROJDEX_TEST_LOAD_PATH` and the
  skip. *Done when* every automated test listed under Testing passes with
  the installed consult 3.7 and compat, and the no-consult load and
  compile test passes.
- [x] 3. Docs: README (install, the command, the option, consult ≥ 2.0,
  `PROJDEX_TEST_LOAD_PATH`), architecture (component table, completion
  section), backlog (remove the consult item; keep nothing of its second
  paragraph that `projdex--prepare` resolves), next-steps. *Done when*
  `devflow:doc-checker` reports nothing stale.
