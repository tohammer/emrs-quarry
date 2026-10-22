# quarry

A fast project file finder and an interactive grep for Emacs, both backed
by one Rust module.

- **File finder:** `project-find-file` from a live index of each
  project's files, kept up to date by a file watcher and ranked with
  [nucleo](https://github.com/helix-editor/nucleo), so it stays fast on
  repositories with a million files.
- **Grep:** `quarry-grep` searches in the module and shows the hits in a
  buffer where you narrow the search with filters, add context lines,
  edit the results and replace across files, in the manner of
  [rg.el](https://github.com/dajva/rg.el). ripgrep need not be installed.
- **Live grep:** with consult, `quarry-consult-grep` searches while you
  type, in the manner of `consult-ripgrep`.

The tools work independently of each other. quarry runs on
[emrs](https://github.com/tohammer/emrs), which runs the Rust side
outside the Emacs thread.

## Status

Version 0.1.0, built and used on Linux with Emacs 31.1 in Doom Emacs.
Each release has a prebuilt module for Linux and Apple-silicon Macs,
which emrs's installer downloads; elsewhere, and for `master`, it builds
the module with cargo.

| Platform or variant | Status |
|---|---|
| Linux | tested |
| macOS | ERT suite in CI only; file watching not used by hand |
| Windows | untested; no prebuilt module |
| Prebuilt module for Linux x86-64 and aarch64, macOS aarch64, downloaded by emrs's installer | ERT suite in the release workflow; the download itself checked by hand in batch Emacs on Linux, not in a Doom setup; macOS untested |
| Emacs 31.1 | tested |
| Emacs 30.1 | ERT suite in CI only |
| Doom Emacs recipe | tested |
| straight.el, elpaca, package-vc | untested |
| Grep in a terminal frame | tested |
| Grep in a GUI frame, its faces in any theme | untested |
| Replace (`R`) | ERT suite and benchmark only |
| Live grep | consult 3.7 only |

## Quick start

Requirements:

- Linux, Emacs 30.1 or later built with module support.
- Rust 1.88 or later, with `cargo` on `PATH` and network access, only if
  the module is built on your machine: for a checkout of `master` (the
  recipe below) or a platform without a release file. To download the
  module of a release instead, see [Installation](#installation).
- Doom Emacs. For other package managers see
  [Installation](#installation).

1. Add to `packages.el`:

   ```elisp
   (package! emrs
     :recipe (:host github :repo "tohammer/emrs" :files ("elisp/*.el")))
   (package! quarry
     :recipe (:host github :repo "tohammer/emrs-quarry" :files ("lisp/*.el")))
   ```

2. Add to `config.el`:

   ```elisp
   (use-package! quarry
     :hook (doom-first-input . quarry-mode))
   (map! :leader :desc "Find file in project" "p f" #'project-find-file)
   ```

3. Run `doom sync`, which clones both packages, then restart Emacs.
4. In a project, press `SPC p f` (`C-c p f` without evil). The first use
   asks `Build the quarry module 0.2.0-snapshot with cargo?` (answer `y`;
   the build runs in the buffer `*emrs-install quarry*`) and says to run
   the command again when the build is done. Then type part of a file
   name.
5. Optional: run `M-x quarry-status` to see the index:

   ```text
   quarry: ~/src/myproject/: 83 files, indexing no, watching yes, 1 walks, 0 skipped
   ```

For grep, run `M-x quarry-grep-project`; see the
[grep guide](docs/user/grep.md).

## Installation

You install two packages: `emrs`, the Elisp side of the runtime, which
includes the installer `emrs-install.el`, and `quarry`, whose repository
also holds the Rust source. Install `emrs` from its default branch, and
update it whenever you update quarry.

The module comes from the installer ([ADR 0027](docs/decisions/0027-module-comes-from-emrs-install.md)).
On the first command that needs it, it uses, in this order:

1. The module installed for the version of quarry's Elisp, under
   `emrs/modules/quarry/<version>/` in `user-emacs-directory`, or else
   `quarry-module` plus `module-file-suffix` on `load-path`.
2. For a released version (plain `X.Y.Z`), the file
   `quarry-module-<platform><suffix>` of the
   [release](https://github.com/tohammer/emrs-quarry/releases), after
   asking, checked against the release's `SHA256SUMS`. Releases cover the
   platforms in [Limitations](#limitations).
3. For a `-snapshot` version, which is what `master` has, a
   `cargo build --release` in quarry's checkout, after asking `Build the
   quarry module <version> with cargo?`. The command that started the
   build has to be run again when it is done.

A local build older than its sources, for example after `doom sync -u`
pulled changes, is offered again by a new Emacs: `The quarry module is
older than its sources.  Rebuild it now with cargo?`. Emacs cannot unload
a module, so restart it to use a new one.

`M-x emrs-install-module` installs the module again (`C-u` builds it),
`M-x emrs-install-build` builds it and `M-x emrs-install-clean` deletes
installed versions that are no longer used. The options
`emrs-install-download` (`ask`, `always` or `never`),
`emrs-install-directory`, `emrs-install-timeout` and
`emrs-install-cargo-program` belong to emrs; see its
[installer reference](https://github.com/tohammer/emrs/blob/master/docs/user/distributing.md#installer-reference).

**Without Rust.** A recipe that follows `master` always builds. To get
the download, pin quarry to the commit of a release tag, here `v0.2.0`;
the Elisp and the module of a release have the same version. emrs needs
no pin. Update the pin to move to a newer release.

- Doom: add `:pin "<commit>"` to the `package!` form of quarry, where
  `<commit>` is the first field of
  `git ls-remote https://github.com/tohammer/emrs-quarry refs/tags/v0.2.0`.
  Then run `doom sync`.
- straight.el without Doom (untested): check out the tag in
  `straight/repos/emrs-quarry/` and run `M-x straight-freeze-versions`
  to keep it.
- elpaca (untested): add `:tag "v0.2.0"` to the recipe.
- package-vc (untested): pass the tag as the second argument,
  `(package-vc-install '(quarry :url "https://github.com/tohammer/emrs-quarry" :lisp-dir "lisp") "v0.2.0")`.
- Manual installation: `git checkout v0.2.0` in the clone.

(v0.1.0 predates the installer: its README describes how to place the
module by hand. Tags from v0.2.0 on work as described here.)

### Doom Emacs

Use the recipes and configuration of the [Quick start](#quick-start).

Doom binds `SPC p f` to `projectile-find-file` and `C-x p` to its own
popup, so `project-find-file` has no key; the `map!` form gives it one
for `quarry-mode` to remap.

After `doom sync -u` has pulled changes of quarry, the first command
in a new Emacs offers to rebuild the module. If cargo is missing or the
build fails, the message or the buffer `*emrs-install quarry*` says why.

Optional: to use the consult prompt for `SPC p f`, add to the
`use-package!` form:

```elisp
:custom (quarry-find-file-command 'quarry-consult-find-file)
```

### straight.el (untested)

```elisp
(straight-use-package
 '(emrs :host github :repo "tohammer/emrs" :files ("elisp/*.el")))
(straight-use-package
 '(quarry :host github :repo "tohammer/emrs-quarry" :files ("lisp/*.el")))
(quarry-mode 1)
```

### elpaca (untested)

1. Install the packages and enable the mode once they are there:

   ```elisp
   (elpaca (emrs :host github :repo "tohammer/emrs" :files ("elisp/*.el")))
   (use-package quarry
     :ensure (:host github :repo "tohammer/emrs-quarry" :files ("lisp/*.el"))
     :config (quarry-mode 1))
   ```

2. Restart Emacs. The first command gets the module (see above).

### package-vc (untested)

1. Install the packages:

   ```elisp
   (package-vc-install '(emrs :url "https://github.com/tohammer/emrs"
                              :lisp-dir "elisp"))
   (package-vc-install '(quarry :url "https://github.com/tohammer/emrs-quarry"
                                :lisp-dir "lisp"))
   ```

2. Add `(quarry-mode 1)` to your init file.
3. Restart Emacs. The first command gets the module (see above).

### Manual installation

For a setup without a package manager.

1. Clone this repository and [emrs](https://github.com/tohammer/emrs).
   For a downloaded module, check out a release tag in the quarry clone.
2. Put quarry's `lisp/` and emrs's `elisp/` on `load-path` and enable
   the mode. The installer gets the module on first use, building in the
   quarry clone for a `-snapshot` version:

   ```elisp
   (use-package quarry
     :load-path ("~/src/quarry/lisp" "~/src/emrs/elisp")
     :config (quarry-mode 1))
   ```

### Place the module by hand

For a machine where Emacs cannot download, for example without network
access. Download the file for your platform and `SHA256SUMS` from the
[release](https://github.com/tohammer/emrs-quarry/releases) that matches
your quarry, and check it in the download directory. `<file>` is its
name, such as `quarry-module-linux-x86_64.so`. On Linux:

```sh
grep '<file>' SHA256SUMS | sha256sum --check
```

On macOS:

```sh
grep '<file>' SHA256SUMS | shasum -a 256 --check
```

It prints `<file>: OK`. Rename the file to `quarry-module.so` (macOS:
`quarry-module.dylib`), put it in a directory on `load-path` and restart
Emacs. To update, replace the file. The installer prefers a module it
installed for the same version under `emrs-install-directory`; delete
that one if you place the file by hand.

Alternatively set `emrs-install-download` to `never` to stop the download offers,
or build it yourself: `cargo build --release` in the clone and copy
`target/release/libquarry.so` (macOS: `libquarry.dylib`) the same way.

### Check the installation

Run `M-x quarry-status` in a project. It shows the project root and its
file count. If the module is missing, the installer asks as described
under [Installation](#installation).

## Find files

`quarry-mode` remaps `project-find-file` to `quarry-find-file`, so the
keys of `project-find-file` (`C-x p f` in plain Emacs) open quarry's
prompt.

| Command | Action |
|---|---|
| `quarry-find-file` | Visit a file of the current project, chosen from the index. With a prefix argument, run `project-find-file`, which also offers ignored files. |
| `quarry-consult-find-file` | The same in a consult prompt that queries the index while you type. Needs consult 2.0 or later. |
| `quarry-find-file-in-directory` | Visit a file below `default-directory`, or with a prefix argument below a directory it asks for. |
| `quarry-consult-find-file-in-directory` | The same in a consult prompt. Needs consult 2.0 or later. |
| `quarry-mode` | Global minor mode: remaps `project-find-file` to `quarry-find-file-command`. |
| `quarry-status` | Show the root, file count, whether it is indexing or watching, the number of walks and of skipped paths. |
| `quarry-rescan` | Walk the current project again and report the file count. |
| `quarry-stop` | Stop the current project's index; the next command starts a new one with the current options. |
| `quarry-stop-all` | Stop all indexes. |

Each project gets its index on first use. While the first walk runs,
the prompt offers the files found so far; the consult prompt fills as
the walk goes on. In remote (TRAMP) projects `quarry-find-file` runs
`project-find-file`.

### Query syntax

The query is matched against the path relative to the project root:

| Syntax | Matches |
|---|---|
| `foo bar` | Paths that match every term, in any order |
| `foo` | Fuzzy: `f`, `o`, `o` in this order, gaps allowed |
| `'foo` | The substring `foo` |
| `^foo` | Paths that start with `foo` |
| `foo$` | Paths that end with `foo` |
| `!foo` | Paths that do not contain `foo` |
| `foo\ bar` | A literal space in a term |
| `\!foo`, `\^foo`, `\'foo`, `foo\$` | A literal `!`, `^`, `'` or `$` |

With `(setq quarry-match-style 'substring)`, `foo` matches the substring
and `'foo` matches fuzzy, like fzf's `--exact`. Then `'` makes the rest
of the term use the fuzzy style's syntax: `'foo$` is a fuzzy suffix.

Case is smart: a term in lower case matches any case, a term with an
upper-case letter matches that case only. Results are ordered by score,
then by shorter path, then alphabetically. Each term's matched
characters get a face of their own (`quarry-match-0` to
`quarry-match-3`, in turn).

Your `completion-styles` (orderless, flex, ...) do not apply inside
quarry's prompts; other prompts are unaffected. In the default
completion UI, `TAB` completes the input when exactly one file matches,
and `RET` on input that matches exactly one file visits it.

### consult prompt

`quarry-consult-find-file` opens at once and queries the index on every
input without blocking Emacs. To make `quarry-mode` use it:

```elisp
(setq quarry-find-file-command 'quarry-consult-find-file)
```

It differs from `quarry-find-file`:

- You must choose a candidate; a path that is not in the index cannot
  be visited.
- With consult's default split style `perl`, the input `#query#filter`
  sends `query` to the index and filters the results with your
  completion styles. With `consult-async-split-style` set to `none`, the
  whole input is the query.
- Its history is `quarry-consult-history`.

### Files below a directory

`quarry-find-file-in-directory` and
`quarry-consult-find-file-in-directory` work like Doom's
`+default/find-file-under-here` or `consult-fd`, with quarry's matcher.
Candidates are relative to the directory; the query syntax is the same.

- A directory inside the current project is answered from the project's
  index.
- Any other local directory, such as `node_modules/` or one outside every
  project, is walked once for the prompt, following the rules of
  [What is indexed](#what-is-indexed). Large directories such as `~` take
  seconds. `C-g` ends the walk.

The plain prompt waits up to a second for the first files and then shows
what was found by then. The consult prompt fills as the walk goes on.

To use the commands for `SPC f F` in Doom, add to `config.el` one of:

```elisp
(map! [remap +default/find-file-under-here] #'quarry-find-file-in-directory)
(map! [remap +default/find-file-under-here] #'quarry-consult-find-file-in-directory)
```

### With Projectile or the project switcher

`quarry-mode` remaps keys only. Commands that call `project-find-file`
by name, such as the `project-switch-project` menu, still run it; add
`quarry-find-file` to `project-switch-commands` to have it there.

quarry takes the project root from project.el. With Projectile:

- Remap `projectile-find-file` to `quarry-find-file`.
- Set `projectile-switch-project-action` to `quarry-find-file`, or in
  Doom with the workspaces module, `+workspaces-switch-project-function`.

### Other project commands

With `(setq quarry-provide-project-files t)` and `quarry-mode` on,
`project-files` is answered from the index instead of `git ls-files` or
`find`. This speeds up commands built on it, such as
`project-find-regexp`. It applies to local projects whose index is
running, for the whole project root; otherwise, and after
`quarry-files-timeout` seconds, the normal method runs.

For your own front end, `quarry-query` and `quarry-query-async` return a
project's ranked paths; see their docstrings.

### What is indexed

Regular files and symbolic links to files below the project root.
Compared with `project-files`:

- Untracked files that are not ignored are included, regardless of
  `project-vc-include-untracked`.
- `project-vc-ignores` does not apply; use `quarry-ignores`.
- `.gitignore`, `.ignore`, `.git/info/exclude` and your global git
  excludes apply, also outside git repositories and from directories
  above the root.
- `.git`, `.hg`, `.svn` and `.jj` are never walked.
- Symbolic links to directories are not followed.
- Hidden files are included unless `quarry-include-hidden` is nil.
- File names that are not valid UTF-8 and unreadable directories are
  skipped; `quarry-status` counts them.

Created, deleted and renamed files show up in the next query, about
100 ms after the change. A changed ignore file makes quarry walk the
project again in the background.

### Speed

`bench/run-bench.sh` (see [CONTRIBUTING.md](CONTRIBUTING.md#benchmarks))
types about 100 query prefixes with a limit of 100 into generated
AOSP-like trees. Measured on 2026-10-09 on an Intel Core i5-8365U
(4 cores, about 1.1 GHz under the powersave governor), Emacs 31.0.50:

| Files | quarry p99 | `project-files` + `flex` p99 | Indexing | Memory after indexing |
|---|---|---|---|---|
| 100,000 | 33.5 ms | 307 ms, plus 413 ms listing per prompt | 0.7 s (warm cache) | +34 MB |
| 1,000,000 | 177 ms | 3.5 s, plus 8.3 s listing per prompt | 4.5 s | +250 MB |

The comparison returns every match unranked and treats `^`, `$`, `!`
and spaces literally.

## Grep

| Command | Searches |
|---|---|
| `quarry-grep` | A directory it asks for, with a regexp |
| `quarry-grep-literal` | A directory it asks for, with a literal string |
| `quarry-grep-project` | The project root, with a regexp |
| `quarry-grep-dwim` | The project root, for the symbol at point, in files of the current buffer's type |
| `quarry-consult-grep` | `default-directory`, while you type; needs consult |
| `quarry-consult-grep-project` | The project root, while you type; needs consult |

The first four show the hits in the buffer `*quarry-grep*`; press `?`
there for a menu of its keys. They work without `quarry-mode` and do not
use the file index.

- [Grep guide](docs/user/grep.md): the result buffer, filters, context
  lines, editing with wgrep, replacing across files, options and limits.
  Large replacements are covered in
  [Large replacements](docs/user/grep.md#large-replacements).
- [Live grep guide](docs/user/live-grep.md): the consult commands, their
  input syntax and [options](docs/user/live-grep.md#options), and Doom
  key bindings.

## Configuration

Set options with `setq` or `M-x customize-group RET quarry`. The grep
options are in the group `quarry-grep` and listed in the
[grep guide](docs/user/grep.md#options); the live grep options in the
[live grep guide](docs/user/live-grep.md#user-options).

`quarry-include-hidden` and `quarry-ignores` apply to indexes started
afterwards; run `quarry-stop` to restart one. The other options apply at
once.

| Option | Default | Description |
|---|---|---|
| `quarry-find-file-command` | `quarry-find-file` | Command `quarry-mode` runs in place of `project-find-file`: `quarry-find-file` or `quarry-consult-find-file`. |
| `quarry-include-hidden` | `t` | Index hidden files. Also the default of grep's hidden switch. |
| `quarry-ignores` | `nil` | Extra gitignore-style patterns, relative to the project root (for grep, to the searched directory). A `!` pattern cannot re-include a file that a `.gitignore` hides. |
| `quarry-match-style` | `fuzzy` | How plain terms match: `fuzzy` or `substring`. |
| `quarry-limit` | `200` | Candidates per query, 1 to 10,000. |
| `quarry-highlight` | `t` | Highlight matched characters in candidates. |
| `quarry-match-faces` | `(quarry-match-0 quarry-match-1 quarry-match-2 quarry-match-3)` | Faces for matched characters, one per term in turn. `(completions-common-part)` highlights all terms alike. |
| `quarry-query-timeout` | `10.0` | Seconds before a query gives up. |
| `quarry-provide-project-files` | `nil` | With `quarry-mode`, answer `project-files` from the index. |
| `quarry-files-timeout` | `10.0` | Seconds `project-files` waits for the index before it falls back. |
| `quarry-consult-input-debounce` | `0.05` | Seconds without typing before the consult prompt queries. |
| `quarry-consult-input-throttle` | `0.1` | Minimum seconds between two queries of the consult prompt. |
| `quarry-consult-refresh-interval` | `0.25` | Seconds between queries of the consult prompt while the project is being indexed. |

## Limitations

- Release files only for Linux (x86-64, aarch64, glibc 2.28 or later)
  and Apple-silicon Macs; elsewhere, and for `master`, you need a Rust
  toolchain.
- Local files only. In remote (TRAMP) projects `quarry-find-file` runs
  `project-find-file`; the directory and grep commands refuse. Use
  `project-find-file` and rg.el there.
- The consult commands use consult internals; a consult upgrade can
  break them until quarry is updated. `quarry-find-file` and
  `quarry-grep` do not depend on consult.
- File contents are not indexed; only names are.
- On Linux, file watching needs one inotify watch per directory (see
  [Troubleshooting](#troubleshooting)).

## Troubleshooting

### `No quarry module ... available for ...`

The installer found no module and could not get one. The message lists
what it tried: nothing installed, no release file for this version or
platform (a `-snapshot` version has none), and the build declined or no
checkout with `Cargo.toml`. Run `M-x emrs-install-module`, or place the
file by hand ([Place the module by hand](#place-the-module-by-hand)).

### `Building the quarry module; run the command again when it is done`

The build runs in the buffer `*emrs-install quarry*`. Run the command
again when it has finished. If cargo is not on Emacs's `PATH` (`Program
'cargo' not found`), set `emrs-install-cargo-program` to its full path.
If the build fails, the buffer shows cargo's output.

### `void-function emrs-...`

`emrs.el` is older than quarry. Update the `emrs` package (`doom sync
-u`) and restart Emacs. Its recipe must list `elisp/*.el`, since the
installer is a second file.

### A feature does nothing after an update

The module is older than the Elisp. Run `M-x emrs-install-module` and
restart Emacs; with a recipe that follows `master`, `C-u M-x
emrs-install-module` builds it. An old module ignores context counts and
replace templates, refuses globs with `/` and excluded file types, and
`quarry-grep` says `The loaded quarry module is older than quarry-grep
...; install it again with M-x emrs-install-module and restart Emacs`
when it notices. A module built from an older `-snapshot` checkout has
the same version as the Elisp, so the installer's own warning (`The
quarry module reports version ... but ... is registered`) does not
appear; that is why quarry-grep checks.

### `Cannot load the quarry module from ...`

The file is for another platform, or on Linux your glibc is older than
2.28 (`ldd --version` shows it); the message names the platform. Build
the module instead: `C-u M-x emrs-install-module`.

On macOS, a file placed by hand after a browser download carries a
quarantine attribute. Whether that stops Emacs from loading it is
untested; if it does, remove the attribute and restart Emacs:

```sh
xattr -d com.apple.quarantine quarry-module.dylib
```

### `Checksum mismatch for ...`

The download does not match `SHA256SUMS`; nothing was installed. Try
again with `M-x emrs-install-module`.

### `File watching for ... failed`

The inotify watch limit, shared by all programs of your user, is
reached. A tree the size of AOSP needs about 150,000 watches. quarry
keeps working and walks the project again before each prompt.

1. Raise the limit until the next reboot:

   ```sh
   sudo sysctl fs.inotify.max_user_watches=524288
   ```

2. Optional: make it permanent:

   ```sh
   echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/90-inotify.conf
   sudo sysctl --system
   ```

3. Run `M-x quarry-stop-all`.

### The first command fails with an invalid pattern

A pattern in `quarry-ignores` is not valid gitignore syntax; the message
names it. Fix or remove it, then run the command again.

## Development

Building from a checkout, the Doom development setup, tests, CI and
benchmarks: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

The Rust code (`src/`) is licensed under either MIT (`LICENSE-MIT`) or
Apache-2.0 (`LICENSE-APACHE`), at your option. The Emacs Lisp files in
`lisp/`, `tests/` and `bench/` are licensed under GPL-3.0-or-later
(`LICENSE-GPL`).
