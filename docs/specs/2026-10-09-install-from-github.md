# Install from GitHub with a package recipe

Status: approved
Date: 2026-10-09

## Purpose

Today projdex is installed by hand: build the module, copy it onto
`load-path` under the right name, and put `projdex.el` and a matching
`emrs.el` from separate checkouts on `load-path` (README, "Installation").
Nobody but the developer can reasonably do that.

Goal: a Doom user installs projdex with two `package!` declarations, one
for emrs and one for projdex, both pointing at GitHub, and `doom sync`
leaves a working installation. straight, elpaca and package-vc users get
equivalent recipes. The developer keeps working in
`~/src/emacs-projdex` with the same recipe switched to the local
checkout, where Elisp edits apply without `doom sync`.

Success:

- On a machine with Emacs, a Rust toolchain and git credentials for the
  (private) repositories, the README's Doom recipes plus `doom sync`
  produce an Emacs where `projdex-find-file` works, without any manual
  build or copy step.
- After `doom sync -u` brings new Rust code, the module is rebuilt during
  the sync; the new module is used after a restart.
- Without a Rust toolchain, `doom sync` still completes; projdex then
  reports the missing module and offers to build it.
- In development mode, an edit to `lisp/projdex.el` takes effect after
  `eval-buffer` or a restart, without `doom sync`.

## Scope

In:

- Building the module from the package's repository: a command and a
  straight `:pre-build` entry point (ADR 0006).
- Finding the module next to the true location of `projdex.el`.
- Offering to build when the module is missing.
- emrs as its own package following emrs's default branch (ADR 0007).
- README: recipes for Doom, straight, elpaca and package-vc; the manual
  installation stays as a fallback; a development section.
- Switching the developer's Doom config to the new recipes.

Out:

- Prebuilt binaries and release artifacts (backlog "Distribution"; needs
  CI).
- MELPA or any package archive.
- Making the repositories public or renaming them. Recipes use
  `tohammer/emrs-projdex` and `tohammer/emrs` over the default protocol;
  git credentials are expected to be set up.
- Windows and macOS verification of the build (untested, as the rest of
  projdex; the code handles their library names).

## Design

### Build logic: `lisp/projdex-build.el`

A small file with no dependency on emrs or the module, so it can be loaded
from a `:pre-build` form before projdex is built, and by `projdex.el`.

- `projdex-build-cargo-program` (defcustom, default `"cargo"`).
- `projdex-build--repo`: the repository root, the parent of the directory
  of `(file-truename (locate-library "projdex.el" t))`; when that fails
  (not on `load-path`), the parent of the directory of this file's own
  true name. The root must contain `Cargo.toml`, otherwise a `user-error`:
  "projdex source not found (installed without its repository?); install
  the module by hand, see the README".
- `projdex-build--module-file`: `<repo>/lisp/projdex-module` plus
  `module-file-suffix`.
- Library produced by cargo, per `system-type`: `libprojdex.so`
  (gnu/linux and other Unix), `libprojdex.dylib` (darwin), `projdex.dll`
  (windows-nt), under `<repo>/target/release/`.
- Install step: copy the library to a temporary file in `lisp/`, then
  `rename-file` it over the module file (replaces the directory entry; an
  Emacs that has the old file loaded keeps a valid mapping).
- `projdex-build-module` (command, autoloaded): runs
  `cargo build --release` asynchronously in a `compilation-mode` buffer
  `*projdex-build*` with `default-directory` at the repository; on success
  installs the library and messages either "projdex module built" or, when
  a projdex module is already loaded in this Emacs, "projdex module built;
  restart Emacs to use it". On failure it messages that the build failed
  and leaves the buffer for inspection.
- `projdex-build-module-sync`: the same synchronously (for `:pre-build`),
  output to `*projdex-build*`. It never signals: any error, including a
  missing cargo, becomes a `display-warning` with the reason and the hint
  to run `M-x projdex-build-module` later. Returns non-nil on success.

### Finding the module

`projdex--start` loads the module with `emrs-load-module 'projdex FILE`
when `projdex-build--module-file` exists, and otherwise as today
(`projdex-module` on `load-path`, keeping manual installations and the
current Doom config working). When the repository cannot be determined,
only the `load-path` lookup is tried.

### Missing module

When loading fails with `file-missing` and a repository with `Cargo.toml`
is found and Emacs is interactive, projdex asks "projdex module not
built. Build it now with cargo? " (`y-or-n-p`). Yes starts
`projdex-build-module` and signals the `user-error` "Building the projdex
module; run the command again when it is done". No, or no repository, or
batch mode: the existing `user-error`, extended with "or run M-x
projdex-build-module". Other load errors stay as they are.

### Recipes (README)

Doom, for users:

```elisp
(package! emrs
  :recipe (:host github :repo "tohammer/emrs" :files ("elisp/emrs.el")))
(package! projdex
  :recipe (:host github :repo "tohammer/emrs-projdex" :files ("lisp/*.el")
           :pre-build ((load (expand-file-name "lisp/projdex-build.el") nil t)
                       (projdex-build-module-sync))))
```

straight without Doom: the same recipes with `straight-use-package`.
elpaca: the recipes with `:host`, `:repo`, `:files`, then
`M-x projdex-build-module` once and after updates. package-vc:
`package-vc-install` with `:lisp-dir "lisp"` for projdex and
`:lisp-dir "elisp"` for emrs, then the command. Every variant then needs
`(projdex-mode 1)` or a `use-package` with `:config (projdex-mode 1)`.

The emrs recipe is not pinned (ADR 0007).

### Development mode (README, "Development")

The developer keeps one recipe and adds the local checkout when it exists:

```elisp
(defvar my/projdex-dev (file-directory-p "~/src/emacs-projdex"))
(package! projdex
  :recipe `(:host github :repo "tohammer/emrs-projdex" :files ("lisp/*.el")
            :pre-build ((load (expand-file-name "lisp/projdex-build.el") nil t)
                        (projdex-build-module-sync))
            ,@(when my/projdex-dev
                '(:local-repo "~/src/emacs-projdex" :build (:not compile)))))
```

With an absolute `:local-repo` straight uses the checkout as the
repository and never clones or pulls it; `:build (:not compile)` leaves no
`.elc` to shadow edits. The README's development section lists:

| Change | Do | Takes effect |
|---|---|---|
| Elisp in `lisp/` | `eval-buffer`, or restart | at once, no `doom sync` |
| Rust in `src/` | `M-x projdex-build-module` | after restarting Emacs |
| New file in `lisp/` | `doom sync` once | build dir gets the symlink |
| emrs too | same pattern for the emrs recipe; a `[patch]` in an uncommitted `.cargo/config.toml` pointing the `emrs` crate at `../emrs/emrs` | as above |

With the dev switch on, any change in the checkout makes `doom sync`
rebuild the package and so run cargo; that is incremental and a no-op
when no Rust changed.

### Files and repository

- `.gitignore`: `lisp/projdex-module.*` and the temporary install file.
- `projdex.el` requires `projdex-build`.
- `docs/architecture.md`: the build file, module lookup and the two entry
  points.

## Error handling

| Situation | Behaviour |
|---|---|
| No cargo during `doom sync` | Warning from `projdex-build-module-sync`; sync completes; first projdex command offers to build. |
| Compile error during `doom sync` | Same, with the output in `*projdex-build*`. |
| No cargo for the command | Message that cargo was not found (`projdex-build-cargo-program`). |
| Installed without repository | `user-error` naming the manual installation. |
| Module loaded, rebuilt | Built file replaces the old by rename; message to restart; emrs's stale warning as before. |
| `emrs.el` older than the module's protocol | emrs's protocol error, "upgrade the emrs Elisp package" (ADR 0007). |
| Clone fails (no credentials) | straight's error; out of projdex's control. README states the credential requirement. |

## Testing

Automated (ERT, `tests/run-ert.sh`):

- Repository detection through a symlinked `projdex.el` (a temp build
  directory with a symlink into a temp repository) resolves to the
  repository; without `Cargo.toml` it signals the `user-error`.
- Build with a fake cargo (`projdex-build-cargo-program` set to a script
  that writes `target/release/<library>`): sync and async variants install
  the module file with the right name; a failing fake cargo leaves no
  module and gives a warning (sync) or message (async), and the sync
  variant does not signal; a missing program does not signal in the sync
  variant.
- Install over an existing module file replaces it by rename (inode
  changes).
- Module lookup: `projdex--start` passes the module file to
  `emrs-load-module` when it exists next to the true `projdex.el`, and
  falls back to `load-path` otherwise (stubbed `emrs-load-module`).
- Missing module: with `y-or-n-p` stubbed to yes, the build starts and the
  `user-error` says so; with no, the extended `user-error`.
- The existing suite keeps passing.

Manual, in the developer's Doom config (task 3):

- Dev switch off (temporarily): `doom sync` clones both repositories from
  GitHub, `:pre-build` builds the module, `projdex-find-file` works after
  restart.
- Without cargo on `PATH` for the sync: sync completes with the warning;
  the first command offers to build.
- Dev switch on: `doom sync`, then an edit in `lisp/projdex.el` plus
  `eval-buffer` changes behaviour without `doom sync`;
  `M-x projdex-build-module` after a Rust edit, restart, change visible.

Not verified: elpaca, package-vc and plain straight recipes (documented
only), macOS and Windows.

## Tasks

- [x] 1. Build logic and module lookup. `lisp/projdex-build.el`
  (repository detection, sync and async build, install by rename),
  module lookup and missing-module offer in `projdex.el`, `.gitignore`,
  and the ERT tests listed under Testing. *Done when* those tests and the
  whole suite pass with `tests/run-ert.sh`, and `M-x projdex-build-module`
  in the checkout produces `lisp/projdex-module.so` that a fresh Emacs
  loads.
- [ ] 2. Documentation. README: Requirements (Rust toolchain, git
  credentials), Installation with the Doom recipe first, then straight,
  elpaca, package-vc, and the manual installation as fallback; a
  Development section with the dev-mode recipe and table; Status line.
  `docs/architecture.md` (build file, lookup, entry points);
  next-steps "Watch out for" (emrs pins only default-branch commits,
  ADR 0007; the Doom notes for the new setup); backlog: remove "Install
  from GitHub", adjust "Distribution" to prebuilt binaries and archives.
  *Done when* every command and recipe in the README matches the code of
  task 1 and the doc-checker finds nothing stale.
- [ ] 3. Developer's Doom config and manual checks. Switch
  `~/.doom.d/packages.el` to the recipes with the dev switch (emrs too),
  remove the `:load-path` to `target/emacs` from `config.el` and the
  `target/emacs` symlink, and run the manual checks under Testing with the
  user. *Done when* each manual check is confirmed or its failure is
  recorded and fixed.
