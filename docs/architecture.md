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
| `lisp/projdex.el` | Options, instance table, event and exit handling, query entry points, completion table and `projdex` style, commands, `projdex-mode`, `project-files` method | `emrs.el`, `project` |
| `tests/projdex-tests.el`, `tests/run-ert.sh` | ERT suite on generated trees. The script builds the module, installs it as `projdex-module`, takes `emrs.el` from the emrs checkout Cargo resolved and runs with `--module-assertions` | Cargo, Emacs |
| Rust tests (in each `src/*.rs`) | Unit tests per module; service and watcher tests through `emrs::testing::Host` on temporary trees | `tempfile` |
| `bench/run-bench.sh`, `bench/projdex-bench.el` | Generates 100k and 1M file trees, measures indexing time, memory and per-call latency against a `project-files` + `flex` baseline | Cargo, Emacs, git |

## How it fits together

`emrs.el` loads `projdex-module` and talks to its services; `projdex.el`
uses the emrs API (`emrs-start`, `emrs-call`, `emrs-call-sync`,
`emrs-call-stream`, ...) and never calls the module functions directly. The
emrs version is fixed by the commit pinned in `Cargo.toml`, and the test
and benchmark scripts use the `emrs.el` from that checkout.

### Instances

`projdex--instances` maps the project root to a record (instance, file
count, `indexing`, `watching`, epoch). `projdex--ensure` returns the
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
involved, the old text does not end in `\` or `$`, and not both the last
atom and the appended text are non-ASCII). Otherwise it scores the whole
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
directories watched. A changed ignore file or lost events produce a full
rescan instead. When the inotify limit is reached or the backend fails,
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
`completion-category-overrides` so only that style applies to the
`project-file` category during its prompt. Remote projects and a prefix
argument defer to `project-find-file`.

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
