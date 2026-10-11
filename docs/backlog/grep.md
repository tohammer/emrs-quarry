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

## A menu to make the keys discoverable

Check whether the result buffer should get a transient menu, or
something like it, that shows the available commands. The buffer has
some forty keys, several behind the `-` and `+` prefixes and several
that only work on a filter line; nothing in the buffer shows them. rg.el
has such a menu (`rg-menu`, on `m`), built on transient. To weigh: a
transient menu (a dependency, though transient ships with Emacs since
28) against lighter means such as `which-key` descriptions for the
prefix maps, a menu-bar and context menu, or a short key summary in the
buffer or on `?`; whether the menu only lists commands or also holds the
toggles (case, ignore files, hidden) as switches; and how it shows the
commands that depend on point. Origin: requested by the author on
2026-10-10, after the first use of quarry-grep. Revisit together with
the manual checks, when the keys have been used for a while.

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
highlighting. Revisit with the next change to the item shape (context
lines, or the delivery cost of large results), so the format changes
once.
