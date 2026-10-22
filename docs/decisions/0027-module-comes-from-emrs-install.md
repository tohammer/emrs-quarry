# 0027 — The module comes from emrs-install; quarry-build.el and the pre-build step go

Date: 2026-10-22
Status: accepted; supersedes ADR 0006

## Context

ADR 0006 had quarry build its own module: `lisp/quarry-build.el` ran
cargo in the repository, installed the library as `lisp/quarry-module`
next to `quarry.el`, and a `:pre-build` form in the Doom and straight
recipes rebuilt it at `doom sync`. Since v0.1.0 quarry releases prebuilt
modules (spec 2026-10-19-prebuilt-modules), but users install them by
hand.

emrs v0.2.0 ships `elisp/emrs-install.el` (emrs spec
2026-10-19-module-installer, emrs ADRs 0006, 0008, 0009). It downloads
the release file of a released version after asking, checked against
`SHA256SUMS`, builds a `-snapshot` version from the package's checkout,
offers a rebuild when a local build is older than its sources, and
installs per user under `emrs-install-directory`. emrs-dirdiff moved to
it in its ADR 0004, without a pre-build step, because how such a step
finds `emrs-install.el` is untried.

quarry has no users besides its author yet, so nothing needs a migration
path.

## Decision

- quarry registers its module with `emrs-install-register` and loads it
  with `emrs-install-load`.
- `lisp/quarry-build.el`, the commands `quarry-build-module` and
  `quarry-build-module-sync` and the option `quarry-build-cargo-program`
  are removed without aliases.
- The recipes list emrs's `elisp/*.el` and have no `:pre-build` step.
- The module version is passed to the installer from one constant,
  `quarry-module-version`, which must equal `version` in `Cargo.toml`
  and the `;; Version:` header of `quarry.el` (emrs ADR 0008, quarry
  ADR 0026).

The user chose this on 2026-10-22 ("there are no users yet, no migration
at all").

## Consequences

- A user of a release (Doom pinned to a tag, package-vc on a tag) gets
  the module by download after one confirmation, without Rust.
- A user of `master` (a `-snapshot` version) gets a local build: the
  first quarry command after an update asks to build, and has to be run
  again when the build is done. Before, `doom sync` built it.
- Modules live under `emrs-install-directory`, one directory per version,
  no longer in the checkout. Old versions are removed with
  `M-x emrs-install-clean`.
- Every message about getting or loading the module is the installer's.
  quarry keeps only its own check that the loaded module has the
  services the Elisp needs, and points to `M-x emrs-install-module`.
- A pre-build step can come back once emrs settles how one finds
  `emrs-install.el`; that would supersede the third point.
