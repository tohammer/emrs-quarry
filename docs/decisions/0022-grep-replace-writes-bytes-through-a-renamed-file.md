# 0022 — Grep replace reads files raw, writes them through a renamed file, and saves buffers without before-save hooks

Date: 2026-10-15
Status: accepted

## Context

ADR 0021 has Elisp write the replacements: a visiting buffer is changed
and saved, any other file is read with `insert-file-contents` into a
temporary buffer and written back with `write-region`. wgrep does the
same. The review of the replace branch (2026-10-14) found that this
loses data:

- `insert-file-contents` runs format decoding and
  `after-insert-file-functions`. A file that starts with `Content-Type:
  text/enriched` lost its header and blank lines, and the wrong line was
  replaced.
- `write-region` over the file truncates it first; a write that fails
  (full disk, quota) leaves a cut file, and the only copy of the old
  text is a temporary buffer that is gone after the error.
- `save-buffer` runs `before-save-hook` (formatters, whitespace
  cleanup) and `require-final-newline`, so an open file got changes
  beyond the matches while the same file, not open, did not.
- A UTF-8 file with one invalid byte is decoded as Latin-1, so new
  non-ASCII text went in as Latin-1 bytes.

Other tools were looked at for the hook question: wgrep saves open
buffers with `basic-save-buffer` (all hooks) and writes other files
without any; Emacs's own `project-query-replace-regexp` and xref leave
the buffers unsaved for the user. The author chose, on 2026-10-15, to
save without the before-save hooks.

## Decision

- A file that no buffer visits is read with
  `insert-file-contents-literally` and decoded with
  `decode-coding-inserted-region`, which picks the coding system as
  `insert-file-contents` does but converts nothing else. It is encoded
  in the buffer and written as bytes, with no annotation functions and
  no format.
- The bytes go into a new file in the same directory, which gets the
  original's modes and extended attributes and is renamed over it. A
  symbolic link is followed, so it stays a link. A file with more than
  one hard link, or one whose new file would get another owner or
  group, is written in place, with its old bytes written back if that
  fails.
- A file decoded with a coding system other than UTF-8 or `undecided`
  whose bytes contain a valid multibyte UTF-8 sequence is not written:
  its encoding is ambiguous.
- A visiting buffer is saved with `before-save-hook` and
  `require-final-newline` bound to nil; `after-save-hook` and the rest of
  `save-buffer` run. The edits are a change group, cancelled when they
  or the save fail or are quit before the file is written.
- `inhibit-quit` covers only the writing of a file, not the reading,
  the edits or the save hooks.

This supersedes the reading and writing described in ADR 0021; the rest
of 0021 (the service computes, Elisp previews and writes) stands.

## Consequences

- A replace changes exactly the matched text in every file, open or
  not, and a failed write leaves the file as it was.
- Writing costs about 0.4 ms more per file (temporary file, attributes,
  rename): 10,000 files take about 11 s instead of 8 s on the
  measuring machine under load.
- A formatter on `before-save-hook` does not run during a replace.
- A crash between creating the new file and the rename leaves a
  `.quarry-XXXXXX` file next to the original.
- The new file is not synced before the rename beyond what
  `write-region-inhibit-fsync` says.
