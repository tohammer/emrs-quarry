# 0006 — The module is built locally and lives next to projdex.el

Date: 2026-10-09
Status: superseded by ADR 0027

## Context

projdex is to be installed from its GitHub repository with a package
recipe (Doom `package!`, straight, elpaca, package-vc). The repository holds
only source; the Rust module has to be built on the user's machine, and
there are no prebuilt binaries (no CI, backlog "Distribution").

straight can run `:pre-build` commands whenever it rebuilds a package
(after an update, a pin or recipe change, or a forced rebuild), in the
repository directory and before it symlinks the files into the build
directory. A command may be an Elisp form, evaluated in the Emacs that
runs the build; an error in it aborts the build and with it `doom sync`.
elpaca and package-vc have no equivalent that projdex could rely on.

Where the module goes must work for all of them. Package managers put a
build directory on `load-path` whose contents they control (straight:
symlinks for the recipe's `:files`, recreated on every rebuild), so a file
written there by a later command does not survive, and one written into
the repository is not on `load-path` unless the recipe lists it.

## Decision

- The build logic lives in projdex's Elisp (`lisp/projdex-build.el`, which
  does not need emrs or the module). It runs `cargo build --release` in the
  repository that contains projdex.el and copies the library into that
  repository's `lisp/` directory as `projdex-module` plus
  `module-file-suffix`, by writing a temporary file and renaming it over
  the target, so an Emacs that has the old file loaded keeps a valid
  mapping.
- Two entry points call it: the command `projdex-build-module` (any
  package manager, and offered when the module is missing), and a
  `:pre-build` form the README gives for straight and Doom. The
  `:pre-build` entry never signals: a failed build becomes a warning, so a
  missing Rust toolchain does not stop `doom sync`; the module is then
  missing and the command offers to build it.
- projdex finds the module first in the repository of its own files: the
  true name of `projdex-build.el` (of the `.el` next to a byte-compiled
  file), which resolves straight's and elpaca's symlinks into the
  repository, or else of `projdex.el` on `load-path`; then as
  `projdex-module` on `load-path`, so the manual installation keeps
  working.

## Consequences

- Users need a Rust toolchain (1.88 or later) and network access for cargo
  the first time; the README says so. Prebuilt binaries stay in the
  backlog ("Distribution").
- The built module sits in the repository's `lisp/` directory and is
  ignored by git. A repository-less install (package.el from a tarball)
  cannot build; `projdex-build-module` says so.
- A rebuilt module takes effect after an Emacs restart (a loaded module
  cannot be unloaded); emrs already warns when the loaded file changed.
- With `:pre-build`, a Doom or straight update rebuilds the module during
  `doom sync`, incrementally, because cargo's `target/` stays in the
  repository. Other package managers rebuild with the command.
