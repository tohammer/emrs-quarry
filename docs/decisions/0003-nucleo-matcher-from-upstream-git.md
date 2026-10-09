# 0003 — nucleo-matcher from an upstream git commit

Date: 2026-10-09
Status: accepted

## Context

The latest crates.io release of `nucleo-matcher`, 0.3.1 (2024-02-20), has a
bug in case-sensitive prefix and postfix atoms on ASCII text: it compares
the whole haystack with the needle, so `^Fo` does not match `Foo`. With
smart case, every prefix query containing an upper-case letter is affected,
which users would see. Upstream fixed it on 2025-03-12 (helix-editor/nucleo
`dc305406`, "Fix case-sensitive prefix matching") but has not released
since. The same range also changes atom splitting to any Unicode whitespace
(`dfb82eef`) and regenerates the normalization tables.

## Decision

Depend on `nucleo-matcher` from `https://github.com/helix-editor/nucleo.git`
at commit `8c16d47cdfa9607d3e44df5f81c635c6f43c65ee` (master on
2026-10-09) instead of 0.3.1. The narrowing rule in `src/matcher.rs`
follows that version's atom splitting and normalization behaviour.

## Consequences

- projdex cannot be published to crates.io while it has a git dependency;
  it is not published today (`publish = false`).
- Updating nucleo is deliberate: bump the commit, rerun `cargo test`. The
  narrowing tests (`narrowing_conditions`, `narrowing_and_nucleo_quirks`,
  the equivalence test) assert nucleo's current behaviour and fail when it
  changes in a way that matters.
- Return to a crates.io release once one contains the fix.
