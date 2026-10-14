# Find a file below a directory

Status: implemented
Date: 2026-10-14

## Purpose

Two commands that find a file below a directory, by default
`default-directory`, with quarry's matcher and ranking, in the manner of
Doom's `+default/find-file-under-here`, `consult-fd` and
`consult-find`. Those run a process per input that walks the directory
each time. Here a directory inside a project is answered from the
project's index, and any other local directory from a single walk per
prompt (ADR 0020).

Success: the commands can take the place of `+default/find-file-under-here`
in the author's daily use. In a subdirectory of an indexed project the
prompt is as fast as `quarry-find-file`. Outside a project it opens at
once, fills while the directory is walked, and leaves nothing running
after the prompt ends.

## Scope

In:

- `:dir` for `(:query)` of the index service: only paths below a
  directory, matched, ranked and returned relative to it.
- `:watch` as a start argument of the index service: an instance
  without a watcher.
- One-shot instances on the Elisp side: started for one prompt, stopped
  when it ends.
- `quarry-find-file-in-directory` in `lisp/quarry.el` and
  `quarry-consult-find-file-in-directory` in `lisp/quarry-consult.el`.

Out:

- Key bindings and remaps. The package binds nothing; the README shows
  the lines for Doom, as for the live grep.
- Remote directories: refused, as in quarry-grep.
- `project-files` for a subdirectory (`DIRS` other than the root), which
  `:dir` would make possible; the `:files` stream gets no `:dir` here.
  Goes to the backlog.
- Persistent instances for directories outside a project, and reuse of
  a one-shot walk across prompts.

## Design

### The index service: `:dir`

`(:query :text S :limit N :positions BOOL :substring BOOL :dir D)`.
`:dir` is optional; nil or `""` mean the whole index, as today.

- `D` is a path relative to the root in the index's own form (`/`
  separated). The service adds a trailing `/` when it is missing. A
  `D` that starts with `/` or has an empty, `.` or `..` component is an
  error reply (`invalid :dir`).
- Candidates are the index paths that start with `D` (with its `/`, so
  only whole components: `src/` does not take `srcx/a`).
- Each candidate is matched on the part after `D`: its haystack is the
  index's `Utf32String` sliced after the character count of `D`. Scores,
  positions and `:groups` refer to that part. The ranking is unchanged
  (score, then path length, then path); with a common prefix, length
  and order of the full paths equal those of the parts.
- `:paths` are relative to `D`; `:total` counts the matches below `D`
  only; `:indexing` is as today.
- The narrowing cache (`matcher::narrows`) is reused only for the same
  `D`: the cache key gains the directory, next to the text, style and
  index version.
- A `D` with no paths below it is not an error: `:total 0`.

`Matcher::query_styled` takes the directory as an argument; the existing
callers pass none. The module docs of `src/service.rs` give the new
shape.

### The index service: `:watch`

Start argument `:watch BOOL`, default t. With nil, `start` creates no
`Watcher`: `(:status)` reports `:watching nil`, no `(:watch-failed)`
event is emitted, and walks report their directories to nobody.
Everything else, walks, generations, `(:rescan)`, queries, is as with a
watcher.

### Elisp: records, targets and queries (`lisp/quarry.el`)

- `quarry--rec` gains a slot `one-shot`. `quarry--start` gains an
  optional ONE-SHOT argument. With it, it starts the instance with
  `:watch nil`, sets `watching` nil and `one-shot` t, and does **not**
  put the record into `quarry--instances` or record failures in
  `quarry--failures`. `quarry-stop`, `quarry-stop-all`, `quarry-status`
  and `project-files` never see one-shot records.
- A *target* is either a root (a string) or a one-shot record.
  `quarry--target-rec` returns the record of a target: for a root,
  `quarry--ensure`, as today; for a record, the record itself while its
  instance is starting or running, and otherwise a `user-error`
  "quarry: the walk of DIR has ended".
- `quarry--call-sync`, `quarry--table`, `quarry--prepare` and
  `quarry-consult--async` take a target where they take a root today.
  `quarry--prepare` sends no `(:rescan)` to a one-shot record, which is
  not watching by design.
- `quarry--request`, `quarry--table`, `quarry-query`,
  `quarry-query-async` and `quarry-consult--async` gain an optional
  DIR, sent as `:dir` when non-nil. The public `quarry-query` and
  `quarry-query-async` still take a root (and accept a one-shot record
  too, for the commands); DIR is a new last optional argument.

### Elisp: where a directory is answered

`quarry--dir-target (dir)` returns `(TARGET . REL)` for an absolute,
local, existing directory DIR:

1. `(project-current nil dir)`. If there is a project with a local root,
   compare the true names of DIR and the root. If DIR is the root, the
   result is `(ROOT . nil)`.
2. If DIR is below the root, REL is DIR's true name relative to the
   root's, with a trailing `/`. `quarry--prepare` the root (with the
   caller's NO-WAIT), then query `:text "" :limit 1 :dir REL`. If the
   reply has `:total` above 0, the result is `(ROOT . REL)`.
3. Otherwise (no project, a remote project root, DIR not below the
   root's true name, or no indexed files below DIR, whether or not the
   project's walk is still running) start a one-shot record for DIR and
   `quarry--prepare` it. The result is `(REC . nil)`.

The commands check DIR first: a remote DIR is a `user-error` "quarry
finds files in local directories only: DIR"; a missing one is a
`user-error` that names it. As in `quarry--prepare`, everything that
starts an instance or offers to build the module happens before the
prompt.

### The commands

`quarry-find-file-in-directory (&optional dir)`, autoloaded.
Interactively DIR is `default-directory`; with a prefix argument it is
read with `read-directory-name` ("Find file in directory: "), as in
`quarry-consult-grep`.

- After the checks, `quarry--dir-target`, then a `completing-read` set
  up like `quarry-find-file`'s: the `quarry` style through the same
  category override and buffer-local `completion-styles`, the table of
  the target and REL, require-match `confirm`, history
  `quarry-directory-file-history`. The prompt is "Find file in
  ABBREVIATED-DIR: ", with `abbreviate-file-name`.
- Candidates are relative to DIR. The command visits DIR plus the
  chosen path with `concat`, not `expand-file-name`, as
  `quarry-find-file` does. Input that is not a candidate but completes
  to exactly one is visited as that one, as in `quarry-find-file`.
- The prompt runs in `unwind-protect`: a one-shot record is stopped
  with `emrs-stop` when the prompt ends, normally, on `C-g` or on an
  error.

`quarry-consult-find-file-in-directory (&optional dir)`, autoloaded
from `lisp/quarry-consult.el`. Same DIR, checks, target and
`unwind-protect`. The prompt is `quarry-consult-find-file`'s pipeline
with `quarry-consult--async` on the target and REL, `quarry--prepare`
with NO-WAIT, require-match t, history
`quarry-consult-directory-history`. It needs consult as
`quarry-consult-find-file` does and signals the same `user-error`
without it. The step's existing re-query while `:indexing` is true makes
a one-shot prompt fill during its walk.

Shared code between each new command and the existing project command
of the same front end goes into a helper. The existing commands keep
their behaviour, including their prefix argument (`include-all`).

## Error handling

| Situation | Result |
|---|---|
| DIR remote | `user-error` before the prompt; no instance started |
| DIR missing or not a directory | `user-error` naming it |
| Module missing | `quarry--prepare`'s offer to build, before the prompt, as today |
| Project instance cannot start or fails | `user-error` from `quarry--prepare`, as today |
| One-shot instance cannot start | `user-error` from `quarry--prepare`; nothing is left running |
| One-shot instance fails during the prompt | The table or the step reports it once and shows no candidates, as for a failed project instance; the record is stopped at the end of the prompt anyway (a no-op) |
| Prompt quit or error | `unwind-protect` stops the one-shot instance; its walk is cancelled by `stop` |
| Query timeout | As today: no candidates and one message |
| `invalid :dir` reply | Only from a programming error; the Elisp side always sends a normalized relative path |
| Very large DIR (`~`) | Allowed; the walk takes as long as it takes, the consult prompt fills meanwhile, `C-g` ends it |

## Testing

Rust (`src/matcher.rs`, `src/service.rs`, through `emrs::testing::Host`
where a service is involved):

- `:dir` returns only paths below it, relative to it, with `:total`
  counting only those; whole components only (`src/` vs `srcx/`).
- A query `src` in `:dir "src/"` ranks by the part below (`src/a/src.rs`
  above `src/main.rs`): the directory's characters do not match.
- Positions and groups refer to the relative path, also with a
  non-ASCII directory name.
- Narrowing: a longer text in the same `:dir` scores only the previous
  matches; a different `:dir` scores fresh. The existing check that the
  optimisations return what single-threaded scoring of the whole index
  returns covers a `:dir` as well, parallel scoring included.
- Missing `:dir` and `""` give today's results; `"src"` and `"src/"`
  are the same; `/src`, `a//b`, `./a`, `a/../b` are `invalid :dir`.
- `:watch nil`: `:watching` false, no events beyond `:indexed`, a new
  file is not picked up without `(:rescan)`, and `(:rescan)` picks it up.

ERT (generated trees, as now):

- `quarry--dir-target`: the root gives `(ROOT . nil)`; a subdirectory
  with files gives `(ROOT . "sub/")`, also when DIR is reached through
  a symlink; an ignored subdirectory and a directory outside any project
  give a one-shot record, also while the project's probe reports
  `:indexing` t with `:total` 0; a one-shot started there is stopped
  when `quarry--prepare` signals an error or `quit`.
- `quarry-find-file-in-directory` on a subdirectory visits DIR plus the
  chosen relative path; candidates do not include files outside DIR.
- One-shot: the instance is running during the prompt and stopped after
  it on RET, on `C-g` (a `quit` signalled from the prompt) and on an
  error; it never appears in `quarry--instances`.
- A remote DIR and a missing DIR are `user-error`s with no instance
  started.
- A prefix argument asks for the directory in both commands; the consult
  command also refuses a remote or missing DIR, and checks for consult
  before asking.
- The consult command, with consult on `QUARRY_TEST_LOAD_PATH`: the same
  visit and the same stop of a one-shot record; skipped without consult,
  as the other consult tests.
- The existing tests of both front ends pass unchanged.

Manual checks (added to the file finder backlog's checks until done):

- Doom: the README's binding in place of `+default/find-file-under-here`
  on `SPC f F`, used in a project subdirectory, in an ignored directory
  (`node_modules/`), in `~/Downloads` and in `~`.
- In `~`, the consult prompt fills while the walk runs, and `C-g` ends
  it with no instance left (`emrs` list or `top`).
- Vertico and the default completion UI both show ranked, highlighted
  relative candidates.

## Tasks

- [x] 1. `:dir` in `(:query)`: argument, normalization and its error,
  filter, sliced haystack, relative paths and positions, `:total`,
  narrowing cache keyed on the directory; module docs of
  `src/service.rs`. *Done when* the Rust tests above for `:dir` pass,
  `cargo test` and `cargo clippy --all-targets -- -D warnings` pass, and
  queries without `:dir` are unchanged (existing tests).
- [x] 2. `:watch` start argument (parallel with 1). *Done when* the
  `:watch nil` tests above pass, a start without `:watch` behaves as
  today (existing watcher tests), and the module docs give the argument.
- [x] 3. Elisp core in `lisp/quarry.el`: the `one-shot` slot,
  `quarry--start` with ONE-SHOT, targets and `quarry--target-rec`, DIR
  through the request, table, `quarry-query`, `quarry-query-async`,
  `quarry--prepare` without rescan for one-shot records,
  `quarry--dir-target`, `quarry-find-file-in-directory` and
  `quarry-directory-file-history`. Depends on 1 and 2. *Done when* the
  ERT tests above except the consult one pass with
  `tests/run-ert.sh`, and the byte-compile of `lisp/quarry.el` is
  warning-free.
- [x] 4. `quarry-consult-find-file-in-directory` and
  `quarry-consult-directory-history` in `lisp/quarry-consult.el`, with
  DIR through `quarry-consult--async`. Depends on 3. *Done when* the
  consult ERT test passes with consult on `QUARRY_TEST_LOAD_PATH`, is
  skipped without it, and the existing consult tests pass.
- [x] 5. Documentation: README (the two commands, the prefix argument,
  where a directory is answered from, the one-shot walk and its cost on
  large directories, the Doom binding lines), `docs/architecture.md`
  (components, the request list), `docs/architecture/elisp.md`
  (targets, one-shot records, the commands),
  `docs/architecture/service.md` (`:dir`, `:watch`), the backlog
  (survey item 1 removed; `project-files` for a subdirectory added; the
  manual checks above). Can run alongside 4. *Done when* the
  doc-checker finds nothing stale for this change.

## Deviations

Found in the review (2026-10-14). Where this list and the sections above
differ, the list says what was built.

- Step 2 of "Elisp: where a directory is answered" used the project index
  when the probe reply had `:total` above 0 or `:indexing` t. `:indexing`
  is true during any walk, also the rescan `quarry--prepare` sends to an
  unwatched project, so an ignored directory such as `node_modules/` got
  the index and a prompt that stayed empty. The rule is now `:total`
  above 0 only. A directory the first walk has not reached yet gets a
  one-shot walk of just that directory: correct results, an extra walk.
