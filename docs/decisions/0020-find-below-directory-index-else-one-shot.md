# 0020 — Find below a directory: the project index, else a one-shot instance

Date: 2026-10-14
Status: accepted

## Context

Finding a file below a directory (Doom's `+default/find-file-under-here`,
`consult-fd`, `consult-find`) runs a process per input that walks the
directory each time. quarry's index holds the paths of a project, but a
directory need not be inside a project, and one inside a project may be
ignored by it (`node_modules/`, `build/`), so the index has no files
below it. Ways considered for such a directory:

- **Fall back** to `consult-fd` or a plain finder: quarry never walks
  ad hoc, but those directories stay slow and the command behaves
  differently by place.
- **A persistent instance** with the directory as its root: works today,
  but instances and watches pile up per directory visited, and `~`
  would be watched whole.
- **A one-shot instance**: walk the directory once when the prompt
  opens, without a watcher, and stop the instance when the prompt ends.
  This is how the grep service treats any directory (it walks per
  search and keeps nothing; ADR 0010, 0011), at one walk per prompt.
- **Always one-shot**, the index never used: one code path, but it
  repeats a walk the index has already done.

Where the index answers, its paths below the directory could be matched
whole (`src/grep/service.rs` for directory `src/grep/`) or relative to
the directory (`service.rs`). Matched whole, the directory's own
characters match every query (typing `src` in `src/` matches
everything) and rank by them.

## Decision

The project index where it can answer, a one-shot instance elsewhere.

- A local directory below the root of the current project (compared as
  true names), when the project index has files below it, is answered
  by that index: `(:query)` takes `:dir`, a path relative to the root,
  and matches, ranks and returns the paths below it relative to it.
- Every other local directory (no project, or the index has no files
  below it) gets an instance of the index service rooted at the
  directory, started with `:watch nil`, used for that one prompt and
  stopped when the prompt ends, also on quit or error.
- A remote directory is refused, as in quarry-grep.

## Consequences

- The command is fast and ranked in any local directory and leaves
  nothing running outside a project.
- A one-shot instance walks the whole directory once per prompt: on `~`
  that can take seconds and memory proportional to the file count. The
  consult prompt fills while the walk runs; the plain prompt waits for a
  first page as `quarry-find-file` does.
- A one-shot walk applies the walker rules, ignore files above the
  directory included (`parents(true)`), as grep does. From inside an
  ignored directory it lists what `rg --files` there would.
- The index service gets a start argument, `:watch`, and `(:query)` an
  argument, `:dir`; neither changes the meaning of existing requests.
- An empty directory inside a project, and a directory a running walk
  of the project has not reached yet, get a one-shot walk too: the
  index is used only when it already has files below the directory
  (`:indexing` cannot tell, it is true during any walk). The first
  finds nothing, harmless; the second costs an extra walk of just that
  directory and gives correct results.
