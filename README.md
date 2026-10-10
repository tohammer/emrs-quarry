# quarry

A fast project file finder for Emacs. A Rust module keeps a live index of
each project's files, updated by a file watcher, and answers fuzzy queries
from it with [nucleo](https://github.com/helix-editor/nucleo) ranking, so
`project-find-file` stays fast on large repositories.

The package also holds `quarry-grep`, an interactive grep in the manner of
[rg.el](https://github.com/dajva/rg.el): the search runs in the same
module, and the matches are shown in a buffer from which the search is
changed and run again (see "Grep"). The two tools do not need each other.

quarry is built on [emrs](https://github.com/tohammer/emrs), which runs the
Rust side as a message-passing service outside the Emacs thread.

Status: version 1. It was built and tested on Linux only, with Emacs 31.1
(the ERT suite and `cargo test` pass there) and, for the benchmark, Emacs
31.0.50. It has not been run with Emacs 30. macOS and Windows are untested;
the watcher code for them is type-checked but never ran against the real
backends (`docs/backlog.md`). There is no CI. It installs from GitHub with
package recipes and a local cargo build; only the Doom recipe is checked by
hand, the straight, elpaca and package-vc variants are untested. There are
no prebuilt binaries.

## Requirements

- Emacs 30.1 or later, built with module support.
- Rust 1.88 or later, with `cargo` on `PATH` (or set
  `quarry-build-cargo-program`), to build the module.
- Network access for cargo's first dependency fetch.
- Git credentials for the repositories `tohammer/emrs-quarry` and
  `tohammer/emrs`, which are private; the recipes use the default protocol.
- Linux for anything you want to rely on (see Status).
- Optional: [consult](https://github.com/minad/consult) 2.0 or later for
  the consult front end (see "consult front end"). quarry does not depend
  on it and never loads it.
- Optional: [wgrep](https://github.com/mhayashi1120/Emacs-wgrep) to edit
  grep results (see "Editing results"). quarry loads it only when you
  press `e` in a result buffer.

## Installation

quarry needs two packages: `emrs` (the Elisp side of the runtime) and
`quarry`, whose repository also holds the Rust source. The module is built
on your machine with cargo and installed as `lisp/quarry-module` plus
`module-file-suffix` inside quarry's repository, where quarry finds it
(`docs/decisions/0006`). `emrs` follows the default branch of its
repository and is not pinned (`docs/decisions/0007`).

### Doom Emacs

In `packages.el`:

```elisp
(package! emrs
  :recipe (:host github :repo "tohammer/emrs" :files ("elisp/emrs.el")))
(package! quarry
  :recipe (:host github :repo "tohammer/emrs-quarry" :files ("lisp/*.el")
           :pre-build ((load (expand-file-name "lisp/quarry-build.el") nil t)
                       (quarry-build-module-sync))))
```

In `config.el`:

```elisp
(use-package! quarry
  :hook (doom-first-input . quarry-mode)
  :custom
  ;; Asynchronous, needs consult 2.0 or later (see "consult front end"):
  ;; (quarry-find-file-command 'quarry-consult-find-file)
  (quarry-find-file-command 'quarry-find-file))
```

`quarry-mode` remaps `project-find-file`, which has no key in Doom:
Doom binds `C-x p` to its popup command, and `SPC p f` (`C-c p f` without
evil) runs `projectile-find-file`. Bind the leader key to
`project-find-file` so the remap applies and `quarry-find-file-command`
chooses the command:

```elisp
(map! :leader :desc "Find file in project" "p f" #'project-find-file)
```

`doom sync` clones both repositories, and the `:pre-build` form runs
`cargo build --release` in quarry's checkout. straight runs it whenever it
rebuilds the package, so `doom sync -u` rebuilds the module when quarry
changed. A rebuilt module is used after restarting Emacs; emrs warns when
the module file it loaded has changed.

`quarry-build-module-sync` never signals. Without a Rust toolchain, or if
the build fails, `doom sync` still completes with a warning and the output
in the buffer `*quarry-build*`. The first quarry command then asks
"quarry module not built. Build it now with cargo?"; you can also run
`M-x quarry-build-module` at any time.

### straight.el without Doom

Use the same two recipes with `straight-use-package`, then enable the mode:

```elisp
(straight-use-package
 '(emrs :host github :repo "tohammer/emrs" :files ("elisp/emrs.el")))
(straight-use-package
 '(quarry :host github :repo "tohammer/emrs-quarry" :files ("lisp/*.el")
           :pre-build ((load (expand-file-name "lisp/quarry-build.el") nil t)
                       (quarry-build-module-sync))))
(quarry-mode 1)
```

Untested.

### elpaca

Use the recipes with `:host`, `:repo` and `:files` only, with no
`:pre-build`. Run `M-x quarry-build-module` once after installing and after
each update, then restart Emacs. Untested.

```elisp
(elpaca (emrs :host github :repo "tohammer/emrs" :files ("elisp/emrs.el")))
(elpaca (quarry :host github :repo "tohammer/emrs-quarry" :files ("lisp/*.el")))
```

### package-vc

```elisp
(package-vc-install '(emrs :url "https://github.com/tohammer/emrs"
                           :lisp-dir "elisp"))
(package-vc-install '(quarry :url "https://github.com/tohammer/emrs-quarry"
                              :lisp-dir "lisp"))
```

Then run `M-x quarry-build-module` and restart Emacs; repeat the command
after updates. Untested.

For package-vc, enable the mode with `(quarry-mode 1)` or a `use-package`
form with `:config (quarry-mode 1)`. elpaca installs asynchronously, so
enable it once the package is there: `(use-package quarry :ensure (...)
:config (quarry-mode 1))` with the recipe as `:ensure` value, or
`(quarry-mode 1)` in `elpaca-after-init-hook`.

### Where quarry looks for the module

First `lisp/quarry-module` plus `module-file-suffix` in the repository that
holds the real `quarry.el` (symlinks are resolved), then `quarry-module`
on `load-path`. If neither exists, the first command offers to build (see
Doom Emacs above) or, in batch mode or without a repository, signals an
error that names `M-x quarry-build-module` and the manual installation.
If cargo is not on `PATH`, set `quarry-build-cargo-program`.

### Manual installation

This also works as a fallback, for example without a package manager or
with a copy of `quarry.el` that is not inside its repository.

1. Build the module. When `quarry.el` is loaded from the checkout,
   `M-x quarry-build-module` does this and installs the module in
   `lisp/`; skip step 2. Otherwise:

   ```sh
   cargo build --release
   ```

2. Copy the library to a directory on `load-path`, named `quarry-module`
   plus Emacs's `module-file-suffix`:

   ```sh
   cp target/release/libquarry.so ~/.emacs.d/quarry/quarry-module.so      # Linux
   cp target/release/libquarry.dylib ~/.emacs.d/quarry/quarry-module.dylib # macOS
   ```

3. Put `lisp/quarry.el`, `lisp/quarry-build.el` (and
   `lisp/quarry-consult.el` for the consult front end) and `emrs.el` on
   `load-path`. `emrs.el` is `elisp/emrs.el` of the
   [emrs repository](https://github.com/tohammer/emrs). The Lisp and Rust
   halves must match: use the commit pinned in `Cargo.toml` (`rev = ...` of
   the `emrs` dependency), or any newer emrs; an `emrs.el` that is too old
   for the module fails with a protocol error. Either clone emrs and check
   out the commit, or take it from the checkout Cargo made, as
   `tests/run-ert.sh` does:

   ```sh
   cargo metadata --format-version 1 |
       sed -n 's|.*"manifest_path":"\([^"]*\)/emrs/Cargo.toml".*|\1/elisp|p' | head -n 1
   ```

4. Enable the mode:

   ```elisp
   (use-package quarry
     :load-path ("~/.emacs.d/quarry" "~/src/emrs/elisp" "~/src/quarry/lisp")
     :config (quarry-mode 1))
   ```

   or, without `use-package`:

   ```elisp
   (add-to-list 'load-path "~/.emacs.d/quarry")
   (require 'quarry)
   (quarry-mode 1)
   ```

If the module is not found, the first command signals an error that says
where it must be installed. An invalid pattern in `quarry-ignores` also
makes the first command fail, with the pattern in the message.

For other front ends, `quarry-query` and `quarry-query-async` return the
ranked paths of a project directly (see their docstrings).

## Usage

| Command | What it does |
|---|---|
| `quarry-find-file` | Visit a file of the current project, chosen from the index. Starts the project's instance on first use. |
| `quarry-consult-find-file` | The same in a consult prompt that queries the index asynchronously (see "consult front end"). Needs consult 2.0 or later. |
| `quarry-mode` | Global minor mode. Remaps `project-find-file` to `quarry-find-file-command` (default `quarry-find-file`); with `quarry-provide-project-files` set, it also serves `project-files` from the index. |
| `quarry-rescan` | Walk the current project again and report the file count when done. |
| `quarry-stop` | Stop the current project's instance. The next command starts a new one with the current options. |
| `quarry-stop-all` | Stop all instances. |
| `quarry-status` | Show root, file count, whether it is indexing or watching, number of walks and skipped paths in the echo area. |

`quarry-find-file` and `quarry-consult-find-file` fall back to
`project-find-file` with a prefix argument (which asks for ignored files
too) and in remote (TRAMP) projects. With `quarry-mode` the same applies
to `project-find-file`, since it is remapped to one of them.

One instance runs per project root, started lazily on first use. While the
first walk runs, queries answer from the files seen so far.

`quarry-provide-project-files`: when non-nil and `quarry-mode` is on,
`project-files` is answered from the index instead of `git ls-files` or
`find`. This speeds up commands built on `project-files`, such as
`project-find-regexp`. It serves only local projects that already have a
running instance and only calls for the whole project root; otherwise, and
when the index does not answer within `quarry-files-timeout`, the normal
method runs. It does not speed up `project-find-file` itself, which quarry
replaces instead (`docs/decisions/0001`).

### Query syntax

The query is nucleo's pattern syntax, matched against the path relative to
the project root:

| Syntax | Meaning |
|---|---|
| `foo bar` | Space-separated terms, all must match, in any order |
| `foo` | Fuzzy: `f`, `o`, `o` in this order, gaps allowed (with `quarry-match-style` `substring`: the substring `foo`) |
| `'foo` | The substring `foo` (with `quarry-match-style` `substring`: fuzzy) |
| `^foo` | Prefix |
| `foo$` | Suffix |
| `!foo` | Does not contain `foo` |
| `foo\ bar` | A literal space in a term |
| `\!foo`, `\^foo`, `\'foo`, `foo\$` | A literal `!`, `^`, `'` or `$` |

So by default `act man` also matches `a/c/t/m/a/n`-like paths, ranked
below contiguous matches, and `'act 'man` only paths containing `act`
and `man`. With `(setq quarry-match-style 'substring)` the two swap,
similar to fzf's `--exact` mode: `'` then means "the rest of this term in
the fuzzy style's syntax", so `'foo$` is a fuzzy suffix and `'!foo`
excludes `foo` (`docs/decisions/0004`).

Case is smart: all lower case matches any case, an upper-case letter
matches that case only. Results are ordered by score, then shorter path,
then alphabetically. Matched characters are highlighted, each term in its
own colour (faces `quarry-match-0` to `quarry-match-3`, used in turn).

quarry ranks in Rust and passes the result through a completion style also
called `quarry`, bound only for the duration of its own prompt. Your
`completion-styles` (orderless, flex, ...) do not apply inside quarry
prompts and other prompts are unaffected (`docs/decisions/0002`). In the
default completion UI, TAB completes the input when exactly one file
matches, and RET on input that matches exactly one file visits that file.

`quarry-mode` remaps the key bindings of `project-find-file`. Commands
that call `project-find-file` by name, such as the `project-switch-project`
menu (`project-switch-commands`), are not remapped; add
`quarry-find-file` to `project-switch-commands` if you want it there.

quarry takes the project root from project.el. With Projectile, remap
`projectile-find-file` to `quarry-find-file`, and set
`projectile-switch-project-action` to it for the file prompt after
switching projects (with Doom's workspaces module:
`+workspaces-switch-project-function`, which receives the project
directory). To use Projectile's root, wrap `quarry-find-file` in a
command that binds `project-find-functions` to return that root.

### consult front end

`quarry-consult-find-file` is an optional front end for
[consult](https://github.com/minad/consult) users. Each input goes to the
index asynchronously, so typing never waits for the module; a query that a
newer input supersedes is cancelled. While the first walk of a project
still runs, the candidates are queried again every
`quarry-consult-refresh-interval` seconds, so the list fills without
typing; the prompt opens at once, without waiting for a first page of
files as `quarry-find-file` does. The indicator shows whether a query is running.

It needs consult 2.0 or later, which is not a dependency of quarry:
`lisp/quarry-consult.el` loads without consult, and the command then
signals a `user-error`. `quarry.el` never loads it. The package recipes
above include the file (`lisp/*.el`). It uses consult's internal async
pipeline (`docs/decisions/0008`), so a consult upgrade can break it.

To make `quarry-mode` run it in place of `project-find-file`:

```elisp
(setq quarry-find-file-command 'quarry-consult-find-file)
```

A plain `setq` takes effect at once, before or after the mode is enabled.
The command is autoloaded; without package autoloads, `(require
'quarry-consult)` first. You can also bind or call it directly.

Differences from `quarry-find-file`:

- A candidate must be chosen. A path that is not in the index cannot be
  visited, unlike `quarry-find-file`, which accepts it.
- The query syntax and the ranking are the same, but the completion styles
  of your UI (orderless, ...) never re-filter quarry's results, as in
  `quarry-find-file`. What the styles see depends on
  `consult-async-split-style`. With the default `perl` style the input
  `#query#filter` sends `query` to the index and filters the results with
  `filter` locally, using your completion styles. With the style `none`
  the whole input is the query and nothing is filtered locally.
- The history is separate: `quarry-consult-history`.

## Grep

`quarry-grep` searches a directory for lines and shows them in a result
buffer, in the manner of rg.el. The search runs in the module, on all
cores, and the matches arrive as values, not as text to be parsed; ripgrep
does not have to be installed. It works with `quarry-mode` off and uses
neither the file index nor the watcher: every search walks the directory.
The commands are autoloaded; without package autoloads, `(require
'quarry-grep)` first.

| Command | Asks for | Searches |
|---|---|---|
| `quarry-grep` | regexp, file type, directory | the directory |
| `quarry-grep-literal` | string, file type, directory | the directory |
| `quarry-grep-project` | regexp, file type | the project root (`project-current`), or `default-directory` outside a project |
| `quarry-grep-dwim` | nothing | the project root for the symbol at point as a string, in files of the current buffer's type |

The pattern prompt offers the active region, or else the symbol at point,
as default. The file type prompt completes over the type names of the
`ignore` crate (what `rg --type-list` prints) and `everything`; its
default is the type of the current buffer's file, else `everything`.
Input that is not a type name is taken as globs separated by spaces, for
example `*.el *.org`. An empty pattern is refused.

### The result buffer

One buffer, `*quarry-grep*`, reused by each search. Its
`default-directory` is the searched directory, and paths are shown
relative to it.

```text
 files: rust   dir: ~/src/emacs-quarry/   case: smart   ign: on   hidden: on   hits: 3 in 2 files
+ line/re  fn \w+
+ line     walk
- line/re  ^\s*//
- path     /tests/
+ path     bench                                  (off)

File: src/grep/search.rs (1)
   41 pub fn walk_and_search(

File: src/walk.rs (2)
  169 pub fn walk(
  182 pub fn walk_dirs(

Search finished: 3 lines in 2 files, 61 ms
```

- The header line shows the file type, the directory, the case rule,
  whether ignore files are used and hidden files searched, and the number
  of lines and files found so far. A click with `mouse-1` on a part runs
  the command of its key below.
- The filter block has one line per filter, in the order they were added
  (see "Filters"). The first line is the pattern the command asked for.
- Each file has a heading with the number of its lines, and one line per
  match with the line number and the text, with the matches highlighted
  (see "Highlighting").
- The last line says `Searching…` while results arrive, then how many
  lines were found in how many files and how long it took. It also names
  a search that stopped at the line cap, files that could not be read, a
  cancellation, and an error such as an invalid regexp.

Results appear as they arrive, without moving point or scrolling the
window. A search that finishes within 150 ms is shown sorted by path; a
longer one shows the files in the order they are found.

| Key | Action |
|---|---|
| `RET`, `mouse-1`, `mouse-2` | On a result line or its number: visit the file at that line, at the column of the first match of the primary filter. On a file heading: visit the file. On a filter line: edit its pattern in the minibuffer |
| `n`, `p` | Show the next or previous match in another window without selecting it |
| `}`, `{`, `M-N`, `M-P` | Move to the next or previous file heading |
| `TAB` | Fold or unfold the file at point |
| `S-TAB` | Fold all files, or unfold them when all are folded |
| `g` | Search again |
| `r`, `t` | Edit the primary filter, as a regexp or as a string |
| `d`, `f` | Change the directory; the file type |
| `c` | Cycle the case rule: smart, sensitive, insensitive |
| `i`, `H` | Switch ignore files on or off; hidden files |
| `- p`, `+ p` | Add a path filter, excluding or keeping only what matches |
| `- l`, `+ l` | Add a line filter, excluding or keeping only what matches |
| `- P`, `+ P`, `- L`, `+ L` | The same, with the pattern as a regexp |
| `- f` | Exclude the file at point |
| `- d`, `+ d` | Exclude, or search only, the directory of the file at point |
| `k`, `x`, `!`, `%` | On a filter line: remove it; switch it off or on; flip it between including and excluding; switch it between string and regexp |
| `K` | Remove all filters except the primary one |
| `C-c <`, `C-c >` | Go back or forward in the buffer's search history |
| `C-c C-k` | Cancel the running search |
| `e` | Edit the results with wgrep (see "Editing results") |
| `q` | Quit the window |

`next-error` and `previous-error` (`M-g n`, `M-g p`) walk the results from
any buffer, also through folded files. Every search that differs from the
one before, by a filter too, is an entry in the buffer's history; going
back or forward runs that search again with its filters, including those
switched off. A new search cancels the one that is running, and so does
killing the buffer.

A search started from the result buffer (`g`, a switch, a filter command,
the history) brings point back to the result line it was on, or to that
file's heading when the line is gone. When the file is gone too, as after
`- f`, point goes to the next file. On a filter line point stays on that
line. If you move point while the search runs, it is left where you put
it.

With `smart` case a pattern ignores case unless it has an uppercase
letter. With ignore files off (`ign: off`) everything is searched except
version control directories; `quarry-ignores` is not applied then either.

### Filters

A search is a list of filters, shown at the top of the buffer. Each filter
looks at lines or at paths, keeps only what matches (`+`) or drops it
(`-`), and is a string or, marked `/re`, a regexp. The pattern a command
asks for is the first of them, a `+ line` filter, and is a filter like the
others. Every change to the filters runs the search again.

- A **line** filter is matched against the text of a line. The case rule
  of the header line applies to each line filter by itself.
- A **path** filter is matched against a slash followed by the path
  relative to the searched directory. So `/test/` matches `test/a.c` and
  `src/test/a.c`, a directory `test` at any depth, and `.rs` matches by
  extension.
  Path filters always use smart case. A directory that an excluding path
  filter matches is not entered.
- The filters are combined with "and": a line is shown when it and its
  file match every `+` filter and no `-` filter, so each added filter can
  only narrow the result. For "either of two", write one regexp filter,
  such as `/(audio|video)/` for two directories or `foo|bar` for two
  words (`+ P`, `+ L`, or `%` on the filter's line).

`- p`, `+ p`, `- l` and `+ l` ask for a string and add the filter at the
end of the list. The same keys with an uppercase letter, `- P`, `+ P`,
`- L` and `+ L`, ask for a regexp.

`- f`, `- d` and `+ d` take the pattern from the result at point. `- f`
excludes that file at once. `- d` and `+ d` put the file's directory into
the minibuffer, as `/dir/sub/`; confirm it, or shorten it to a parent
such as `/dir/` first. These are ordinary path filters, so `/dir/sub/`
also matches a directory `dir/sub` deeper in the tree.

A filter the search already has is not added twice; if it is switched
off, it is switched on.

`k` removes the filter at point, `x` switches it off or on (shown dimmed
with `(off)`; it stays in the list and is not applied), `!` flips it
between `+` and `-`, `%` between string and regexp, and `RET` edits its
pattern. `K` removes all filters but the primary one.

The **primary** filter is the first `+ line` filter that is switched on.
The files are scanned for it; it decides which matches get the main
highlight and where point lands when a result is visited, not which lines
are found. A search needs one: removing, switching off or flipping the
only `+ line` filter that is on is refused. When the primary filter goes
and another `+ line` filter is on, that one becomes the primary filter.
`r` and `t` edit the primary filter.

### Highlighting

| Face | Marks |
|---|---|
| `quarry-grep-match` (inherits `match`) | The matches of the primary filter in a result line |
| `quarry-grep-match-secondary` (inherits `lazy-highlight`) | The matches of the other `+ line` filters, where they lie outside the primary matches |
| `quarry-grep-path-match` (inherits `highlight`) | The parts of a file heading's path that `+ path` filters matched |

In the filter block each `+` filter that is on shows its pattern in the
face of its matches, so you can see which colour belongs to which filter.
`-` filters have nothing to highlight.
`quarry-grep-highlight-include-filters` and
`quarry-grep-highlight-path-filters` switch the second and the third face
off; the primary matches are always highlighted.

### Editing results

`e` makes the result lines editable, with the
[wgrep](https://github.com/mhayashi1120/Emacs-wgrep) package, which must
be installed; quarry does not depend on it, and without it `e` says so.
Change the text of result lines, then press `C-c C-c` to apply the
changes or `C-c C-k` to discard them. Both return to the result buffer as
it was, with its keys. The other keys of wgrep's edit mode work too, for
example `C-c C-d` to mark a line for deletion. While the buffer is being
edited the keys of the result buffer are off and no search can be started
in it.

- Committed changes land in the buffers of the files, which are opened
  for that; they are not saved. Save them with `M-x
  wgrep-save-all-buffers` or `C-x s`, or set `wgrep-auto-save-buffer` to
  have wgrep save on commit.
- Only the text of result lines can be changed. The filter block, file
  headings, line numbers and the status line are read-only.
- A line that is shown cut (longer than `quarry-grep-max-columns`) or
  that holds bytes that are not valid UTF-8 is read-only too: what the
  buffer shows is not the file's line, so writing it back would damage
  the file. Raise `quarry-grep-max-columns` and search again to edit a
  long line.
- Line numbers are those of the search. Before entering, `e` compares
  each result file's modification time with the one the search saw, and
  looks for unsaved changes in a buffer visiting it. If a file changed or
  is gone, it asks whether to search again first. Yes runs the search;
  press `e` again when it is done. No edits the results as they are;
  wgrep then refuses each change whose line in the file is no longer the
  text the search found.
- Folded files are unfolded on entering, and `e` is refused while a
  search runs.
- After a commit the result lines show the edited text and the status
  line says that the results were edited; `g` searches again, which
  shows what is on disk.

### Options and faces

Customize group `quarry-grep`. They apply to the next search.

| Option | Default | Meaning |
|---|---|---|
| `quarry-grep-case` | `smart` | Case rule a new search starts with: `smart`, `sensitive` or `insensitive`. |
| `quarry-grep-max-lines` | `50000` | The search stops when this many lines are found, and the last line says so. |
| `quarry-grep-max-columns` | `500` | Longer lines are shown cut after this many characters. |
| `quarry-grep-buffer-name` | `*quarry-grep*` | Name of the result buffer. |
| `quarry-grep-highlight-include-filters` | `t` | Highlight the matches of the `+ line` filters other than the primary one. |
| `quarry-grep-highlight-path-filters` | `t` | Highlight in file headings what the `+ path` filters matched. |
| `quarry-include-hidden` | `t` | A new search includes hidden files; `H` switches it per search. |
| `quarry-ignores` | `nil` | Extra gitignore-syntax patterns, relative to the searched directory. |

Faces: `quarry-grep-match`, `quarry-grep-match-secondary`,
`quarry-grep-path-match`, `quarry-grep-file-heading`,
`quarry-grep-line-number`, `quarry-grep-filter-include`,
`quarry-grep-filter-exclude`, `quarry-grep-filter-kind`,
`quarry-grep-filter-pattern`, `quarry-grep-filter-disabled`,
`quarry-grep-status`, `quarry-grep-error` and `quarry-grep-header-value`.

### Limits

- Local directories only. In a remote (TRAMP) directory the commands
  signal an error; use rg.el there.
- Regexps are Rust regexps (the `regex` crate, as in ripgrep's default
  engine): no backreferences and no look-around. Emacs regexp syntax does
  not apply; a group is `(...)`, not `\(...\)`.
- Matches are single lines; there are no context lines.
- Symbolic links are not searched, neither to files nor to directories,
  so a file is found once, under its real path. Version control
  directories (`.git`, `.hg`, `.svn`, `.jj`) are never searched, and files
  with a NUL byte are skipped as binary.
- The search stops at `quarry-grep-max-lines` lines; narrow the search
  or raise the option to see more.
- `~/.ripgreprc`, PCRE2 and compressed files are not supported.
- The result buffer is not a `compilation-mode` buffer
  (`docs/decisions/0012`), so commands made for those, such as
  `grep-edit-mode`, do not work in it; results are edited through wgrep
  (`docs/decisions/0013`).

## Options

The options of the file finder; those of the grep tool are listed under
"Grep". Customize group `quarry`. `quarry-include-hidden` and `quarry-ignores`
apply to instances started afterwards; run `quarry-stop` to restart a
project's instance. The other options apply at once.

| Option | Default | Meaning |
|---|---|---|
| `quarry-include-hidden` | `t` | Index hidden files. |
| `quarry-ignores` | `nil` | Extra gitignore-syntax patterns, relative to the project root. They add to the ignore files; a `!` pattern here cannot re-include a file a `.gitignore` hides. |
| `quarry-limit` | `200` | Number of candidates returned per query (the service clamps it to 1..10000). |
| `quarry-highlight` | `t` | Highlight matched characters in candidates. |
| `quarry-match-style` | `fuzzy` | How plain terms match: `fuzzy` or `substring` (see Query syntax). Applies to the next query, no restart needed. |
| `quarry-match-faces` | `(quarry-match-0 quarry-match-1 quarry-match-2 quarry-match-3)` | Faces for matched characters, one per term in turn. `(completions-common-part)` highlights all terms alike. |
| `quarry-query-timeout` | `10.0` | Seconds before a query gives up. A safety net against a stuck instance, not a latency budget. |
| `quarry-provide-project-files` | `nil` | With `quarry-mode`, serve `project-files` from the index. |
| `quarry-files-timeout` | `10.0` | Seconds `project-files` waits for the index before falling back. |
| `quarry-find-file-command` | `quarry-find-file` | Command `quarry-mode` runs in place of `project-find-file`: `quarry-find-file` or `quarry-consult-find-file`. |
| `quarry-consult-input-debounce` | `0.05` | Seconds without typing before the consult front end queries. |
| `quarry-consult-input-throttle` | `0.1` | Minimum seconds between two queries of the consult front end. |
| `quarry-consult-refresh-interval` | `0.25` | Seconds between queries of the consult front end while the instance is indexing. |

## What is indexed

Regular files below the project root and symbolic links to files, as paths
relative to the root. Rules, and how they differ from `project-files`:

- Untracked files that are not ignored are included, regardless of
  `project-vc-include-untracked`.
- `project-vc-ignores` is not honoured; use `quarry-ignores`.
- `.gitignore`, `.ignore`, `.git/info/exclude` and the user's global git
  excludes apply, also outside git repositories. Ignore files in directories
  above the root apply too.
- Directories `.git`, `.hg`, `.svn` and `.jj` are never walked.
- Symbolic links are not followed; a link to a directory is not listed.
- Hidden files are included unless `quarry-include-hidden` is nil.
- File names that are not valid UTF-8 and unreadable directories are skipped.
  `quarry-status` shows how many.

## File watching

The Rust side watches the indexed directories with `notify`, debounces
events for 100 ms and applies them to the index: created, deleted and
renamed files and directories show up in the next query. Content changes
are ignored. Changed ignore files (`.gitignore`, `.ignore`,
`.git/info/exclude`) and lost events trigger a full rescan in the
background, which replaces the index when it finishes.

On Linux this takes one inotify watch per indexed directory. The limit,
`fs.inotify.max_user_watches`, is shared by all programs of the user; it
was 65,536 on the machine quarry was developed on. A tree the size of AOSP
needs about 150,000. If
the limit is reached, quarry reports `File watching ... failed` and keeps
working without watching: it rescans before each prompt, so results stay
correct but each prompt starts a full walk in the background. To raise the
limit temporarily:

```sh
sudo sysctl fs.inotify.max_user_watches=524288
```

and permanently:

```sh
echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/90-inotify.conf
sudo sysctl --system
```

Then run `quarry-stop` (or `quarry-stop-all`) so the instance starts again
and sets up its watches.

## Performance

`bench/run-bench.sh` generates AOSP-like trees (nested directories, empty
files, committed to a temporary git repository) and, with a limit of 100,
types a fixed sequence of about 100 query prefixes through
`completion-all-completions` with the `quarry` style, timing each call. The
baseline is `project-files` of the vc backend followed by the `flex` style.

Results of 2026-10-09 on an Intel Core i5-8365U (4 cores, 8 threads, about
1.1 GHz under the powersave governor, 14 GiB RAM), Emacs 31.0.50:

| Files | quarry p99 | Baseline p99 | Baseline listing (per prompt) | Indexing | RSS after indexing |
|---|---|---|---|---|---|
| 100,000 | 33.5 ms | 307 ms | 413 ms | 0.7 s (warm cache) | +34 MB |
| 1,000,000 | 177 ms | 3.5 s | 8.3 s | 4.5 s | +250 MB |

The 1,000,000-file result misses the 150 ms goal of the spec on this
machine; exact scoring of short queries, which match most paths, dominates.
The baseline is not like-for-like: it returns every match unranked and
unlimited, and it treats `^`, `$`, `!` and spaces literally.

Run it with `bench/run-bench.sh` (options `--size 100k|1m|both`,
`--skip-baseline`, `--keep`; see the header of the script). Trees need up to
about 800 MB and 1.2 million inodes for 1m, more with the git repository for
the baseline, and go to `target/bench-trees` or `$QUARRY_BENCH_DIR`. The
script exits non-zero if quarry's p99 exceeds 50 ms (100k) or 150 ms (1m).

## Development

Work in a checkout, for example `~/src/emacs-quarry`. With Doom, keep the
user recipe and add the checkout when it exists (`my/quarry-dev` is any
variable name you like):

```elisp
(defvar my/quarry-dev (file-directory-p "~/src/emacs-quarry"))
(package! quarry
  :recipe `(:host github :repo "tohammer/emrs-quarry" :files ("lisp/*.el")
            :pre-build ((load (expand-file-name "lisp/quarry-build.el") nil t)
                        (quarry-build-module-sync))
            ,@(when my/quarry-dev
                '(:local-repo "~/src/emacs-quarry" :build (:not compile)))))
```

With an absolute `:local-repo`, straight uses the checkout as the repository
and never clones or pulls it. `:build (:not compile)` leaves no `.elc` that
would shadow edits. With the switch on, any change in the checkout makes
`doom sync` rebuild the package and so run cargo; that is incremental and
does nothing when no Rust changed.

| Change | Do | Takes effect |
|---|---|---|
| Elisp in `lisp/` | `eval-buffer`, or restart | at once, no `doom sync` |
| Rust in `src/` | `M-x quarry-build-module` | after restarting Emacs |
| New file in `lisp/` | `doom sync` once | the build directory gets the symlink |
| emrs too | the same pattern for the emrs recipe (`:local-repo` and `:build (:not compile)`, file `elisp/emrs.el`), and a patch in an uncommitted `.cargo/config.toml` (below) | as above |

To build against a local emrs checkout, put this in `.cargo/config.toml`
and do not commit it:

```toml
[patch."https://github.com/tohammer/emrs.git"]
emrs = { path = "../emrs/emrs" }
```

`Cargo.toml` must pin only emrs commits that are on emrs's default branch,
because the recipe for `emrs` follows that branch (`docs/decisions/0007`).

`tests/run-ert.sh` tests copies of the Lisp files in `target/elisp` with the
debug module, so a module built in `lisp/` does not affect the tests.

### Tests

```sh
cargo test              # Rust unit and service tests
tests/run-ert.sh        # builds the module and runs the ERT suite in Emacs
ERT_SELECTOR=cache tests/run-ert.sh   # only tests whose name matches the regexp
bench/run-bench.sh      # benchmark, run by hand
QUARRY_TEST_LOAD_PATH=~/.emacs.d/straight/build/consult:~/.emacs.d/straight/build/compat tests/run-ert.sh
```

The grep tests (`tests/quarry-grep-tests.el`) need nothing extra. The
tests of editing grep results (`tests/quarry-grep-wgrep-tests.el`) need
wgrep: add its directory to `QUARRY_TEST_LOAD_PATH` as well. Without it
the script says so and those tests are skipped, except the one for the
refusals of `e`. The
consult front end tests (`tests/quarry-consult-tests.el`) need consult
2.0 or later and its dependency compat. `QUARRY_TEST_LOAD_PATH`
is a colon-separated list of directories that the script adds to
`load-path`; put the directories of consult and compat there. Without it,
or when consult cannot be loaded from it, the script says so and skips
the tests that need consult (the command and end-to-end tests); the
tests of the async step, the test of loading without consult and the
rest of the suite run as usual. Rerun them after
upgrading consult.

Set `EMACS` to use another Emacs binary. There is no CI (`docs/backlog.md`),
so run the first two before merging.

## Documentation

- `docs/architecture.md` and `docs/architecture/`: how the system is built now.
- `docs/specs/`: specifications; `docs/decisions/`: decision records.
- `docs/backlog.md` and `docs/next-steps.md`: open points and what comes next.

## Licence

The Rust code is licensed under either MIT or Apache-2.0, at your option.
`lisp/quarry.el` is licensed under GPL-3.0-or-later.
