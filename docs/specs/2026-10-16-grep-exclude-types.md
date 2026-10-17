# Grep: excluding file types

Status: approved
Date: 2026-10-16

## Purpose

File types can be included in a search but not excluded. Today, to search
everything except JSON, you have to know the type's extensions and write
them as excluding globs (`!*.json`). This spec adds type exclusion, as
`rg -T` does, to the files prompt of `quarry-grep` and the result buffer,
and to the live grep. Included and excluded types can then be mixed.

Success: `!json !markdown` in the files prompt and `-- -T json -T
markdown` in the live grep search everything except JSON and Markdown
files. `rust !gen/**` and every other input without `!TYPE` gives the
same results as before.

## Scope

In:

- The service: excluded types in `:file-types` (ADR 0024).
- The files prompt (`quarry-grep`, `quarry-grep-literal`,
  `quarry-grep-project`, `f` in the result buffer) and the `FILES`
  argument of the commands: `!NAME` for a type name.
- The live grep (`quarry-consult-grep`, `quarry-consult-grep-project`):
  `-T TYPE` and `--type-not TYPE`.
- README, `docs/architecture/grep.md`, the module docs of
  `src/grep/service.rs`, and the backlog item "Excluding file types",
  which this spec replaces.

Out:

- Completion of `!NAME` in the files prompt. The prompt completes the
  whole input against the type names, so it only helps with the first
  word anyway. Revisit if the prompt gets per-word completion.
- `quarry-grep-dwim`: it searches the current buffer's type and takes no
  file restriction.
- `all` as an excluded type (`rg -T all`): it excludes every file that
  has a type. `all` is not a type name here (README), so `!all` stays a
  glob in the prompt, and `-T all` is the error "unknown file type: all".

## Design

### Meaning (ADR 0024)

The types of a search are one ordered list. Each entry is a type to
include (`rust`) or to exclude (`!rust`). For a file:

- If the file is of at least one listed type, the last such entry
  decides. `!` means the file is not searched; otherwise it is.
- If it is of none of them, it is searched only when no entry includes a
  type. With only excluded types, every file of another type, and every
  file without a type, is searched.

The globs, the path filters, the ignore files and the hidden rule apply
on top, unchanged (ADR 0017).

| You give | `a.rs` | `a.json` | `a.h` | `README` |
|---|---|---|---|---|
| `!json` | yes | no | yes | yes |
| `rust !json` | yes | no | no | no |
| `cpp !c` | no | no | no | no |
| `!c cpp` | no | no | yes | no |
| `c !cpp` | no | no | no | no |

(`a.h` is of `c` and `cpp`; `a.cpp` would be yes for `cpp !c` and `!c
cpp`. `README` is of no type.)

### Service (`src/grep/service.rs`)

- `:file-types` takes names from `(:types)`, each optionally with `!` in
  front: `("cpp" "!c")`. `file_types` calls `select` for a plain name and
  `negate` for a `!` name, in list order. The crate implements the rule
  above. Its `has_selected` is true only when a plain name is present.
- Checks, before anything is searched: the name after `!` must be a name
  from `(:types)`. An unknown, empty or `all` name fails with `unknown
  file type: NAME`. NAME is the entry as given, `!` included (`unknown
  file type: !nosuch`), so the user sees what they wrote.
- No other field and no reply shape change. An older Elisp never sends a
  `!` name; an older module given one answers `unknown file type: !json`.
  That is an honest error, and next-steps already tells the user to
  rebuild.

### Lisp: the search value and the files prompt (`lisp/quarry-grep.el`)

- `types` of `quarry-grep--search` holds the ordered list, entries as the
  service takes them (`"rust"`, `"!json"`). `quarry-grep--request` sends
  it unchanged.
- `quarry-grep--classify-files`: a word that is a type name is an
  included type. A word that is `!` followed by a type name is an
  excluded type. Every other word is a glob. Duplicate type entries
  (the same string) are kept only at their last place. This replaces
  `cl-pushnew`, which kept the first; for lists of included types only,
  the result is the same.
- `quarry-grep--files-text` is unchanged: the types in their order, then
  the globs. So the header line and the prompt default show `rust !json
  !gen/**` with no extra work. Types and globs are separate restrictions,
  so their relative order does not matter.
- The docstrings of `quarry-grep`, `quarry-grep-literal`,
  `quarry-grep-project` and `quarry-grep--classify-files` name `!NAME`.

### Live grep (`lisp/quarry-consult-grep.el`)

- A new entry in `quarry-consult-grep--options`: `-T`, `--type-not`,
  taking a value (`-Tjson`, `--type-not=json`, `-T json`). It appends
  `!VALUE` to the same `types` list that `-t` fills, so `-t cpp -T c`
  becomes `("cpp" "!c")`.
- `-t` and `-T` both apply the same rule: drop an earlier copy of the
  entry, then append. That replaces `-t`'s "skip if present".
- `-T` with a value that starts with `!` (`-T !json`) sends `!!json`, and
  the service answers `unknown file type: !!json`. No special case.
- The hand-over to the result buffer (`C-c C-o`) already copies `types`.
  It now carries excluded types, and the result buffer's header shows
  them.

### README

- "Grep", the files prompt paragraph: `!NAME` for a type name excludes the
  type, `![r]ust` is the glob. The combination table gets the rows
  "an excluded type (`!TYPE`)" and "a file of several listed types"
  (the last one decides), with the `cpp !c` example.
- "Live grep", the options table: `-T TYPE`, `--type-not TYPE`. The
  combination table gets the same two rows.
- The comparison with rg: `-T` behaves as in rg.

### Architecture (`docs/architecture/grep.md`)

The paragraph "The file types become one `ignore::types::Types`
selection…" now says: selected and negated in the given order, and the
last matching entry decides. The live grep paragraph lists `-T` next to
`-t`.

## Error handling

| Situation | What happens |
|---|---|
| `!nosuch` in the files prompt, `nosuch` not a type | A glob that excludes files and directories named `nosuch`, as today; no error (ADR 0024) |
| `-T nosuch` or `-T all` in the live grep | The service error `unknown file type: !nosuch` shows in the prompt, as `-t nosuch` does today |
| `-T` with nothing after it yet | Not an error: it is being typed, and the parser treats it as it treats a bare `-t` (architecture, "Live grep") |
| `-T ru` while typing `-T rust` | Error in the prompt until the name is complete; the same as for `-t` (grep backlog, "A failed search empties the candidate list") |
| A `(:search)` with `!x` sent to an old module | `unknown file type: !x`; rebuilding the module fixes it |
| Only excluded types, and they exclude every file | No hits, no error, as for any combination that no file passes |

## Testing

Automated:

- `cargo test` in `src/grep/service.rs`, on a temporary tree with `a.rs`,
  `a.json`, `a.h`, `a.cpp`, `a.c`, `README` and a hidden `.x.json`:
  - every row of the table under "Meaning";
  - `!json` together with an including glob and with an excluding glob;
  - `:hidden nil` with `!json`: `.x.json` stays out, as do other hidden
    files;
  - errors: `!nosuch`, `!`, `!all`, and `!` before the first unknown name
    in a mixed list (the first bad entry is the one named).
- ERT (`tests/run-ert.sh`):
  - `quarry-grep--classify-files`: `!json` becomes a type, `![j]son` and
    `!nosuch` become globs; duplicates are kept at their last place
    (`("c" "!c" "c")` → `("!c" "c")`); a list without `!` gives what it
    gave before.
  - `quarry-grep--request` sends `:file-types` in order with the `!`.
  - A search of a temporary tree through the commands with `!json` finds
    no JSON hits. The header line shows `!json`.
  - Live grep parser: `-T json`, `-Tjson`, `--type-not=json`, `--type-not
    json`; `-t cpp -T c` in order; `-T c -t c` → `("c")`; `-T` alone is
    no error, as `-t` alone. The hand-over carries `!json` into the
    result buffer.
- `cargo clippy --all-targets -- -D warnings` and `cargo fmt --check`.

Manual, in the author's setup after rebuilding the module:

- `M-x quarry-grep` with `!json !markdown` in this repository; then `f`
  in the result buffer and change it to `rust !gen/**`.
- `quarry-consult-grep-project` with `fn -- -T rust`; then `C-c C-o` and
  check the header line.

## Tasks

The implementation branch starts from `master` once the replace branch
(PR #7) is merged: that branch changes the same README sections and
`quarry-grep.el`.

- [x] 1. **Service.** Excluded types in `:file-types` as under "Service":
  `select` and `negate` in order, the error for a bad `!` entry, the
  module docs (the `:file-types` row and the error table), the
  architecture paragraph, and the tests listed for `cargo test`. *Done
  when* `cargo test`, `cargo clippy --all-targets -- -D warnings` and
  `cargo fmt --check` pass, and each row of the table under "Meaning" is
  a test.
- [ ] 2. **Files prompt and search value** (after 1). `!NAME` in
  `quarry-grep--classify-files`, keep-last duplicates, docstrings, the
  README paragraph and combination table for the files prompt, and the
  ERT tests for classify, request and the command search. *Done when*
  `tests/run-ert.sh` passes with the module built from task 1, and the
  existing grep tests pass unchanged.
- [ ] 3. **Live grep** (after 1; can run in parallel with 2). `-T` and
  `--type-not` in `quarry-consult-grep--options`, the shared keep-last
  rule for `-t` and `-T`, the README options and combination tables, the
  architecture's live grep paragraph, and the ERT tests for the parser
  and the hand-over. *Done when* `tests/run-ert.sh` passes with consult
  on `QUARRY_TEST_LOAD_PATH`, and the live grep tests pass unchanged.
- [ ] 4. **Docs wrap-up.** The backlog item "Excluding file types" is
  removed, next-steps says to rebuild the module for `!TYPE`, and the
  spec is set to `implemented`. *Done when* `devflow:doc-checker` reports
  nothing stale for the branch.
