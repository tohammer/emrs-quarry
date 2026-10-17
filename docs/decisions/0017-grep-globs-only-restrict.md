# 0017 — Grep globs are path globs that only restrict

Date: 2026-10-12
Status: accepted; the last consequence superseded in part by ADR 0024
(`!NAME` for a type name excludes the type)

## Context

`:globs` of a `(:search)` were turned into a file type of the `ignore`
crate, which matches file names only: a glob with `/` was refused, there
was no negation, and a file type and globs could not be combined. The
live search takes `-g GLOB` in rg's spelling (ADR 0019), where
`-g 'src/**'` and `-g '!*.min.js'` are the common uses. Two ways to get
them:

- **Give the globs to the walker as overrides**, as rg does. In the
  `ignore` crate an override is asked before every other rule, so a file
  that a glob selects is searched although an ignore file names it or it
  is hidden. That is rg's documented behaviour ("overrides any other
  ignore logic").
- **Ask the same matcher (`ignore::overrides::Override`) in the search's
  entry filter**, after the walker's rules. The syntax is the same; a
  glob can then only take files away.

## Decision

The second. `:globs` are gitignore-style globs relative to `:dir`,
matched by an `Override` that the entry filter asks, next to the path
filters. A glob without `/` matches a name at any depth, one with a `/` at its
start or inside a path below `:dir` (a `/` at the end only says "a
directory"); `!` in front excludes; the last glob that matches
decides. With at least one glob without `!`, a file must match one. A
directory that an excluding glob matches is not entered. File types
(`:file-types`, any number, a file must be of one of them) and `:globs`
may be given together; a file must pass both.

## Consequences

- Unlike `rg -g`, a glob never brings back an ignored or hidden file.
  For that there are `:no-ignore` and `:hidden`. The promise that
  `:hidden nil` leaves out every dot entry "whatever the file type or
  globs" holds without a special case.
- Globs that were accepted before mean what they meant: names at any
  depth, case-sensitive.
- An including glob does not keep the walk out of other directories: the
  walk enters them and drops their files one by one. A literal include
  path filter has the same cost (architecture, "What is searched").
- With types and globs together a file must pass both, where in rg an
  including glob wins over the types: `rg -t elisp -g '*test*'`
  searches every file with "test" in its name. The useful combination,
  a type with excluding globs, behaves the same in both. So every kind
  of restriction narrows, and only restrictions of one kind (several
  types, several including globs) are alternatives.
- As in a gitignore file, a file below an excluded directory cannot be
  brought back by a later glob.
- An including glob must name files: `src/` matches the directory and
  none of its files, so it selects nothing; `src/**` is meant. An
  excluding glob keeps the walk out of a directory only when it matches
  the directory itself (`!gen/`), not with `!gen/**`.
- The matcher reads each glob as a line of a gitignore file. The service
  escapes a leading `#`, which would make the line a comment, and
  refuses a glob that names nothing (empty, blank, `!`, `/`), which the
  matcher would drop and so search everything.
- Where the user writes types and globs as plain words (the files
  prompt), a word that is a type name is a type and every other word a
  glob. A glob spelled like a type name is therefore taken as the type;
  it has to be written another way (`[m]ake`). The live grep's `-t` and
  `-g` say which is which.
