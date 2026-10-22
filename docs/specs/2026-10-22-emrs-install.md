# The module through emrs-install

Status: approved
Date: 2026-10-22

## Purpose

quarry should work without Rust for users of a release. Since v0.1.0 the
release workflow publishes a tested module per platform, but users
download and place it by hand (README "Prebuilt module"). emrs v0.2.0
ships `elisp/emrs-install.el` (emrs spec `2026-10-19-module-installer`,
emrs ADRs 0006, 0008, 0009), which downloads the release file of a
released version after asking, checked against `SHA256SUMS`, and builds
a `-snapshot` version from the package's checkout. emrs-dirdiff already
uses it (its spec `2026-10-20-emrs-install`). This spec moves quarry from
its own build file to the installer ([ADR 0027](../decisions/0027-module-comes-from-emrs-install.md),
superseding ADR 0006).

Success:

- A user of a release gets the module with one confirmation, without
  Rust.
- A user of a checkout of `master` (a `-snapshot` version) gets a local
  build.
- `lisp/quarry-build.el` and the module code built on it in
  `lisp/quarry-core.el` are gone, and with them the open backlog points
  that only the installer could fix.

## Scope

In:

- The emrs pin moves to v0.2.0, `Package-Requires` to emrs `0.2.0`.
- Registration and loading through `emrs-install.el`; removal of
  `quarry-build.el`, its commands and its option, without aliases (ADR
  0027).
- One version constant and a test that the three version strings agree.
- `tests/run-ert.sh` and `bench/run-bench.sh` keep the user's install
  directory and the network out of tests and benchmarks.
- README, CONTRIBUTING, architecture, backlog, next-steps.

Out:

- A `:pre-build` step (ADR 0027).
- Migration for users of v0.1.0 (there are none besides the author).
- Changes to the release workflow: its file names already match what the
  installer downloads (`quarry-module-<platform><suffix>` and
  `SHA256SUMS` under `v<version>/`).
- MELPA, Windows.

## Design

### emrs pin and Package-Requires

`Cargo.toml` pins emrs at `8a3fa355b3cf4d4bea7e73042f8255f0fc9e5307`
("Release 0.2.0 (#13)", the commit of tag v0.2.0, on emrs's `master`, ADR
0007). Between the current pin `f05b9fa` and it, emrs changed nothing in
`src/` and one line of `elisp/emrs.el`; the full suite still runs after
the bump. The `Package-Requires` of `lisp/quarry.el` becomes
`((emacs "30.1") (emrs "0.2.0"))`.

### Version

The module version is one string (emrs ADR 0008, quarry ADR 0026). It
must be identical in:

1. `version` in `Cargo.toml` (the module reports it as `:version`),
2. `quarry-module-version`, a `defconst` in `lisp/quarry-core.el`, which
   the registration uses,
3. the `;; Version:` header of `lisp/quarry.el`.

Now all three are `0.2.0-snapshot`. CONTRIBUTING "Releasing" names the
three places.

### Registration and loading

`lisp/quarry-core.el` requires `emrs-install` instead of `quarry-build`
and registers at top level:

```elisp
(emrs-install-register 'quarry
  :version quarry-module-version
  :url "https://github.com/tohammer/emrs-quarry/releases/download"
  :source (or load-file-name buffer-file-name))
```

`:source` is `quarry-core.el`; its true name leads from straight's or
elpaca's symlinked build directory into the checkout, whose root has
`Cargo.toml`.

`quarry--load-module` becomes `(emrs-install-load 'quarry)`. Everything
about getting the module comes from the installer: lookup (the installed
version, else `quarry-module` plus `module-file-suffix` on `load-path`),
download consent, the stale-build offer, the build prompt, the errors and
the version warning. Callers keep calling `quarry--load-module` and let
its `user-error` through, as today.

Removed: `lisp/quarry-build.el` (`quarry-build-module`,
`quarry-build-module-sync`, `quarry-build-cargo-program` and the
internals), and in `lisp/quarry-core.el` `quarry--module-file` and
`quarry--offer-build`. The `defgroup quarry` moves from `quarry-build.el`
to `quarry-core.el`. `lisp/quarry.el` no longer requires `quarry-build`,
and its Commentary says where the module comes from.

quarry-grep's two messages about a loaded module that is older than the
Elisp (no grep service; no replace) say "install it again with M-x
emrs-install-module and restart Emacs" instead of naming
`quarry-build-module`. This check stays: a module built from an older
`-snapshot` checkout reports the same version as the Elisp, so the
installer's version warning does not catch it.

`.gitignore` keeps `lisp/quarry-module.*`, so a module placed there by
hand, or left from before, stays untracked. Such a file is not used
unless its directory is on `load-path`.

### Package recipes

emrs recipes list `elisp/*.el` instead of `elisp/emrs.el`, and quarry
recipes have no `:pre-build`. Doom:

```elisp
(package! emrs
  :recipe (:host github :repo "tohammer/emrs" :files ("elisp/*.el")))
(package! quarry
  :recipe (:host github :repo "tohammer/emrs-quarry" :files ("lisp/*.el")))
```

The same change applies to straight, elpaca and package-vc, and to the
development recipe in CONTRIBUTING. A recipe that follows `master` gets
a local build; the README's existing hint to pin Doom to the commit of a
release tag (`:pin`, found with `git ls-remote`) moves from "Prebuilt
module" to the installation text, as the way to get the download
without Rust.

### Test and benchmark runners

`tests/run-ert.sh` keeps building the debug module and copying it with
the Lisp files to `target/elisp`, which is on `load-path`, so the
installer's `load-path` lookup finds it (and `EMRS_MODULE_FILE` keeps
working for emrs's release workflow). Before the test files are loaded it
binds `emrs-install-directory` to a new temporary directory and
`emrs-install-download` to `never`, so a module installed for the user
(which the lookup would prefer) is never under test, nothing is written
to the user's directory and the network is not used. `emrs-install.el`
is found next to `emrs.el` in the emrs checkout Cargo resolved, as
`emrs.el` is today. The comment about a module built in `lisp/` goes.

`bench/run-bench.sh` sets the same two variables in both modes; the
replace mode's comment about a stale module in `lisp/` goes.

### README

- Status table: the prebuilt module row says it is downloaded by the
  installer.
- Requirements and Quick start: Rust only for a checkout of `master` or
  a platform without a release file; the recipes above; what happens on
  first use (a download prompt for a release, a build prompt for
  `master`) and that a command started the build has to be run again.
- Installation: the description of how the module is obtained, short,
  with a link to emrs's README section "Installing modules for users" for
  the options (`emrs-install-download`, `emrs-install-directory`,
  `emrs-install-cargo-program`) and commands (`M-x emrs-install-module`,
  `M-x emrs-install-build`, `M-x emrs-install-clean`). The `doom sync`
  rebuild and `*quarry-build*` text goes; after an update of `master`
  the first command offers a rebuild.
- "Prebuilt module": the manual steps shrink to placing the file as
  `quarry-module<suffix>` on `load-path`, for a machine without network
  access from Emacs. "Check the installation" names the installer's
  lookup.
- Configuration: the `quarry-build-cargo-program` row goes.
- Troubleshooting: entries keyed to the installer's messages and to
  `M-x emrs-install-module`; the macOS quarantine note stays for a
  manually placed file.
- Limitations: as now, platforms with release files.

### CONTRIBUTING

- Development setup: the recipe without `:pre-build`; the module lives
  in `emrs-install-directory` under `quarry/0.2.0-snapshot/`; a Rust
  change needs `M-x emrs-install-build` (or `C-u M-x
  emrs-install-module`) and a restart, and a new Emacs offers the rebuild
  by itself.
- Releasing: three version strings (see Version).

## Error handling

All failures to get or load the module are the installer's (emrs spec,
section Error handling): `user-error`s that name what was tried and the
ways out, a warning when the module's `:version` differs from
`quarry-module-version`. quarry adds only the check above for a loaded
module without a service quarry-grep needs.

## Testing

Automated (`cargo test`, `tests/run-ert.sh`, CI on Linux and macOS with
Emacs 30.1 and 31.1):

- The whole existing suite, with the module found through the installer.
- New: the version in `Cargo.toml`, `quarry-module-version` and the
  `;; Version:` header of `quarry.el` are equal, and the loaded module
  reports it as `:version`.
- New: `quarry` is registered with the installer, with the release URL
  above and a `:source` whose checkout is this repository.
- Changed: the tests of a missing or failing module
  (`quarry-test-module-not-found`, `quarry-test-grep-module-missing` and
  the like) stub `emrs-install-load` and check that its `user-error`
  reaches the caller and no instance or buffer is left. The tests of
  quarry-grep's old-module messages expect `emrs-install-module`.
- Removed: the tests of `quarry-build.el` and of the offer to build
  (`quarry-test-build-*`, `quarry-test-start-module-*`,
  `quarry-test-missing-module-offer`) and their helpers; emrs's suite
  covers the same behaviour of the installer.
- Byte compilation of `lisp/*.el` without warnings, `checkdoc` clean for
  the changed files.

Manual, in an Emacs whose `user-emacs-directory` is a temporary
directory, with `load-path` reaching symlinks to the checkout's
`lisp/*.el` (as with straight):

- Build: without an installed module, the first `M-x quarry-find-file`
  asks to build, the build runs in `*emrs-install quarry*`, the module
  lands in `<user-emacs-directory>/emrs/modules/quarry/0.2.0-snapshot/`,
  and the command works when run again. After touching `src/lib.rs`, a
  new Emacs offers a rebuild.
- Download: with `quarry-module-version` bound to `0.1.0` before the
  registration runs and `cargo` not on `PATH`, `(emrs-install-load
  'quarry)` asks, downloads the v0.1.0 file over HTTPS, checks it and
  loads a module that reports `0.1.0`.

Not tested: the Doom recipe end to end (the author's Doom setup is
checked after the merge, see next-steps), macOS by hand.

## Tasks

- [x] 1. Bump the emrs pin to `8a3fa35` and `Package-Requires` to emrs
  `0.2.0`. *Done when* `cargo test` and `tests/run-ert.sh` pass, and
  `emrs-install.el` is in the emrs checkout Cargo resolved.
- [ ] 2. Register the module and load it with `emrs-install-load`; add
  `quarry-module-version`; remove `lisp/quarry-build.el` and the
  functions listed under Design; move the `defgroup`; change quarry-grep's
  two messages; update `tests/run-ert.sh` and `bench/run-bench.sh` as
  described; remove, change and add the tests listed under Testing.
  *Done when* `tests/run-ert.sh` passes, byte compilation of `lisp/*.el`
  reports no warnings, `checkdoc` reports nothing for the changed files,
  `bench/run-bench.sh replace` runs, and `grep -rn quarry-build` finds
  nothing outside `docs/specs/`, `docs/decisions/` and `docs/audits/`.
- [ ] 3. Manual checks as described under Testing. *Done when* both pass.
- [ ] 4. Documentation: README and CONTRIBUTING as described;
  `docs/architecture.md` (components table, release paragraph) and
  `docs/architecture/elisp.md` (building and finding the module);
  `docs/backlog/project.md` (Distribution: the installer item, the
  `doom sync` warning and the "rebuild" message removed, the manual-check
  item reduced to what still applies; the order-dependent ERT test item
  removed if no test it describes remains); `docs/next-steps.md` (the
  rebuild and development-mode items rewritten for the installer). *Done
  when* the doc-checker reports nothing stale.
