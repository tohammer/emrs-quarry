# Backlog: project

Build, distribution, CI, the test suite and user-doc visuals. Part of [the backlog](../backlog.md).

## Continuous integration

CI runs on Linux and macOS (CONTRIBUTING.md "CI"). Open: Windows and Linux on
ARM, which emrs's CI has; `cargo test` on macOS, where only the ERT suite
runs. Revisit Windows before claiming Windows support.

## Distribution

Releases publish prebuilt modules for linux-x86_64, linux-aarch64 and
macos-aarch64, tested with the ERT suite (spec
2026-10-19-prebuilt-modules); users install them by hand (README
"Prebuilt module"). Open:

- Use the binaries automatically through emrs's installer
  `emrs-install.el` (emrs spec 2026-10-19-module-installer, emrs ADRs
  0006 and 0008; emrs-dirdiff uses it since its v0.2.0). Needs a spec
  here. Steps: register the module and load it with `emrs-install-load`
  instead of `lisp/quarry-build.el`; drop the `:pre-build` forms; change
  the emrs recipes from `elisp/emrs.el` to `elisp/*.el` (README and the
  other install docs); supersede quarry ADR 0006 (module next to
  quarry.el; the installer uses a user directory). The version is
  already `0.2.0-snapshot` as ADR 0008 requires.
- Doom users with a prebuilt module and no Rust get a build warning on
  every `doom sync` from the `:pre-build` form. Goes away with the
  installer.
- A module that fails to load says "rebuild it with M-x
  quarry-build-module", which does not fit a downloaded module without
  Rust. Goes away with the installer, which reports platform and glibc.
- Windows (`windows-x86_64`) is left out of the release platforms until
  it is tested (see "Continuous integration").
- A package archive (MELPA) for quarry and emrs, which needs the installer.
- Not checked by hand (no Mac, cargo installed): the macOS checksum
  command, whether a browser-downloaded `.dylib` needs the quarantine
  removed (README marks it untested), and the `doom sync` warning without
  Rust. Revisit when a Mac or a machine without Rust is at hand.

Origin: the install-from-GitHub spec, which left prebuilt binaries out of
scope; the prebuilt-modules spec of 2026-10-19. Revisit with emrs's
installer.

## Order-dependent ERT test

`quarry-test-build-async-installs` passes only while no quarry module is
loaded: with one loaded, the message gains "; restart Emacs to use it".
ERT runs tests alphabetically, so a test that loads the module and sorts
before it breaks it. The consult tests (`quarry-test-consult-*`) and all
grep tests (`quarry-test-grep-*`) are named to sort after it; a new test
file must follow the same rule. Origin: task 2 of the consult spec
(2026-10-09); extended by the grep spec (2026-10-10). Fix the test to
accept both messages when the naming rule first gets in the way.

## Recording of the live grep

Origin: userdocs rework, 2026-10-18. The docs show every buffer and
output as text; what text cannot show is the live grep filling its
candidates while you type. Open: a short recording (under about 30
seconds, one task, readable font) of `quarry-consult-grep-project`
near the top of the README, made from a committed script or tape, in
`docs/user/images/` as GIF or WebP, a few MB at most, with alt text.
Do it after the grep tools have been run in a GUI frame and their
faces looked at, since the recording shows them.
