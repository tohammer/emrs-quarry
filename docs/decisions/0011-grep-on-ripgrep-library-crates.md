# 0011 — Grep searches with ripgrep's library crates, not an `rg` process

Date: 2026-10-10
Status: accepted

## Context

The grep tool needs a search engine. rg.el and consult run the `rg`
program and parse its text output. The `ripgrep` crate has no library
target, but the engine it is built from is published as crates by the
same author: `ignore` (walk, ignore rules, file types), `grep-regex`,
`grep-searcher` and `grep-matcher`.

`grep-printer` (rg's text and JSON output) is not needed with an own
`Sink`. The crates are licensed Unlicense or MIT, compatible with
quarry's MIT or Apache-2.0.

A throwaway prototype on these crates (parallel walk, one searcher per
thread, an own `Sink` collecting line number, text and match positions)
was timed against `rg` 15.2.0 on 2026-10-10: 8 cores, Linux, warm file
cache, three runs each, on a machine that was not idle. `rg` wrote
coloured, grouped output to `/dev/null`; the prototype collected
everything in memory.

| Search (smart case) | Files | Lines | `rg` | Prototype |
|---|---|---|---|---|
| `defun` in Doom's `straight/repos` | 19,516 | 33,824 | 73–124 ms | 61–90 ms |
| `save-excursion`, same tree | 19,516 | 4,507 | 64–67 ms | 54–56 ms |
| `wx[A-Z]\w+Event` in wxWidgets | 11,166 | 20,352 | 98–156 ms | 68–74 ms |
| `TODO` in wxWidgets | 11,166 | 1,412 | 108–193 ms | 59–60 ms |
| no match, `straight/repos` | 19,516 | 0 | 69–119 ms | 53–108 ms |
| `defun`, not `interactive` on the line, path without `/test` | 17,272 | 32,405 | 100 ms (`rg … \| rg -v`) | 106 ms |

Read as "the same speed", not as "faster than `rg`". Not measured then:
cold-cache searches and trees of AOSP size.

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
