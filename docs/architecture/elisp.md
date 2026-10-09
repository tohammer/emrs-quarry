# Architecture: the Elisp side

Building and loading the module, instances, and the two front ends. Part
of [the architecture](../architecture.md).

## Building and finding the module

The module is built on the user's machine and lives next to `projdex.el`
(ADR 0006). `projdex-build--find-repo` takes the repository root as the
parent of the directory of the true name (symlinks resolved) of
`projdex-build.el` itself (of its `.el` when loaded from a `.elc`), or of
`projdex.el` on `load-path` when that fails. Its own location comes first,
so another `projdex.el` on `load-path` cannot redirect a build; `projdex-build--repo` additionally requires `Cargo.toml` there
and otherwise signals a `user-error` that points to the manual
installation. Both entry points run `cargo build --release --target-dir <repo>/target`
(`projdex-build-cargo-program`) in the repository, with output in
`*projdex-build*`, and install `target/release/libprojdex.so`
(`.dylib` on macOS, `projdex.dll` on Windows) by copying it to a temporary
file in `lisp/` and renaming that over `lisp/projdex-module` plus
`module-file-suffix`. The rename replaces the directory entry, so an Emacs
that has the old module loaded keeps a valid mapping; it needs a restart to
use the new one.

- `projdex-build-module` is the interactive, asynchronous command (a
  `compilation-mode` buffer). It reports "projdex module built", with
  "restart Emacs to use it" when a projdex module is already loaded. The
  install runs from `compilation-finish-functions` for `*projdex-build*`,
  so `recompile` (`g`) installs too; a second build while one runs is a
  `user-error`.
- `projdex-build-module-sync` waits and never signals; any failure becomes
  a `display-warning` that names `M-x projdex-build-module`; in batch
  (`doom sync`) the warning carries the tail of cargo's output, since the
  buffer dies with the process. A straight
  `:pre-build` form loads `projdex-build.el` and calls it, so `doom sync`
  completes without a Rust toolchain.

`projdex--start` loads the module with `emrs-load-module` from
`projdex--module-file` (the file in `lisp/` when it exists), and otherwise
by name from `load-path`, which keeps manual installations working. When
loading fails with `file-missing`, an interactive Emacs with a repository
is asked whether to build now (`y-or-n-p`); yes starts
`projdex-build-module` and signals a `user-error` to run the command again
when it is done. Otherwise the `user-error` names the expected file and
`M-x projdex-build-module`.

## Instances

`projdex--instances` maps the project root to a record (instance, file
count, `indexing`, `watching`, epoch, a unique `id` for cache keys, and
whether the watch-failure warning was shown). `projdex--ensure` returns the
running record or starts an instance with `emrs-start` and the start
arguments (`:root`, `:include-hidden`, `:ignores`). Events update the
record: `:indexed` sets the file count, `:changed` adjusts it by the
added and removed counts, and both increment the epoch; `:watch-failed` clears `watching` and shows one warning. On exit the
record is removed; a failed instance leaves a warning and its message. There
is no automatic restart; the next command starts a new instance.

## Completion on the Elisp side

`projdex--table` returns a completion table with category `project-file`,
`identity` sort functions, and the whole input as the query. Completion UIs
call the table several times per keystroke, so each table keeps its last
four results in a cache keyed by (string, record, epoch, limit, highlight,
match style). A change event increments the epoch, which invalidates
cached results. Highlighting copies each path and adds, at the positions
of term N, face N of `projdex-match-faces` (modulo their number).

The `projdex` completion style hands the input to the table unchanged and
returns its result as is. `projdex-find-file` binds
`completion-category-overrides` for the `project-file` category and sets
`completion-styles` to `(projdex)` buffer-locally in its minibuffer, so
only that style applies during its prompt (ADR 0005). Remote projects and a prefix
argument defer to `project-find-file`, in `projdex-consult-find-file` too.

The table's try-completion returns nil without results, the input for
several, `t` for a sole exact match and the sole match otherwise, so TAB
completes a unique match; the style's try function wraps that as
`(STRING . POINT)` or `(CANDIDATE . LENGTH)`. Replies with `:indexing` true
are not cached. After a failure the table reports once and has no
candidates for the rest of the prompt; a timeout gives no candidates and
one message.

`projdex--prepare (root &optional no-wait)` makes the instance ready
for a prompt and is the first step of both commands, so no table or
async step starts an instance, or asks whether to build the module
(`projdex--offer-build`), from inside the minibuffer. It ensures the
instance, sends `(:rescan)` when the instance is not watching, then
probes with `(:status)`, so a failed or unstartable instance is a
`user-error` before the prompt. For `projdex-find-file`
(`projdex--await-first-page`), while a walk runs and the index holds
fewer than `projdex-limit` files, it keeps probing, for at most 1 s
(`projdex--first-page-wait`): completion UIs ask for the empty input once
and do not refresh while indexing runs, so a prompt opened on a new
instance would stay empty until the user types. The consult command
passes NO-WAIT and gets a single probe: its async step re-queries while
indexing runs, so its prompt opens at once and fills. Results for typed input
during a long first walk still reflect the paths seen so far.

`projdex-find-file` reads with require-match `confirm` and history
`projdex-file-history`; input that is not an indexed path but completes to
exactly one is visited as that file.

`projdex-mode-map` binds the remap of `project-find-file` directly to the
value of `projdex-find-file-command` (`projdex-find-file` or
`projdex-consult-find-file`) when `projdex.el` is loaded, so a value set
before loading applies. A variable watcher on the option
(`projdex--find-file-command-watcher`) rebinds it with `keymap-set` on
`set`, `let` and `unlet` of the global value, so a `setq` takes effect at
once, with the mode on or off. A plain binding, unlike a filtered
`menu-item`, is seen by `where-is-internal`, so `C-h w`, `M-x` key hints
and menus show the key of the command it remaps to (ADR 0009).

`project-files` is overridden by an `:around` method that applies only with
`projdex-mode` and `projdex-provide-project-files`, for the whole root of a
local project that has a running instance. It collects the `:files` stream
while waiting in `accept-process-output` and falls back to the next method
on timeout or error.

## The consult front end

`projdex-consult-find-file` (`lisp/projdex-consult.el`) shows candidates
from `consult--read` with an async pipeline of consult 2.0 or later
(ADR 0008). The file requires consult optionally and declares the
functions it calls, so it loads and compiles without it; the command
signals a `user-error` when consult cannot be loaded or lacks
`consult--async-pipeline`.
After the same remote and prefix-argument fallback and
`projdex--prepare` with NO-WAIT (one probe, no wait for a first page), it
reads with category `project-file`, no sorting,
require-match `t` (a candidate must be chosen, a new file cannot be
visited) and history `projdex-consult-history`, and visits the root plus
the chosen path.

The pipeline is, in order, `consult--async-split` (which honours
`consult-async-split-style`), `consult--async-throttle` (with
`projdex-consult-input-throttle` and `projdex-consult-input-debounce`,
since consult's defaults are tuned for processes), the projdex step,
`consult--async-indicator` and `consult--async-refresh`. There is no
minimum input: the empty input lists files. The pipeline is complete, so
`consult--read` gets `:async-wrap #'identity`.

The step, `projdex-consult--async`, keeps the current input, the pending
call, a timer and a flag for the first error:

- A new input string cancels the pending call (`emrs-cancel`) and the
  timer, sends the input with `projdex-query-async` (`projdex-limit`,
  `projdex-highlight`) and shows the indicator as running. Nothing else
  is passed on. A call carries a serial number, so a reply of a
  superseded call is ignored.
- The step sends `flush` to the sink only when a reply arrives, then the
  candidates (the paths copied, highlighted with `projdex--highlight`,
  the strings `projdex--table` returns) and the finished indicator. The
  old candidates stay on screen until the new ones are there.
- A reply with `:indexing` true arms a timer that sends the current input
  again after `projdex-consult-refresh-interval`, so the list fills while
  the first walk runs. A reply with `:indexing` false arms nothing.
- A call error is shown once with `message`, followed by `flush` and the
  failed indicator, and arms no timer. The next input queries again,
  which may start a new instance; an error from that is reported the same
  way. A cancelled call is ignored.
- `cancel` and `destroy` cancel the call and the timer and pass the action
  on.

Callbacks run from process filters and timers, outside the minibuffer;
consult's refresh step and the sink handle that.

Completion styles cannot re-filter the results. `consult--async-split`
hands the UI's styles only the filter part of the input (what follows the
second separator, empty with the split style `none`), so with the
default `perl` style `#query#filter` filters projdex's results locally
with the user's styles, and a plain query is not filtered at all. This
meets the requirement of ADR 0005 without setting `completion-styles`
(ADR 0008). The command composes consult's internal steps (`consult--`
functions); only the end-to-end tests exercise them, against the consult
found through `PROJDEX_TEST_LOAD_PATH`.
