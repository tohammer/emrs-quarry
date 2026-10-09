# Architecture

This document describes the system as it is now.

## Overview

projdex is an Emacs package with two parts: a Rust `cdylib` built on emrs
(`src/`) that keeps one file index per project root, and the Elisp library
`lisp/projdex.el` that starts the instances, owns the completion table and
provides the commands.

```text
 Emacs thread                               runtime threads (emrs pool)
 projdex.el                                 projdex service, one per root
   projdex-find-file                          index + matcher state
     completing-read ── table ── emrs-call-sync (:query) ─► handle
                                                            ▲  ▲
   project-files :around ── emrs-call-stream (:files) ─────┘  │ self-messages
   on-event ◄── (:indexed) (:changed) (:watch-failed) ◄─┐     │ WalkBatch/WalkDone,
                                                        │     │ FsChanges/FsRescan/
                                                        │     │ WatchFailed
                                                        └─ walk task, projdex-watch thread
```

The service owns the index. Everything that changes it reaches the service
as a self-message through `ctx.address()`, so all index access happens in
`handle`, one message at a time, and needs no locking.

## Components

| Component | Responsibility | Depends on |
|---|---|---|
| `src/lib.rs` | `emrs::module!("projdex", [Projdex])`; module docs | `service` |
| `src/service.rs` | `Projdex`: start arguments, `Request`/`Event`, `start`, `handle`; generations; pending `:files` and `:rescan` replies; the `:files` stream task | `index`, `matcher`, `walk`, `watch`, `emrs` |
| `src/index.rs` | The path set of one project: add, remove, remove by directory prefix, iterate; a version number that changes with every mutation; paths kept as `Utf32String` | `nucleo-matcher` |
| `src/matcher.rs` | Query text to ranked paths with match positions; parallel scoring; incremental narrowing | `index`, `nucleo-matcher` |
| `src/walk.rs` | Walker configuration (`ignore` crate), parallel walk sending batches of at most 1000 paths, skipped count | `ignore` |
| `src/watch.rs` | Watch set, debouncing, translation of file-system events into index changes, rescan triggers, failure reporting | `walk`, `notify`, `notify-debouncer-full` |
| `lisp/projdex.el` | Options, module lookup, instance table, event and exit handling, query entry points, completion table and `projdex` style, commands, `projdex-mode`, `project-files` method | `emrs.el`, `projdex-build.el`, `project` |
| `lisp/projdex-build.el` | Builds the module with cargo and installs it as `lisp/projdex-module` plus `module-file-suffix` in the repository: repository detection, `projdex-build-module` (async), `projdex-build-module-sync` (for `:pre-build`), install by rename. Needs neither emrs nor the module | Cargo, Emacs |
| `tests/projdex-tests.el`, `tests/run-ert.sh` | ERT suite on generated trees. The script builds the debug module, copies the Lisp files and the module as `projdex-module` to `target/elisp` (so a module built in `lisp/` is not the one under test), takes `emrs.el` from the emrs checkout Cargo resolved and runs with `--module-assertions` | Cargo, Emacs |
| Rust tests (in each `src/*.rs`) | Unit tests per module; service and watcher tests through `emrs::testing::Host` on temporary trees | `tempfile` |
| `bench/run-bench.sh`, `bench/projdex-bench.el` | Generates 100k and 1M file trees, measures indexing time, memory and per-call latency against a `project-files` + `flex` baseline | Cargo, Emacs, git |

## How it fits together

`emrs.el` loads `projdex-module` and talks to its services; `projdex.el`
uses the emrs API (`emrs-start`, `emrs-call`, `emrs-call-sync`,
`emrs-call-stream`, ...) and never calls the module functions directly. The
module's emrs version is fixed by the commit pinned in `Cargo.toml`, and the
test and benchmark scripts use the `emrs.el` from that checkout. Installed
from GitHub, `emrs.el` is its own package that follows emrs's default
branch, so `Cargo.toml` pins only commits on that branch (ADR 0007).

### Building and finding the module

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

### Instances

`projdex--instances` maps the project root to a record (instance, file
count, `indexing`, `watching`, epoch, a unique `id` for cache keys, and
whether the watch-failure warning was shown). `projdex--ensure` returns the
running record or starts an instance with `emrs-start` and the start
arguments (`:root`, `:include-hidden`, `:ignores`). Events update the
record: `:indexed` sets the file count, `:changed` adjusts it by the
added and removed counts, and both increment the epoch; `:watch-failed` clears `watching` and shows one warning. On exit the
record is removed; a failed instance leaves a warning and its message. There
is no automatic restart; the next command starts a new instance.

### Threads

| Thread | Runs | Talks to the service by |
|---|---|---|
| emrs worker pool | `Projdex::handle`, one message at a time per instance | owns the index |
| walk task (`ctx.spawn`) | `walk::walk_dirs`, which uses the `ignore` crate's parallel walker with one thread per core | `WalkBatch`, `WalkDone` self-messages |
| `:files` stream task (`ctx.spawn`) | Sends a snapshot of the index to the stream (capacity 4096), stops when the stream's token is cancelled | stream |
| `notify` backend thread, debouncer thread (100 ms window) | Collect and debounce file-system events | channel to `projdex-watch` |
| `projdex-watch` | Translates debounced events into changes, walking new directories itself | `FsChanges`, `FsRescan`, `WatchFailed` self-messages |
| scoring threads (`std::thread::scope`) | Score chunks of the index when more than 10,000 paths are to be scored | joined before the query returns |

### Message flow

Requests from Emacs: `:query`, `:files` (stream), `:rescan`, `:status`.
Internal requests, `#[serde(skip_deserializing)]` so Emacs cannot send
them: `WalkBatch`, `WalkDone`, `FsChanges`, `FsRescan`, `WatchFailed`.
Events to Emacs: `:indexed`, `:changed`, `:watch-failed`. The exact shapes
are in the module docs of `src/service.rs`.

`start` validates the root, creates the watcher (a failure only disables
watching), and spawns the first walk without waiting for it.

### Generations and rescans

Every walk has a generation number and builds a fresh index from its
batches. Until the walk's `WalkDone`, queries use the previous index (or,
during the first walk, the partial fresh one); batches and `WalkDone` of
any other generation are discarded. File-system changes during a walk are
applied to the index queries use and recorded; at `WalkDone` they are
replayed on the fresh index before it becomes current, so no change is
lost.

Rescans coalesce: a `:rescan` or watcher `FsRescan` while a walk runs only
sets "walk again", and one follow-up walk starts when the running walk
ends. Only `stop()` cancels a walk. `:rescan` replies are answered by the
first walk that started after the request; `:files` streams wait only for
the running walk. A walk that fails keeps the old index (or makes the
partial one current when there was none); the `:rescan` calls waiting for
it fail with the message. The exact rules are in the spec, section
"Rescans".

### Queries, narrowing and scoring

A query parses the text with nucleo's `Pattern` (smart case, smart
normalization) and ranks by score descending, then path length, then path.
In the substring style (`:substring t`, ADR 0004) `matcher::parse` builds
the pattern atom by atom and turns plain fuzzy atoms into substring atoms;
a leading `'` marks a fuzzy one. Match positions are computed only for the
returned paths, atom by atom, so each position carries its term number
(`:groups`).

The matcher remembers the last query, the index version and the full set of
matching paths, and the style. The next query of the same style scores only
that set when the index is unchanged and the new text extends the old text
in a way that cannot match more (`matcher::narrows`: no `!` or `$`
involved, the old text does not end in `\` or `$`, not both the last
atom and the appended text are non-ASCII, and not a backslash in the last
atom with non-ASCII appended text). Otherwise it scores the whole
index. When more than 10,000 paths are scored, the set is split into one
chunk per core, each chunk is scored on a scoped thread with its own
matcher, and the per-chunk top results are merged. Both optimisations
return exactly what single-threaded scoring of the whole index returns; a
Rust test checks it.

### Watching

The watcher covers exactly the directories the walk visits. On Linux that
is one non-recursive inotify watch per directory, plus `<dir>/.git/info`
where it exists. Elsewhere the root is watched recursively and events are
filtered (`Mode::Recursive`; never run on macOS or Windows).

The watcher keeps a set of known directories, each stamped with a clock
value. A full walk advances the clock and confirms every directory it
visits; when its index becomes current, directories with an older stamp are
dropped with their watches. This reconciles the watch set with the walk
without a second tree traversal.

Events are translated by comparing each affected path with the disk, which
makes paired and unpaired rename halves behave the same: a file that exists
and is not ignored is added, a missing path is removed (a missing known
directory removes everything below it), a new directory is walked and its
directories watched. `notify-debouncer-full` drops a create and remove
within its window, so raw remove and rename-away events also go straight
to the translating thread. A changed ignore file in a non-ignored
directory, a new `.git` that already has `info/exclude`, or lost events
produce a full rescan instead; after lost events, full walks re-add every
directory watch until a walk that began after the loss has become
current. When the inotify limit is reached or the backend fails,
the watcher is dropped and `WatchFailed` is sent once; the instance keeps
answering from the index it has, and `projdex-find-file` sends `:rescan`
before each prompt.

### Completion on the Elisp side

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
argument defer to `project-find-file`.

The table's try-completion returns nil without results, the input for
several, `t` for a sole exact match and the sole match otherwise, so TAB
completes a unique match; the style's try function wraps that as
`(STRING . POINT)` or `(CANDIDATE . LENGTH)`. Replies with `:indexing` true
are not cached. After a failure the table reports once and has no
candidates for the rest of the prompt; a timeout gives no candidates and
one message.

`projdex-find-file` sends `(:rescan)` first when the instance is not
watching, then `(:status)` probes, so a failed or unstartable instance is
a `user-error` before the prompt. While a walk runs and the index holds
fewer than `projdex-limit` files, it keeps probing, for at most 1 s
(`projdex--first-page-wait`): completion UIs ask for the empty input once
and do not refresh while indexing runs, so a prompt opened on a new
instance would stay empty until the user types. Results for typed input
during a long first walk still reflect the paths seen so far. It reads with require-match `confirm`
and history `projdex-file-history`; input that is not an indexed path but
completes to exactly one is visited as that file.

`project-files` is overridden by an `:around` method that applies only with
`projdex-mode` and `projdex-provide-project-files`, for the whole root of a
local project that has a running instance. It collects the `:files` stream
while waiting in `accept-process-output` and falls back to the next method
on timeout or error.

## Lessons

- **nucleo-matcher 0.3.1 has a prefix bug.** Case-sensitive prefix and
  postfix atoms on ASCII text compare the whole haystack, so `^Fo` does not
  match `Foo`. The crate is pinned to an upstream git commit that fixes it
  (ADR 0003). The narrowing tests assert the pinned version's behaviour and
  fail when an update changes it.
- **Smart normalization can widen the match set.** Typing a non-ASCII
  character switches normalization off for that atom, so a longer query can
  match paths the shorter one did not. Incremental narrowing therefore stops
  when both the last atom and the appended text are non-ASCII
  (`matcher::narrows`).
- **`notify-debouncer-full` is quadratic in the number of watches.** It
  keeps the watched roots in a `Vec` and scans it on every `watch` call,
  which is unusable with hundreds of thousands of directories. projdex uses
  the debouncer only for debouncing and adds and removes watches on the
  backend directly (`SharedWatcher` in `src/watch.rs`).
- **inotify limits matter on AOSP-sized trees.** One watch per indexed
  directory needs about 150,000 watches, more than many default
  configurations allow. The watch failure is handled by degrading to a
  rescan before each prompt, and the README tells users how to raise the
  limit.
- **The user's global gitignore changes counts.** The walk applies the
  user's global git excludes, also outside git repositories, so the number
  of indexed files can be lower than the number of files on disk, for
  example in a generated benchmark tree.
- **nucleo unescapes ASCII and non-ASCII needles differently.** `\ ` is a
  space only in an ASCII needle, and a backslash before another character
  is doubled in a non-ASCII one. A term with a backslash that turns
  non-ASCII changes its needle in the middle, which broke narrowing for
  substring terms; `matcher::narrows` excludes that case. The substring
  style reuses `Atom::parse` and only switches the kind, so it inherits
  nucleo's unescaping instead of rebuilding needles.
- **A category override does not replace `completion-styles`.** Emacs
  appends the user's styles behind the override's, and tries them when the
  first returns nothing. orderless then asked the table for the empty
  prefix and, since the table ignores `completion-regexp-list`, a query
  without matches listed every file. The prompt now sets
  `completion-styles` buffer-locally (ADR 0005).
- **Batch-mode `completing-read` reads stdin.** The ERT tests drive the
  minibuffer with `execute-kbd-macro` instead.
- **`project-read-file-name-function` cannot speed up `project-find-file`.**
  `project-find-file` builds the full file list with `project-files` before
  calling it, which is the slow part. projdex remaps the command instead
  (ADR 0001).
- **A walk's index must not replace the live one until it is complete.**
  Generations keep queries on the previous index and replay recorded
  changes onto the fresh one, because a change during a walk may or may not
  be seen by the walker.
