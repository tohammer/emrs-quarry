# 0011 — Grep searches with ripgrep's library crates, not an `rg` process

Date: 2026-10-10
Status: accepted

## Context

The grep tool needs a search engine. rg.el and consult run the `rg`
program and parse its text output. The `ripgrep` crate has no library
target, but the engine it is built from is published as crates by the
same author: `ignore` (walk, ignore rules, file types), `grep-regex`,
`grep-searcher` and `grep-matcher`.

A prototype on these crates searched 19,500 files in 55 to 90 ms, the same
as `rg` on the same machine, including a negative line pattern and a path
exclusion (`GREP-EVALUATION.md` in the emrs repository, section 2).

## Decision

The grep service links `grep-regex`, `grep-searcher`, `grep-matcher` and
`ignore`, and implements its own `Sink` that produces typed results. It
does not start an `rg` process and does not need `rg` installed.

Left out: PCRE2 (`grep-pcre2` needs a C library at build time), compressed
files and preprocessors (`grep-cli`), and `~/.ripgreprc`.

## Consequences

- Results reach Emacs as structured values: path, line number, text and
  match positions. Nothing is parsed back out of coloured text.
- Filters that `rg` cannot express without a pipe, such as "matches A but
  not B on the same line", are applied inside the `Sink`.
- Patterns use Rust regex syntax, as in `rg`. Look-around and
  back-references are not available.
- The module grows by the regex engine, and its build takes longer.
- What `rg` adds above these crates (flags, configuration file, output
  formats) is not available and has to be written where it is wanted.
