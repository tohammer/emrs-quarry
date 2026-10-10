# Architecture: the grep service

The Rust side of the interactive grep: threads, messages, what is
searched, order, cap and cancellation. Part of
[the architecture](../architecture.md). The Elisp side is not written yet
(spec `2026-10-10-grep.md`).

## Threads

| Thread | Runs | Hands its results on by |
|---|---|---|
| emrs worker pool | `GrepService::handle`: checks a request, opens the stream, spawns the search, returns | `reply.err`, `reply.stream` |
| search task (`ctx.spawn`), one per running search | `Search::run`: starts the walker and waits for it, then sends what is still buffered and the summary | stream |
| walker threads (`ignore` crate), one per core, per running search | Walk entries; each thread opens and searches the files it is given with its own `Searcher` and its own copy of the filters | sort buffer, then stream |

The service has no state. Each search owns everything it uses, so several
searches run at the same time without knowing of each other, each with its
own walker threads.

## Message flow

Requests from Emacs: `(:types)` and `(:search …)` (stream). There are no
events and no internal requests. The exact shapes, the defaults and the
error messages are in the module docs of `src/grep/service.rs`.

`(:types)` answers from the `ignore` crate's default type definitions.

`(:search …)` is checked in `handle` before anything is searched: the
directory, the filters (`Filters::compile`), the file type or globs, the
extra ignore lines (by building the walker). A request that fails a check
fails the call; a filter error carries `(:filter INDEX)` as data so Elisp
can point at the filter. Then `handle` opens the stream (capacity 256
items) and spawns the search.

The stream carries one file item per file with kept lines, and one summary
item at the end.

## What is searched

The walker comes from `walk::walker`, so the rules for version control
directories, hidden files, ignore files and extra ignore lines are those
of the index, with ignore files and hidden files switchable per search.
Only regular files are searched. Symbolic links are not, neither to
directories (the walker never follows them) nor to files (the index lists
those; grep leaves them out as `rg` does, so that a file is found once,
under its real path). The path filters are the walker's entry predicate:
an exclude path filter that matches a directory keeps the walk out of it,
and a file that the path filters drop is never opened. A file type or
globs become an `ignore::types::Types` selection.

Each file is searched for the primary filter (the first include line
filter) by `grep-searcher`. Its `Sink` gets every matching line, removes
the terminator, asks the other line filters (`Filters::keep_line`), and
builds the line item: the text as UTF-8, cut at `max-columns` characters,
and the match positions computed on that text. A file in which the
searcher meets a NUL byte is binary and gives nothing; a byte order mark
selects the encoding.

## Order

Finished file items go into a buffer behind a mutex until
`sort-budget-ms` (150 ms by default) has passed since the request
arrived. If the walk ends before that, the search task sorts the buffer by
path and sends it, and the summary says `sorted`. Otherwise the first
walker thread that notices the deadline, at a walk entry or with an item in
hand, sorts and sends the buffer, and from then on each thread sends its
items as it finds them.

Every send happens under the buffer's mutex. The stream blocks when Emacs
has 256 items waiting; then one thread waits in the send, and each other
thread that finishes a file with matches waits for the mutex with that one
item. Nothing else is queued, so a slow Emacs slows the search down
instead of filling memory.

## Cap

A counter shared by the threads holds the lines of the finished files. A
thread stops reading its file when its own lines and the counter together
reach `max-lines`; when the file is done it adds what still fits to the
counter and keeps only that many lines. The thread that brings the counter
to `max-lines` sets the stop flag, and every thread leaves the walk at its
next entry. The lines delivered therefore never exceed `max-lines`, and
equal it whenever the summary says `truncated`.

## Cancellation

Each walker thread asks the stream's token at every walk entry; the token
is cancelled by `emrs-cancel` and when the instance stops. A send that
finds the stream closed has the same effect. The stop flag is set, the
walk quits, a thread inside a file stops at its next matching line, and
the search task ends without a summary. A panic in a walker thread sets
the stop flag too and reaches emrs through the search task, which logs it;
the stream then ends as failed and the instance keeps running.
