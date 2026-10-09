# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
architecture.md or an ADR.

## Next

1. Review and approve the version 1 spec,
   `docs/specs/2026-10-09-projdex-v1.md`, then implement it with
   `/devflow:implement`.

## Watch out for

- emrs is pinned to a commit in `Cargo.toml`. Bump it deliberately; after a
  bump, rerun `tests/run-ert.sh`, which also picks up the matching `emrs.el`.
- There is no CI (backlog). Run `cargo test` and `tests/run-ert.sh`
  locally before merging.
