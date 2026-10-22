# Architecture: the Elisp side

Registering and loading the module, instances and targets, finding a file
below a directory, and the two front ends. Part
of [the architecture](../architecture.md).

## Registering and loading the module

The module comes from emrs's installer, `emrs-install.el` (ADR 0027,
which replaces ADR 0006). `quarry-core.el` requires it and registers the
module at top level:

```elisp
(emrs-install-register 'quarry
  :version quarry-module-version
  :url "https://github.com/tohammer/emrs-quarry/releases/download"
  :source (or load-file-name buffer-file-name))
```

`quarry-module-version` is a `defconst` and must equal `version` in
`Cargo.toml` and the `;; Version:` header of `quarry.el`; the test
`quarry-test-module-versions-agree` checks it. `:source` is
`quarry-core.el`; its true name leads from straight's or elpaca's
symlinked build directory into the checkout, whose root has `Cargo.toml`.

`quarry--load-module` (in `quarry-core.el`, which `quarry.el` requires and
which does not require `quarry.el`; `quarry--start` and
`quarry-grep--ensure-instance` call it) is `(emrs-install-load 'quarry)`.
Callers let its `user-error` through. What the installer does is in the
emrs docs ([installer reference](https://github.com/tohammer/emrs/blob/master/docs/user/distributing.md#installer-reference),
emrs spec `2026-10-19-module-installer` and its ADRs); in short:

- It looks for the installed version under
  `emrs-install-directory`/quarry/<version>/, else for `quarry-module`
  plus `module-file-suffix` on `load-path`.
- Without either it downloads the release file of a plain version (after
  asking, checked against `SHA256SUMS`), or offers a cargo build of a
  `-snapshot` version in the checkout of `:source`, and signals a
  `user-error` to run the command again when the build is done.
- A local build older than its sources is offered again by a new Emacs.
- It warns once when the loaded module's `:version` differs from
  `quarry-module-version`.

The installer cannot see a module built from an older `-snapshot`
checkout, which reports the same version as the Elisp. quarry-grep checks
that itself: it turns the `emrs-error` of an unknown `grep` service into
a `user-error`, and notices a module that ignores replace templates, both
saying to install it again with `M-x emrs-install-module` and to restart
Emacs (see [Grep](grep.md)).

## Instances

`quarry--instances` maps the project root to a record (instance, file
count, `indexing`, `watching`, epoch, a unique `id` for cache keys, and
whether the watch-failure warning was shown). `quarry--ensure` returns the
running record or starts an instance with `emrs-start` and the start
arguments (`:root`, `:include-hidden`, `:ignores`; the last two from the
options `quarry-include-hidden` and `quarry-ignores`, which live in
`quarry-core.el` because the grep tool uses them too). Events update the
record: `:indexed` sets the file count, `:changed` adjusts it by the
added and removed counts, and both increment the epoch; `:watch-failed` clears `watching` and shows one warning. On exit the
record is removed; a failed instance leaves a warning and its message. There
is no automatic restart; the next command starts a new instance.

### Targets and one-shot records

A *one-shot record* is a record with the slot `one-shot` set. `quarry--start`
makes one when its optional ONE-SHOT argument is non-nil: the instance
starts with `:watch nil`, so `watching` is nil and the instance never
sees a change after its first walk. The record is **not** put into
`quarry--instances` and a failure is not recorded in `quarry--failures`
(`quarry--on-exit` only shows a warning for it). So `quarry-stop`,
`quarry-stop-all`, `quarry-status` and `project-files` never see one;
whoever started it stops it with `emrs-stop` (ADR 0020).

A *target* is what a query is sent to: a project root (a string) or a
one-shot record. `quarry--target-rec` returns the record of a target. For
a root that is `quarry--ensure`, which may start an instance. For a record
it is the record itself while its instance is starting or running; after
that it is a `user-error` ("quarry: the walk of DIR has ended"), since a
one-shot instance is never restarted. `quarry--call-sync`,
`quarry--table`, `quarry--prepare`, `quarry-query`, `quarry-query-async`
and the consult step take a target where they used to take a root; the
public `quarry-query` and `quarry-query-async` are documented with a
root and accept a one-shot record as well, for the commands of this
package.
`quarry-query`, `quarry-query-async`, `quarry--request` and `quarry--table`
also take an optional DIR, a directory relative to the root, which is sent
as `:dir`. A call that fails on a one-shot record reports the failure's
own message, as there is none in `quarry--failures`.

## Completion on the Elisp side

`quarry--table` returns a completion table with category `project-file`,
`identity` sort functions, and the whole input as the query. Completion UIs
call the table several times per keystroke, so each table keeps its last
four results in a cache keyed by (string, record, epoch, limit, highlight,
match style). A change event increments the epoch, which invalidates
cached results. Highlighting copies each path and adds, at the positions
of term N, face N of `quarry-match-faces` (modulo their number).

The `quarry` completion style hands the input to the table unchanged and
returns its result as is. `quarry-find-file` binds
`completion-category-overrides` for the `project-file` category and sets
`completion-styles` to `(quarry)` buffer-locally in its minibuffer, so
only that style applies during its prompt (ADR 0005). Remote projects and a prefix
argument defer to `project-find-file`, in `quarry-consult-find-file` too.

The table's try-completion returns nil without results, the input for
several, `t` for a sole exact match and the sole match otherwise, so TAB
completes a unique match; the style's try function wraps that as
`(STRING . POINT)` or `(CANDIDATE . LENGTH)`. Replies with `:indexing` true
are not cached. After a failure the table reports once and has no
candidates for the rest of the prompt; a timeout gives no candidates and
one message.

`quarry--prepare (target &optional no-wait)` makes the instance ready
for a prompt and is the first step of both commands, so no table or
async step starts an instance, or lets the installer ask whether to
download or build the module, from inside the minibuffer. It ensures the
instance, sends `(:rescan)` when the instance is not watching (not to a
one-shot record, which is not watching by design and walks once), then
probes with `(:status)`, so a failed or unstartable instance is a
`user-error` before the prompt. For `quarry-find-file`
(`quarry--await-first-page`), while a walk runs and the index holds
fewer than `quarry-limit` files, it keeps probing, for at most 1 s
(`quarry--first-page-wait`): completion UIs ask for the empty input once
and do not refresh while indexing runs, so a prompt opened on a new
instance would stay empty until the user types. The consult command
passes NO-WAIT and gets a single probe: its async step re-queries while
indexing runs, so its prompt opens at once and fills. Results for typed input
during a long first walk still reflect the paths seen so far.

`quarry-find-file` reads with require-match `confirm` and history
`quarry-file-history`; input that is not an indexed path but completes to
exactly one is visited as that file.

`quarry-mode-map` binds the remap of `project-find-file` directly to the
value of `quarry-find-file-command` (`quarry-find-file` or
`quarry-consult-find-file`) when `quarry.el` is loaded, so a value set
before loading applies. A variable watcher on the option
(`quarry--find-file-command-watcher`) rebinds it with `keymap-set` on
`set`, `let` and `unlet` of the global value, so a `setq` takes effect at
once, with the mode on or off. A plain binding, unlike a filtered
`menu-item`, is seen by `where-is-internal`, so `C-h w`, `M-x` key hints
and menus show the key of the command it remaps to (ADR 0009).

`project-files` is overridden by an `:around` method that applies only with
`quarry-mode` and `quarry-provide-project-files`, for the whole root of a
local project that has a running instance. It collects the `:files` stream
with `emrs-call-stream-sync`, which waits on the module's pipe only, so
the filters of other processes do not run inside `project-files`
(timers do; emrs ADR 0003), and falls back to the next method on timeout
or error.

## Finding a file below a directory

`quarry--dir-target (dir &optional no-wait)` decides where an absolute,
local, existing directory DIR is answered from and returns `(TARGET .
REL)`:

1. `(project-current nil dir)` gives a project with a local root, and the
   true names of DIR and the root are equal: `(ROOT . nil)`, the whole
   index of the project.
2. DIR is below the root (true names, so a symlinked path works):
   REL is DIR's true name relative to the root's, with a trailing `/`.
   The root is prepared (`quarry--prepare`, with NO-WAIT), then queried
   with `:text "" :limit 1 :dir REL`. When the reply has `:total` above 0,
   the result is `(ROOT . REL)`: queries carry `:dir REL` and the candidates are relative to DIR.
3. Otherwise (no project, a remote project root, DIR not below the root's
   true name, or no indexed file below DIR, as in an ignored
   `node_modules/` or a directory a running walk has not reached; the
   `:indexing` flag does not count): a one-shot record for DIR is started with
   `quarry--start` and prepared, and the result is `(REC . nil)`. If
   preparing fails, the instance is stopped before the error goes on.

`quarry--check-directory` runs first in both commands: a remote DIR is a
`user-error` ("quarry finds files in local directories only") and a
missing one a `user-error` that names it. Everything that starts an
instance or offers to build the module happens before the prompt.

`quarry-find-file-in-directory (&optional dir)` takes `default-directory`
for DIR, or, with a prefix argument, reads it with `read-directory-name`.
After `quarry--dir-target` it reads with `quarry--read-file`, the part of
`quarry-find-file` that is shared: the `quarry` style through the
category override and the buffer-local `completion-styles`, the table of
the target and REL, require-match `confirm`, and the exact-completion
rule. The history is `quarry-directory-file-history` and the prompt names
`abbreviate-file-name` of DIR. The file visited is DIR plus the chosen
path, joined with `concat` as in `quarry-find-file`. The prompt runs in
`unwind-protect`, which stops a one-shot instance when it ends, on `RET`,
`C-g` or an error. The plain prompt waits for a first page as
`quarry-find-file` does, so a one-shot walk of a large directory is
waited for up to `quarry--first-page-wait`.

## The consult front end

`quarry-consult-find-file` (`lisp/quarry-consult.el`) shows candidates
from `consult--read` with an async pipeline of consult 2.0 or later
(ADR 0008). The file requires consult optionally and declares the
functions it calls, so it loads and compiles without it; the command
signals a `user-error` when consult cannot be loaded or lacks
`consult--async-pipeline`.
After the same remote and prefix-argument fallback and
`quarry--prepare` with NO-WAIT (one probe, no wait for a first page), it
reads with category `project-file`, no sorting,
require-match `t` (a candidate must be chosen, a new file cannot be
visited) and history `quarry-consult-history`, and visits the root plus
the chosen path.

`quarry-consult-find-file-in-directory` (`lisp/quarry-consult.el`) is the
same command on this pipeline, with the same DIR, checks, target and
`unwind-protect` as the plain one. It calls `quarry--dir-target` with
NO-WAIT and shares the read with `quarry-consult-find-file`
(`quarry-consult--read`, which binds `default-directory` to DIR). The step
gets the target and REL, so the prompt opens at once and, through the
re-query while `:indexing` is true, fills while a one-shot instance walks.
The history is `quarry-consult-directory-history`. It signals the same
`user-error` without consult.

The pipeline is, in order, `consult--async-split` (which honours
`consult-async-split-style`), `consult--async-throttle` (with
`quarry-consult-input-throttle` and `quarry-consult-input-debounce`,
since consult's defaults are tuned for processes), the quarry step,
`consult--async-indicator` and `consult--async-refresh`. There is no
minimum input: the empty input lists files. The pipeline is complete, so
`consult--read` gets `:async-wrap #'identity`.

The step, `quarry-consult--async`, keeps the current input, the pending
call, a timer and a flag for the first error:

- The step takes a target and an optional REL (`quarry-consult--async
  root dir`), which it passes on to `quarry-query-async`. For a one-shot
  record it does not look up `quarry--failures`.
- A new input string cancels the pending call (`emrs-cancel`) and the
  timer, sends the input with `quarry-query-async` (`quarry-limit`,
  `quarry-highlight`) and shows the indicator as running. Nothing else
  is passed on. A call carries a serial number, so a reply of a
  superseded call is ignored.
- The step sends `flush` to the sink only when a reply arrives, then the
  candidates (the paths copied, highlighted with `quarry--highlight`,
  the strings `quarry--table` returns) and the finished indicator. The
  old candidates stay on screen until the new ones are there.
- A reply with `:indexing` true arms a timer that sends the current input
  again after `quarry-consult-refresh-interval`, so the list fills while
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
default `perl` style `#query#filter` filters quarry's results locally
with the user's styles, and a plain query is not filtered at all. This
meets the requirement of ADR 0005 without setting `completion-styles`
(ADR 0008). The command composes consult's internal steps (`consult--`
functions); only the end-to-end tests exercise them, against the consult
found through `QUARRY_TEST_LOAD_PATH`.

The live grep (`lisp/quarry-consult-grep.el`) is a second consult front
end, on the grep service; it is described with the grep tool
([grep.md](grep.md), "The live grep").
