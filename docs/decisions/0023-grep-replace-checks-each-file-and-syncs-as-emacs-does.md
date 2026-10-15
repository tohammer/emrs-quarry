# 0023 — Grep replace checks each file before writing it, and syncs as Emacs does

Date: 2026-10-15
Status: accepted

## Context

A second review of the replace write path (after ADR 0022) found files
that were written wrongly or not at all where they should have been:

- A coding cookie such as `utf-8-dos` on a file with LF line ends:
  decoding leaves the LFs, encoding turns every line end into CRLF.
- UTF-16 files were rejected as ambiguous, since their byte pairs often
  look like UTF-8 sequences.
- The in-place write of a hard-linked file went through the file name
  handlers, so a plain `notes.gz` came out compressed.
- A file another Emacs is editing was replaced without asking, and its
  lock question could not be quit.
- A visiting buffer with unsaved edits, found through a hard link the
  stale check misses, was saved with the replacement; a save hook that
  changed the buffer and then failed left buffer and file apart.

Syncing every file before its rename was tried: on an NVMe SSD under
LUKS, applying 10,000 files took 40 s to over 2 minutes instead of about
13 s. Emacs's own saves sync only when `write-region-inhibit-fsync` is
nil, and its default is t. The author chose on 2026-10-15 to follow
Emacs.

The apply code also reads the text of result lines, where ADR 0012 says
commands read properties and never the text.

## Decision

- Each file read for a replace must read back as it is: encoding the
  decoded text with the coding system it will be written with must give
  the file's bytes. Otherwise its lines are rejected ("the file does
  not read back as it is"). The ambiguity check of ADR 0022 does not
  apply to UTF-16.
- Writes inhibit the handlers that `insert-file-contents-literally`
  inhibits (compressed, encrypted, image files).
- The target is locked with `lock-file` before writing, with `C-g`
  possible at the question about another Emacs's lock; the writes
  themselves take no lock.
- A visiting buffer with unsaved changes, or whose coding system cannot
  encode the new text, is rejected before any edit. Whether its file
  was written is decided by the save (an `after-save-hook` entry, or the
  file's bytes), not by the modified flag.
- A writable file in a directory that cannot be written is written in
  place, with its old bytes written back if that fails.
- Syncing follows `write-region-inhibit-fsync`, as any save.
- Applying a replacement may read a result line's text: it compares it
  with the file and builds the new line from it. Nothing is parsed out
  of it; the line's identity still comes from properties.

## Consequences

- No encoding or line-end surprise can change untouched lines: such a
  file is left alone.
- With the default `write-region-inhibit-fsync`, a power loss right
  after a replace can leave empty files on file systems without ext4's
  rename heuristics, as after any Emacs save. Users who set it to nil
  get synced replaces at the measured cost.
- The round-trip check and the lock add 0.1 to 0.2 ms per file.
