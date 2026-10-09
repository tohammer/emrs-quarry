# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
architecture.md or an ADR.

## Next

1. Review the version 1 change (`/devflow:review`) and wrap up
   (`/devflow:wrapup`).

## Watch out for

- emrs is pinned to a commit in `Cargo.toml`. Bump it deliberately; after a
  bump, rerun `tests/run-ert.sh`, which also picks up the matching `emrs.el`.
- There is no CI (backlog). Run `cargo test` and `tests/run-ert.sh`
  locally before merging.
- `nucleo-matcher` is pinned to an upstream git commit because 0.3.1 has a
  prefix bug (ADR 0003). Bump it deliberately and rerun `cargo test`; the
  narrowing tests fail when nucleo's behaviour changes in a way that matters.
