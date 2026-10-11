# Backlog: grep

The grep service and `quarry-grep.el`. Part of [the backlog](../backlog.md).

## Delivery of very large results is slower than the search

A search for `defun` in a tree of 19,800 files finds 33,800 lines in
about 100 ms inside the service, but takes 200 to 260 ms until the last
item has reached Lisp (release build, batch Emacs, without inserting
anything): emrs converts one plist per line on the Emacs thread, and the
search waits for it at the stream's capacity. Inserting the lines into
the buffer comes on top and was not measured with the real renderer. Ordinary searches (hundreds of
lines) are not affected. Context lines multiply the lines of a result
by up to `1 + before + after` and are not capped (ADR 0014), so a large
search with context reaches this cost sooner. Option: send each file's lines as one string
with parallel integer lists for line numbers and match positions, so
the conversion cost is per file, not per line; this changes the item
shape. Origin: task 4 of the grep spec (2026-10-10), measurement by the
implementer. Revisit when the result buffer is in daily use and large
searches feel slow.

## Manual checks not done yet

The grep spec lists manual checks that batch tests cannot replace, and
only terminal Emacs under a pty was tried: mouse clicks on line numbers
and header parts in a GUI frame, folding and the three highlight faces in
the author's theme, point and scrolling with two windows on the result
buffer during a slow search, the file type prompt under vertico, a
search for a common word in a tree of 20,000 files compared by feel with
`M-x rg`, and a search that reaches the line cap. Emacs 30 was not run
at all. From the context lines spec (2026-10-11): the context face and
the gap line in the author's theme, in a GUI frame and in a terminal,
and `2 C` on a result of a few hundred hits by feel. From the keys menu
spec (2026-10-11): the menu (`?`) in the author's Doom setup (evil,
theme, GUI frame), and on Emacs 30.1 with its own transient 0.7.2, where
only the tests of the menu were run against that transient's source
loaded into Emacs 31.1. Origin: grep spec,
Testing section, and its review (2026-10-10); context lines and keys
menu specs, Testing sections. Do these once quarry-grep is in daily use; turn what
fails into backlog items or fixes.

## wgrep on other line ends and encodings, and on huge results

Editing through wgrep was tested on UTF-8 files with `\n` line ends.
Not tested: files with `\r\n` line ends (quarry shows the line without
the `\r`), UTF-16 files found through their byte order mark, and files
in other 8-bit encodings whose lines are valid UTF-8 by accident. wgrep
compares the old line text before it applies a change and should reject
a mismatch, but that was not checked. Entering edit mode walks every
result line and the stale check stats every file, so `e` on tens of
thousands of lines may be slow; not measured. Origin: task 7 of the grep
spec and its review (2026-10-10). Revisit on the first report, or test
the three file kinds before announcing quarry-grep to others.

## A file that fills the line cap before its NUL byte counts as text

A binary file gives no lines, but when its first lines fill the rest of
the line cap before the NUL byte is read, those lines are delivered.
Origin: task 4 of the grep spec (2026-10-10); accepted because the
search has stopped at that point anyway. Revisit if binary lines show up
in capped results.

## A colour of its own for each additional include line filter

Today the primary filter's matches have one face and all other include
line filters share a second one. Give each additional filter its own
colour, at least while there are not too many, so that a line shows
which filter matched where; beyond the number of faces provided, reuse
them in turn or fall back to the shared face. To settle:

- The faces must be customizable: a list of faces as an option, in the
  manner of `quarry-match-faces` of the file finder, with the faces
  themselves defined by `defface`.
- Whether non-primary filters are coloured at all stays the user's
  choice. `quarry-grep-highlight-include-filters` switches it off today;
  check that it still covers this, or fold both into one option (off,
  one shared colour, one colour per filter).
- The filter block shows each pattern in its filter's colour, as it does
  now for the two faces.
- The service reports only whether a match is primary or not. It has to
  say which filter each match belongs to, which changes the item shape
  (`:secondary` becomes positions with a filter number); overlaps
  between two additional filters then need a rule.

Origin: requested by the author on 2026-10-11, after trying the
highlighting. Revisit with the next change to an existing field of the
item shape (the delivery cost of large results), so the format changes
once. Context lines (2026-10-11) only added a flag to line items and
were done without it.

## Filters: editing in the buffer, file content, narrowing in memory

Three extensions of the filters, weighed before the grep spec and left
out of it:

- **Editing a filter in the buffer as you type.** Feasible: the pattern
  of a filter line becomes an editable field, the rest stays read-only,
  and a change runs the search again after a short idle delay; with
  cancellation and under 100 ms per search on an ordinary tree that is
  search-as-you-type. The cost: the buffer must be writable with
  read-only regions, the same technique wgrep uses, so the two states
  must be kept apart; results arrive below while point is in a filter
  line; undo and invalid half-typed regexps need handling. Today a
  filter is edited in the minibuffer with `RET`.
- **Filters on file content**: only files that contain X somewhere, or
  no file that contains X. Needs a second pass over the files with hits
  and a third filter target next to line and path.
- **Narrowing in memory.** Adding a filter only narrows the result, so
  the service could filter results it holds instead of searching again.
  Not worth it while a rerun costs under 100 ms; interesting on very
  large trees.

Origin: evaluation before the grep spec (2026-10-10); the author asked
for in-buffer editing "if possible". Revisit when the filter block has
been used for a while.

## Grep on the file index and the watcher

With a current index, grep need not walk the tree or evaluate ignore
files: the index lists the candidate files at once, which matters on
very large trees and most with include path filters, since a walk cannot
skip directories for them. The watcher could mark results as stale or
refresh them when files change. Both need the two services to share
state, which is not designed (ADR 0010): emrs has no service-to-service
calls, the index is owned by one service without locks, and a full
snapshot copies the whole index (file finder backlog, "Unbounded memory
during walks and `(:files)`"). The index also holds only non-ignored
files of a project root, so grep keeps its own walk for other
directories and for searches with ignore files off. Origin: evaluation
before the grep spec (2026-10-10); this is why both tools live in one
module. Revisit when searches on a very large tree are measured and the
walk is a real share of the time.

## Further features weighed before the spec

Candidates, each one line; none is designed.

- **Regexp replace with preview across files.** The strongest
  candidate: the engine has the capture groups, and it complements
  wgrep for mechanical changes.
- **consult front end**: the pattern as you type in the minibuffer, in
  the manner of `quarry-consult.el`.
- **Saved and named searches**, and a list of search buffers, as rg.el
  has. Today there is one result buffer; `clone-buffer` keeps a result.
- **Export to a plain `grep-mode` buffer**, as a bridge to embark and
  other tools.
- **Multi-line matches.** The engine supports them; display and wgrep
  get harder.
- **Searching unsaved buffer contents.** The module sees only the disk;
  Emacs would have to send the text of modified buffers.
- **Remote directories.** A module cannot search over TRAMP; the
  commands refuse and name rg.el. Handing the search over to rg.el
  automatically, when it is installed, would be possible.
- **PCRE2** (look-around, back-references): on demand; it needs a C
  library at build time (ADR 0011).

Considered and not planned: a trigram index for content search (a large
project of its own; the search is fast enough below AOSP size), and
`~/.ripgreprc`, compressed files and preprocessors (ADR 0011).

Origin: evaluation before the grep spec (2026-10-10). Pick from here
when the items above it in this file are done or a need shows up.
