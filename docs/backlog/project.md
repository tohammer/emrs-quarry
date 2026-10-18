# Backlog: project

Build, distribution, CI and the test suite. Part of [the backlog](../backlog.md).

## Continuous integration

CI runs on Linux and macOS (README "Tests"). Open: Windows and Linux on
ARM, which emrs's CI has; `cargo test` on macOS, where only the ERT suite
runs. Revisit Windows before claiming Windows support.

## Distribution

Installation from GitHub works through package recipes and a local cargo
build (spec 2026-10-09-install-from-github, README "Installation"). emrs now
has the release side of prebuilt binaries (emrs spec
`2026-10-17-release-pipeline`, emrs ADRs 0004–0007; first used by
emrs-dirdiff v0.1.0): `cargo emacs package` and a reusable workflow that
builds, tests and publishes `quarry-module-<platform>.<ext>` and
`SHA256SUMS` on a tag `v<version>`. Open:

- Add `.github/workflows/release.yml` that calls
  `tohammer/emrs/.github/workflows/module-release.yml@master` with
  `package: quarry`, and leave out `windows-x86_64` until Windows is
  tested. macOS x86_64 is not a release platform (emrs ADR 0007).
- Release versions: quarry has stayed at `0.1.0`. Tag a release, then set
  the crate version to the next `-dev` version, because the installer
  downloads the release of the exact version (emrs ADR 0004).
- Test the released files with the ERT suite: `tests/run-ert.sh` builds its
  own debug module and finds `emrs.el` with `cargo metadata`. Let it take a
  prebuilt module (`EMRS_MODULE_DIR`) and `emrs.el` (`EMRS_EL_DIR`), install
  consult and wgrep in the `test-command`, and pass that command to the
  workflow. Until then the release runs only emrs's smoke test.
- Use the binaries: emrs's installer `emrs-install.el` (emrs backlog
  "Installer for prebuilt modules", decisions in emrs ADR 0006) is to
  replace `lisp/quarry-build.el` and the `:pre-build` recipes, and with
  that quarry ADR 0006 (module next to quarry.el; the installer uses a user
  directory). Its spec is next in emrs.
- A package archive (MELPA) for quarry and emrs, which needs the installer.

Origin: the install-from-GitHub spec, which left prebuilt binaries out of
scope; updated after the emrs release pipeline, 2026-10-18. Revisit before
announcing quarry to users.

## Order-dependent ERT test

`quarry-test-build-async-installs` passes only while no quarry module is
loaded: with one loaded, the message gains "; restart Emacs to use it".
ERT runs tests alphabetically, so a test that loads the module and sorts
before it breaks it. The consult tests (`quarry-test-consult-*`) and all
grep tests (`quarry-test-grep-*`) are named to sort after it; a new test
file must follow the same rule. Origin: task 2 of the consult spec
(2026-10-09); extended by the grep spec (2026-10-10). Fix the test to
accept both messages when the naming rule first gets in the way.
