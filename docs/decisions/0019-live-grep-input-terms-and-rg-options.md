# 0019 — Live grep input: terms that become filters, and a set of rg's options

Date: 2026-10-12
Status: accepted

## Context

`consult-ripgrep` reads its input as words, each a regexp that the line
must match, followed after ` -- ` by options for the `rg` command line.
quarry has no command line. Three readings of the input were compared:
the whole input as one regexp; words as terms; words as terms plus
options in rg's spelling after ` -- `.

## Decision

The third, chosen by the author, with `!` for exclusion.

- The words before ` -- ` are terms. The first term without `!` is the
  primary filter, each further one an include line filter, each term
  with `!` in front an exclude line filter. `\ ` is a space inside a
  term, `\!` at the start of a term a literal `!`.
- After ` -- ` come options from a fixed set, spelled as in rg: file
  type, glob, literal patterns, the case rule, ignore files, hidden
  files. An option outside the set is an error shown in the prompt; it
  is not ignored.
- The input is translated into the same search value the result buffer
  uses, so the hand-over to the result buffer loses nothing.

## Consequences

- The terms map one to one onto the service's filters: no look-around
  and no joined regexp, and each term is highlighted.
- The order of the terms does not change the result. It changes the
  cost: files are searched for the first term, so a rare first term is
  faster.
- The options imitate rg and are not rg. What the service cannot do
  (`-w`, `-C`, `-m`, `--pcre2`, ...) is refused, and `-g` differs from
  rg's where ADR 0017 says so. The README lists the set.
- `!` is quarry's addition; consult has no exclusion. A pattern that
  starts with `!` needs `\!`.
- A new option is a change to one parser table and to the README.
