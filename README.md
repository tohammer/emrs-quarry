# projdex

A fast project file finder for Emacs. A Rust module keeps a live index of
each project's files, updated by a file watcher, and answers fuzzy queries
from it with [nucleo](https://github.com/helix-editor/nucleo) ranking, so
`project-find-file` stays fast on large repositories.

projdex is built on [emrs](https://github.com/tohammer/emrs), which runs the
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
  `projdex-build-cargo-program`), to build the module.
- Network access for cargo's first dependency fetch.
- Git credentials for the repositories `tohammer/emrs-projdex` and
  `tohammer/emrs`, which are private; the recipes use the default protocol.
- Linux for anything you want to rely on (see Status).

## Installation

projdex needs two packages: `emrs` (the Elisp side of the runtime) and
`projdex`, whose repository also holds the Rust source. The module is built
on your machine with cargo and installed as `lisp/projdex-module` plus
`module-file-suffix` inside projdex's repository, where projdex finds it
(`docs/decisions/0006`). `emrs` follows the default branch of its
repository and is not pinned (`docs/decisions/0007`).

### Doom Emacs

In `packages.el`:

```elisp
(package! emrs
  :recipe (:host github :repo "tohammer/emrs" :files ("elisp/emrs.el")))
(package! projdex
  :recipe (:host github :repo "tohammer/emrs-projdex" :files ("lisp/*.el")
           :pre-build ((load (expand-file-name "lisp/projdex-build.el") nil t)
                       (projdex-build-module-sync))))
```

In `config.el`:

```elisp
(use-package! projdex
  :hook (doom-first-input . projdex-mode))
```

`doom sync` clones both repositories, and the `:pre-build` form runs
`cargo build --release` in projdex's checkout. straight runs it whenever it
rebuilds the package, so `doom sync -u` rebuilds the module when projdex
changed. A rebuilt module is used after restarting Emacs; emrs warns when
the module file it loaded has changed.

`projdex-build-module-sync` never signals. Without a Rust toolchain, or if
the build fails, `doom sync` still completes with a warning and the output
in the buffer `*projdex-build*`. The first projdex command then asks
"projdex module not built. Build it now with cargo?"; you can also run
`M-x projdex-build-module` at any time.

### straight.el without Doom

Use the same two recipes with `straight-use-package`, then enable the mode:

```elisp
(straight-use-package
 '(emrs :host github :repo "tohammer/emrs" :files ("elisp/emrs.el")))
(straight-use-package
 '(projdex :host github :repo "tohammer/emrs-projdex" :files ("lisp/*.el")
           :pre-build ((load (expand-file-name "lisp/projdex-build.el") nil t)
                       (projdex-build-module-sync))))
(projdex-mode 1)
```

Untested.

### elpaca

Use the recipes with `:host`, `:repo` and `:files` only, with no
`:pre-build`. Run `M-x projdex-build-module` once after installing and after
each update, then restart Emacs. Untested.

```elisp
(elpaca (emrs :host github :repo "tohammer/emrs" :files ("elisp/emrs.el")))
(elpaca (projdex :host github :repo "tohammer/emrs-projdex" :files ("lisp/*.el")))
```

### package-vc

```elisp
(package-vc-install '(emrs :url "https://github.com/tohammer/emrs"
                           :lisp-dir "elisp"))
(package-vc-install '(projdex :url "https://github.com/tohammer/emrs-projdex"
                              :lisp-dir "lisp"))
```

Then run `M-x projdex-build-module` and restart Emacs; repeat the command
after updates. Untested.

For package-vc, enable the mode with `(projdex-mode 1)` or a `use-package`
form with `:config (projdex-mode 1)`. elpaca installs asynchronously, so
enable it once the package is there: `(use-package projdex :ensure (...)
:config (projdex-mode 1))` with the recipe as `:ensure` value, or
`(projdex-mode 1)` in `elpaca-after-init-hook`.

### Where projdex looks for the module

First `lisp/projdex-module` plus `module-file-suffix` in the repository that
holds the real `projdex.el` (symlinks are resolved), then `projdex-module`
on `load-path`. If neither exists, the first command offers to build (see
Doom Emacs above) or, in batch mode or without a repository, signals an
error that names `M-x projdex-build-module` and the manual installation.
If cargo is not on `PATH`, set `projdex-build-cargo-program`.

### Manual installation

This also works as a fallback, for example without a package manager or
with a copy of `projdex.el` that is not inside its repository.

1. Build the module. When `projdex.el` is loaded from the checkout,
   `M-x projdex-build-module` does this and installs the module in
   `lisp/`; skip step 2. Otherwise:

   ```sh
   cargo build --release
   ```

2. Copy the library to a directory on `load-path`, named `projdex-module`
   plus Emacs's `module-file-suffix`:

   ```sh
   cp target/release/libprojdex.so ~/.emacs.d/projdex/projdex-module.so      # Linux
   cp target/release/libprojdex.dylib ~/.emacs.d/projdex/projdex-module.dylib # macOS
   ```

3. Put `lisp/projdex.el`, `lisp/projdex-build.el` and `emrs.el` on
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
   (use-package projdex
     :load-path ("~/.emacs.d/projdex" "~/src/emrs/elisp" "~/src/projdex/lisp")
     :config (projdex-mode 1))
   ```

   or, without `use-package`:

   ```elisp
   (add-to-list 'load-path "~/.emacs.d/projdex")
   (require 'projdex)
   (projdex-mode 1)
   ```

If the module is not found, the first command signals an error that says
where it must be installed. An invalid pattern in `projdex-ignores` also
makes the first command fail, with the pattern in the message.

For other front ends, `projdex-query` and `projdex-query-async` return the
ranked paths of a project directly (see their docstrings).

## Usage

| Command | What it does |
|---|---|
| `projdex-find-file` | Visit a file of the current project, chosen from the index. Starts the project's instance on first use. |
| `projdex-mode` | Global minor mode. Remaps `project-find-file` to `projdex-find-file`; with `projdex-provide-project-files` set, it also serves `project-files` from the index. |
| `projdex-rescan` | Walk the current project again and report the file count when done. |
| `projdex-stop` | Stop the current project's instance. The next command starts a new one with the current options. |
| `projdex-stop-all` | Stop all instances. |
| `projdex-status` | Show root, file count, whether it is indexing or watching, number of walks and skipped paths in the echo area. |

`projdex-find-file` falls back to `project-find-file` with a prefix argument
(which asks for ignored files too) and in remote (TRAMP) projects. With
`projdex-mode` the same applies to `project-find-file`, since it is
remapped to `projdex-find-file`.

One instance runs per project root, started lazily on first use. While the
first walk runs, queries answer from the files seen so far.

`projdex-provide-project-files`: when non-nil and `projdex-mode` is on,
`project-files` is answered from the index instead of `git ls-files` or
`find`. This speeds up commands built on `project-files`, such as
`project-find-regexp`. It serves only local projects that already have a
running instance and only calls for the whole project root; otherwise, and
when the index does not answer within `projdex-files-timeout`, the normal
method runs. It does not speed up `project-find-file` itself, which projdex
replaces instead (`docs/decisions/0001`).

### Query syntax

The query is nucleo's pattern syntax, matched against the path relative to
the project root:

| Syntax | Meaning |
|---|---|
| `foo bar` | Space-separated terms, all must match, in any order |
| `foo` | Fuzzy: `f`, `o`, `o` in this order, gaps allowed (with `projdex-match-style` `substring`: the substring `foo`) |
| `'foo` | The substring `foo` (with `projdex-match-style` `substring`: fuzzy) |
| `^foo` | Prefix |
| `foo$` | Suffix |
| `!foo` | Does not contain `foo` |
| `foo\ bar` | A literal space in a term |
| `\!foo`, `\^foo`, `\'foo`, `foo\$` | A literal `!`, `^`, `'` or `$` |

So by default `act man` also matches `a/c/t/m/a/n`-like paths, ranked
below contiguous matches, and `'act 'man` only paths containing `act`
and `man`. With `(setq projdex-match-style 'substring)` the two swap,
similar to fzf's `--exact` mode: `'` then means "the rest of this term in
the fuzzy style's syntax", so `'foo$` is a fuzzy suffix and `'!foo`
excludes `foo` (`docs/decisions/0004`).

Case is smart: all lower case matches any case, an upper-case letter
matches that case only. Results are ordered by score, then shorter path,
then alphabetically. Matched characters are highlighted, each term in its
own colour (faces `projdex-match-0` to `projdex-match-3`, used in turn).

projdex ranks in Rust and passes the result through a completion style also
called `projdex`, bound only for the duration of its own prompt. Your
`completion-styles` (orderless, flex, ...) do not apply inside projdex
prompts and other prompts are unaffected (`docs/decisions/0002`). In the
default completion UI, TAB completes the input when exactly one file
matches, and RET on input that matches exactly one file visits that file.

`projdex-mode` remaps the key bindings of `project-find-file`. Commands
that call `project-find-file` by name, such as the `project-switch-project`
menu (`project-switch-commands`), are not remapped; add
`projdex-find-file` to `project-switch-commands` if you want it there.

projdex takes the project root from project.el. With Projectile, remap
`projectile-find-file` to `projdex-find-file`, and set
`projectile-switch-project-action` to it for the file prompt after
switching projects (with Doom's workspaces module:
`+workspaces-switch-project-function`, which receives the project
directory). To use Projectile's root, wrap `projdex-find-file` in a
command that binds `project-find-functions` to return that root.

## Options

Customize group `projdex`. `projdex-include-hidden` and `projdex-ignores`
apply to instances started afterwards; run `projdex-stop` to restart a
project's instance. The other options apply at once.

| Option | Default | Meaning |
|---|---|---|
| `projdex-include-hidden` | `t` | Index hidden files. |
| `projdex-ignores` | `nil` | Extra gitignore-syntax patterns, relative to the project root. They add to the ignore files; a `!` pattern here cannot re-include a file a `.gitignore` hides. |
| `projdex-limit` | `200` | Number of candidates returned per query (the service clamps it to 1..10000). |
| `projdex-highlight` | `t` | Highlight matched characters in candidates. |
| `projdex-match-style` | `fuzzy` | How plain terms match: `fuzzy` or `substring` (see Query syntax). Applies to the next query, no restart needed. |
| `projdex-match-faces` | `(projdex-match-0 projdex-match-1 projdex-match-2 projdex-match-3)` | Faces for matched characters, one per term in turn. `(completions-common-part)` highlights all terms alike. |
| `projdex-query-timeout` | `10.0` | Seconds before a query gives up. A safety net against a stuck instance, not a latency budget. |
| `projdex-provide-project-files` | `nil` | With `projdex-mode`, serve `project-files` from the index. |
| `projdex-files-timeout` | `10.0` | Seconds `project-files` waits for the index before falling back. |

## What is indexed

Regular files below the project root and symbolic links to files, as paths
relative to the root. Rules, and how they differ from `project-files`:

- Untracked files that are not ignored are included, regardless of
  `project-vc-include-untracked`.
- `project-vc-ignores` is not honoured; use `projdex-ignores`.
- `.gitignore`, `.ignore`, `.git/info/exclude` and the user's global git
  excludes apply, also outside git repositories. Ignore files in directories
  above the root apply too.
- Directories `.git`, `.hg`, `.svn` and `.jj` are never walked.
- Symbolic links are not followed; a link to a directory is not listed.
- Hidden files are included unless `projdex-include-hidden` is nil.
- File names that are not valid UTF-8 and unreadable directories are skipped.
  `projdex-status` shows how many.

## File watching

The Rust side watches the indexed directories with `notify`, debounces
events for 100 ms and applies them to the index: created, deleted and
renamed files and directories show up in the next query. Content changes
are ignored. Changed ignore files (`.gitignore`, `.ignore`,
`.git/info/exclude`) and lost events trigger a full rescan in the
background, which replaces the index when it finishes.

On Linux this takes one inotify watch per indexed directory. The limit,
`fs.inotify.max_user_watches`, is shared by all programs of the user; it
was 65,536 on the machine projdex was developed on. A tree the size of AOSP
needs about 150,000. If
the limit is reached, projdex reports `File watching ... failed` and keeps
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

Then run `projdex-stop` (or `projdex-stop-all`) so the instance starts again
and sets up its watches.

## Performance

`bench/run-bench.sh` generates AOSP-like trees (nested directories, empty
files, committed to a temporary git repository) and, with a limit of 100,
types a fixed sequence of about 100 query prefixes through
`completion-all-completions` with the `projdex` style, timing each call. The
baseline is `project-files` of the vc backend followed by the `flex` style.

Results of 2026-10-09 on an Intel Core i5-8365U (4 cores, 8 threads, about
1.1 GHz under the powersave governor, 14 GiB RAM), Emacs 31.0.50:

| Files | projdex p99 | Baseline p99 | Baseline listing (per prompt) | Indexing | RSS after indexing |
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
the baseline, and go to `target/bench-trees` or `$PROJDEX_BENCH_DIR`. The
script exits non-zero if projdex's p99 exceeds 50 ms (100k) or 150 ms (1m).

## Development

Work in a checkout, for example `~/src/emacs-projdex`. With Doom, keep the
user recipe and add the checkout when it exists (`my/projdex-dev` is any
variable name you like):

```elisp
(defvar my/projdex-dev (file-directory-p "~/src/emacs-projdex"))
(package! projdex
  :recipe `(:host github :repo "tohammer/emrs-projdex" :files ("lisp/*.el")
            :pre-build ((load (expand-file-name "lisp/projdex-build.el") nil t)
                        (projdex-build-module-sync))
            ,@(when my/projdex-dev
                '(:local-repo "~/src/emacs-projdex" :build (:not compile)))))
```

With an absolute `:local-repo`, straight uses the checkout as the repository
and never clones or pulls it. `:build (:not compile)` leaves no `.elc` that
would shadow edits. With the switch on, any change in the checkout makes
`doom sync` rebuild the package and so run cargo; that is incremental and
does nothing when no Rust changed.

| Change | Do | Takes effect |
|---|---|---|
| Elisp in `lisp/` | `eval-buffer`, or restart | at once, no `doom sync` |
| Rust in `src/` | `M-x projdex-build-module` | after restarting Emacs |
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
```

Set `EMACS` to use another Emacs binary. There is no CI (`docs/backlog.md`),
so run the first two before merging.

## Documentation

- `docs/architecture.md`: how the system is built now.
- `docs/specs/`: specifications; `docs/decisions/`: decision records.
- `docs/backlog.md` and `docs/next-steps.md`: open points and what comes next.

## Licence

The Rust code is licensed under either MIT or Apache-2.0, at your option.
`lisp/projdex.el` is licensed under GPL-3.0-or-later.
