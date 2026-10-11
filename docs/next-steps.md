# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
architecture.md or an ADR.

## Next

- Rebuild the module (`M-x quarry-build-module`) and restart Emacs:
  context lines need the new module, an older one shows none.
- Use quarry-grep daily and do its manual checks (grep backlog, "Manual
  checks not done yet"), now including context lines (`C`, `B`, `A`).
- Next grep feature: pick from the grep backlog once the keys have been
  used for a while; the menu to make them discoverable is the nearest
  candidate.

## Watch out for

- emrs is pinned to a commit in `Cargo.toml`. Bump it deliberately; after a
  bump, rerun `tests/run-ert.sh`, which also picks up the matching `emrs.el`.
  Pin only commits that are on emrs's default branch: users get `emrs.el`
  from that branch, which must not be older than the module's protocol
  (ADR 0007).
- There is no CI (backlog). Run `cargo test` and `tests/run-ert.sh`
  locally before merging.
- `nucleo-matcher` is pinned to an upstream git commit because 0.3.1 has a
  prefix bug (ADR 0003). Bump it deliberately and rerun `cargo test`; the
  narrowing and substring-style tests fail when nucleo's parsing or
  unescaping changes in a way that matters.
- Development mode (Doom, `:local-repo` with `:build (:not compile)`, README
  "Development"): Elisp edits need no `doom sync`, only `eval-buffer` or a
  restart; Rust changes need `M-x quarry-build-module` and a restart; a
  new file in `lisp/` needs the package's build directory removed and
  then a `doom sync`, before Emacs is restarted. The module is loaded
  from `lisp/quarry-module.so` in the checkout.
- quarry-grep uses wgrep internals (ADR 0013). After a wgrep upgrade,
  rerun `tests/run-ert.sh` with wgrep on `QUARRY_TEST_LOAD_PATH`.
- The consult front end uses consult internals (`consult--async-pipeline`
  and its steps, ADR 0008). After a consult upgrade, rerun
  `tests/run-ert.sh` with `QUARRY_TEST_LOAD_PATH` pointing at it (and at
  compat); without it the command and end-to-end tests
  are skipped.
