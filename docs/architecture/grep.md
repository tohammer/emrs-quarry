# Architecture: grep

The interactive grep: first the Rust service (threads, messages, what is
searched, order, cap and cancellation), then the Elisp side
(`lisp/quarry-grep.el`). Part of [the architecture](../architecture.md).
Results are edited through wgrep (ADR 0013), described at the end.

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
under its real path). With hidden files switched off, no entry whose name
starts with a dot is searched, also not one that the file type or the
globs select.

The path filters are the walker's entry predicate: a file that they drop
is never opened, and a literal exclude path filter that occurs in a
directory's path keeps the walk out of that directory, since it occurs in
the path of every file below. A regexp exclude path filter does not prune:
what matches a directory's path need not match the files below it
(`^/src/[^/]*$`), so it is tested on each file. A file type or globs
become an `ignore::types::Types` selection; globs match file names, not
paths.

Each file is searched for the primary filter (the first include line
filter) by `grep-searcher`. Its `Sink` gets every matching line, removes
the terminator, asks the other line filters (`Filters::keep_line`), and
builds the line item: the text as UTF-8, cut at `max-columns` characters,
and the match positions. The matches are found on the whole line, so that
a pattern sees what follows the cut, and reported for the text that is
sent: a match that crosses the cut ends there. (For a very long line the
filters look 64 KiB beyond the cut, not further.) A file in which the
searcher meets a NUL byte is binary and gives nothing; a byte order mark
selects the encoding.

The primary filter runs on buffers that hold many lines of a file, with
the line terminators in place; the other line filters run on one line at
a time, without its terminator. The matchers are built so that both
decide alike for `^`, `$` and `\r\n` line ends. They do not for the text
anchors `\A` and `\z` or with multi-line mode switched off (`(?-m)`):
these are not supported in line filters; use `^` and `$`.

A line that the primary filter matches and the other line filters keep
is a *kept line*, a hit. With `:before` or `:after` above 0, a line that
is not kept and lies at most that many lines before or after a kept line
of its file is a *context line* (ADR 0014). The searcher is given the
same two distances, but counts them from the primary filter's matches,
so what it reports besides the kept lines (its context lines, and the
matches another line filter dropped) holds every line that can qualify
and more. The sink decides by line number: such a line is taken when the
last kept line is at most `:after` lines back; otherwise it is held
back, the last `:before` of them, and taken when a kept line follows. A
dropped match can therefore be the context of a kept line and has no
context of its own. Context lines travel in the file item's `:lines`, in
place and once each, with `:context t`, their text made like a kept
line's (terminator removed, cut at `max-columns`) and without match
positions; the line filters are not asked. With both distances 0 the
searcher reports matches only, as before. A distance above 1000 is taken
as 1000 (`MAX_CONTEXT`, ADR 0015): the searcher holds that many lines of
every file across the refills of its buffer, with or without a match.

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

The cap counts kept lines; context lines are not counted anywhere
(ADR 0014). A counter shared by the threads holds the kept lines of the
finished files. A thread stops reading its file when its own kept lines
and the counter together reach `max-lines`; when the file is done it adds
what still fits to the counter and keeps only that many kept lines,
cutting its lines after the last of them. The thread that brings the
counter to `max-lines` sets the stop flag, and every thread leaves the
walk at its next entry. The kept lines delivered therefore never exceed
`max-lines`, and equal it whenever the summary says `truncated`. The kept
line at which a thread stops reading its file has its context lines
before and not those after.

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

Emacs cannot unload a module, so updated Lisp can meet a loaded module
from before the `grep` service existed. `emrs-start` then signals an
`emrs-error` for the unknown service; `quarry-grep--ensure-instance`
turns it into a `user-error` that says the module is older than
quarry-grep and to rebuild it and restart Emacs. The service name is the
variable `quarry-grep--service`, so a test can ask for one that does not
exist.

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
`hidden`, `before` and `after` (the lines of context, 0 by default), and
`filters`, an ordered list of `quarry-grep--filter` records
(`target` `line` or `path`, `exclude`, `pattern`, `regexp`, `enabled`).
The pattern a command asks for is the first filter. A search of the four
commands takes `before` and `after` from `quarry-grep-context-before` and
`quarry-grep-context-after`; `C`, `B` and `A` change them through
`quarry-grep--change`, so the counts are part of the value and of the
history. A count above `quarry-grep-max-context` (1000, the service's
limit, ADR 0015) is reduced to it before the search is built, with a
message in the echo area.

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
`:max-columns` come from the options at the time of the request,
`:before` and `:after` from the search. The
primary filter (`quarry-grep--primary`) is the first enabled include line
filter, as in the service.

Buffer-local state: `quarry-grep--current` (the search shown),
`quarry-grep--state` (`running`, `done`, `cancelled`, `failed`),
`quarry-grep--call` (the open stream, or nil), `quarry-grep--serial`,
the counts `quarry-grep--lines` (hits, without context lines) and
`quarry-grep--files`,
`quarry-grep--summary` (the summary item), `quarry-grep--error` and
`quarry-grep--error-filter`, `quarry-grep--status-marker`, and the
history lists.

### Streams and serial numbers

`quarry-grep--run` is the one place a search starts. It ensures the
instance first (so a missing module leaves the buffer and its history
untouched), cancels the running search, records history, widens the
buffer, resets the state, renders the filter block and the status line,
makes the buffer `next-error-last-buffer`, and calls `emrs-call-stream`.
The four commands check before their first prompt
(`quarry-grep--check-result-buffer`) that the result buffer is not being
edited with wgrep, and `quarry-grep--start` checks again before it
touches the buffer.

`clone-buffer` copies the local variables, so a clone would share the
original's status marker (a marker into the original), its stream and
its serial number: killing the clone would cancel the original's search.
A buffer-local `clone-buffer-hook` (`quarry-grep--after-clone`) gives the
clone a marker of its own at its status line and clears its call and
serial. A search that was running goes on in the original; the clone
shows what had arrived as a cancelled search. From then on the two are
independent, each with its own copy of the history.

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
line. The result lines of a block are its hits and, with context on,
their context lines and gap lines. `quarry-grep--status-marker` stands at the start of the status
line; a batch of file items is inserted there and the marker is moved
behind it, so blocks appear in arrival order and the status line stays
last. `quarry-grep--keeping-positions` wraps every insertion and every
change of the status line: it records point and each window's point and
start as numbers and puts them back, so nothing scrolls and point is not
carried along when it stands at or after the insertion. It also widens
around the change and puts a narrowing back afterwards. Results arrive at
any time, so every function that walks or changes the whole buffer does
that (`quarry-grep--on-batch`, `quarry-grep--finish`,
`quarry-grep--blocks`, `quarry-grep--stale-files`, folding all blocks,
`quarry-grep--edit-restore`); the user's narrowing is theirs and stays. A
new search and `e` widen for good.

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
| `quarry-grep-line` | a result line: a hit or a context line | its line number in the file |
| `quarry-grep-context` | a context line | t |
| `quarry-grep-gap` | a gap line | t; the line has `quarry-grep-file` and no `quarry-grep-line` |
| `quarry-grep-column` | a result line | character offset of the first primary match in the text, or nil when the match was cut off and on a context line |
| `quarry-grep-inexact` | a result line | t when the text is not exactly the file's line |
| `quarry-grep-prefix` | the line number and the space after it | t; what follows on the line is exactly the item's `:text` |
| `quarry-grep-separator` | the empty line that ends a file block | t |
| `quarry-grep-status` | the status line | t |

Faces are put on with the `face` property; the mode has no font-lock
keywords. Filter lines, headings and result lines have `mouse-face` and
`follow-link`, so `mouse-1` arrives as `mouse-2`, which the mode map binds.

The header line is `(:eval (quarry-grep--header))`, a string built from
the current search and the counts. Emacs takes the string an `:eval`
form returns as a mode line format again, so `quarry-grep--header-part`
doubles each `%` in a value; otherwise a directory `100%b` would show the
buffer name in its place. Each clickable part carries a keymap from
`quarry-grep--header-map` that selects the clicked window and calls the
part's command interactively, on `mouse-1` and on `mouse-2`.

A new search erases the buffer; where point goes is described under
"Point after a search".

`quarry-grep--insert-file` counts the lines of an item without
`:context` for the heading and for `quarry-grep--lines`. A context line
is inserted like a hit, with the face `quarry-grep-context` on its text
and the property of that name over the line. When the buffer's search
has a count above 0, a gap line (`⋮` in the number column, same face)
goes between two neighbouring lines whose numbers are not adjacent; the
item does not mark gaps. A search without context has no gap lines.

Highlighting is decided when lines are inserted. The item's `:spans` get
`quarry-grep-match`; its `:secondary` spans get
`quarry-grep-match-secondary` when `quarry-grep-highlight-include-filters`
is non-nil; the heading's `:path-spans` get `quarry-grep-path-match`,
added to the heading face with `add-face-text-property`, when
`quarry-grep-highlight-path-filters` is non-nil. In the filter block
`quarry-grep--filter-roles` gives each enabled include filter the face of
its matches (the primary filter always, the others as the two options
say), and `quarry-grep--insert-filter` shows the pattern in that face.

Folding puts an overlay with `invisible` `quarry-grep-fold` over a block
from the end of its heading to the end of its last line. Blocks are found
through the `quarry-grep-file` property (`quarry-grep--block-at`,
`quarry-grep--blocks`). `quarry-grep--next-error` removes the overlay of
the block it enters.

### Filter commands

All of them build a new filter list and hand it to
`quarry-grep--set-filters`, which copies the current search, refuses a
list without an enabled include line filter with a `user-error` (the
primary rule: nothing was changed at that point) and calls
`quarry-grep--run`. So every filter change is a history entry, and the
commands need no rule of their own for which filter is primary:
`quarry-grep--primary` picks the first enabled include line filter of
whatever list results, and `r`, `t` and `K` use it.

- `quarry-grep--add-filter` (behind `- p`, `+ p`, `- l`, `+ l`, `- f`,
  `- d`, `+ d`) appends a literal filter. The four add commands take an
  optional REGEXP argument from Lisp; `- P`, `+ P`, `- L` and `+ L` are
  thin commands that call them with it. A prefix argument is not used:
  after a bare `C-u`, Emacs takes `-` as the sign of the argument, so
  `C-u - p` could never reach a command. A filter equal to an existing one in target, direction,
  pattern and syntax is not added: an enabled one is a `user-error`, a
  disabled one is replaced by the enabled filter in its place.
- The three commands that read the result at point take the path from
  the `quarry-grep-file` property. `- d` and `+ d` prefill the
  minibuffer with `/` plus the directory part and refuse a file without
  one; the result is a literal filter that matches at any depth, which
  the prompt ("containing") says and the user can edit.
- `- f` must name one file. A literal path filter matches anywhere in a
  path (`/a.c` also names `a.cpp` and `sub/a.c`), so
  `quarry-grep--file-pattern` builds a regexp filter: `(?-i)^/`, the path
  quoted by `quarry-grep--regexp-quote`, and `$`. The quoting escapes
  every character that is special in the Rust `regex` crate
  (`regexp-quote` is for Emacs regexps and leaves `(){}|` alone). `(?-i)`
  keeps case apart although path filters use smart case. The pattern is
  the same for the same file, so the duplicate rule still applies.
- `k`, `x`, `!` and `%` replace or drop the filter object of the line at
  point (`quarry-grep-filter` property). `%` cannot break the primary
  rule and goes through `quarry-grep--replace-filter`.

### Point after a search

`quarry-grep--render-start` looks at the line point is on before it
erases the buffer.

- On a filter line, point stays on the filter line at the same position
  in the list, or on the last one when the list got shorter, at the same
  column. This is done at once, since the filter block is rendered
  before the request is sent.
- On a result line or a heading, point goes to the start of the buffer
  and `quarry-grep--return` records the path, the line number (nil for a
  heading) and where point was put. `quarry-grep--insert-file` notes the
  start of the block with that path; after the batch,
  `quarry-grep--return-to-block` moves point to the line with that
  number, or to the heading. When the search ends as done without that
  block, `quarry-grep--return-near` moves point to the first heading
  whose path sorts after the recorded one, else to the first heading.
  A cancelled or failed search leaves point alone.
- Both steps act only where point is still at the position the search
  put it (`quarry-grep--return-goto`), and that is decided separately
  for the buffer's own point and for the point of each window that shows
  the buffer. A window in which the user moved point or scrolled is left
  alone, also when it is not the selected one. After the step the record
  is dropped, so later batches follow the rule that results never move
  point.
- The four commands move point to the start of the buffer first, which
  is the first filter line, so they start at the top.

The window start is set to the buffer start without force when a search
starts; when point is then moved to a returning line outside the window,
redisplay scrolls to it.

### Visiting

`quarry-grep--visit` takes the file from `quarry-grep-file` (appended to
`default-directory` with `concat`, so a name like `~x` stays below the
directory), finds the line by counting from the start of the widened
buffer, adds `quarry-grep-column`, and widens only when the place is
outside the narrowing. From the result window the file is shown in
another window; from elsewhere (`next-error` in a source buffer) in the
selected window, as `compilation-mode` does. `quarry-grep--next-error`
is the mode's `next-error-function`; `n` and `p` make the buffer
`next-error-last-buffer` and call `next-error-no-select`. It stops on
hits only: lines with `quarry-grep-context` do not count, and gap lines
have no `quarry-grep-line`. `RET` on a context line visits its line at
the first column, since its `quarry-grep-column` is nil; on a gap line
there is nothing to visit.

### History

`quarry-grep--past` and `quarry-grep--future` are buffer-local lists of
searches. `quarry-grep--run` pushes the search shown so far onto the past
and empties the future when the new search is not `equal` to it; `g`
therefore adds nothing. Back and forward pass the first search of their
list and the direction to `quarry-grep--run`, which takes it from that
list and moves the current search to the other one. All of this happens
in `quarry-grep--run` after the instance is there, so a search that
cannot start (module missing) leaves both lists as they were. The history
belongs to the buffer and survives a new command that reuses it.

### Editing with wgrep

wgrep is optional: `quarry-grep.el` declares its variables and functions
and loads it only in `quarry-grep-edit` (`e`), with `(require 'wgrep nil
t)`; when that fails the command names the package. The command is
refused while a search runs and without result lines.

**Stale check.** `quarry-grep--stale-files` goes over the file blocks and
lists the paths whose file is gone, whose modification time (`time-convert`
to milliseconds, which rounds down as the service does) differs from the
heading's `quarry-grep-mtime`, or that a modified buffer visits. Buffers
are compared by true name (`buffer-file-truename` of the modified
file-visiting buffers, collected once, against `file-truename` of each
result file), since a buffer can visit the file through a symbolic link;
nothing is resolved while no buffer is modified. A nil
`quarry-grep-mtime` is unknown and does not count. With such files `e`
asks (`y-or-n-p`); yes runs the search again and does not enter edit mode.

**Entering.** Fold overlays and wgrep overlays of an earlier commit are
removed. Buffer-locally, `wgrep-header&footer-parser` and
`wgrep-results-parser` are set to the two functions below,
`wgrep-prepared` to nil (the properties of an earlier edit are gone) and
`wgrep-original-mode-map` to the mode's map; then
`wgrep-change-to-wgrep-mode` runs. `wgrep-setup-internal` is not called:
it would bind `wgrep-enable-key` in the mode's map, to a command that
skips the checks above. wgrep replaces the local map with
`wgrep-mode-map`, which has no parent, so none of the mode's keys is
active while editing and `C-c C-k` is wgrep's abort.

**Property translation.** No text is parsed.

- `quarry-grep--edit-header-and-footer`: everything before the first
  `quarry-grep-heading` gets `wgrep-header` and `read-only`, the
  `quarry-grep-status` line `wgrep-footer` and `read-only`. The first
  character also gets `front-sticky (read-only)`. `mouse-face` and
  `follow-link` are removed from the whole buffer, since a `mouse-1`
  click would otherwise become `mouse-2`, which is a yank in edit mode.
- `quarry-grep--edit-results` (called with the buffer narrowed to the
  part between header and footer): a result line that is not
  `quarry-grep-inexact` gets `wgrep-line-filename` (the absolute name,
  `default-directory` plus `quarry-grep-file`) and `wgrep-line-number`
  on its `quarry-grep-prefix`; wgrep makes that prefix read-only and
  treats the rest of the line as the file's line. Every other line
  (headings, separators, inexact result lines) gets `wgrep-ignore`,
  newline included. A heading also gets the property
  `wgrep-construct-filename-property` makes for its file, from which
  wgrep starts looking for the file's lines. A context line is a result
  line here and is editable like a hit; a gap line is ignored like a
  separator. An inexact line has no file
  for wgrep, so it is read-only and cannot be written back even after
  wgrep's `C-c C-p` has made everything editable.

**While editing.** `quarry-grep--editing` is set. `quarry-grep--run` and
`quarry-grep--current` (the first call of every command that changes the
search, including the clicks on the header line) signal a `user-error`,
so no search can replace the text under an edit.

**Leaving.** wgrep has no hook for the end of its edit mode.
`quarry-grep--edit-sync` runs from a buffer-local `post-command-hook`
and at the start of the two functions above; when
`quarry-grep--editing` is set but the local map is no longer
`wgrep-mode-map`, it calls `quarry-grep--edit-restore`. That works for
commit, abort, `wgrep-exit` and `M-x`, without advice. The restore:

- removes `read-only`, `rear-nonsticky`, `front-sticky` and wgrep's
  properties, including the per-file ones it recorded;
- walks the lines once and puts `mouse-face` and `follow-link` back on
  filter lines, headings and result lines; re-applies
  `quarry-grep-line`, `quarry-grep-column` and `quarry-grep-context`
  over each result line from its first character; leaves gap lines as
  they are; and re-applies `quarry-grep-file` over each block
  from its heading to its `quarry-grep-separator`. Text typed in edit
  mode has no properties (wgrep makes the end of the prefix
  `rear-nonsticky`), which would split a block for folding. A line added
  by a newline typed into a result belongs to the block and has no line
  number;
- sets `quarry-grep--status-marker` to the status line again: an abort
  erases the buffer and inserts wgrep's copy, which collapses markers;
- switches undo off again and makes the buffer read-only;
- sets `quarry-grep--edited` when wgrep left result overlays, that is
  after a commit that applied or rejected something; the status line
  then has a second line that says so until the next search.

wgrep's overlays on the committed lines (applied or rejected, with the
reason shown at point) stay until the next search or the next `e`. The
buffer is not searched again after a commit: the changes are in file
buffers, not on disk, so a search would show the old text.
