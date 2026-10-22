# Backlog: project

Build, distribution, CI, the test suite and user-doc visuals. Part of [the backlog](../backlog.md).

## Continuous integration

CI runs on Linux and macOS (CONTRIBUTING.md "CI"). Open: Windows and Linux on
ARM, which emrs's CI has; `cargo test` on macOS, where only the ERT suite
runs. Revisit Windows before claiming Windows support.

## Distribution

Releases publish prebuilt modules for linux-x86_64, linux-aarch64 and
macos-aarch64, tested with the ERT suite (spec
2026-10-19-prebuilt-modules); emrs's installer downloads them (ADR 0027,
spec 2026-10-22-emrs-install). Open:

- Windows (`windows-x86_64`) is left out of the release platforms until
  it is tested (see "Continuous integration").
- A package archive (MELPA) for quarry and emrs. The installer no longer
  blocks it; what is left is the packaging work (recipes for both
  packages, the module out of the package's files).
- Not checked by hand (no Mac): the macOS checksum command for a module
  placed by hand, and whether a browser-downloaded `.dylib` placed by
  hand needs the quarantine removed (README marks it untested). The
  installer's own download on macOS is not tried either. Revisit when a
  Mac is at hand.

Origin: the install-from-GitHub spec, which left prebuilt binaries out of
scope; the prebuilt-modules spec of 2026-10-19; the emrs-install spec of
2026-10-22. Revisit with MELPA or a Windows release.

## Recording of the live grep

Origin: userdocs rework, 2026-10-18. The docs show every buffer and
output as text; what text cannot show is the live grep filling its
candidates while you type. Open: a short recording (under about 30
seconds, one task, readable font) of `quarry-consult-grep-project`
near the top of the README, made from a committed script or tape, in
`docs/user/images/` as GIF or WebP, a few MB at most, with alt text.
Do it after the grep tools have been run in a GUI frame and their
faces looked at, since the recording shows them.
