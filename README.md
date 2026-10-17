# quarry

A fast project file finder and an interactive grep for Emacs, both backed
by one Rust module.

For the file finder, the module keeps a live index of each project's
files, updated by a file watcher, and answers fuzzy queries from it with
[nucleo](https://github.com/helix-editor/nucleo) ranking, so
`project-find-file` stays fast on large repositories.

The grep tool, `quarry-grep`, works in the manner of
[rg.el](https://github.com/dajva/rg.el): the search runs in the same
module, and the matches are shown in a buffer from which the search is
changed and run again (see "Grep"). With consult it also searches while
you type (see "Live grep"). The two tools do not need each other.

quarry is built on [emrs](https://github.com/tohammer/emrs), which runs the
Rust side as a message-passing service outside the Emacs thread.

Status: version 1. It was built and used on Linux only, with Emacs 31.1
and, for the file finder's benchmark, Emacs 31.0.50 (the replace
benchmark ran on 31.1). CI runs the ERT suite on Linux and
macOS with Emacs 30.1 and 31.1, and `cargo test` on Linux; beyond that,
Emacs 30 and macOS have not been used by hand, and the watcher code for
macOS is known only from those tests (`docs/backlog.md`). Windows is
untested. It installs from GitHub with
package recipes and a local cargo build; only the Doom recipe is checked by
hand, the straight, elpaca and package-vc variants are untested. There are
no prebuilt binaries.

The grep tool was tested by the ERT suite in batch and by hand in a
terminal Emacs; the live grep by the ERT suite in batch and in the
author's Doom setup. It has not been run in a GUI frame, its faces were not
looked at in any theme, and it shares the Emacs 30 gap. Editing results
with wgrep is untested on files with `\r\n` line ends and on files in
encodings other than UTF-8. Replace (`R`, `C-c C-c`) is tested by the
ERT suite and the benchmark only: it has not been used by hand, and its
faces have not been looked at in a GUI frame or a terminal.

## Requirements

- Emacs 30.1 or later, built with module support.
- Rust 1.88 or later, with `cargo` on `PATH` (or set
  `quarry-build-cargo-program`), to build the module.
- Network access for cargo's first dependency fetch.
- Linux for anything you want to rely on (see Status).
- Optional: [consult](https://github.com/minad/consult), 2.0 or later
  for the consult front end (see "consult front end"); the live grep
  (see "Live grep") was tested with consult 3.7 only. quarry does not depend on it;
  only the commands that need it load it.
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

Update `emrs` together with quarry. quarry uses functions of `emrs.el` as
they are added; with an `emrs.el` older than the commit pinned in
`Cargo.toml`, a command can fail with `void-function` (for example
`emrs-call-stream-sync`, which `quarry-provide-project-files` needs).

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
   for the module fails with a protocol error, or with `void-function`
   for a function quarry uses that it does not have yet. Either clone emrs and check
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
ranked paths of a project directly (see their docstrings); an optional last
argument limits them to the paths below a directory of the project.

## Usage

| Command | What it does |
|---|---|
| `quarry-find-file` | Visit a file of the current project, chosen from the index. Starts the project's instance on first use. |
| `quarry-consult-find-file` | The same in a consult prompt that queries the index asynchronously (see "consult front end"). Needs consult 2.0 or later. |
| `quarry-find-file-in-directory` | Visit a file below a directory, `default-directory` or, with a prefix argument, one it asks for. Candidates are relative to the directory (see "Files below a directory"). |
| `quarry-consult-find-file-in-directory` | The same in a consult prompt that fills while a directory is walked. Needs consult 2.0 or later. |
| `quarry-mode` | Global minor mode. Remaps `project-find-file` to `quarry-find-file-command` (default `quarry-find-file`); with `quarry-provide-project-files` set, it also serves `project-files` from the index. |
| `quarry-rescan` | Walk the current project again and report the file count when done. |
| `quarry-stop` | Stop the current project's instance. The next command starts a new one with the current options. |
| `quarry-stop-all` | Stop all instances. |
| `quarry-status` | Show root, file count, whether it is indexing or watching, number of walks and skipped paths in the echo area. |

`quarry-find-file` and `quarry-consult-find-file` fall back to
`project-find-file` with a prefix argument (which asks for ignored files
too) and in remote (TRAMP) projects. With `quarry-mode` the same applies
to `project-find-file`, since it is remapped to one of them.

One instance runs per project root, started lazily on first use (a
directory outside the index gets one for a single prompt; see "Files
below a directory"). While the
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

### Files below a directory

`quarry-find-file-in-directory` and `quarry-consult-find-file-in-directory`
find a file below a directory, in the manner of Doom's
`+default/find-file-under-here`, `consult-fd` and `consult-find`, but with
quarry's matcher and ranking and without a process per input. The
directory is `default-directory`; with a prefix argument the command asks
for it. The candidates are paths relative to the directory, ranked and
highlighted as in `quarry-find-file` (the directory's own name never
matches), and the chosen one is visited below the directory. The query
syntax is the one above. The plain command reads as `quarry-find-file`
does; the consult command is `quarry-consult-find-file` on this directory
(see "consult front end"), with the same differences from the plain one
and the history `quarry-consult-directory-history`. The plain command's
history is `quarry-directory-file-history`.

Where the directory is answered from:

- A directory below the root of the current project (compared as true
  names, so a symlink does not matter) is answered by the project's
  index, as fast as `quarry-find-file`, when the index has files below
  it (not while the project's first walk has yet to reach the directory:
  then it is walked on its own, as below). The directory need not be a
  project of its own.
- Any other local directory, including a directory the project ignores
  such as `node_modules/` and a directory outside every project, gets an
  instance of its own for the one prompt: it walks the directory once, with
  no file watcher, and is stopped when the prompt ends, also on `C-g` or
  an error. Nothing stays running and nothing is reused by the next
  prompt, which walks again. The walk follows the rules of "What is
  indexed", ignore files above the directory included, so from inside an
  ignored directory it lists what `rg --files` there would.

The plain prompt waits up to a second for a first page of files, like
`quarry-find-file`. The consult prompt opens at once and fills as the
walk goes on. A walk takes as long as the directory is large: `~` can
take seconds and memory in proportion to its number of files. In the
consult prompt the list fills meanwhile and `C-g` ends the walk. The plain
prompt does not refresh by itself: it shows the files found when it opens,
and a typed input is matched against those found so far.

Only local directories: for a remote (TRAMP) directory the commands signal
an error, as `quarry-grep` does. The package binds no keys. To put the
commands in place of `+default/find-file-under-here` (`SPC f F`) in Doom,
in `config.el`:

```elisp
(map! [remap +default/find-file-under-here] #'quarry-find-file-in-directory)
```

or, for the consult prompt:

```elisp
(map! [remap +default/find-file-under-here] #'quarry-consult-find-file-in-directory)
```

A remap changes keys only, not calls from Lisp.

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
| `quarry-grep` | regexp, file types and globs, directory | the directory |
| `quarry-grep-literal` | literal, file types and globs, directory | the directory |
| `quarry-grep-project` | regexp, file types and globs | the project root (`project-current`), or `default-directory` outside a project |
| `quarry-grep-dwim` | nothing | the project root for the symbol at point as a literal, in files of the current buffer's file type |
| `quarry-consult-grep` | input in a consult prompt, searched while you type (see "Live grep") | `default-directory`; with a prefix argument, a directory it asks for |
| `quarry-consult-grep-project` | the same | the project root, or `default-directory` outside a project; with a prefix argument, a project it asks for |

The pattern prompt offers the active region, or else the symbol at point,
as default. The files prompt (`Search in files (types and globs)`)
completes over the type names of the `ignore` crate (what `rg
--type-list` prints) and `everything`; its default is the type of the
current buffer's file, else `everything`. `all` is not a type name;
`everything` is the word for no restriction. The prompt takes words
separated by spaces: type names, globs, or both (`rust elisp !gen/**`).
A word that is a type name is a type, in any number; every other word is
a glob. A glob that is spelled like a type name is taken as the type;
write `[m]ake` to mean the glob.

How the restrictions combine:

| You give | A file is searched if |
|---|---|
| several types | it is of one of them (they are alternatives) |
| several including globs | it matches one of them (they are alternatives) |
| types and globs | it passes the types and the globs (both narrow) |
| an excluding glob (`!...`) | no excluding glob matches it; when several globs match a file, the last one decides |

Nothing in this is an error; a combination that no file passes gives no
hits.

Globs are gitignore-style and relative to the searched directory. One
without a `/` matches a name at any depth (`*.el`); one with a `/` at
its start or inside matches a path from the searched directory
(`sub/*.txt`, `src/**`); `**` crosses directories. A `/` at the end only
says "a directory" and does not anchor: `!vendor/` excludes every
directory `vendor`. A `!` in front excludes (`!*.min.js`), and the last
glob that matches a file decides. An including glob must name files, not
their directory: `src/**`, not `src/`, which selects nothing. Case
counts. Globs only restrict: unlike `rg -g`, a glob never
brings back an ignored or hidden file; for that use the ignore and
hidden switches (`i` and `H`, see "The result buffer").

An empty pattern is refused.

### The result buffer

One buffer, `*quarry-grep*`, reused by each search. Its
`default-directory` is the searched directory, and paths are shown
relative to it. To keep a result while you search for something else,
clone the buffer (`M-x clone-buffer`); the clone is a result buffer of
its own, with its own searches and history.

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

- The header line shows the file types and globs, the directory, the case rule,
  whether ignore files are used and hidden files searched, the lines of
  context (`ctx: 2`, or `ctx: 1/3` for 1 before and 3 after; see
  "Context lines"), and the number of hits and files found so far. It
  ends with the hint `? menu`. A click with `mouse-1` on a part runs the
  command of its key below; a click on the hint opens the menu (`?`).
  The hint is not shown while the results are edited, since `?` is text
  then.
- The filter block has one line per filter, in the order they were added
  (see "Filters"). The first line is the pattern the command asked for.
- Each file has a heading with the number of its hits, and one line per
  hit with the line number and the text, with the matches highlighted
  (see "Highlighting"). With context switched on, the lines around each
  hit are shown too (see "Context lines").
- The last line says `Searching…` while results arrive, then how many
  lines were found in how many files and how long it took. It also names
  a search that stopped at the line cap, files that could not be read, a
  cancellation, and an error such as an invalid regexp. It says "stopped
  at N lines" whenever N lines were found, also when the tree holds
  exactly that many.
- An invalid regexp leaves the filters as they are. The status line shows
  the engine's message and point goes to the faulty filter, where `RET`
  corrects it.

Results appear as they arrive, without moving point or scrolling the
window. A search that finishes within 150 ms is shown sorted by path. In
a longer one, what was found in the first 150 ms is shown sorted and the
rest follows in the order it is found.

| Key | Action |
|---|---|
| `RET`, `mouse-1`, `mouse-2` | On a result line or its number: visit the file at that line, at the column of the first match of the primary filter. On a context line: visit that line, at its first column. On a file heading: visit the file. On a filter line: edit its pattern in the minibuffer |
| `n`, `p` | Show the next or previous match in another window without selecting it |
| `}`, `{`, `M-N`, `M-P` | Move to the next or previous file heading |
| `TAB` | Fold or unfold the file at point |
| `S-TAB` | Fold all files, or unfold them when all are folded |
| `g` | Search again |
| `r`, `t` | Edit the primary filter, as a regexp or as a literal |
| `d`, `f` | Change the directory; the file types and globs |
| `c` | Cycle the case rule: smart, sensitive, insensitive |
| `C`, `B`, `A` | Set the lines of context shown around each hit: both counts, the count before, the count after (see "Context lines") |
| `i`, `H` | Switch ignore files on or off; hidden files |
| `- p`, `+ p` | Add a path filter, excluding or including, with a literal as pattern |
| `- l`, `+ l` | Add a line filter, excluding or including, with a literal as pattern |
| `- P`, `+ P`, `- L`, `+ L` | The same, with the pattern as a regexp |
| `- f` | Exclude the file at point, and only that file |
| `- d`, `+ d` | Exclude, or search only, the directory of the file at point |
| `k`, `x`, `!`, `%` | On a filter line: remove it; switch it off or on; flip it between including and excluding; switch it between literal and regexp. During a replace preview `x` also switches matches off and on |
| `K` | Remove all filters except the primary one |
| `C-c <`, `C-c >` | Go back or forward in the buffer's search history |
| `C-c C-k` | Cancel the running search; during a replace preview, leave the preview |
| `e` | Edit the results with wgrep (see "Editing results") |
| `R` | Preview a replacement of the primary filter's matches (see "Replacing matches") |
| `C-c C-c` | Write the previewed replacement into the files |
| `?` | Show a menu of all these keys with the current value of each switch (see below) |
| `h`, `C-h m` | Show the help of the mode |
| `q` | Quit the window |

`?` opens `quarry-grep-menu`, a transient that lists all the keys above
under their own keys, with the current value of each switch (`case:
smart`, `context: 1/3`, ...). A key in the menu runs the command it has
in the buffer and closes the menu; entries that do not apply at point
or in the state of the search, such as `k` on a result line, are shown
inactive. A numeric prefix argument typed before `?`, or `C-u` in the
menu, goes to the command: `C-u 3 ? C` shows 3 lines of context. The
menu needs the transient that ships with Emacs 30.1; it is loaded when
`?` is first used. `C-g` closes the menu.

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
looks at lines or at paths, includes only what matches (`+`) or excludes
it (`-`), and is a literal or, marked `/re`, a regexp. The pattern a command
asks for is the first of them, a `+ line` filter, and is a filter like the
others. Every change to the filters runs the search again.

- A **line** filter is matched against the text of a line. The case rule
  of the header line applies to each line filter by itself.
- A **path** filter is matched against a slash followed by the path
  relative to the searched directory. So `/test/` matches `test/a.c` and
  `src/test/a.c`, a directory `test` at any depth, and `.rs` matches by
  extension.
  Path filters always use smart case. A directory that a literal
  exclude path filter matches is not entered.
- The filters are combined with "and": a line is shown when it and its
  file match every `+` filter and no `-` filter, so each added filter can
  only narrow the result. For "either of two", write one regexp filter,
  such as `/(audio|video)/` for two directories or `foo|bar` for two
  words (`+ P`, `+ L`, or `%` on the filter's line).

`- p`, `+ p`, `- l` and `+ l` ask for a literal and add the filter at the
end of the list. The same keys with an uppercase letter, `- P`, `+ P`,
`- L` and `+ L`, ask for a regexp.

`- f`, `- d` and `+ d` take the pattern from the result at point.

`- f` excludes that file at once, and no other: it adds a regexp path
filter that is anchored at both ends and keeps case apart. For
`src/a.c` the filter line is

```text
- path/re  (?-i)^/src/a\.c$
```

so `src/a.cpp`, `lib/src/a.c` and `src/A.c` stay.

`- d` and `+ d` put the file's directory into the minibuffer, as
`/dir/sub/`; confirm it, or shorten it to a parent such as `/dir/` first.
These are ordinary literal path filters, so `/dir/sub/` also matches a
directory `dir/sub` deeper in the tree. For a file that lies in the
searched directory itself there is no directory to name, and the two
commands refuse.

A filter the search already has is not added twice; if it is switched
off, it is switched on.

`k` removes the filter at point, `x` switches it off or on (shown dimmed
with `(off)`; it stays in the list and is not applied), `!` flips it
between `+` and `-`, `%` between literal and regexp, and `RET` edits its
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
| `quarry-grep-context` (inherits `shadow`) | The text of a context line, and the gap line between groups of lines |

In the filter block each `+` filter that is on shows its pattern in the
face of its matches, so you can see which colour belongs to which filter.
`-` filters have nothing to highlight.
`quarry-grep-highlight-include-filters` and
`quarry-grep-highlight-path-filters` switch the second and the third face
off; the primary matches are always highlighted.

### Context lines

`C`, `B` and `A` show the lines around each hit, as `-C`, `-B` and `-A`
do in grep and rg: `C` sets the number of lines before and after, `B`
only the number before, `A` only the number after. `B` and `A` leave
the other side as it is: after `2 C`, `3 B` shows three lines before and
two after, and the header line reads `ctx: 3/2`; `C` sets
both sides again. A numeric prefix is
the number and nothing is asked: `2 C` shows two lines before and after
every hit. Without a prefix the number is read in the minibuffer; its
default is the current count, for `C` the larger of the two. `0 C` gives
the result buffer without context. A negative number is refused and
changes nothing. Each is a new search and, when a count changed, an entry
in the history.

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

- A context line has a line number like a hit and its text in the face
  `quarry-grep-context`. `RET` or a click on it visits that line of the
  file. Context lines are not highlighted.
- Where two groups of lines do not touch, a gap line with `⋮` stands
  between them. A search without context has no gap lines. A gap line
  belongs to its file: it is folded with the file, and the commands that
  read the file at point (`- f`, `- d`, `+ d`, `TAB`, `{`, `}`) work on
  it.
- Counts and `n`, `p` and `next-error` concern hits only: the number in
  a file heading, `hits` in the header line and the status line do not
  count context lines, and `n` and `p` go from hit to hit.
- A line that a `- line` filter removed can appear as context next to a
  hit. Line filters apply to hits, not to context lines.
- `quarry-grep-max-lines` counts hits, so a result with context can be
  several times as large as the same result without. The search stops at
  the hit that fills the cap, so the last hit of a file can then come
  with its lines before it and without its lines after it.
- A new search starts with the counts of `quarry-grep-context-before` and
  `quarry-grep-context-after`; the commands of the result buffer keep
  the counts of the search they change.
- At most 1000 lines per side. A larger count, typed, as a prefix or in
  an option, is reduced to 1000 and the echo area says so.

After updating quarry, rebuild the module (`M-x quarry-build-module`) and
restart Emacs. A module loaded from before this change ignores the
counts: the search works and shows no context lines, only gap lines
between the hits.

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
- Context lines can be edited like hits. The gap line (`⋮`) that stands
  where lines are left out cannot.
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
- Folded files are unfolded on entering. `e` is refused while a search
  runs, when there are no results, and during a replace preview or
  after a replacement was applied (see "Replacing matches").
- After a commit the result lines show the edited text and the status
  line says that the results were edited; `g` searches again, which
  shows what is on disk.

### Replacing matches

`R` replaces what the primary filter matched, across all files of the
result, after you have seen every change. It is for mechanical changes
such as a rename or a moved module path. It asks for a template, with
the current one as initial input, and searches again with it. The buffer
text does not change; each match shows the old text struck through
(`quarry-grep-replace-old`) followed by the new text
(`quarry-grep-replace-new`). The header shows `→ TEMPLATE`, which `R`
edits when clicked, and `N of M matches on`. Lines that cannot
be replaced (shortened, or not valid UTF-8) are shown as before and
counted in the status line.

The template is the syntax of `rg -r`:

| Template | Is |
|---|---|
| `$0` | the whole match |
| `$1`, `${1}` | capture group 1 |
| `$name`, `${name}` | the group named `name` (`(?P<name>...)`) |
| `$$` | a dollar sign |

A name runs as far as ASCII letters, digits and `_` go, so `$1a` is the group
named `1a`, which does not exist. Write `${1}a` for group 1 followed by
`a`. A group that does not exist or did not take part gives empty text.
A literal filter has only `$0`. A template cannot contain a newline.
The search with a template is an entry in the search history of its own:
`C-c <` goes back to the search without it. Filter commands during a
preview keep the template and update the preview.

- `x` switches matches off and on, and only the switched-on matches are
  written. On a match it switches that match; on a result line outside a
  match, all matches of the line; on a file heading, all matches of the
  file (off when any is on, else on). Then point moves to the next line
  with a match.
- `C-c C-k` leaves the preview when no search runs. `e` is refused
  during a preview; leave it first.
- `C-c C-c` writes the switched-on matches. It is refused while a search
  runs, after a failed or cancelled search, and when no match is
  switched on. A preview that stops at `quarry-grep-max-lines` counts
  the matching lines up to `quarry-grep-replace-max-lines`; `C-c C-c`
  then offers to search again with a limit that holds them all and
  writes nothing, or, above the option, says to narrow the search (see
  "Large replacements"). If a result file changed since the search (or
  a modified buffer visits it), it asks whether to search again, and
  writes nothing either way.
  Otherwise it asks `Replace N matches on L lines in F files?`, and
  names the files among them that are folded or outside a narrowing
  (`C-x n n`): they are written too.
- Every line is compared with the text the search found and rejected
  when it differs, or when its buffer is read-only, has unsaved changes
  or is not up to date with its file, when the file cannot be read or
  written, or when the new text has a character that the file's
  encoding (or the encoding of the buffer that visits it) cannot hold. A
  file that Emacs reads as Latin-1 or another 8-bit encoding but that
  holds UTF-8 text (UTF-8 with a stray byte) is not changed: its lines
  are rejected as of ambiguous encoding. Nor is a file whose text, read
  as Emacs would read it, does not give its bytes back when written in
  the same encoding, such as one whose coding cookie says CRLF line ends
  while its lines end in LF. A buffer visited literally
  (`find-file-literally`, or with the coding system `no-conversion` or
  `raw-text`) takes only ASCII new text; with other new text its lines
  are rejected. The other lines and files go on. Afterwards each result line is marked as applied or
  rejected (the reason is in its `help-echo`; faces
  `quarry-grep-replace-applied` and `quarry-grep-replace-rejected`), and
  the echo area says `Replaced N lines in F files; R rejected`. `g`
  searches again and shows what still matches; until then `x`, `C-c C-c`
  and `e` are refused. `C-g` stops: a file that is being written is
  finished first, a buffer that is being saved gets its old text back,
  and the files written stay written.
- A file that an Emacs buffer visits is changed in that buffer and
  saved with `save-buffer`, without `before-save-hook` (so no formatter
  or `delete-trailing-whitespace` on save) and without
  `require-final-newline`; `after-save-hook` runs and a backup file may
  be made. It is one undo step in that buffer. When the saving fails or
  is stopped before the file is written, the buffer gets its old text
  back, unmodified, and the file's lines are rejected. When a hook fails
  or is stopped after the file was written, the lines count as replaced
  and the buffer keeps them.
- Other files are read as their bytes, decoded as Emacs would decode
  them but with no format conversion (such as `text/enriched`), changed,
  and written back in their own encoding, line ends and byte order mark,
  with no undo: use git. No handler of compressed or encrypted files
  (`.gz`, `.gpg`) runs on reading or writing. The new content goes to a
  temporary file in the same directory, which gets the file's
  permissions and is renamed over the file, so a failed write leaves
  the file as it was. Like any Emacs save, it is synced to the disk
  only when `write-region-inhibit-fsync` is nil (the default is t). A symbolic link is followed
  and stays a link; the file it points to is replaced. A file with more
  than one hard link, one owned by another user or group than the new
  file would be, or one in a directory you cannot write is written in
  place instead, so that the links and the owner stay; if that write
  fails, the old content is written back. The file is locked while it
  is written, as Emacs locks a file you edit: when another Emacs holds
  its lock, you are asked, and `C-g` there stops with the file as it
  was.
- Empty matches (`^`, `\b`, `x*` matching nothing) are not replaced.
  To insert text at the start of lines, match something: `^(.)` with
  `PREFIX$1`.

The replace needs the new module: rebuild it with `M-x
quarry-build-module` and restart Emacs. An older module is detected when
the search with the template gets its first results; the search then runs without the template and says to rebuild.

#### Large replacements

A search stops at `quarry-grep-max-lines` hits (50,000 by default;
context lines do not count), and `C-c C-c` does not write a result that
stopped there. The status line of a truncated preview shows the total,
"Search stopped at 50000 of 73412 lines", or "of more than 100000
lines" above `quarry-grep-replace-max-lines`. Three ways through:

- **Raise the limit for this search.** `C-c C-c` asks `73412 lines
  match, the limit is 50000; search again with a limit that holds them
  all?` for up to `quarry-grep-replace-max-lines` lines (100,000 by
  default). Yes searches again with such a limit and the template. Above that, each
  search reads the option when it starts, so `M-: (setq
  quarry-grep-max-lines 300000)` and then `g` in the result buffer
  search again with the template. Measured on a
  laptop (`docs/architecture/grep.md`, "Cost of large change sets"): the
  preview takes about 3 s per 100,000 hits, applying about 1 ms per file
  on an SSD, so 10,000 files take about 13 s. Above about 100,000 hits
  nothing was measured; the buffer and the Emacs thread become the
  limit. Set the option back afterwards.
- **Replace part by part.** A filter change keeps the template, and what
  it leaves out is not written. Limit the search to one part (`+ p
  src/foo/`, `+ d` on a result, or `f` with `src/foo/**`), check the
  preview, `C-c C-c`, then change the filter to the next part. Pressing
  `g` again does not work as batching: while more hits remain than the
  limit, the result stays truncated and `C-c C-c` writes nothing.
- **Match fewer lines.** Word boundaries (`\bold_name\b`), an include
  line filter (`+ l`) for the context the change belongs to, or leaving
  out generated and vendored directories (`f` with `!vendor/ !gen/`, or
  `- p`) often bring the hits under the limit and make the preview
  easier to review.

For changes of millions of lines, a command-line tool such as `fastmod`
or `rg -l | xargs sed` is the better fit.

### Live grep

`quarry-consult-grep` and `quarry-consult-grep-project` search while the
pattern is typed in the minibuffer and show the hits as candidates, in
the manner of `consult-ripgrep`. The grep service answers each input,
and the search for the previous input is cancelled. `RET` visits the
hit.

| Command | Searches | With a prefix argument |
|---|---|---|
| `quarry-consult-grep` | `default-directory` | asks for the directory |
| `quarry-consult-grep-project` | the project root (`project-current`), or `default-directory` outside a project | asks for a project first |

Both need [consult](https://github.com/minad/consult). They were tested
with consult 3.7 only, by the ERT suite in batch Emacs; which older
version still works is not known. consult is
not a dependency of quarry: `lisp/quarry-consult-grep.el` loads without
it, and the commands then signal a `user-error`. They use consult's
internal async pipeline and its grep candidate format
(`docs/decisions/0008`, `0018`), so a consult upgrade can break them.
The commands are autoloaded; without package autoloads, `(require
'quarry-consult-grep)` first. The package binds no keys; bind the
commands yourself (for Doom see below). Remote (TRAMP) directories are
refused, as by the other grep commands.

An active region is the initial input, quoted so that it is searched
literally. The symbol at point is offered as future history (`M-n`). The
history is `quarry-consult-grep-history`.

#### Input

consult splits the input first (`consult-async-split-style`). With the
default style `perl` the input reads `#search part#filter part`: the
search part goes to the grep service, and the filter part filters the
candidates in Emacs with your completion styles. A search starts when
the search part has `consult-async-min-input` characters (3 by default).

The search part is a list of terms separated by spaces, then, after
` -- `, options:

```text
#fn walk !test -- -t rust -g !gen/**#async
```

- Each term is a pattern that a line must match. The terms may match in
  any order and anywhere in the line.
- A term with `!` in front is a pattern that a line must not match
  (`!test`).
- `\ ` is a space inside a term (`foo\ bar`), and `\!` at the start of a
  term is a literal `!`. Any other backslash belongs to the pattern,
  together with the character after it, so `\\` before a space is a
  backslash and the space ends the term. A tab separates terms as a
  space does.
- The first term without `!` is the primary filter. The order of the
  terms does not change the hits, but files are searched for the first
  term, so a rare first term is faster. Point and the preview go to the
  match of the first term.
- Terms are Rust regexps (see "Limits"), unless `-F` is given; then all
  terms are literals.
- The case rule is `quarry-grep-case` (smart by default), and hidden
  files are searched when `quarry-include-hidden` is non-nil, unless an
  option says otherwise.

The options are spelled as in rg. A value is the next word, or attached
(`-trust`, `--type=rust`).

| Option | Meaning |
|---|---|
| `-t TYPE`, `--type TYPE` | a file type; any number, in order |
| `-g GLOB`, `--glob GLOB` | a glob, see below; any number, in order |
| `-F`, `--fixed-strings` | all terms are literals, not regexps |
| `-i`, `--ignore-case` | case rule `insensitive` |
| `-s`, `--case-sensitive` | case rule `sensitive` |
| `-S`, `--smart-case` | case rule `smart` |
| `-u`, `--no-ignore` | ignore files are not used |
| `-uu` | `-u` and `-.` |
| `-.`, `--hidden` | hidden files are searched |
| `--no-hidden` | hidden files are not searched |

Types and globs combine as in the files prompt of the result buffer (see
"The result buffer"):

| You give | A file is searched if |
|---|---|
| several `-t` | it is of one of the types |
| several including `-g` | it matches one of the globs |
| `-t` and `-g` | it passes the types and the globs (both narrow) |
| an excluding `-g !...` | no excluding glob matches it; when several globs match a file, the last one decides |

Nothing in this is an error; a combination that no file passes gives no
hits. For example, `quarry -- -t elisp -g *test* -g *.rs` searches for
"quarry" in Elisp files whose name contains "test". The two globs are
alternatives, but no `.rs` file is an Elisp file, so `-g *.rs` adds
nothing. `quarry -- -t elisp -t rust -g *test*` searches Elisp and Rust
files whose name contains "test". To search Elisp files and, besides
them, every file matching a glob, there is no single input: types and
globs both narrow.

This differs from rg. In rg an including `-g` overrules `-t` (the first
example would search every file with "test" in its name and every `.rs`
file there). Here every option narrows, and only options of the same
kind are alternatives.

Of several case options the last counts. Nothing else is supported: not
the other options of rg (`-w`, `-C`, `-m`, `--pcre2`, ...), and not
clusters of short options (`-Fi`; write `-F -i`). An unknown option is
not ignored: it is shown as an error in the prompt, and nothing is
searched. What is still being typed is no error: an option whose value
is not typed yet, a last word that is the start of an option (`--hid`),
a lone `!` and a backslash at the end of the input are ignored. Options
are read only when there is a term to search for.

`-g` differs from rg's:

- Globs only restrict. A glob never brings back an ignored or hidden
  file, as `rg -g` does; use `-u` and `-.` for that.
- A glob with a `/` at its start or inside is anchored at the searched
  directory, as in a gitignore file: `!gen/**` excludes what is in a
  top-level `gen/`, and `!**/gen/**` at any depth. A glob without such a
  `/` matches a name at any depth (`*.el`, and `!gen/` for every
  directory `gen`). The last glob that matches a file decides.
- To search one directory, name its files: `-g src/**`. `-g src/`
  selects nothing, as in rg.
- `!gen/` keeps the walk out of the directory; `!gen/**` gives the same
  hits but enters it and drops its files one by one.
- A glob that starts with `#` is a glob (`#*#`), not a comment.
- With `-t` and `-g` a file must pass both the types and the globs.

A search collects at most `quarry-consult-grep-max-lines` hits (1000 by
default); a search that stopped there says `[first 1000 hits]` after the
input. Errors are shown in the same place, for example an invalid
regexp, an unknown file type or an unknown option. The next input
searches again.

#### To the result buffer

`C-c C-o` in the prompt (`quarry-consult-grep-to-buffer`, bound in
`quarry-consult-grep-map`) leaves the prompt and runs the search that is
typed in the `*quarry-grep*` buffer (see "The result buffer"). The terms
become its filters, in their order; the file types, the globs, the case
rule and the ignore and hidden switches are carried over. The context
lines are those of `quarry-grep-context-before` and
`quarry-grep-context-after`, and the search stops at
`quarry-grep-max-lines` hits, not at the live limit. The filter part of
the input is not carried over; the echo area says so. Input that is no
search, such as an unknown option, is an error, and the prompt stays
open. To use another key, bind the command in `quarry-consult-grep-map`.

The candidates have the format and the category of `consult-ripgrep`
(`docs/decisions/0018`), so preview, grouping by file, `embark-export`
to a `grep-mode` buffer and wgrep on that buffer work as they do for
`consult-ripgrep`. `embark-export` exports the candidates that are
shown; `C-c C-o` runs the search again, without the live limit.

#### From Lisp

Both commands take the directory and the initial input as arguments:
`(quarry-consult-grep DIR INITIAL)`. INITIAL is a string in the input
syntax above, without the `#` of the split style. To search for a string
literally, pass it through `quarry-consult-grep-quote`, which quotes the
regexp characters, the spaces, a leading `!` and the separator of the
split style:

```elisp
(defun my/grep-isearch-string ()
  "Search the project for the last isearch string, literally."
  (interactive)
  (quarry-consult-grep-project
   nil (quarry-consult-grep-quote isearch-string)))
```

#### Doom Emacs

To put the commands in place of `+default/search-project` and
`+default/search-cwd`, in `config.el`:

```elisp
(map! [remap +default/search-project] #'quarry-consult-grep-project
      [remap +default/search-cwd]     #'quarry-consult-grep)
```

A remap changes keys only, not calls from Lisp: commands that call the
Doom functions, such as `+default/search-project-for-symbol-at-point`,
still run rg. One prefix argument differs from Doom's: with it,
`quarry-consult-grep-project` asks for another project, where
`+default/search-project` searches ignored and hidden files too. For
that, type ` -- -uu` after the terms. `quarry-consult-grep` with a
prefix argument asks for the directory, as `+default/search-cwd` does.

Doom previews a hit of its own search commands only on `C-SPC`. That is
a setting of consult per command (`:preview-key`), which consult looks
up by the name of the command that runs, so the quarry commands do not
have it and preview every candidate as point moves. To get Doom's
behaviour, name them, and any command of your own that calls them:

```elisp
(after! consult
  (consult-customize
   quarry-consult-grep quarry-consult-grep-project
   :preview-key "C-SPC"))
```

`:preview-key nil` switches the preview off. Outside Doom the same form
works without `after!`, once consult is loaded.

### Options and faces

Customize group `quarry-grep`. They apply to the next search. The
options of the live grep are listed under "Options".

| Option | Default | Meaning |
|---|---|---|
| `quarry-grep-case` | `smart` | Case rule a new search starts with: `smart`, `sensitive` or `insensitive`. |
| `quarry-grep-context-before` | `0` | Lines shown before each hit that a new search starts with, at most 1000. |
| `quarry-grep-context-after` | `0` | Lines shown after each hit that a new search starts with, at most 1000. |
| `quarry-grep-max-lines` | `50000` | The search stops when this many hits are found, and the last line says so. |
| `quarry-grep-replace-max-lines` | `100000` | The largest line limit that `C-c C-c` of a replace preview offers to search with. |
| `quarry-grep-max-columns` | `500` | Longer lines are shown cut after this many characters. |
| `quarry-grep-buffer-name` | `*quarry-grep*` | Name of the result buffer. |
| `quarry-grep-highlight-include-filters` | `t` | Highlight the matches of the `+ line` filters other than the primary one. |
| `quarry-grep-highlight-path-filters` | `t` | Highlight in file headings what the `+ path` filters matched. |
| `quarry-include-hidden` | `t` | A new search includes hidden files; `H` switches it per search. |
| `quarry-ignores` | `nil` | Extra gitignore-syntax patterns, relative to the searched directory. |

Faces: `quarry-grep-match`, `quarry-grep-match-secondary`,
`quarry-grep-path-match`, `quarry-grep-file-heading`,
`quarry-grep-line-number`, `quarry-grep-context`,
`quarry-grep-filter-include`,
`quarry-grep-filter-exclude`, `quarry-grep-filter-kind`,
`quarry-grep-filter-pattern`, `quarry-grep-filter-disabled`,
`quarry-grep-status`, `quarry-grep-error`, `quarry-grep-header-value`,
`quarry-grep-replace-old`, `quarry-grep-replace-new`,
`quarry-grep-replace-applied` and `quarry-grep-replace-rejected`.

### Limits

- Local directories only. In a remote (TRAMP) directory the commands
  signal an error; use rg.el there.
- Regexps are Rust regexps (the `regex` crate, as in ripgrep's default
  engine): no backreferences and no look-around. Emacs regexp syntax does
  not apply; a group is `(...)`, not `\(...\)`.
- In line filters `\A`, `\z` and `(?-m)` are not supported: a pattern is
  matched line by line, so use `^` and `$`.
- Matches are single lines; a pattern cannot match across a line end.
- In files with `\r\n` line ends the `\r` is not part of the line: it is
  not shown, and `$` matches before it. Files are read as UTF-8; a
  UTF-16 file is searched when it starts with a byte order mark.
- Symbolic links are not searched, neither to files nor to directories,
  so a file is found once, under its real path. Version control
  directories (`.git`, `.hg`, `.svn`, `.jj`) are never searched, and files
  with a NUL byte are skipped as binary.
- The search stops at `quarry-grep-max-lines` hits; narrow the search
  or raise the option to see more.
- `~/.ripgreprc`, PCRE2 and compressed files are not supported.
- The result buffer is not a `compilation-mode` buffer
  (`docs/decisions/0012`), so commands made for those, such as
  `grep-edit-mode`, do not work in it; results are edited through wgrep
  (`docs/decisions/0013`).

## Options

The options of the file finder and of the live grep; those of the grep
tool are listed under "Grep". Customize group `quarry`. For the file
finder, `quarry-include-hidden` and `quarry-ignores` apply to instances
started afterwards; run `quarry-stop` to restart a project's instance.
The other options apply at once.

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
| `quarry-consult-grep-max-lines` | `1000` | Number of hits a live grep collects before it stops (see "Live grep"). |
| `quarry-consult-grep-input-debounce` | `0.05` | Seconds without typing before the live grep searches. |
| `quarry-consult-grep-input-throttle` | `0.1` | Minimum seconds between two searches of the live grep. |

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

`bench/run-bench.sh replace` measures grep's replace instead: it builds
the release module, generates trees of 1,000 and 10,000 files with 5
matched lines each and one of 1,000 files with 100 matched lines each
(100,000 matches), and
times the preview and the writing, twice each. Every file is compared
with the expected content afterwards; the script exits non-zero when
one differs. The trees go to a temporary directory under
`$QUARRY_BENCH_TMP`, `$TMPDIR` or `/tmp` and are removed. The numbers
are in `docs/architecture/grep.md`, "Cost of large change sets".

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
would shadow edits. When `doom sync` rebuilds the package it also runs
cargo; that is incremental and does nothing when no Rust changed. A
change in the checkout alone does not make `doom sync` rebuild it: after
new files were added to `lisp/` (2026-10-10, Emacs 31.1), `doom sync`
left the old symlinks in place, and Emacs failed at startup with
"Cannot open load file ... quarry-core". Removing the package's build
directory first makes the next `doom sync` rebuild it.

| Change | Do | Takes effect |
|---|---|---|
| Elisp in `lisp/` | `eval-buffer`, or restart | at once, no `doom sync` |
| Rust in `src/` | `M-x quarry-build-module` | after restarting Emacs |
| New file in `lisp/` | remove `.local/straight/build-<version>/quarry` in the Doom directory, then `doom sync`; do this before restarting Emacs | the build directory gets the symlink, and the module is rebuilt |
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
bench/run-bench.sh replace   # grep replace benchmark; checks every file
QUARRY_TEST_LOAD_PATH=~/.emacs.d/straight/build/consult:~/.emacs.d/straight/build/compat tests/run-ert.sh
```

The grep tests (`tests/quarry-grep-tests.el`) need nothing extra. The
tests of editing grep results (`tests/quarry-grep-wgrep-tests.el`) need
wgrep: add its directory to `QUARRY_TEST_LOAD_PATH` as well. Without it
the script says so and those tests are skipped, except the one for the
refusals of `e`. The
consult front end tests (`tests/quarry-consult-tests.el`) and the live
grep tests (`tests/quarry-consult-grep-tests.el`) need consult
(2.0 or later for the file finder; the live grep is tested with 3.7)
and its dependency compat. `QUARRY_TEST_LOAD_PATH`
is a colon-separated list of directories that the script adds to
`load-path`; put the directories of consult and compat there. Without it,
or when consult cannot be loaded from it, the script says so and skips
the tests that need consult (the command and end-to-end tests of the
file finder; of the live grep, the tests that call consult, among
them those that open its prompt and the hand-over to the result
buffer); the tests of the async steps,
of the live grep's input syntax and of its commands' directory logic,
the test of loading without consult and the rest of the suite run as
usual. Rerun them after
upgrading consult.

Set `EMACS` to use another Emacs binary.

CI (`.github/workflows/ci.yml`) runs on every pull request and on
`master`: `cargo fmt --all -- --check`, `cargo clippy --all-targets -- -D
warnings` and `cargo test` on Linux, `cargo check` with the minimum
supported Rust, and `tests/run-ert.sh` on Linux and macOS with Emacs 30.1
and 31.1, with consult and wgrep installed from GNU ELPA and NonGNU ELPA.
`master` takes changes only through pull requests.

## Documentation

- `docs/architecture.md` and `docs/architecture/`: how the system is built now.
- `docs/specs/`: specifications; `docs/decisions/`: decision records.
- `docs/backlog.md` and `docs/next-steps.md`: open points and what comes next.

## Licence

The Rust code (`src/`) is licensed under either MIT (`LICENSE-MIT`) or
Apache-2.0 (`LICENSE-APACHE`), at your option. The Emacs Lisp files in
`lisp/`, `tests/` and `bench/` are licensed under GPL-3.0-or-later
(`LICENSE-GPL`).
