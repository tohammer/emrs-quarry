# Grep: regexp replace with preview

Status: approved
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
preview. `quarry-grep--replace-p` decides for the menu and the commands,
as the other `-p` predicates do. The header line gets a part `→
TEMPLATE` during a preview, which runs `R` when clicked, and the counts
`N of M matches switched on`.

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

`quarry-grep-replace-apply` is refused (`user-error`, saying why) when:
there is no template, a search runs, the search failed or was
cancelled, the summary says `truncated` (only what was previewed is
written: narrow the search or raise `quarry-grep-max-lines`), no match
is switched on, or the changes were already applied (see below).

Then it runs the stale check of `e` (`quarry-grep--stale-files`: file
gone, mtime changed, visited by a modified buffer). With stale files it
asks, as `e` does, whether to search again. Yes reruns the search with
the template and applies nothing. Otherwise it asks "Replace N matches
on L lines in F files? " (`y-or-n-p`).

For each file block with switched-on matches, in buffer order:

1. The new line for each line with a switched-on match is the line's
   text with each switched-on span replaced by its
   `quarry-grep-replacement`. Switched-off spans keep their old text.
   The old line is the text after the prefix.
2. The target buffer: the buffer that visits the file, if there is one;
   it is unmodified, since the stale check passed. Otherwise a temporary
   buffer into which the file is read with `insert-file-contents`, which
   decodes it and sets `buffer-file-coding-system`.
3. For each line, in ascending order: go to line N (counted from the
   start of the widened buffer). The line must equal the old line
   exactly; otherwise the line is rejected with "line changed since
   the search", and the file's other lines go on. Replacing a line
   never changes the line count, since templates have no newline, so
   the numbers stay valid.
4. If at least one line was changed: a visiting buffer is saved with
   `save-buffer`. A temporary buffer is written with `write-region` to
   the file, with `coding-system-for-write` bound to the coding system
   it was read with, and then killed. A file that cannot be read or
   written rejects all its lines, with the error message.

Each result line gets an overlay with the result: `applied`, or
`rejected` with the reason as `help-echo`. The faces are
`quarry-grep-replace-applied` and `quarry-grep-replace-rejected`. The
echo area and the status line say "Replaced N lines in F files; R
rejected". `C-g` during the loop stops after the current file. The files
written so far stay written, and the status line says how many files
were not processed.

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
way out.

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
| `C-g` while applying | stops after the current file, reports what was written |
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
- [ ] 4. **Applying.** `quarry-grep-replace-apply`, the per-file
  procedure, the overlays and faces of the results, the applied state,
  progress and `C-g`. *Done when* the applying, rejection, encoding and
  500-file tests pass. Needs task 3.
- [ ] 5. **Menu, README, architecture.** Menu entries and predicate,
  the menu test; README section on replace (keys, template syntax with
  the `${1}a` pitfall, that only previewed matches are written, that
  unvisited files have no undo); `docs/architecture/grep.md` and the
  table in `docs/architecture.md`. *Done when* the menu test passes and
  `devflow:doc-checker` finds nothing missing. Can run in parallel with
  task 6. Needs task 4.
- [ ] 6. **Measurement.** `bench/replace-bench.el` and its entry in
  `bench/run-bench.sh`; run it on 1,000 and 10,000 files and on 100,000
  matches; numbers in `docs/architecture/grep.md`, and a backlog item if
  10,000 files take over 30 seconds. *Done when* the script runs and
  the numbers are recorded. Can run in parallel with task 5. Needs task
  4.
