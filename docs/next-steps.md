# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
architecture.md or an ADR.

## Next

- Release v0.2.0 (CONTRIBUTING.md "Releasing"): the README's way to get
  the module without Rust pins the tag `v0.2.0`, which does not exist
  yet. Then check the download with the real release in Doom pinned to
  it.
- Next feature: pick from the survey (grep backlog, "Survey: find and
  grep features worth making native") or from "Further features weighed
  before the spec". Decide after a while of daily use; the survey's
  second item, definitions across a project by pattern, is the cheapest
  of the useful ones (Elisp and data only).

## Watch out for

- Replace writes a file through a new file renamed over it and syncs
  only as `write-region-inhibit-fsync` says (default t), as any Emacs
  save (ADRs 0022, 0023). A power loss right after a replace can leave
  empty files off ext4. Rerun `bench/run-bench.sh replace` after a change
  to the write path; it checks every file.

- emrs is pinned to a commit in `Cargo.toml`, and the release workflow
  to the same emrs release (`module-release.yml@` and `cargo-emacs` in
  `.github/workflows/release.yml`). Bump them together; after a
  bump, rerun `tests/run-ert.sh`, which also picks up the matching `emrs.el` and `emrs-install.el`.
  Pin only commits that are on emrs's default branch: users get `emrs.el`
  from that branch, which must not be older than the module's protocol
  (ADR 0007).
- `master` takes changes only through pull requests, documentation
  included (a ruleset on GitHub), and all six CI jobs must pass before
  the merge. GitHub cancels a macOS job when no runner takes it within
  about 15 minutes ("The job was not acquired by Runner"); the check
  then shows as failed. Rerun that job. The same happens in the release
  workflow; `gh run rerun <run-id> --failed` reruns only the cancelled jobs,
  and the release is published once all pass.
- A release follows CONTRIBUTING.md "Releasing": plain version in
  `Cargo.toml`, `quarry-module-version` (`lisp/quarry-core.el`) and the
  `;; Version:` header of `quarry.el`, tag, then the next `-snapshot`
  (ADR 0026). The three must agree; the test
  `quarry-test-module-versions-agree` fails otherwise.
- CI uses the newest stable Rust, so `cargo clippy --all-targets -- -D
  warnings` can fail there on a lint the local toolchain does not have
  yet.
- `nucleo-matcher` is pinned to an upstream git commit because 0.3.1 has a
  prefix bug (ADR 0003). Bump it deliberately and rerun `cargo test`; the
  narrowing and substring-style tests fail when nucleo's parsing or
  unescaping changes in a way that matters.
- Development mode (Doom, `:local-repo` with `:build (:not compile)`,
  CONTRIBUTING.md "Development setup"): Elisp edits need no `doom sync`,
  only `eval-buffer` or a restart; Rust changes need `M-x
  emrs-install-build` (or `C-u M-x emrs-install-module`) and a restart,
  and a new Emacs offers the rebuild by itself; a new file in `lisp/`
  needs the package's build directory removed and then a `doom sync`,
  before Emacs is restarted. The module is loaded from
  `emrs-install-directory` (`quarry/0.2.0-snapshot/`), not from `lisp/`.
- The test that compares the menu with the mode map reads an internal of
  transient (`transient--layout`). After a transient or Emacs upgrade,
  rerun `tests/run-ert.sh`; a failure of
  `quarry-test-grep-menu-matches-keymap` alone points at that reader.
- quarry-grep uses wgrep internals (ADR 0013). After a wgrep upgrade,
  rerun `tests/run-ert.sh` with wgrep on `QUARRY_TEST_LOAD_PATH`.
- The consult front end uses consult internals (`consult--async-pipeline`
  and its steps, ADR 0008). After a consult upgrade, rerun
  `tests/run-ert.sh` with `QUARRY_TEST_LOAD_PATH` pointing at it (and at
  compat); without it the tests that call consult are skipped.
- The live grep uses more consult internals than the file finder's front
  end (ADR 0018): `consult--grep-state`, `consult--prefix-group`,
  `consult--lookup-member`, the candidate layout `consult--grep-position`
  reads, the face `consult-grep-context`, and the split functions in
  `consult-async-split-styles-alist`. After a consult upgrade, rerun
  `tests/run-ert.sh` with consult on `QUARRY_TEST_LOAD_PATH`;
  `quarry-test-consult-grep-position` and the prompt tests are the ones
  that notice.
- A glob is read as a line of a gitignore file (ADR 0017). After an
  upgrade of the `ignore` crate, rerun `cargo test`; the glob tests in
  `src/grep/service.rs` fail when its reading of `#`, `!` or `/`
  changes.
