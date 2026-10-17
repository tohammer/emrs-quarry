# Grep: regexp replace with preview

Status: implemented
Date: 2026-10-14

## Purpose

Replace what a search found across many files in one step, with capture
groups in the replacement, after seeing every change. This is for
mechanical changes such as a rename, a changed call signature or a
moved module path, which take too long to edit by hand with wgrep.

Success: in a `*quarry-grep*` buffer, `R` and a template such as
`new_$1` show every match as old → new. `x` leaves single matches or
whole files out. `C-c C-c` writes the switched-on changes and reports
how many lines were changed and how many were rejected. A change set
of thousands of files is written correctly, at a measured cost.

How to apply was decided with the author (ADR 0021): a preview of its
own, written by Elisp, not through wgrep and not by the service.

## Scope

In:

- `:replace` in the `(:search …)` request and `:replacements` on line
  items.
- A `replace` slot in the search value, so the template is part of the
  history and survives filter changes.
- The preview in the result buffer: old match struck through, new text
  next to it, per match switchable.
- Applying in Elisp, with the stale check of `e`, a check of every line
  and a result per line.
- The menu and the header line, README, architecture.
- Tests on generated trees, including large change sets, and a
  measurement script.

Out:

- Writing files in the service (option 3 of ADR 0021). Revisit when the
  measured cost of large change sets is too high.
- Replace in the live grep (`quarry-consult-grep`). Its hand-over
  (`C-c C-o`) to the result buffer is the way to get there.
- Filling the replaced text into wgrep's edit mode. `e` stays as it is,
  and is refused during a preview.
- Empty matches (`^`, `\b`, `x*` matching nothing). The service drops
  them from `:spans` today, and they get no replacement. To insert text
  at the start of lines, match something (`^(.)` → `PREFIX$1`).
- Case-preserving replacement, as `query-replace` does it.
- Templates with a newline; they are refused.
- Undo for files that were not visited. git is the undo.

## Design

### The service

`(:search …)` gets one optional field:

| Field | Value | Default |
|---|---|---|
| `:replace` | string: a replacement template for the primary filter's matches | nil: no replacement |

The template uses the syntax of `rg -r`, implemented with the capture
interpolation of `grep-matcher`: `$0` is the whole match, `$1` or `${1}`
a group by number, `$name` or `${name}` a group by name, and `$$` a
literal `$`. A name runs as far as letters, digits and `_` go, so
`$1a` is the group named `1a`; write `${1}a`. A group that does not
exist or did not take part gives the empty string. A literal primary
filter has only `$0`. A template is not checked; every string is valid.

With `:replace`, a kept line whose `:inexact` is nil gets
`:replacements`: a list of strings, one per entry of `:spans`, in the
same order, each the template interpolated for that match. The
interpolation runs on the whole line, as the matching does. A kept line
with `:inexact` t has no `:replacements`; it was cut or holds invalid
UTF-8, so its new text is not known for certain. Context lines have no
`:replacements`. Without `:replace` nothing changes, so the item shape
grows by one field and changes none.

The order of `:spans` and of the matches that `:replacements` is built
from must be the same: both come from the non-empty matches of the
primary filter on the whole line, which do not overlap. A test checks
this on lines with several matches, touching matches and multibyte
characters.

### Search value and history

`quarry-grep--search` gets a slot `replace`: nil, or the template
string. `quarry-grep--request` sends it as `:replace`. Since searches
are values, a search with a template is a history entry of its own:
`C-c <` after `R` goes back to the search without one. A filter command
or any other change during a preview keeps the template, so the preview
follows the narrowed search.

### Commands and keys

| Key | Command | Does |
|---|---|---|
| `R` | `quarry-grep-replace` | Asks for the template, with the current one as the initial input and a history of its own (`quarry-grep-replace-history`). Runs the current search with it. A template with a newline is a `user-error`. Refused while editing with wgrep |
| `x` | `quarry-grep-toggle-filter`, extended | On a filter line as today. During a preview: on a result line, switches the match at point off or on, or all matches of the line when point is not on a match. On a heading, switches all matches of the file: off when any is on, else on. Then moves to the next line with a match |
| `C-c C-c` | `quarry-grep-replace-apply` | Writes the switched-on changes (see "Applying") |
| `C-c C-k` | `quarry-grep-cancel`, extended | Cancels a running search as today. When no search runs and a template is set, runs the search without the template: the preview is left |

`e` is refused during a preview, with a message that names `C-c C-k`.
The menu (`?`) gets `R` and `C-c C-c`, with `C-c C-c` inactive outside a
preview. (Added in task 5: the entries of `x` and `C-c C-k` are active
wherever the commands now act, through `quarry-grep--toggle-at-point-p`
and `quarry-grep--cancellable-p`.) `quarry-grep--replace-p` decides for the menu and the commands,
as the other `-p` predicates do. The header line gets a part `→
TEMPLATE` during a preview, which runs `R` when clicked, and the counts
`N of M matches on`.

### The preview

The buffer text stays exactly what it is without a template: the
prefix and the item's `:text`. That keeps visiting, folding,
`next-error`, the stale check and every rule that reads properties
unchanged (ADR 0012).

Each primary match on a line with `:replacements` gets these text
properties over its span:

| Property | Value |
|---|---|
| `quarry-grep-replacement` | the new text of this match |
| `quarry-grep-replace-off` | t when the match is switched off |
| `display` | when on: the old text in the face `quarry-grep-replace-old` (struck through) followed by the new text in `quarry-grep-replace-new`. When off: not set; the match shows in `quarry-grep-match` as without a template |

`x` changes only `quarry-grep-replace-off` and `display`, with
`inhibit-read-only`, and updates the header counts.

A kept line without `:replacements` (an inexact line) has no
`quarry-grep-replacement`. It is shown as without a template, and the
status line counts these lines as "cannot be replaced (shortened or not
UTF-8)". A file whose matches are all of that kind is still shown.

The two faces are `defface`s in the group of quarry-grep. Defaults:
`quarry-grep-replace-old` inherits `quarry-grep-match` and adds
`:strike-through t`. `quarry-grep-replace-new` has the colours of
`diff-refine-added` as its own (changed in task 2: inheriting that face
fails while diff-mode is not loaded, and loading it is not wanted), so
it does not follow the theme.

### Applying

Deviations from the approved text, made after the two reviews and noted
in place below: files are read raw and written through a renamed file,
and open buffers are saved without the before-save hooks (ADR 0022);
the round-trip check, the lock handling, the UTF-16 exemption and
syncing as `write-region-inhibit-fsync` says (ADR 0023); `C-g` handling
and how "written" is decided for a visiting buffer.

`quarry-grep-replace-apply` is refused (`user-error`, saying why) when:
there is no template, a search runs, the search failed or was
cancelled, the summary says `truncated` (only what was previewed is
written: narrow the search or raise `quarry-grep-max-lines`), no match
is switched on, or the changes were already applied (see below).

Then it runs the stale check of `e` (`quarry-grep--stale-files`: file
gone, mtime changed, visited by a modified buffer). With stale files it
asks, as `e` does, whether to search again. Yes reruns the search with
the template and applies nothing; no stops and applies nothing either
(unlike `e`, which goes on: a modified visiting buffer would be
changed and saved with the user's unsaved edits). Without stale files
it asks "Replace N matches
on L lines in F files? " (`y-or-n-p`). (Changed on 2026-10-17, asked
for by the author: the question adds "(N files folded, M files outside
the narrowing)" with the parts that apply, since those files are
written too.)

For each file block with switched-on matches, in buffer order:

1. The new line for each line with a switched-on match is the line's
   text with each switched-on span replaced by its
   `quarry-grep-replacement`. Switched-off spans keep their old text.
   The old line is the text after the prefix.
2. The target buffer: the buffer that visits the file, if there is one;
   it is unmodified, since the stale check passed. Otherwise a temporary
   buffer into which the file is read with `insert-file-contents`, which
   decodes it and sets `buffer-file-coding-system`. (Changed after the
   review: the file is read with `insert-file-contents-literally` and
   decoded with `decode-coding-inserted-region`, which picks the coding
   system as `insert-file-contents` does but runs no format decoding,
   `after-insert-file-functions` or file name handler of compressed or
   encrypted files; a file starting with `Content-Type: text/enriched`
   was decoded as enriched text and the wrong lines were replaced. A
   file decoded as other than UTF-8 whose bytes hold a valid UTF-8
   sequence of two or more bytes is rejected as a whole with "the file's
   encoding is ambiguous (UTF-8 mixed with other bytes)". A visiting
   buffer that is unibyte or has a `raw-text` or `no-conversion` coding
   system is rejected with "buffer is visited literally" when a new text
   is not ASCII. The file name is the path joined to the search's
   directory, not to the result buffer's `default-directory`.)
   (Changed after the second review: a visiting buffer with unsaved
   changes is rejected with "buffer has unsaved changes"; the stale
   check misses a buffer that visits a hard link of the file outside the
   tree, and saving would write the user's edits. A visiting buffer
   whose `buffer-file-coding-system` cannot encode a new text is rejected
   with the message of the temporary buffer, before anything changes,
   so `save-buffer` never asks for another encoding. A file read into a
   temporary buffer must read back as it is: its decoded text, encoded
   with the coding system it is written with, must give its bytes
   exactly, else its lines are rejected with "the file does not read
   back as it is (encoding or line ends)"; a `utf-8-dos` cookie on a file
   with LF lines would have got CRLF on every line. UTF-16 is exempt
   from the ambiguity check, whose byte pairs often look like UTF-8.)
3. For each line, in ascending order: go to line N (counted from the
   start of the widened buffer). The line must equal the old line
   exactly; otherwise the line is rejected with "line changed since
   the search", and the file's other lines go on. Replacing a line
   never changes the line count, since templates have no newline, so
   the numbers stay valid.
4. If at least one line was changed: a visiting buffer is saved with
   `save-buffer`. A temporary buffer is written with `write-region` to
   the file, with `coding-system-for-write` bound to the coding system
   it was read with, and then killed. (Added in task 4: a file read as
   `undecided`, that is pure ASCII, is written as UTF-8 with its line
   ends, the encoding of the new text.) A file that cannot be read or
   written rejects all its lines, with the error message.
   (Changed after the review: a visiting buffer is saved with
   `before-save-hook` and `require-final-newline` bound to nil, the
   user's decision, so a formatter or whitespace cleanup on save does not
   change other lines; `after-save-hook` and the rest of `save-buffer`
   stay. Its changes run in a change group: when they or the saving fail
   or are stopped before the file is written, the change group is
   cancelled and the buffer is unmodified again, and the file's lines
   are rejected with the error message, or "stopped". A temporary buffer
   is encoded and written as bytes, with no
   `write-region-annotate-functions` or format, into a new file in the
   file's directory that gets the file's modes and extended attributes
   and is renamed over the file; on any error it is deleted and the file
   is untouched, so a full disk no longer truncates the file. A symbolic
   link is followed and stays a link. A file with more than one hard
   link, or for which the new file would have another owner or group, is
   written in place, with its old bytes written back if that fails.)
   (Changed after the second review: whether a visiting buffer's file
   was written is decided from the save, not from `buffer-modified-p`,
   which an `after-save-hook` can set again: a buffer-local
   `after-save-hook` entry sets a flag, and when a write function wrote
   the file and then signalled, the file's bytes are compared with the
   buffer. Once written, the lines count as applied and an error or
   `quit` after it only shows a message or stops the loop. A temporary
   buffer is written with no handler of compressed, encrypted or image
   files, synced to the disk as `write-region-inhibit-fsync` says (as
   any Emacs save; the author chose this on 2026-10-15 after syncing
   every file took 10,000 files to 40–130 s on a disk), and
   with the file locked by `lock-file` first, where a question about
   another Emacs's lock can be answered or quit with `C-g`. A writable
   file in a directory that cannot be written is written in place
   instead of rejected.)

Each result line gets an overlay with the result: `applied`, or
`rejected` with the reason as `help-echo`. The faces are
`quarry-grep-replace-applied` and `quarry-grep-replace-rejected`. The
echo area and the status line say "Replaced N lines in F files; R
rejected". `C-g` during the loop stops after the current file. The files
written so far stay written, and the status line says how many files
were not processed. (Changed after the review: quitting was inhibited
for the whole loop, so a slow save hook could not be interrupted. Now
only the writing of a temporary buffer is not interruptible; `C-g` while
a file is read or changed, or while a buffer is saved, stops at once,
leaves that file as it was, rejects its lines with "stopped" and ends
the loop. `C-g` after the file was written, in `after-save-hook`, stops
after it.)

After applying, the buffer is in the state *applied*
(`quarry-grep--replace-applied`). The preview still shows what was
written, the overlays show the result, and `x`, `C-c C-c` and `e` are
refused with a message that `g` searches again. Any search, including
`g`, ends this state and removes the overlays. A rerun with the
template shows what still matches: the rejected lines, and matches that
the new text produced.

Progress: every 100 files, a message "Replacing: F of T files".

### Large change sets

What the Emacs thread does per file is the cost: reading, finding the
lines, comparing, writing. It is measured by a script in `bench/`
(`bench/replace-bench.el`, run with `bench/run-bench.sh replace`) on
generated trees of 1,000 and 10,000 files with 5 matched lines each,
and in a tree with 100,000 matches in 1,000 files. It reports the time
until the preview is complete and the time to apply, in a release
build in batch Emacs. The numbers go into
`docs/architecture/grep.md`. If applying 10,000 files takes more than
30 seconds, a backlog item records it with option 3 of ADR 0021 as the
way out. (Measured after the second review: with each file synced to
the disk, 10,000 files take 40 s to over 2 minutes on an SSD, against
about 13 s without; the backlog records it.)

## Error handling

| Situation | Behaviour |
|---|---|
| Template has a newline | `user-error` in `R`; nothing runs |
| `R` while editing with wgrep, or in a search that has no primary filter | `user-error`, as the other change commands |
| `C-c C-c` refused (no template, running, failed, cancelled, truncated, nothing switched on, already applied) | `user-error` naming the reason; for truncated, how to get a complete result |
| Stale files | the question of `e`: search again, or stop |
| A line in the file differs from the search | that line rejected, reason in its overlay; the other lines of the file go on |
| A file cannot be read or written (permissions, gone) | all lines of the file rejected with the error message; the other files go on |
| A visiting buffer is read-only | its lines are rejected: "buffer is read-only" |
| A visiting buffer is not up to date with its file (added in task 4: `save-buffer` would ask in the middle of the loop) | its lines are rejected: "buffer is not up to date with its file" |
| The new text has a character the file's coding system cannot encode (added in task 4) | the file's lines are rejected with that message; nothing is written |
| The file is read as an 8-bit encoding but holds UTF-8 sequences (added after the review) | the file's lines are rejected: "the file's encoding is ambiguous (UTF-8 mixed with other bytes)"; nothing is written |
| A visiting buffer is visited literally and a new text is not ASCII (added after the review) | its lines are rejected: "buffer is visited literally" |
| `save-buffer` of a visiting buffer fails before writing (added after the review) | the buffer's changes are undone and it is unmodified; its lines are rejected with the error message |
| Writing a file fails (added after the review) | the temporary file is deleted and the file is untouched; its lines are rejected with the error message |
| `C-g` while applying | stops after the current file, reports what was written (changed after the review: while a file is read or changed or a buffer saved, at once, with that file left as it was and its lines rejected with "stopped"; changed after the second review: also in the question about another Emacs's lock) |
| A visiting buffer has unsaved changes (added after the second review) | its lines are rejected: "buffer has unsaved changes" |
| A visiting buffer's encoding cannot hold a new text (added after the second review) | its lines are rejected with the message of the temporary buffer; the buffer is not changed |
| A file's decoded text does not encode back to its bytes (added after the second review) | its lines are rejected: "the file does not read back as it is (encoding or line ends)"; nothing is written |
| A hook fails or quits after a visiting buffer's file was written (added after the second review) | the lines count as applied; the error is shown, a quit stops after this file |
| Another Emacs holds the file's lock (added after the second review) | `ask-user-about-lock` asks once; an answer that refuses rejects the file's lines, `C-g` stops; nothing is written either way |
| A module older than this feature | it ignores `:replace`; the rebuild message below |

emrs's deserializer skips plist keys that a request type does not name
(found in task 1: emrs `src/convert/de.rs`, and tried on a module built
without `:replace`). An older module therefore searches as usual and
sends no `:replacements`. If a file item has a kept line without
`:inexact` and without the key `:replacements` (checked with
`plist-member`: a kept line whose primary filter matched only empty
text has `:replacements nil`), the preview cancels the search, says
that the module is older than replace and must be rebuilt, and runs
the search without the template.

## Testing

Rust (`src/grep/search.rs`, `src/grep/service.rs`):

- `$0`, `$1`, `${1}x`, `${name}`, `$$`, a missing group, a literal
  primary filter, several matches on a line, multibyte text before and
  inside matches, `\r\n` lines, an inexact line (cut and invalid
  UTF-8) without `:replacements`, context lines without them, and no
  `:replacements` at all without `:replace`.
- `:replacements` has as many entries as `:spans` on every kept exact
  line, also with secondary filters on the line.

ERT (`tests/quarry-grep-tests.el`, generated trees, real module):

- `R` renders the preview: `display` and properties on each match,
  buffer text unchanged, header part and counts.
- `x` on a match, on a line outside a match, on a heading; the counts.
- Filter change during a preview keeps the template; `C-c <` goes back
  to the search without it; `C-c C-k` leaves the preview.
- Applying: files changed exactly as expected byte for byte (several
  matches per line, some switched off, a whole file off), unvisited
  files written, an unmodified visiting buffer changed and saved, point
  in it kept.
- Refusals: truncated, running, nothing switched on, applied, `e`
  during a preview.
- A line changed on disk after the search (with the mtime set back, so
  the stale check passes) is rejected; the file's other lines are
  applied.
- An unwritable file is rejected with its message; the other files are
  applied.
- Files with `\r\n` line ends, a UTF-8 BOM and Latin-1 encoding keep
  their line ends, BOM and encoding. A Latin-1 line with a non-ASCII
  character is inexact and not replaced.
- A large change set in the suite: 500 files with 4 matches each,
  applied, every file compared with the expected content. This keeps
  the bulk path in the regular tests at a few seconds' cost.
- The menu test covers the new keys.

Measurement: the bench script above, run once, numbers recorded.

Manual checks (not covered by batch tests): the two faces and the
struck-through text in the author's theme, in a GUI frame and in a
terminal (where strike-through may not show); `x` through a long
preview; `C-g` during a large apply; a replace in files that are open
in Emacs, with undo in those buffers afterwards.

## Tasks

- [x] 1. **Service: `:replace` and `:replacements`.** Request field,
  interpolation with `grep-matcher` on the whole line, `:replacements`
  on exact kept lines, the module docs of `src/grep/service.rs`. Find
  out how an older module treats the unknown field and write it into
  this spec's Error handling. *Done when* the Rust tests above pass,
  `cargo clippy --all-targets -- -D warnings` is clean and a search
  without `:replace` gives the same items as before.
- [x] 2. **Search value, `R` and the preview.** The `replace` slot, the
  request, `R` with its history and checks, rendering with the
  properties and faces, the header part and counts, the status line
  count of lines that cannot be replaced, `C-c C-k` leaving the
  preview, `e` refused, the detection of an old module. *Done when* the
  preview, filter-change, history and refusal tests pass and
  `tests/run-ert.sh` is green. Needs task 1.
- [x] 3. **`x` on matches and headings.** *Done when* the toggle tests
  pass. Needs task 2.
- [x] 4. **Applying.** `quarry-grep-replace-apply`, the per-file
  procedure, the overlays and faces of the results, the applied state,
  progress and `C-g`. *Done when* the applying, rejection, encoding and
  500-file tests pass. Needs task 3.
- [x] 5. **Menu, README, architecture.** Menu entries and predicate,
  the menu test; README section on replace (keys, template syntax with
  the `${1}a` pitfall, that only previewed matches are written, that
  unvisited files have no undo); `docs/architecture/grep.md` and the
  table in `docs/architecture.md`. *Done when* the menu test passes and
  a doc check of the branch finds nothing missing. Can run in parallel with
  task 6. Needs task 4.
- [x] 6. **Measurement.** `bench/replace-bench.el` and its entry in
  `bench/run-bench.sh`; run it on 1,000 and 10,000 files and on 100,000
  matches; numbers in `docs/architecture/grep.md`, and a backlog item if
  10,000 files take over 30 seconds. *Done when* the script runs and
  the numbers are recorded. Can run in parallel with task 5. Needs task
  4.
