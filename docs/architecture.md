# Architecture

This document describes the system as it is now.

## Overview

quarry is an Emacs package with two tools, a project file finder and an
interactive grep, in two parts: a Rust `cdylib` built on emrs (`src/`)
with one service per tool, and the Elisp libraries in `lisp/`. For the
file finder the module keeps one file index per project root (and one
per one-shot instance), and
`lisp/quarry.el` starts the instances, owns the completion table and
provides the commands. An optional file, `lisp/quarry-consult.el`, adds a
consult front end. Finding a file below a directory uses the same service:
a directory in a project is a `:dir` query on the project's instance
when that index has files below it; any other local directory gets a
one-shot instance, started without a watcher for one prompt (ADR 0020). The project was renamed from projdex; older specs and
ADRs use the old name (ADR 0010).

The module holds a second emrs service, `grep` (`src/grep/`), which
searches a directory for lines and streams the matches (ADR 0011). It
shares the walker rules with the index and nothing else: it has no state
and does not use the index (ADR 0010). Besides searching it can compute,
for a replacement template, the new text of each match; it never writes a
file (ADR 0021). Its Elisp side is
`lisp/quarry-grep.el`: the commands and the result buffer, which is built
on text properties and is not a `compilation-mode` buffer (ADR 0012). It
requires `quarry-core.el`, not `quarry.el`. Results are edited through
the wgrep package, which is optional and loaded only by the edit command
(ADR 0013), or replaced: `R` previews a template's new text for every
match, `x` switches matches off, and `C-c C-c` writes the rest into the
files from Elisp (ADRs 0021, 0022, 0023). An optional file, `lisp/quarry-consult-grep.el`, searches
while the input is typed and shows the hits as consult candidates; it
uses the same service and the same search values (ADRs 0018, 0019).

```text
 Emacs thread                               runtime threads (emrs pool)
 quarry.el                                  index service, one per root
                                            (project root, or a one-shot dir)
   quarry-find-file                           index + matcher state
     completing-read ── table ── emrs-call-sync (:query) ─► handle
                                                            ▲  ▲
   project-files :around ── emrs-call-stream-sync (:files) ┘  │ self-messages
   on-event ◄── (:indexed) (:changed) (:watch-failed) ◄─┐     │ WalkBatch/WalkDone,
                                                        │     │ FsChanges/FsRescan/
                                                        │     │ WatchFailed
                                                        └─ walk task, quarry-watch thread
 quarry-find-file-in-directory: the same table with (:query :dir D) on the
   project's instance, or on a one-shot instance (start argument :watch nil)
   that is stopped when the prompt ends

 quarry-grep.el                             grep service, one instance, no state
   quarry-grep, g, filter commands
     quarry-grep--run ── emrs-call-stream (:search) ─────► handle: checks, opens the stream
   quarry-consult-grep.el: one stream per input ─────────►   (the same request)
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
| `src/service.rs` | `IndexService`: start arguments (`:watch`), `Request`/`Event` (`:dir` of `:query`), `start`, `handle`; generations; pending `:files` and `:rescan` replies; the `:files` stream task | `index`, `matcher`, `walk`, `watch`, `emrs` |
| `src/index.rs` | The path set of one project: add, remove, remove by directory prefix, iterate; a version number that changes with every mutation; paths kept as `Utf32String` | `nucleo-matcher` |
| `src/matcher.rs` | Query text to ranked paths with match positions, also only below a directory (`:dir`: filter by prefix, haystack sliced after it, relative paths and positions); parallel scoring; incremental narrowing, cached per directory | `index`, `nucleo-matcher` |
| `src/walk.rs` | The walker rules both services share (`ignore` crate): version control directories, symbolic links not followed, hidden files, ignore files, extra ignore lines. What a symbolic link to a file means differs: the index lists it, grep skips it. For the index: the parallel walk sending batches of at most 1000 paths, skipped count. For grep: `walker`, a parallel walker for a caller with its own options (ignore files on or off, file types, an entry predicate) | `ignore` |
| `src/watch.rs` | Watch set, debouncing, translation of file-system events into index changes, rescan triggers, failure reporting | `walk`, `notify`, `notify-debouncer-full` |
| `src/grep/filter.rs` | The filters of a search as pure logic: compile the list (literal or regexp, case rule), choose the primary filter, keep or drop a path or a line, decide whether a directory is entered, match positions in paths and lines as character offsets, and the new text of each primary match for a replacement template (`Filters::replacements`) | `grep-regex`, `grep-matcher` |
| `src/grep/search.rs` | One search: the walk, a searcher per walker thread, the `Sink` that turns matching lines into line items and picks the context lines around them, the line cap and the count beyond it (ADR 0025), the sort buffer, cancellation; the entry filter that asks the globs and the path filters; the item types. No emrs types | `grep/filter`, `walk`, `grep-searcher`, `ignore` |
| `src/grep/service.rs` | `GrepService`, emrs service `"grep"`: the requests `(:search)` and `(:types)`, the checks of a request and their errors, the file types and the path globs of a search (ADR 0017), `:replace` and the `:replacements` of line items (ADR 0021), `:count-up-to` and the summary's `:total` (ADR 0025), the stream and the search task; the Lisp shapes in its module docs | `grep/search`, `grep/filter`, `emrs`, `ignore` |
| `lisp/quarry.el` | Options, instance table, event and exit handling, one-shot records and targets, query entry points (with an optional DIR), completion table and `quarry` style, `quarry--prepare`, `quarry--dir-target`, commands including `quarry-find-file-in-directory`, `quarry-mode` and its remap through `quarry-find-file-command`, `project-files` method | `emrs.el`, `quarry-build.el`, `quarry-core.el`, `project` |
| `lisp/quarry-core.el` | What the quarry tools share: module file lookup, `quarry--load-module`, the offer to build, the options `quarry-include-hidden` and `quarry-ignores`. Requires neither `quarry.el` nor the module | `emrs.el`, `quarry-build.el` |
| `lisp/quarry-grep.el` | The grep tool: the commands `quarry-grep`, `quarry-grep-literal`, `quarry-grep-project`, `quarry-grep-dwim` and their prompts; the one instance of the `grep` service; the search and its filters as values, with file types and path globs; `quarry-grep--start-search`, the way in for a search value from elsewhere; `quarry-grep-mode` (from `special-mode`) with the rendering, the header line, context and gap lines, visiting, `next-error`, folding, the change commands, the filter commands and the highlighting of filter matches, history and cancel; `quarry-grep-edit`, which hands the buffer to wgrep by translating its text properties, with the check for changed files before and the restoring of the buffer after; the replace preview (`R`, the `replace` slot of the search, the faces, `x` on matches) and `quarry-grep-replace-apply`, which writes the switched-on matches into visiting buffers and into other files and marks each line applied or rejected (ADRs 0021, 0022, 0023). Works without `quarry.el` and `quarry-mode` | `emrs.el`, `quarry-core.el`, `project`, wgrep (optional) |
| `lisp/quarry-grep-menu.el` | `quarry-grep-menu`, the transient on `?` in the result buffer: every key of the mode map under its own key, the values of the switches, inactive entries where a command does not apply (`x` and `C-c C-k` also follow the replace preview). Runs the existing commands only. Autoloaded from `quarry-grep.el`, so transient is loaded on first use | `quarry-grep.el`, transient (ships with Emacs) |
| `lisp/quarry-consult-grep.el` | Optional live grep on consult: `quarry-consult-grep`, `quarry-consult-grep-project`; the parser of the input (terms and rg-like options, ADR 0019) into a search value, `quarry-consult-grep-quote`, the async step on a stream, candidates in consult-grep's shape (ADR 0018), the note in the prompt, the hand-over to the result buffer. Loads and byte-compiles without consult; requires neither `quarry.el` nor consult | `quarry-grep.el`, `emrs.el`, `project`, consult (optional; tested with 3.7) |
| `lisp/quarry-consult.el` | Optional consult front end: `quarry-consult-find-file` and `quarry-consult-find-file-in-directory`, the async pipeline step that queries the index (a project root or a one-shot record, optionally below a directory), its options and histories. Loads and byte-compiles without consult; `quarry.el` never loads it | `quarry.el`, `emrs.el`, consult 2.0 or later (optional) |
| `lisp/quarry-build.el` | Builds the module with cargo and installs it as `lisp/quarry-module` plus `module-file-suffix` in the repository: repository detection, `quarry-build-module` (async), `quarry-build-module-sync` (for `:pre-build`), install by rename. Needs neither emrs nor the module | Cargo, Emacs |
| `tests/quarry-tests.el`, `tests/quarry-consult-tests.el`, `tests/quarry-consult-grep-tests.el`, `tests/quarry-grep-tests.el`, `tests/quarry-grep-wgrep-tests.el`, `tests/run-ert.sh` | ERT suite on generated trees. The grep tests read the result buffer through its text properties and play the service with a recording stand-in for `emrs-call-stream` where timing would matter; their names start with `quarry-test-grep-`, to sort after the test that needs no module loaded (`docs/backlog.md`). The script builds the debug module, copies the Lisp files and the module as `quarry-module` to `target/elisp` (so a module built in `lisp/` is not the one under test), takes `emrs.el` from the emrs checkout Cargo resolved and runs with `--module-assertions`. The script also adds the directories of `QUARRY_TEST_LOAD_PATH` (consult, compat, wgrep) to `load-path` and loads the consult tests; without consult 2.0 or later only the tests that call consult are skipped (commands, prompts, end to end, and the candidate test through `consult--grep-position`); the step and parser tests run on stand-ins. Without wgrep the tests that edit results are skipped, and the script says so | Cargo, Emacs |
| Rust tests (in each `src/*.rs` and `src/grep/*.rs`) | Unit tests per module; service, watcher and grep tests through `emrs::testing::Host` on temporary trees | `tempfile` |
| `bench/run-bench.sh`, `bench/quarry-bench.el`, `bench/replace-bench.el` | Generates 100k and 1M file trees, measures indexing time, memory and per-call latency against a `project-files` + `flex` baseline; with `replace`, times grep replace on generated change sets and checks the files | Cargo, Emacs, git |

## How it fits together

`emrs.el` loads `quarry-module` and talks to its two services: `quarry.el`
to `index`, one instance per project root plus a one-shot instance per
running directory prompt outside the index, and `quarry-grep.el` to
`grep`, one instance for all result buffers. Both use the emrs API
(`emrs-start`, `emrs-call`, `emrs-call-sync`, `emrs-call-stream`, `emrs-call-stream-sync`, ...)
and never call the module functions directly. Loading the module and the
offer to build it are shared in `quarry-core.el`; neither tool loads the
other's Elisp or uses the other's service. The
module's emrs version is fixed by the commit pinned in `Cargo.toml`, and the
test and benchmark scripts use the `emrs.el` from that checkout. Installed
from GitHub, `emrs.el` is its own package that follows emrs's default
branch, so `Cargo.toml` pins only commits on that branch (ADR 0007).

Releases go through emrs's reusable workflow (`.github/workflows/release.yml`):
a tag `v<version>` publishes `quarry-module-<platform>.<ext>` and
`SHA256SUMS` for linux-x86_64, linux-aarch64 and macos-aarch64 (emrs ADR
0004), after the smoke test and the ERT suite ran against each file
(`tests/run-ert.sh` with `EMRS_MODULE_FILE`). Users put a downloaded file
where a local build goes, `lisp/quarry-module.<ext>` (ADR 0006). Between
releases the version is `<next>-snapshot` (ADR 0026).

## Parts

- [The Elisp side](architecture/elisp.md): building and finding the
  module, instances, targets and one-shot records, completion and
  `quarry-find-file`, finding a file below a directory, the consult
  front end.
- [The service](architecture/service.md): threads, message flow,
  generations and rescans, queries (`:dir`), watching (`:watch nil`).
- [Grep](architecture/grep.md): the service (threads, message flow, what
  is searched, order, cap, cancellation) and the Elisp side (instance,
  search state, streams, rendering and text properties, filters, history,
  editing with wgrep, replace, the live grep on consult).
- [Lessons](architecture/lessons.md).
