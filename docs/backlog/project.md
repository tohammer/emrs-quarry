# Backlog: project

Build, distribution, CI and the test suite. Part of [the backlog](../backlog.md).

## Continuous integration

CI runs on Linux and macOS (README "Tests"). Open: Windows and Linux on
ARM, which emrs's CI has; `cargo test` on macOS, where only the ERT suite
runs. Revisit Windows before claiming Windows support.

## Distribution

Installation from GitHub works through package recipes and a local cargo
build (spec 2026-10-09-install-from-github, README "Installation"). Open:
prebuilt binaries, which CI would build and which would replace the cargo
build and its Rust requirement, and a package archive (MELPA) for quarry
and emrs. Depends on emrs's own distribution work (emrs backlog, "Prebuilt
artifacts and distribution"). Origin: the install-from-GitHub spec, which
left both out of scope. Revisit before announcing quarry to users.

## Order-dependent ERT test

`quarry-test-build-async-installs` passes only while no quarry module is
loaded: with one loaded, the message gains "; restart Emacs to use it".
ERT runs tests alphabetically, so a test that loads the module and sorts
before it breaks it. The consult tests (`quarry-test-consult-*`) and all
grep tests (`quarry-test-grep-*`) are named to sort after it; a new test
file must follow the same rule. Origin: task 2 of the consult spec
(2026-10-09); extended by the grep spec (2026-10-10). Fix the test to
accept both messages when the naming rule first gets in the way.
