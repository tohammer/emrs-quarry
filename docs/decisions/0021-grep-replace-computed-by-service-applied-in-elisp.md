# 0021 — Grep replace: the service computes the new text, Elisp previews and writes it

Date: 2026-10-14
Status: accepted; reading and writing superseded by ADR 0022

## Context

A regexp replace across the files of a search result needs three
things: the replaced text, a preview, and a way to write the change.

The patterns are Rust regexps (ADR 0011), so Emacs cannot compute a
replacement with capture groups itself; the service can, with the
interpolation of `grep-matcher`.

Three ways to apply were weighed with the author on 2026-10-14:

1. Fill the replaced text into wgrep's edit mode and commit with wgrep.
   Small, and lines can be edited by hand; but the preview shows only
   the new line, a match cannot be left out other than by editing, and
   it requires wgrep.
2. A preview of its own in the result buffer, old and new per match,
   each match switchable, written by Elisp through file buffers or
   temporary buffers, as wgrep does.
3. The same preview, with the service writing the files on disk in
   parallel. Fast at any size and off the Emacs thread, but writing
   files from the module is new ground: open buffers, encodings, byte
   order marks and line ends would have to be handled in Rust.

## Decision

Option 2. The service gets a replacement template in the search
request and sends the new text of each match. The result buffer shows
old and new per match through `display` properties, so its text stays
exactly the item text, and each match can be switched off. Applying is
Elisp: an unmodified visiting buffer is changed and saved, any other
file is read into a temporary buffer (`insert-file-contents`, which
decodes as Emacs does), changed and written back with the coding system
it was read with (reading and writing: superseded by ADR 0022). Every
line is compared with the text of the search before it is changed.

A result that reached the line cap cannot be applied: only what was
previewed is written.

## Consequences

- Writing happens on the Emacs thread and blocks it, at a cost per file
  that is measured with large change sets (spec
  `2026-10-14-grep-replace.md`). Option 3 stays possible: the preview
  and the item shape do not depend on who writes.
- Encodings, line ends and byte order marks are Emacs's business, as
  for wgrep; a line that Emacs decodes differently from the service is
  rejected by the comparison, not changed wrongly.
- No dependency on wgrep; `e` stays the way to edit by hand.
- Files that are not visited are written without undo in Emacs.
