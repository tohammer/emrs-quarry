# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
architecture.md or an ADR.

## Next

1. projdex as the file chooser after `projectile-switch-project`
   (backlog). Small; the developer's Doom config already has the
   Projectile-rooted wrapper.
2. Install from GitHub with one `package!` declaration, with emrs as its
   own package (backlog, together with "Distribution"). Needed before
   anyone else uses projdex.
3. consult async source (backlog), built on `projdex-query-async`. It
   must restrict completion styles like `projdex-find-file` does
   (ADR 0005).

## Watch out for

- emrs is pinned to a commit in `Cargo.toml`. Bump it deliberately; after a
  bump, rerun `tests/run-ert.sh`, which also picks up the matching `emrs.el`.
  The developer's Doom config loads `emrs.el` from the local
  `~/src/emrs` checkout, which must be at the same commit.
- There is no CI (backlog). Run `cargo test` and `tests/run-ert.sh`
  locally before merging.
- `nucleo-matcher` is pinned to an upstream git commit because 0.3.1 has a
  prefix bug (ADR 0003). Bump it deliberately and rerun `cargo test`; the
  narrowing and substring-style tests fail when nucleo's parsing or
  unescaping changes in a way that matters.
- Local install (Doom, `:local-repo`): after Elisp changes run `doom sync`
  (straight keeps a compiled `.elc`); after Rust changes run
  `cargo build --release` and restart Emacs. The module is loaded through
  the symlink `target/emacs/projdex-module.so`.
