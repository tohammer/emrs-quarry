# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
architecture.md or an ADR.

## Next

1. Write the version 1 spec with `/devflow:spec`. Settled inputs:
   - One service instance per project root; the root and ignore options
     are the start arguments.
   - Initial walk with the `ignore` crate, streamed to Emacs in batches,
     with indexing progress as `state` deliveries.
   - File watcher (`notify` crate) in version 1; additions, removals and
     renames update the index and reach Emacs as events.
   - Fuzzy ranking with `nucleo-matcher`; `(:query ... :limit ...)`
     returns ranked paths.
   - Front end: `completing-read` table with a pass-through completion
     style, hooked into `project-find-file` (ADR 0001).
   - Tests: Rust tests with `emrs::testing` on temporary trees, ERT on a
     generated large tree, and a latency benchmark against
     `project-files`.

## Watch out for

- emrs is pinned to a commit in `Cargo.toml`. Bump it deliberately; after a
  bump, rerun `tests/run-ert.sh`, which also picks up the matching `emrs.el`.
- There is no CI (backlog). Run `cargo test` and `tests/run-ert.sh`
  locally before merging.
