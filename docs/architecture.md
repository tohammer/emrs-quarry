# Architecture

This document describes the system as it is now.

## Overview

quarry is an Emacs package with two tools, a project file finder and an
interactive grep, in two parts: a Rust `cdylib` built on emrs (`src/`)
with one service per tool, and the Elisp libraries in `lisp/`. For the
file finder the module keeps one file index per project root, and
`lisp/quarry.el` starts the instances, owns the completion table and
provides the commands. An optional file, `lisp/quarry-consult.el`, adds a
consult front end. The project was renamed from projdex; older specs and
ADRs use the old name (ADR 0010).

The module holds a second emrs service, `grep` (`src/grep/`), which
searches a directory for lines and streams the matches (ADR 0011). It
shares the walker rules with the index and nothing else: it has no state
and does not use the index (ADR 0010). Its Elisp side is
`lisp/quarry-grep.el`: the commands and the result buffer, which is built
on text properties and is not a `compilation-mode` buffer (ADR 0012). It
requires `quarry-core.el`, not `quarry.el`. Results are edited through
the wgrep package, which is optional and loaded only by the edit command
(ADR 0013).

```text
 Emacs thread                               runtime threads (emrs pool)
 quarry.el                                  index service, one per root
   quarry-find-file                           index + matcher state
     completing-read ── table ── emrs-call-sync (:query) ─► handle
                                                            ▲  ▲
   project-files :around ── emrs-call-stream (:files) ─────┘  │ self-messages
   on-event ◄── (:indexed) (:changed) (:watch-failed) ◄─┐     │ WalkBatch/WalkDone,
                                                        │     │ FsChanges/FsRescan/
                                                        │     │ WatchFailed
                                                        └─ walk task, quarry-watch thread

 quarry-grep.el                             grep service, one instance, no state
   quarry-grep, g, filter commands
     quarry-grep--run ── emrs-call-stream (:search) ─────► handle: checks, opens the stream
   on-batch ◄── file items ... summary item ◄───────────── search task + walker threads
     insert before the status line                           (one set per running search)
   on-end ◄── done / failed / cancelled
   prompt ── emrs-call-sync (:types), cached
   emrs-cancel (new search, C-c C-k, buffer killed) ─────► stream token
```

The service owns the index. Everything that changes it reaches the service
as a self-message through `ctx.address()`, so all index access happens in
`handle`, one message at a time, and needs no locking.

## Components

| Component | Responsibility | Depends on |
|---|---|---|
| `src/lib.rs` | `emrs::module!("quarry", [service::IndexService, grep::service::GrepService])`; module docs | `service`, `grep` |
| `src/service.rs` | `IndexService`: start arguments, `Request`/`Event`, `start`, `handle`; generations; pending `:files` and `:rescan` replies; the `:files` stream task | `index`, `matcher`, `walk`, `watch`, `emrs` |
| `src/index.rs` | The path set of one project: add, remove, remove by directory prefix, iterate; a version number that changes with every mutation; paths kept as `Utf32String` | `nucleo-matcher` |
| `src/matcher.rs` | Query text to ranked paths with match positions; parallel scoring; incremental narrowing | `index`, `nucleo-matcher` |
| `src/walk.rs` | The walker rules both services share (`ignore` crate): version control directories, symbolic links not followed, hidden files, ignore files, extra ignore lines. What a symbolic link to a file means differs: the index lists it, grep skips it. For the index: the parallel walk sending batches of at most 1000 paths, skipped count. For grep: `walker`, a parallel walker for a caller with its own options (ignore files on or off, file types, an entry predicate) | `ignore` |
| `src/watch.rs` | Watch set, debouncing, translation of file-system events into index changes, rescan triggers, failure reporting | `walk`, `notify`, `notify-debouncer-full` |
| `src/grep/filter.rs` | The filters of a search as pure logic: compile the list (literal or regexp, case rule), choose the primary filter, keep or drop a path or a line, decide whether a directory is entered, match positions in paths and lines as character offsets | `grep-regex`, `grep-matcher` |
| `src/grep/search.rs` | One search: the walk, a searcher per walker thread, the `Sink` that turns matching lines into line items, the line cap, the sort buffer, cancellation; the item types. No emrs types | `grep/filter`, `walk`, `grep-searcher`, `ignore` |
| `src/grep/service.rs` | `GrepService`, emrs service `"grep"`: the requests `(:search)` and `(:types)`, the checks of a request and their errors, the stream and the search task; the Lisp shapes in its module docs | `grep/search`, `grep/filter`, `emrs`, `ignore` |
| `lisp/quarry.el` | Options, instance table, event and exit handling, query entry points, completion table and `quarry` style, `quarry--prepare`, commands, `quarry-mode` and its remap through `quarry-find-file-command`, `project-files` method | `emrs.el`, `quarry-build.el`, `quarry-core.el`, `project` |
| `lisp/quarry-core.el` | What the quarry tools share: module file lookup, `quarry--load-module`, the offer to build, the options `quarry-include-hidden` and `quarry-ignores`. Requires neither `quarry.el` nor the module | `emrs.el`, `quarry-build.el` |
| `lisp/quarry-grep.el` | The grep tool: the commands `quarry-grep`, `quarry-grep-literal`, `quarry-grep-project`, `quarry-grep-dwim` and their prompts; the one instance of the `grep` service; the search and its filters as values; `quarry-grep-mode` (from `special-mode`) with the rendering, the header line, visiting, `next-error`, folding, the change commands, the filter commands and the highlighting of filter matches, history and cancel; `quarry-grep-edit`, which hands the buffer to wgrep by translating its text properties, with the check for changed files before and the restoring of the buffer after. Works without `quarry.el` and `quarry-mode` | `emrs.el`, `quarry-core.el`, `project`, wgrep (optional) |
| `lisp/quarry-consult.el` | Optional consult front end: `quarry-consult-find-file`, the async pipeline step that queries the index, its options and history. Loads and byte-compiles without consult; `quarry.el` never loads it | `quarry.el`, `emrs.el`, consult 2.0 or later (optional) |
| `lisp/quarry-build.el` | Builds the module with cargo and installs it as `lisp/quarry-module` plus `module-file-suffix` in the repository: repository detection, `quarry-build-module` (async), `quarry-build-module-sync` (for `:pre-build`), install by rename. Needs neither emrs nor the module | Cargo, Emacs |
| `tests/quarry-tests.el`, `tests/quarry-consult-tests.el`, `tests/quarry-grep-tests.el`, `tests/quarry-grep-wgrep-tests.el`, `tests/run-ert.sh` | ERT suite on generated trees. The grep tests read the result buffer through its text properties and play the service with a recording stand-in for `emrs-call-stream` where timing would matter; their names start with `quarry-test-grep-`, to sort after the test that needs no module loaded (`docs/backlog.md`). The script builds the debug module, copies the Lisp files and the module as `quarry-module` to `target/elisp` (so a module built in `lisp/` is not the one under test), takes `emrs.el` from the emrs checkout Cargo resolved and runs with `--module-assertions`. The script also adds the directories of `QUARRY_TEST_LOAD_PATH` (consult, compat, wgrep) to `load-path` and loads the consult tests; without consult 2.0 or later only the command and end-to-end tests are skipped, the step tests run. Without wgrep the tests that edit results are skipped, and the script says so | Cargo, Emacs |
| Rust tests (in each `src/*.rs` and `src/grep/*.rs`) | Unit tests per module; service, watcher and grep tests through `emrs::testing::Host` on temporary trees | `tempfile` |
| `bench/run-bench.sh`, `bench/quarry-bench.el` | Generates 100k and 1M file trees, measures indexing time, memory and per-call latency against a `project-files` + `flex` baseline | Cargo, Emacs, git |

## How it fits together

`emrs.el` loads `quarry-module` and talks to its two services: `quarry.el`
to `index`, one instance per project root, and `quarry-grep.el` to
`grep`, one instance for all result buffers. Both use the emrs API
(`emrs-start`, `emrs-call`, `emrs-call-sync`, `emrs-call-stream`, ...)
and never call the module functions directly. Loading the module and the
offer to build it are shared in `quarry-core.el`; neither tool loads the
other's Elisp or uses the other's service. The
module's emrs version is fixed by the commit pinned in `Cargo.toml`, and the
test and benchmark scripts use the `emrs.el` from that checkout. Installed
from GitHub, `emrs.el` is its own package that follows emrs's default
branch, so `Cargo.toml` pins only commits on that branch (ADR 0007).

## Parts

- [The Elisp side](architecture/elisp.md): building and finding the
  module, instances, completion and `quarry-find-file`, the consult
  front end.
- [The service](architecture/service.md): threads, message flow,
  generations and rescans, queries, watching.
- [Grep](architecture/grep.md): the service (threads, message flow, what
  is searched, order, cap, cancellation) and the Elisp side (instance,
  search state, streams, rendering and text properties, filters, history,
  editing with wgrep).
- [Lessons](architecture/lessons.md).
