# Backlog: project

Build, distribution, CI and the test suite. Part of [the backlog](../backlog.md).

## Continuous integration

No CI yet. The emrs repository had to disable GitHub Actions for lack of
quota (2026-10-04), and the same account would pay for this one. Revisit
when quota allows; then mirror emrs's matrix (Linux, macOS, Emacs 30.1 and
31.1).

## Distribution

Installation from GitHub works through package recipes and a local cargo
build (spec 2026-10-09-install-from-github, README "Installation"). Open:
prebuilt binaries, which need CI (see above) and would replace the cargo
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

## Repin emrs

`Cargo.toml` pins emrs to commit `9c47609`. Move the pin to the current
head of emrs's default branch: only commits on that branch may be
pinned, since users get `emrs.el` from it and it must not be older than
the module's protocol (ADR 0007). After the bump run `cargo test` and
`tests/run-ert.sh`, which picks up the matching `emrs.el`, and rebuild
the module. Check on the way whether the new emrs brings what two other
items wait for: a public way to wait on a stream synchronously (file
finder backlog), and whether `emrs::testing::Host` can exercise the Lisp
conversion (architecture, lessons). Origin: requested by the author on
2026-10-11, during the context lines work.
