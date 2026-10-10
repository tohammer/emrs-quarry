# Architecture: grep

The interactive grep: first the Rust service (threads, messages, what is
searched, order, cap and cancellation), then the Elisp side
(`lisp/quarry-grep.el`). Part of [the architecture](../architecture.md).
The filter commands and the wgrep integration are not written yet (spec
`2026-10-10-grep.md`, tasks 6 and 7).

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

## The Elisp side

`lisp/quarry-grep.el` requires `quarry-core.el`, `emrs.el` and `project`,
not `quarry.el`: it runs with `quarry-mode` off and never starts an index
instance (ADR 0010).

### Instance

`quarry-grep--instance` holds the one instance of the `grep` service that
all result buffers share. `quarry-grep--ensure-instance` returns it while
its state is `starting` or `running`; otherwise it calls
`quarry--load-module` (with the shared offer to build a missing module)
and `emrs-start`. Nothing starts it at load time. Its `:on-exit`
(`quarry-grep--on-exit`) forgets the instance if it is still the current
one. There is no restart: the next search starts a new instance.

emrs fails the open calls of a dying instance before it runs `:on-exit`,
with the message "The instance terminated". A search that ends that way
remembers its instance (`quarry-grep--dead-instance`); when the exit is a
failure, `quarry-grep--on-exit` shows a warning and puts the reason into
the status line of those buffers.

`(:types)` is asked for once with `emrs-call-sync` and cached in
`quarry-grep--types` for the Emacs session. The commands ask for it
before their first prompt, so a missing module is reported before the
user has typed anything.

### Search state

A search is a `quarry-grep--search` record: `dir` (absolute, with a
trailing slash), `files` (nil for everything, a type name, or a list of
globs), `case` (`smart`, `sensitive`, `insensitive`), `no-ignore`,
`hidden`, and `filters`, an ordered list of `quarry-grep--filter` records
(`target` `line` or `path`, `exclude`, `pattern`, `regexp`, `enabled`).
The pattern a command asks for is the first filter.

Searches and filters are values. A command that changes the search copies
it (`quarry-grep--change`, `quarry-grep--replace-filter`), replaces what
differs, and runs the copy; it never modifies a record the buffer or its
history holds. That makes `equal` on two searches mean "the same search"
and lets the history keep the records themselves.

`quarry-grep--request` turns a search into the `(:search …)` request. Only
enabled filters are sent, in order (`quarry-grep--sent-filters`); the list
sent is kept in `quarry-grep--sent`, because the `(:filter INDEX)` of a
filter error counts in that list, not in the search's. `:ignores` is
`quarry-ignores`, and nil when ignore files are off. `:max-lines` and
`:max-columns` come from the options at the time of the request. The
primary filter (`quarry-grep--primary`) is the first enabled include line
filter, as in the service.

Buffer-local state: `quarry-grep--current` (the search shown),
`quarry-grep--state` (`running`, `done`, `cancelled`, `failed`),
`quarry-grep--call` (the open stream, or nil), `quarry-grep--serial`,
the counts `quarry-grep--lines` and `quarry-grep--files`,
`quarry-grep--summary` (the summary item), `quarry-grep--error` and
`quarry-grep--error-filter`, `quarry-grep--status-marker`, and the
history lists.

### Streams and serial numbers

`quarry-grep--run` is the one place a search starts. It ensures the
instance first (so a missing module leaves the buffer untouched), cancels
the running search, records history, resets the state, renders the filter
block and the status line, makes the buffer `next-error-last-buffer`, and
calls `emrs-call-stream`.

The stream's callbacks run from a process filter, at any time and with
any buffer current. Each search takes a number from a global counter and
the buffer stores the number it waits for in `quarry-grep--serial`. The
callbacks carry the buffer and their number: `quarry-grep--on-batch` and
`quarry-grep--on-end` do nothing when the buffer is dead or waits for
another number. Superseding a search, killing the buffer and changing its
major mode go through `quarry-grep--abandon`, which clears the number
before it calls `emrs-cancel`, so the `:on-end` that `emrs-cancel` runs at
once is ignored. `C-c C-k` calls `emrs-cancel` with the number in place,
and that same `:on-end` shows the cancellation.

`quarry-grep--finish` maps the end of the stream to the state. For a
failure it keeps the message and, from `:data (:filter INDEX)`, the filter
object at that position of `quarry-grep--sent`; point is put on that
filter's line, where `RET` edits it. An `emrs-error` signalled by
`emrs-call-stream` itself (the instance stopped in between) ends the
search the same way.

### Rendering and text properties

The buffer is, top to bottom: one line per filter, an empty line, one
block per file (heading, result lines, an empty line), and the status
line. `quarry-grep--status-marker` stands at the start of the status
line; a batch of file items is inserted there and the marker is moved
behind it, so blocks appear in arrival order and the status line stays
last. `quarry-grep--keeping-positions` wraps every insertion and every
change of the status line: it records point and each window's point and
start as numbers and puts them back, so nothing scrolls and point is not
carried along when it stands at or after the insertion.

Commands read these properties and never the text (ADR 0012). The
properties of a line cover its newline, so a line is identified at its
first character.

| Property | On | Value |
|---|---|---|
| `quarry-grep-filter` | a filter line | its `quarry-grep--filter` record, the same object as in the current search |
| `quarry-grep-part` | parts of a filter line | `sign`, `kind`, `pattern`, `off` |
| `quarry-grep-file` | a file block: heading and result lines | the path relative to `default-directory` |
| `quarry-grep-heading` | a file heading | t |
| `quarry-grep-mtime` | a file heading | the file's modification time at the search, milliseconds since the epoch, or nil |
| `quarry-grep-line` | a result line | its line number in the file |
| `quarry-grep-column` | a result line | character offset of the first primary match in the text, or nil when the match was cut off |
| `quarry-grep-inexact` | a result line | t when the text is not exactly the file's line |
| `quarry-grep-prefix` | the line number and the space after it | t; what follows on the line is exactly the item's `:text` |
| `quarry-grep-status` | the status line | t |

Faces are put on with the `face` property; the mode has no font-lock
keywords. Filter lines, headings and result lines have `mouse-face` and
`follow-link`, so `mouse-1` arrives as `mouse-2`, which the mode map binds.

The header line is `(:eval (quarry-grep--header))`, a string built from
the current search and the counts, so a `%` in a directory name is not
taken as a format. Each clickable part carries a keymap from
`quarry-grep--header-map` that selects the clicked window and calls the
part's command interactively, on `mouse-1` and on `mouse-2`.

A new search erases the buffer. Point goes to the start, except when it
was on a filter line: then it stays on the line of the filter at the same
position in the list, so `%` can be pressed again.

Folding puts an overlay with `invisible` `quarry-grep-fold` over a block
from the end of its heading to the end of its last line. Blocks are found
through the `quarry-grep-file` property (`quarry-grep--block-at`,
`quarry-grep--blocks`). `quarry-grep--next-error` removes the overlay of
the block it enters.

### Visiting

`quarry-grep--visit` takes the file from `quarry-grep-file` (appended to
`default-directory` with `concat`, so a name like `~x` stays below the
directory), finds the line by counting from the start of the widened
buffer, adds `quarry-grep-column`, and widens only when the place is
outside the narrowing. From the result window the file is shown in
another window; from elsewhere (`next-error` in a source buffer) in the
selected window, as `compilation-mode` does. `quarry-grep--next-error`
is the mode's `next-error-function`; `n` and `p` make the buffer
`next-error-last-buffer` and call `next-error-no-select`.

### History

`quarry-grep--past` and `quarry-grep--future` are buffer-local lists of
searches. `quarry-grep--run` pushes the search shown so far onto the past
and empties the future when the new search is not `equal` to it; `g`
therefore adds nothing. Back and forward move the current search to the
other list, pop theirs, and run it with history left alone. The history
belongs to the buffer and survives a new command that reuses it.
