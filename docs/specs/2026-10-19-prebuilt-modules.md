# Prebuilt module releases

Status: approved
Date: 2026-10-19

## Purpose

Today every user needs a Rust toolchain: the module is built on their
machine (ADR 0006). emrs now has the release side of prebuilt modules:
`cargo emacs package`, the reusable workflow `module-release.yml` and the
asset layout of emrs ADR 0004, first used by emrs-dirdiff v0.1.0. The
installer that downloads them (`emrs-install.el`) does not exist yet.

This spec makes quarry publish tested prebuilt modules on each tag and
tells users how to install one by hand until the installer exists.

Success:

- Pushing the tag `v0.1.0` produces a GitHub release with
  `quarry-module-linux-x86_64.so`, `quarry-module-linux-aarch64.so`,
  `quarry-module-macos-aarch64.dylib` and `SHA256SUMS`.
- Each of these files passed the whole ERT suite, with consult, compat
  and wgrep, on Emacs 30.1 and 31.1 before it was published.
- A user without Rust installs quarry with the README's recipes, follows
  the README's "Prebuilt module" steps, and `quarry-find-file` and
  `quarry-grep` work.
- After the release, `Cargo.toml` and `quarry.el` carry `0.2.0-snapshot`
  (ADR 0026).

## Scope

In:

- `.github/workflows/release.yml` calling emrs's `module-release.yml`.
- `tests/run-ert.sh` testing a given module instead of building one.
- One script that installs the optional test packages, used by CI and the
  release.
- README: installing a prebuilt module, status, requirements.
- The release of v0.1.0 and the version bump after it.

Out:

- The installer `emrs-install.el` and with it automatic download,
  checksum checks in Emacs, a per-user module directory, replacing
  `quarry-build.el` and superseding ADR 0006. These follow emrs's
  installer spec.
- Windows (`windows-x86_64`): untested (backlog "Continuous
  integration"). macOS x86_64 has no release builds (emrs ADR 0007).
- A version check between module and Elisp at load time; the installer
  will match versions.
- MELPA.
- Silencing the `:pre-build` warning on `doom sync` for users without
  Rust who installed a prebuilt module.

## Design

### Release workflow

`.github/workflows/release.yml`, modelled on emrs-dirdiff's:

- Triggers: `push` of tags `v*`, and `workflow_dispatch`.
- `permissions: contents: write`.
- One job that `uses: tohammer/emrs/.github/workflows/module-release.yml@master`
  with:
  - `package: quarry`
  - `platforms: '["linux-x86_64", "linux-aarch64", "macos-aarch64"]'`
  - `test-command`: installs the test packages and runs `tests/run-ert.sh`
    (next sections)
  - `publish: ${{ startsWith(github.ref, 'refs/tags/v') }}`
- The emrs workflow builds each platform (Linux against glibc 2.28),
  runs its smoke test (module name and `:version`), runs the
  `test-command` for each platform and Emacs version, and only then
  publishes. A run started by hand builds and tests without publishing.

The workflow and `cargo-emacs` follow emrs `master`, as emrs-dirdiff
does. quarry's `Cargo.toml` keeps pinning the emrs crate; `emrs.el` for
the tests comes from that pin (`EMRS_EL_DIR`).

### Test packages

A new script `tests/install-test-packages.sh` installs consult (with
compat) and wgrep from GNU ELPA and NonGNU ELPA into `target/elpa` and
prints the value for `QUARRY_TEST_LOAD_PATH` (the colon-separated package
directories). `ci.yml`'s "Install consult and wgrep" step calls it
instead of its inline Elisp; the release's `test-command` calls it too.
The script uses `${EMACS:-emacs}`, like `run-ert.sh`.

### `run-ert.sh` with a given module

When `EMRS_MODULE_FILE` is set, `tests/run-ert.sh`:

- does not run `cargo build`;
- copies that file into `target/elisp` as `quarry-module` plus its
  extension, in place of the debug module;
- takes `emrs.el` from `EMRS_EL_DIR` when that is set, else from
  `cargo metadata` as now.

Without `EMRS_MODULE_FILE` it behaves exactly as now. The emrs workflow
sets both variables and forbids rebuilding the module in the
`test-command`.

### Installing a prebuilt module

A new README subsection under Installation, "Prebuilt module", for users
without Rust. quarry already finds a module as `lisp/quarry-module.<ext>`
in its repository, before `load-path` (ADR 0006); that file is
git-ignored and survives package rebuilds. The steps:

1. Install quarry and emrs with the recipes of the chosen package
   manager, and pin quarry to the release's tag: Doom `:pin` with the
   tag's commit, elpaca `:ref`, package-vc's revision argument; straight
   users pin with a lockfile; the manual installation checks out the
   tag. emrs needs no pin: `emrs.el` from its default branch fits every
   released module (ADR 0007).
2. Download `quarry-module-<platform>.<ext>` and `SHA256SUMS` from the
   release that matches the pinned version.
3. Check the file: `sha256sum --check --ignore-missing SHA256SUMS`, on
   macOS `shasum -a 256 --check --ignore-missing SHA256SUMS` (the
   commands emrs-dirdiff's README gives).
4. Save it as `lisp/quarry-module.<ext>` in quarry's repository (for
   Doom, `~/.config/emacs/.local/straight/repos/emrs-quarry/lisp/`, or
   the `.emacs.d` equivalent) or, for the manual installation, in a
   directory on `load-path`.
5. Restart Emacs; `M-x quarry-status` confirms it.

To update: move the pin to the new tag and replace the file. The Status
section loses "there are no prebuilt binaries" and gains a row per
release platform; Requirements say Rust is needed only without a
prebuilt module, and that Linux modules need glibc 2.28 or later.

### Versions

ADR 0026. The release commit has `0.1.0` in `Cargo.toml` and
`quarry.el` (as now). After the tag, both become `0.2.0-snapshot`.

## Error handling

- **Tests fail on a platform:** the emrs workflow does not publish; the
  tag stays without a release, or the release stays a draft. Fix, delete
  the tag, tag again.
- **Tag and crate version differ:** the emrs workflow refuses to publish
  (the tag must be `v<version>`).
- **Module older than the Elisp** (pin not moved, or downloaded the wrong
  release): the README's troubleshooting entry "A feature does nothing
  after an update" applies; it gains a line for prebuilt modules: download
  the release that matches the pin.
- **Module cannot be loaded** (glibc older than 2.28, wrong platform):
  quarry reports `Loading ... failed: ...; rebuild it with M-x
  quarry-build-module`. The README troubleshooting names the glibc
  requirement and the platform names. The message itself is not changed
  in this spec.
- **macOS quarantine:** a dylib downloaded with a browser carries the
  `com.apple.quarantine` attribute. Whether Emacs can load it is unknown;
  see Testing. If it cannot, the README says to download with `curl` or
  to remove the attribute with `xattr -d com.apple.quarantine`.

## Testing

Automated:

- CI on the pull request: `ci.yml` with the new install script must stay
  green in all six jobs, with no test skipped for missing consult or
  wgrep.
- `tests/run-ert.sh` with `EMRS_MODULE_FILE` pointing at a module from
  `cargo emacs package`: the whole suite passes and no `cargo build` runs.
  Without the variable: unchanged behaviour.
- After merging, a `workflow_dispatch` run of `release.yml` on `master`:
  three builds, smoke tests and ERT on every platform and Emacs version
  pass; nothing is published.
- The tag `v0.1.0`: the release has the three files and `SHA256SUMS`, and
  `sha256sum --check` passes on downloaded copies.

Manual:

- On Linux without using the local build: install with the Doom recipe
  pinned to `v0.1.0`, put the downloaded Linux module in place as the
  README says, restart, and run `quarry-find-file`, `quarry-grep-project`
  and `quarry-consult-grep-project`.
- The README's checksum command on Linux, and its macOS variant if a Mac
  is available.
- macOS aarch64 (if a Mac is available): load a module downloaded with a
  browser, to settle the quarantine question. Otherwise it stays listed as
  unverified in the README's status table.

## Tasks

- [ ] 1. Add `tests/install-test-packages.sh` and use it in `ci.yml`.
  *Done when* the script installs consult, compat and wgrep into
  `target/elpa` and prints the load path; CI passes all six jobs on the
  pull request without "not found" lines from `run-ert.sh`.
- [ ] 2. Let `tests/run-ert.sh` test a given module (`EMRS_MODULE_FILE`,
  `EMRS_EL_DIR`). *Done when* a run with a module from `cargo emacs
  package` passes all tests without building, and a run without the
  variables is unchanged; `CONTRIBUTING.md` "Tests" documents the
  variables. Can run in parallel with task 1.
- [ ] 3. Add `.github/workflows/release.yml` as in Design. *Done when*
  the workflow file is on the branch, `actionlint` (if available) passes,
  and after the merge a `workflow_dispatch` run on `master` passes without
  publishing. Depends on tasks 1 and 2.
- [ ] 4. README: "Prebuilt module" subsection, status table rows,
  requirements, troubleshooting entries; `CONTRIBUTING.md` gets a
  "Releasing" section (version, tag, bump, ADR 0026);
  `docs/architecture.md` mentions the release workflow; backlog
  "Distribution" drops the items this spec closes. *Done when* the docs
  describe the state after the release and every command in them was run
  or is listed as not run. Can run in parallel with task 3.
- [ ] 5. Release v0.1.0: with the user's go-ahead, push the tag `v0.1.0`
  on `master`. *Done when* the release has the three files and
  `SHA256SUMS`, and the checksums verify on downloaded copies.
- [ ] 6. Bump to `0.2.0-snapshot` in `Cargo.toml` (and `Cargo.lock`) and
  `quarry.el`, through a pull request. *Done when* CI passes and
  `version-to-list` accepts the header.
- [ ] 7. Manual checks of Testing. *Done when* the Linux install from the
  release works as the README says, and the macOS quarantine result (or
  "unverified") is in the README.
