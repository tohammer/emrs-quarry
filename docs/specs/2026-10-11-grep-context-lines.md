# Grep: context lines before and after a match

Status: implemented
Date: 2026-10-11

## Purpose

Show the lines around each hit in the `*quarry-grep*` buffer, as `-B`,
`-A` and `-C` do in grep and rg, so that a hit can be judged without
visiting the file. The counts are part of the search and are changed
from the result buffer.

Success: `2 C` in a result buffer shows two lines before and after every
hit, in a face that sets them apart, with a gap line where two groups do
not touch; `n` and `p` still go from hit to hit and the counts still
count hits; `0 C` gives the buffer of today; a context line can be
edited with wgrep like a hit.

## Scope

In:

- Two fields in the `(:search …)` request and a flag on line items.
- Two slots in the search record, two options for what a new search
  starts with, three commands (`C`, `B`, `A`), a part in the header line.
- Rendering: a face for context lines and a gap line between groups.
- wgrep: context lines are editable.

Out:

- A colour per include line filter and the cheaper delivery format for
  large results. Both stay in the backlog. This change only adds a flag
  to the item shape and changes no existing field, so it is not the
  format change those two items wait for.
- Highlighting of filter matches inside context lines.
- A cap on context lines (ADR 0014).

Changed after manual testing: the prompts of `B` and `A` name their
side and show the other side's count.

Changed after the review: the counts are limited to 1000 lines per side
(ADR 0015). Where this spec says that nothing limits a count, that no
longer holds: the service takes a larger count as 1000, and the commands
and the two options reduce it and say so in the echo area.

## Design

### The service

`(:search …)` gets two optional fields:

| Field | Value | Default |
|---|---|---|
| `:before` | integer ≥ 0: lines shown before each kept line | 0 |
| `:after` | integer ≥ 0: lines shown after each kept line | 0 |

A *kept line* is what a line item is today: a line that the primary
filter matched and the other line filters kept. A *context line* is a
line of the same file that is not kept and lies at most `:before` lines
before or at most `:after` lines after a kept line (ADR 0014). Line
filters are not applied to context lines.

Context lines travel in the file item's `:lines`, in place by line
number, with `:context t`:

```elisp
(:file :path "src/walk.rs" :path-spans nil :mtime 1760103296123
       :lines ((:n 168 :text "#[inline]" :context t)
               (:n 169 :text "pub fn walk(" :spans ((7 11)))
               (:n 170 :text "    let mut out = vec![];" :context t)))
```

- `:lines` stays in ascending line number and holds each line once.
- A kept line has no `:context` (nil), as today.
- A context line has `:n`, `:text` and `:inexact` with the meaning they
  have for a kept line (`:max-columns` applies), and `:spans` and
  `:secondary` nil.
- The item does not mark gaps; two neighbours in `:lines` whose `:n`
  differ by more than 1 have a gap between them.

What does not change: a file item exists only for a file with at least
one kept line; `:max-lines`, the summary's `:lines` and `:truncated`
count kept lines only; a binary file gives nothing; order, the sort
budget and cancellation. The search stops at the kept line that fills
the cap, so the last kept line of a file can come with its lines before
and without its lines after.

With both fields 0 the searcher is configured as it is today and the
items are those of today.

`src/grep/search.rs`: `Config` gets `before` and `after`; the searcher is
built with them as `before_context` and `after_context`; `LineSink`
implements `Sink::context` and decides, by line number, which of the
lines the searcher reports (context lines and matches that a line filter
dropped) are within reach of a kept line. Lines before a kept line are
held back until one arrives, at most `before` of them. `Line` gets
`context: bool`. `src/grep/service.rs`: the two request fields and the
module docs.

### The search in Elisp

`quarry-grep--search` gets the slots `before` and `after`, both 0 by
default. They are part of the value: two searches that differ only in
context are different searches for `equal` and for the history.
`quarry-grep--request` sends `:before` and `:after`.

Two options, in the manner of `quarry-grep-case`:

| Option | Default | Meaning |
|---|---|---|
| `quarry-grep-context-before` | 0 | Lines before each hit that a new search starts with |
| `quarry-grep-context-after` | 0 | Lines after each hit that a new search starts with |

They apply to the four commands (`quarry-grep`, `quarry-grep-literal`,
`quarry-grep-project`, `quarry-grep-dwim`). Commands in the result
buffer keep the counts of the search they change.

### Commands

| Key | Command | Sets |
|---|---|---|
| `C` | `quarry-grep-set-context` | both counts |
| `B` | `quarry-grep-set-context-before` | the count before |
| `A` | `quarry-grep-set-context-after` | the count after |

With a numeric prefix argument the command takes it as the count and
does not ask (`3 C`, `C-u 3 C`; `special-mode` makes the digits prefix
keys). Without one it reads a number in the minibuffer; the default is
the current count, for `C` the larger of the two. 0 switches that side
off. A negative number is a `user-error` and changes nothing. The
commands go through `quarry-grep--change`, so each is a new search and,
when a count changed, a history entry; they are refused in wgrep's edit
mode like every change command.

The header line gets a part between `hidden` and `hits`: `ctx: 0`,
`ctx: 2` when both counts are 2, `ctx: 1/3` for 1 before and 3 after. A
click on it runs `quarry-grep-set-context`.

### Rendering

```text
File: src/walk.rs (2)
  167 /// Walks the tree.
  168 #[inline]
  169 pub fn walk(dir: &Path) {
  170     let mut out = vec![];
    ⋮
  201     // second pass
  202     walk(&sub);
  203 }
```

- A context line has the same prefix as a hit (the line number in
  `quarry-grep-line-number`); its text has the new face
  `quarry-grep-context`, which inherits `shadow`.
- A *gap line* stands between two neighbouring lines of a block whose
  line numbers are not adjacent, when the buffer's search has a count
  above 0. Its text is `⋮`, right-aligned in the number column, in
  `quarry-grep-context`. A search without context has no gap lines, as
  today.
- The number in a heading, `quarry-grep--lines`, the `hits` part and the
  status line count hits only.

Text properties:

| Property | On | Value |
|---|---|---|
| `quarry-grep-line` | a hit and a context line | its line number (unchanged meaning) |
| `quarry-grep-context` | a context line | t |
| `quarry-grep-gap` | a gap line | t |

A context line also has `quarry-grep-prefix`, `quarry-grep-inexact` when
it applies, `mouse-face` and `follow-link`; its `quarry-grep-column` is
nil. A gap line has `quarry-grep-file` like the rest of its block and
nothing else; it is inside the fold of its block.

Behaviour on these lines:

- `RET` and a click on a context line visit that line of the file, at
  its first column.
- `n`, `p`, `next-error` and `previous-error` stop on hits only and pass
  over context and gap lines.
- `RET` on a gap line does what it does on the empty line after a block
  today.
- Point after a new search: a context line is remembered by path and
  line number like a hit; when the new result does not show that line,
  point goes to the file's heading.
- The commands that read the file at point (`- f`, `- d`, `+ d`), `TAB`,
  `{` and `}` work from context and gap lines as from hits.

### wgrep

`quarry-grep--edit-results` treats a context line as a hit: it gets
`wgrep-line-filename` and `wgrep-line-number` on its prefix unless it is
`quarry-grep-inexact`. A gap line gets `wgrep-ignore`.
`quarry-grep--edit-restore` puts `quarry-grep-context` back over a
context line from its first character, as it does for
`quarry-grep-line`, and leaves gap lines as they are. The stale check is
unchanged.

### Documentation

README: the keys table, the options table, the faces, the buffer
description and a short section on context lines, including that a line
removed by a `- line` filter can appear as context and that the cap
counts hits. `docs/architecture/grep.md`: "What is searched", "Cap", the
search record, the properties table, rendering, wgrep. Module docs of
`src/grep/service.rs` and `src/grep/search.rs`.

## Error handling

- A negative count typed or given as a prefix: `user-error`, the search
  is unchanged.
- A negative or non-integer `:before` or `:after` in a request fails the
  call when the request is decoded, with emrs's message; Elisp never
  sends one.
- A loaded module from before this change ignores the two fields: the
  search works and shows no context. As after every change to the Rust
  side, the module must be rebuilt and Emacs restarted; the README's
  section on context lines says so.
- A very large count makes the result approach the whole content of the
  files with hits. Nothing limits it (ADR 0014); `C-c C-k` cancels.

## Testing

- **Rust, search** (`src/grep/search.rs`): before only, after only,
  both; context at the start and at the end of a file; two hits whose
  context overlaps or touches give each line once and in order; two
  groups apart leave a jump in `:n`; a primary match dropped by an
  exclude line filter is context next to a kept line and gives no
  context of its own; a file whose primary matches are all dropped gives
  no item; context lines do not count for the cap, and a search that
  reaches the cap delivers exactly `max-lines` kept lines; a cut context
  line is `inexact`; `\r\n` context lines come without `\r`; a binary
  file gives nothing; with both counts 0 the items equal those without
  the fields.
- **Rust, service** (`emrs::testing::Host`): a request with `:before`
  and `:after` returns the `:context` flag in the Lisp shape; a request
  without them returns none.
- **ERT** (`tests/quarry-grep-tests.el`): the request carries the counts
  of the search and a new search takes them from the two options; `C`,
  `B` and `A` with a prefix and with a simulated prompt, the negative
  count, the history entry and back; the header part in its three forms;
  context lines carry `quarry-grep-context` and the face, hits do not;
  gap lines stand exactly where line numbers jump and only with context
  on; the heading count, the `hits` part and the status line count hits;
  `n`, `p` and `next-error` pass over context and gap lines; `RET` on a
  context line visits its line; point returns to a context line after
  `g`; folding hides gap lines.
- **ERT with wgrep** (`tests/quarry-grep-wgrep-tests.el`): an edited
  context line reaches the file after commit; a gap line cannot be
  edited; after abort and after commit the context and gap properties
  are in place and `n` still passes over context lines.
- **Manual:** the context face and the gap line in the author's theme,
  in a GUI frame and in a terminal; `2 C` on a result of a few hundred
  hits by feel.

## Tasks

In order; none can run in parallel.

- [x] 1. Service: `:before` and `:after` in the request and in `Config`,
  the searcher's context settings, `Sink::context` and the selection of
  context lines by distance to kept lines in `LineSink`, `:context` on
  line items, the module docs of both files. *Done when* the Rust tests
  of the Testing section exist and `cargo test` passes, with the
  existing tests unchanged.
- [x] 2. Elisp, search and buffer: the two slots, the two options, the
  request, the three commands and their keys, the header part, the face,
  context and gap lines with their properties, hit counts, `next-error`
  passing over them, visiting and point return; the README parts for
  all of this. *Done when* the ERT tests of the Testing section exist
  and `tests/run-ert.sh` passes.
- [x] 3. wgrep: context lines editable, gap lines ignored, the restore;
  the README's "Editing results". *Done when* the wgrep tests of the
  Testing section exist and `tests/run-ert.sh` passes with wgrep on
  `QUARRY_TEST_LOAD_PATH`.
- [x] 4. Docs: `docs/architecture/grep.md` as listed under
  Documentation; the backlog item "Context lines before and after a
  match" removed; the two backlog items that name context lines as their
  moment to revisit reworded (they now wait for the next format change
  or for measurements); the manual checks of this spec added to the
  backlog's "Manual checks not done yet"; `docs/next-steps.md`. *Done
  when* `devflow:doc-checker` finds nothing stale for this change.
