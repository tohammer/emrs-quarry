# Backlog: grep

The grep service and `quarry-grep.el`. Part of [the backlog](../backlog.md).

## Delivery of very large results is slower than the search

A search for `defun` in a tree of 19,800 files finds 33,800 lines in
about 100 ms inside the service, but takes 200 to 260 ms until the last
item has reached Lisp (release build, batch Emacs, without inserting
anything): emrs converts one plist per line on the Emacs thread, and the
search waits for it at the stream's capacity. Inserting the lines into
the buffer comes on top and was not measured with the real renderer. Ordinary searches (hundreds of
lines) are not affected. Option: send each file's lines as one string
with parallel integer lists for line numbers and match positions, so
the conversion cost is per file, not per line; this changes the item
shape. Origin: task 4 of the grep spec (2026-10-10), measurement by the
implementer. Revisit when the result buffer is in daily use and large
searches feel slow.

## Context lines before and after a match

Let the user set how many lines are shown before and after each match,
as `-B`, `-A` and `-C` do in grep and rg. `grep-searcher` supports it
(`before_context`, `after_context`, `Sink::context`). To design: the
request fields and the item shape for context lines; how they look in a
file block (separator between groups, a different face); keys to change
the counts from the result buffer; that context lines are not matches
for `next-error` and the hit counts; whether line filters apply to them
(they should not); and wgrep, where context lines could be editable like
match lines. Origin: requested by the author on 2026-10-10, during the
grep spec's implementation; the spec lists context lines as out of
scope. Revisit as the next grep feature.

## Manual checks not done yet

The grep spec lists manual checks that batch tests cannot replace, and
only terminal Emacs under a pty was tried: mouse clicks on line numbers
and header parts in a GUI frame, folding and the three highlight faces in
the author's theme, point and scrolling with two windows on the result
buffer during a slow search, the file type prompt under vertico, a
search for a common word in a tree of 20,000 files compared by feel with
`M-x rg`, and a search that reaches the line cap. Emacs 30 was not run
at all. Origin: grep spec, Testing section, and its review
(2026-10-10). Do these once quarry-grep is in daily use; turn what
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
