# Grep

`quarry-grep` searches a directory and shows the hits in a result
buffer, in the manner of [rg.el](https://github.com/dajva/rg.el). From
that buffer you narrow the search with filters, show context lines,
edit the results and replace across files. The search runs in quarry's
module on all cores; ripgrep need not be installed. It works without
`quarry-mode` and walks the directory on every search.

For searching while you type, see the [live grep guide](live-grep.md).
For installation, see the [README](../../README.md#installation).

## Start a search

| Command | Asks for | Searches |
|---|---|---|
| `quarry-grep` | regexp, file types and globs, directory | the directory |
| `quarry-grep-literal` | literal, file types and globs, directory | the directory |
| `quarry-grep-project` | regexp, file types and globs | the project root, or `default-directory` outside a project |
| `quarry-grep-dwim` | nothing | the project root, for the symbol at point as a literal, in files of the current buffer's type |

The pattern prompt offers the active region, or else the symbol at
point, as default. An empty pattern is refused.

The package binds no keys. To bind one, for example:

```elisp
(keymap-global-set "C-c s" #'quarry-grep-project)
```

### File types and globs

The files prompt, `Search in files (types and globs)`, takes words
separated by spaces, for example `rust elisp !gen/**`:

- A type name, such as `rust` or `elisp`, searches files of that type.
  The prompt completes the names; they are those of `rg --type-list`.
- `!` and a type name, such as `!json`, leaves out files of that type.
- `everything` searches all files. It is the default when the current
  buffer's file has no type; otherwise the default is that type.
- Any other word is a glob.

A glob spelled like a type name is taken as the type. Write it another
way: `[m]ake` for a file named `make`, `![r]ust` for the glob `!rust`.

How the words combine:

| You give | A file is searched if |
|---|---|
| several types | it is of one of them |
| several including globs | it matches one of them |
| types and globs | it passes the types and the globs |
| an excluded type (`!TYPE`) | it is not of that type; with only excluded types, files of no type are searched too |
| a file of several listed types | the last of them decides: `cpp !c` leaves out `.h` files, `!c cpp` keeps them |
| an excluding glob (`!...`) | no excluding glob matches it; when several globs match, the last one decides |

A combination that no file passes gives no hits, not an error.

Globs follow gitignore rules, relative to the searched directory:

- Without a `/`, a glob matches a name at any depth: `*.el`.
- With a `/` at the start or inside, it matches a path from the searched
  directory: `sub/*.txt`, `src/**`. `**` crosses directories.
- A `/` at the end means "a directory" and does not anchor: `!vendor/`
  leaves out every directory named `vendor`.
- An including glob must name files: `src/**`, not `src/`, which selects
  nothing.
- Case counts.
- Globs only restrict. Unlike `rg -g`, a glob never brings back an
  ignored or hidden file; use the switches `i` and `H` for that.

## The result buffer

One buffer, `*quarry-grep*`, is reused by each search. Paths are
relative to the searched directory, which is the buffer's
`default-directory`. To keep a result while you search for something
else, run `M-x clone-buffer`; the clone has its own searches and
history.

```text
 files: rust   dir: ~/src/emacs-quarry/   case: smart   ign: on   hidden: on   ctx: 0   hits: 3 in 2 files   ? menu
+ line/re  fn \w+
+ line     walk
- line/re  ^\s*//
- path     /tests/
+ path     bench  (off)

File: src/grep/search.rs (1)
   41 pub fn walk_and_search(

File: src/walk.rs (2)
  169 pub fn walk(
  182 pub fn walk_dirs(

Search finished: 3 lines in 2 files, 61 ms
```

- The header line shows the file types and globs, the directory, the
  case rule, the ignore and hidden switches, the context lines (`ctx:
  1/3` is 1 before and 3 after) and the hits so far. Click a part to
  change it; click `? menu` for the menu.
- The filter block lists the filters in the order you added them. The
  first is the pattern you searched for (see [Filters](#filters)).
- Each file heading shows the file's number of hits.
- The last line says `Searching…` while results arrive, then the totals
  and the time. It also reports a search that stopped at
  `quarry-grep-max-lines`, unreadable files, a cancellation or an
  invalid regexp. For an invalid regexp, point goes to the faulty
  filter; press `RET` to correct it.

Results appear as they arrive, without moving point. A search that
finishes within 150 ms is sorted by path; a longer one shows what it
found in the first 150 ms sorted, and the rest in the order found.

After a search started from the buffer, point returns to the result
line it was on, or to that file's heading, or to the next file.

### Keys

Visit:

| Key | Command | Action |
|---|---|---|
| `RET`, `mouse-1` | `quarry-grep-visit`, `-mouse-visit` | On a hit: visit the file at the first match. On a context line: visit that line. On a file heading: visit the file. On a filter: edit its pattern |
| `n`, `p` | `quarry-grep-next-match`, `-previous-match` | Show the next or previous hit in another window |
| `}`, `{`, `M-N`, `M-P` | `quarry-grep-next-file`, `-previous-file` | Move to the next or previous file heading |
| `TAB` | `quarry-grep-toggle-fold` | Fold or unfold the file at point |
| `S-TAB` | `quarry-grep-toggle-fold-all` | Fold all files, or unfold all when all are folded |

Search:

| Key | Command | Action |
|---|---|---|
| `g` | `quarry-grep-rerun` | Search again |
| `r`, `t` | `quarry-grep-change-regexp`, `-change-literal` | Change the primary filter's pattern, as a regexp or as a literal |
| `d` | `quarry-grep-change-directory` | Change the directory |
| `f` | `quarry-grep-change-files` | Change the file types and globs |
| `c` | `quarry-grep-cycle-case` | Cycle the case rule: smart, sensitive, insensitive |
| `C`, `B`, `A` | `quarry-grep-set-context`, `-before`, `-after` | Set the context lines: both sides, before, after |
| `i` | `quarry-grep-toggle-ignore` | Switch ignore files on or off |
| `H` | `quarry-grep-toggle-hidden` | Switch hidden files on or off |
| `C-c <`, `C-c >` | `quarry-grep-history-back`, `-forward` | Go back or forward in the search history |
| `C-c C-k` | `quarry-grep-cancel` | Cancel the running search; in a replace preview, leave the preview |

Filters:

| Key | Command | Action |
|---|---|---|
| `+ l`, `- l` | `quarry-grep-include-line`, `-exclude-line` | Add a line filter that includes or excludes, with a literal |
| `+ L`, `- L` | `quarry-grep-include-line-regexp`, `-exclude-line-regexp` | The same with a regexp |
| `+ p`, `- p` | `quarry-grep-include-path`, `-exclude-path` | Add a path filter that includes or excludes, with a literal |
| `+ P`, `- P` | `quarry-grep-include-path-regexp`, `-exclude-path-regexp` | The same with a regexp |
| `- f` | `quarry-grep-exclude-file` | Exclude the file at point |
| `- d`, `+ d` | `quarry-grep-exclude-directory`, `-include-directory` | Exclude, or search only, the directory of the file at point |
| `k` | `quarry-grep-remove-filter` | Remove the filter at point |
| `x` | `quarry-grep-toggle-filter` | Switch the filter at point off or on; in a replace preview, also switch matches |
| `!` | `quarry-grep-flip-filter` | Flip the filter at point between including and excluding |
| `%` | `quarry-grep-toggle-regexp` | Switch the filter at point between literal and regexp |
| `K` | `quarry-grep-remove-other-filters` | Remove all filters except the primary one |

Change files and help:

| Key | Command | Action |
|---|---|---|
| `e` | `quarry-grep-edit` | Edit the results with wgrep |
| `R` | `quarry-grep-replace` | Preview a replacement of the primary filter's matches |
| `C-c C-c` | `quarry-grep-replace-apply` | Write the previewed replacement |
| `?` | `quarry-grep-menu` | Open the menu of these keys |
| `h`, `C-h m` | `describe-mode` | Show the mode's help |
| `q` | `quit-window` | Quit the window |

`?` opens a transient menu with every key and the current value of each
switch. Keys that do not apply at point are inactive. A numeric prefix
before `?`, or `C-u` in the menu, goes to the command: `C-u 3 ? C` shows
3 lines of context. `C-g` closes the menu.

`next-error` and `previous-error` (`M-g n`, `M-g p`) walk the hits from
any buffer, also through folded files.

Every search that differs from the one before is an entry in the
buffer's history; going back or forward runs it again with its filters.
A new search, or killing the buffer, cancels the running one.

With `smart` case, a pattern ignores case unless it has an upper-case
letter. With ignore files off (`ign: off`), everything except version
control directories is searched, and `quarry-ignores` does not apply.

## Filters

A search is a list of filters. Each filter looks at lines or at paths,
includes (`+`) or excludes (`-`) what matches, and is a literal or,
marked `/re`, a regexp. Every change to the filters runs the search
again.

- A **line** filter matches the text of a line. The case rule applies
  to each line filter on its own.
- A **path** filter matches `/` followed by the path relative to the
  searched directory. `/test/` matches `test/a.c` and `src/test/a.c`;
  `.rs` matches by extension. Path filters always use smart case.
- A line is shown when it and its file match every `+` filter and no `-`
  filter. For "either of two", use one regexp filter: `/(audio|video)/`
  or `foo|bar`.

`- f` adds a regexp path filter for exactly that file. For `src/a.c`:

```text
- path/re  (?-i)^/src/a\.c$
```

`- d` and `+ d` put the file's directory, such as `/dir/sub/`, in the
minibuffer; confirm it or shorten it to a parent. The filter also
matches a `dir/sub` deeper in the tree. They refuse for a file in the
searched directory itself.

A filter that the search already has is not added twice; a switched-off
one is switched on. A switched-off filter is shown dimmed with `(off)`.

The **primary** filter is the first `+ line` filter that is on. It gets
the main highlight and decides where `RET` lands. Removing, switching
off or flipping the only `+ line` filter that is on is refused. When
the primary filter goes, the next `+ line` filter that is on takes its
place. `r` and `t` edit it.

## Highlighting

| Face | Marks |
|---|---|
| `quarry-grep-match` | Matches of the primary filter |
| `quarry-grep-match-secondary` | Matches of the other `+ line` filters |
| `quarry-grep-path-match` | The part of a file heading that `+ path` filters matched |
| `quarry-grep-context` | Context lines and the gap line `⋮` |

In the filter block, each `+` filter that is on shows its pattern in the
face of its matches. `quarry-grep-highlight-include-filters` and
`quarry-grep-highlight-path-filters` switch off the second and third
face.

## Context lines

`C`, `B` and `A` show lines around each hit, like `-C`, `-B` and `-A` of
grep. `C` sets both sides; `B` and `A` set one side and keep the other.
After `2 C` and `3 B`, the header reads `ctx: 3/2`.

- A numeric prefix is the count: `2 C` shows two lines before and after.
  Without one, the count is read in the minibuffer.
- `0 C` switches context off. At most 1000 lines per side.
- A new search starts with `quarry-grep-context-before` and
  `quarry-grep-context-after`.

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

- Context lines are shown in `quarry-grep-context`, without match
  highlighting. `RET` visits the line.
- `⋮` stands between groups of lines that do not touch.
- Counts, `n`, `p` and `next-error` concern hits only.
- Line filters apply to hits, not to context: a line a `- line` filter
  removed can appear as context.
- `quarry-grep-max-lines` counts hits. When a search stops there, its
  last hit can lack the lines after it.

## Edit results

Prerequisite: the [wgrep](https://github.com/mhayashi1120/Emacs-wgrep)
package.

1. Press `e`.
2. Change the text of result or context lines.
3. Press `C-c C-c` to apply the changes, or `C-c C-k` to discard them.
4. Save the changed buffers with `C-x s`.

Optional: set `wgrep-auto-save-buffer` to have step 4 done on commit.
The other keys of wgrep work too, such as `C-c C-d` to delete a line.

- Changes go into buffers visiting the files, opened as needed; they are
  not saved.
- Only line text can change. The filter block, headings, line numbers,
  the gap line and the status line are read-only.
- A line shown cut (longer than `quarry-grep-max-columns`) or holding
  bytes that are not valid UTF-8 is read-only, since writing it back
  would damage the file. To edit a long line, raise
  `quarry-grep-max-columns` and search again.
- If a file changed since the search, or a buffer visiting it has
  unsaved changes, `e` asks whether to search again first. Yes runs the
  search; press `e` again when it is done. No edits the results as they
  are, and wgrep refuses each change whose line in the file no longer
  has the text found.
- `e` unfolds folded files. It is refused while a search runs, without
  results, in a replace preview and after a replace.
- After `C-c C-c`, the lines show the edited text; `g` shows what is on
  disk.

## Replace across files

`R` replaces what the primary filter matched, in all files of the
result, after you have seen every change. It suits mechanical changes,
such as a rename.

1. Search for what you want to replace and narrow the result with
   filters.
2. Press `R` and enter a template, such as `new_name` or `${1}_v2`.
3. Review the preview. Each match shows the old text struck through,
   followed by the new text. The header shows `→ TEMPLATE` and `N of M
   matches on`.
4. Optional: press `x` on matches you want to keep unchanged.
5. Press `C-c C-c` and confirm `Replace N matches on L lines in F
   files?`.
6. Press `g` to see what still matches.

### Templates

The template syntax is that of `rg -r`:

| Template | Inserts |
|---|---|
| `$0` | The whole match |
| `$1`, `${1}` | Capture group 1 |
| `$name`, `${name}` | The group named `name` (`(?P<name>...)`) |
| `$$` | A dollar sign |

- A name runs as far as ASCII letters, digits and `_`: `$1a` is the
  group `1a`. Write `${1}a` for group 1 followed by `a`.
- A group that does not exist or did not take part inserts nothing.
- A literal filter has only `$0`.
- A template cannot contain a newline.
- Empty matches (`^`, `\b`) are not replaced. To add text at the start
  of lines, match a character: `^(.)` with `PREFIX$1`.

### In the preview

- `x` on a match switches it; on a hit outside a match, all matches of
  the line; on a file heading, all matches of the file (off when any is
  on). Point then moves to the next line with a match.
- Filter commands keep the template and update the preview.
- The preview is an entry in the history: `C-c <` goes back to the
  search without the template.
- `C-c C-k` leaves the preview. `e` is refused in a preview.
- Lines shown cut or not valid UTF-8 are not replaced; the status line
  counts them.

### What `C-c C-c` writes

`C-c C-c` writes the switched-on matches. It writes nothing and:

- refuses while a search runs, after a failed or cancelled search, and
  when no match is on;
- asks whether to search again when a result file changed since the
  search, or a buffer visiting it has unsaved changes;
- offers a larger limit when the preview stopped at
  `quarry-grep-max-lines` (see [Large replacements](#large-replacements)).

The confirmation names the files that are folded or outside a
narrowing: they are written too.

Each line is checked against the text the search found. A line is
rejected, and its file left alone, when:

- its text in the file differs;
- the buffer visiting the file is read-only, has unsaved changes or is
  not up to date with the file;
- the file cannot be read or written;
- the file's encoding cannot hold the new text;
- the file is UTF-8 with a stray byte that Emacs reads as Latin-1 or
  another 8-bit encoding;
- the file, read as Emacs reads it, does not give its bytes back when
  written, such as a file whose coding cookie says CRLF but whose lines
  end in LF;
- the buffer visits the file literally (`find-file-literally`,
  `no-conversion`, `raw-text`) and the new text is not ASCII.

The other lines and files go on. Afterwards each line is marked applied
(`quarry-grep-replace-applied`) or rejected
(`quarry-grep-replace-rejected`, with the reason in its tooltip), and
the echo area says `Replaced N lines in F files; R rejected`. Until `g`,
`x`, `C-c C-c` and `e` are refused.

How a file is written:

- **A file an Emacs buffer visits** is changed in that buffer and saved
  with `save-buffer`. `before-save-hook` (formatters,
  `delete-trailing-whitespace`) and `require-final-newline` do not run;
  `after-save-hook` runs and a backup may be made. The change is one
  undo step. If saving fails before the file is written, the buffer gets
  its old text back and the lines are rejected. If a hook fails after
  the file was written, the lines count as replaced.
- **Other files** are changed as bytes, in their own encoding, line ends
  and byte order mark, with no format conversion and no handler for
  compressed or encrypted files (`.gz`, `.gpg`). There is no undo: use
  version control. The new content goes to a temporary file in the same
  directory, with the file's permissions, which is renamed over the
  file; a failed write leaves the file as it was.
  - A symbolic link stays a link; the file it points to is replaced.
  - A file with several hard links, another owner or group than a new
    file would get, or in a directory you cannot write is written in
    place, so links and owner stay. If that write fails, the old content
    is written back.
  - The file is locked while it is written. When another Emacs holds the
    lock, you are asked; `C-g` there leaves the file as it was.
  - Like any Emacs save, the file is synced to disk only when
    `write-region-inhibit-fsync` is nil (default `t`). On file systems
    other than ext4, a power loss right after a replace can leave empty
    files.

`C-g` during the write stops it: the file being written is finished, a
buffer being saved gets its old text back, and the files written stay
written.

### Large replacements

A search stops at `quarry-grep-max-lines` hits (50,000; context lines do
not count), and `C-c C-c` does not write a preview that stopped there.
Its status line shows the total, such as `Search stopped at 50000 of
73412 lines`, or `of more than 100000 lines` beyond
`quarry-grep-replace-max-lines`.

- **Raise the limit for this search.** Up to
  `quarry-grep-replace-max-lines` lines (100,000), `C-c C-c` asks
  `73412 lines match, the limit is 50000; search again with a limit
  that holds them all?`. Yes searches again with the template. For more
  lines, run `M-: (setq quarry-grep-max-lines 300000)`, press `g`, and
  set the option back afterwards.
- **Replace part by part.** Limit the search to one part (`+ p
  src/foo/`, `+ d`, or `f` with `src/foo/**`), check the preview, press
  `C-c C-c`, then change the filter to the next part. The template stays.
- **Match fewer lines.** Use word boundaries (`\bold_name\b`), an
  include line filter (`+ l`), or leave out generated and vendored
  directories (`f` with `!vendor/ !gen/`).

Measured on 2026-10-14 and 2026-10-15 with `bench/run-bench.sh replace`
(see [CONTRIBUTING.md](../../CONTRIBUTING.md#benchmarks)) on an Intel
Core i5-8365U, Emacs 31.1, release build, with
`write-region-inhibit-fsync` at its default: the preview takes about 3 s
per 100,000 hits; writing 10,000 files takes about 13 s on ext4 on an
NVMe SSD. Beyond 100,000 hits nothing was measured. For changes of
millions of lines, use a command-line tool such as `fastmod`.

## Options

Group `quarry-grep`. Options apply to the next search.

| Option | Default | Description |
|---|---|---|
| `quarry-grep-case` | `smart` | Case rule a new search starts with: `smart`, `sensitive` or `insensitive`. |
| `quarry-grep-context-before` | `0` | Context lines before each hit that a new search starts with, at most 1000. |
| `quarry-grep-context-after` | `0` | Context lines after each hit that a new search starts with, at most 1000. |
| `quarry-grep-max-lines` | `50000` | Hits after which a search stops. |
| `quarry-grep-replace-max-lines` | `100000` | Largest number of matching lines for which `C-c C-c` offers a larger limit. |
| `quarry-grep-max-columns` | `500` | Characters after which a line is shown cut. |
| `quarry-grep-buffer-name` | `"*quarry-grep*"` | Name of the result buffer. |
| `quarry-grep-highlight-include-filters` | `t` | Highlight matches of the `+ line` filters other than the primary one. |
| `quarry-grep-highlight-path-filters` | `t` | Highlight in file headings what `+ path` filters matched. |
| `quarry-include-hidden` | `t` | A new search includes hidden files (group `quarry`). |
| `quarry-ignores` | `nil` | Extra gitignore-style patterns, relative to the searched directory (group `quarry`). |

Faces: `quarry-grep-match`, `quarry-grep-match-secondary`,
`quarry-grep-path-match`, `quarry-grep-file-heading`,
`quarry-grep-line-number`, `quarry-grep-context`,
`quarry-grep-filter-include`, `quarry-grep-filter-exclude`,
`quarry-grep-filter-kind`, `quarry-grep-filter-pattern`,
`quarry-grep-filter-disabled`, `quarry-grep-status`,
`quarry-grep-error`, `quarry-grep-header-value`,
`quarry-grep-replace-old`, `quarry-grep-replace-new`,
`quarry-grep-replace-applied`, `quarry-grep-replace-rejected`.

## Limitations

- Local directories only; in a remote (TRAMP) directory the commands
  refuse. Use rg.el there.
- Regexps are Rust regexps, as in ripgrep: no backreferences, no
  look-around, groups are `(...)`, not `\(...\)`.
- Matches are single lines. `\A`, `\z` and `(?-m)` are not supported;
  use `^` and `$`.
- In files with `\r\n` line ends, `\r` is not part of the line.
- Files are read as UTF-8; UTF-16 only with a byte order mark.
- Symbolic links are not followed; a file is found under its real path.
- `.git`, `.hg`, `.svn` and `.jj` are never searched; files with a NUL
  byte are skipped as binary.
- `~/.ripgreprc`, PCRE2 and compressed files are not supported.
- The result buffer is not a `compilation-mode` buffer: commands such as
  `grep-edit-mode` do not work in it; use `e`.
- Editing with wgrep is untested on files with `\r\n` line ends and in
  encodings other than UTF-8.
