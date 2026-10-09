# 0004 — Substring match style with `'` as the fuzzy marker

Date: 2026-10-09
Status: accepted

## Context

nucleo matches each plain term as a subsequence, so `act man` also finds
`a/c/t/m/a/n`-like paths. Users coming from orderless-literal or plain
substring search find that surprising and want plain terms to match as
substrings, without typing `'` before each one. nucleo's `Pattern::parse`
has no such mode; `Pattern::new` with a fixed kind drops the `^`, `$`,
`!` syntax.

## Decision

An option `projdex-match-style` (`fuzzy`, the default, or `substring`),
sent per query as `:substring`. In the substring style projdex splits
atoms the way nucleo does and parses each one with `Atom::parse`; an atom
that comes out non-negated fuzzy gets the kind substring (the public
`kind` field; needle, case and normalization stay as parsed). A leading
`'` instead means "the rest of the term parsed as in the fuzzy style", so
`'foo` is fuzzy, `'foo$` a fuzzy suffix and `'!foo` a negated substring.
This is similar to fzf's `--exact` mode, but not the same in the corner
cases (in fzf, `'!foo` is fuzzy).

## Consequences

- `^`, `$`, `!` and escapes work identically in both styles; only plain
  and `'`-terms differ.
- Narrowing stays valid: a growing substring term matches less, and a
  term's kind is fixed by its first characters. One exception, found in
  review: nucleo unescapes non-ASCII needles differently, so a term with a
  backslash that turns non-ASCII does not narrow (`matcher::narrows`). The narrowing cache is
  keyed by style, and the equivalence test runs in both styles.
- The style is a query parameter, not a start argument: changing the
  option needs no restart.
