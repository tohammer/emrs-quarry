# 0024 — Grep excludes file types with `!`, and the last type that matches decides

Date: 2026-10-16
Status: accepted

## Context

A file type could only be included: a type name in the files prompt,
`-t` in the live grep, `:file-types` in a `(:search)`. Excluding meant
writing the type's extensions as excluding globs (`!*.json`). rg has
`-T TYPE` (`--type-not`), and the `ignore` crate supports it
(`TypesBuilder::negate`). Two questions had to be settled.

**Spelling in the files prompt.** The prompt takes plain words: a type
name is a type, every other word a glob, and `!` in front of a glob
excludes (ADR 0017). `!rust` was therefore the glob that excludes files
and directories named `rust`. Options: `!rust` for the excluded type;
another sign (`-rust`); a keyword (`not:rust`). `-rust` is a valid glob
as well, so it only moves the clash, and both alternatives add a second
way of saying "exclude" next to the `!` of globs.

**A file of an included and an excluded type.** Types are sets of
extensions that overlap: `*.h` belongs to `c`, `cpp` and others. With
`cpp !c`, a `.h` file is both. Options: the last type in the order given
that the file is of decides, as in the `ignore` crate and rg; or an
exclusion always wins. The second is independent of order, but differs
from rg and from the globs of the same prompt, cannot say "C++ headers,
but no other C files", and needs matching of quarry's own instead of
`negate`.

## Decision

Chosen by the author on 2026-10-16:

- In the files prompt, a word `!NAME` where `NAME` is a type name
  excludes that type. As with `[m]ake`, the glob is written another way
  (`![r]ust`). This supersedes the part of ADR 0017 that made every `!`
  word a glob.
- The live grep takes `-T TYPE` and `--type-not TYPE`, spelled as in rg,
  next to `-t`.
- The service takes excluded types in `:file-types` itself, as names
  with `!` in front, in the order given: `("cpp" "!c")`. It hands them
  to `TypesBuilder::select` and `negate` in that order.
- For each file, the last type in that order that the file is of
  decides: included or excluded. A file of no listed type is searched
  only when no type is included. Types and globs still both narrow
  (ADR 0017).

## Consequences

- One sign, `!`, excludes in the files prompt, whether the word is a
  type or a glob, and rg's habits carry over to the live grep.
- Order matters, but only for a file of more than one of the listed
  types: `cpp !c` leaves out `.h` files, `!c cpp` keeps them.
- A type given twice is kept only where it occurs last. That does not
  change what is searched, since the last occurrence decides anyway.
- The glob `!NAME` for a type name now means something else. A file or
  directory named exactly like a type is rare; such a glob is written
  `![N]AME`.
- One list keeps the order of included and excluded types. A separate
  field for excluded types would lose it.
- A misspelled excluded type in the files prompt is a glob that excludes
  nothing much, without an error, as a misspelled included type already
  is. `-T` in the live grep names the type, so a wrong name is an error
  there.
