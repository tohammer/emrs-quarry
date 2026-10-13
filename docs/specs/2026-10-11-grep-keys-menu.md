# Grep: a menu that shows the keys

Status: implemented
Date: 2026-10-11

Superseded in part by `2026-10-12-live-grep.md`: the menu's entry reads
"file types".

## Purpose

Make the keys of the `*quarry-grep*` buffer discoverable: `?` opens a
menu that lists every command of the buffer under its key, with the
current value of each switch.

Success: in a result buffer `?` shows the menu; `c` in it cycles the case
setting exactly as `c` in the buffer does; with point on a result line
the entries for a filter line are shown inactive; a key added to the
mode's keymap without a menu entry fails the tests.

## Scope

In:

- The command `quarry-grep-menu`, a transient prefix, in the new file
  `lisp/quarry-grep-menu.el`; `?` in `quarry-grep-mode-map`.
- A hint in the header line that names `?`.
- Functions in `quarry-grep.el` that say whether a command applies at
  point, where the menu needs one and none exists.
- README and architecture docs.

Out:

- New commands, changed keys (other than `?`), or changes to what a
  command does.
- Collecting several changes in the menu and searching once (ADR 0016).
- A menu bar or context menu, `which-key` descriptions.
- A menu for wgrep's edit mode; its keys are wgrep's.

## Design

ADR 0016 holds the decision and its reasons.

### The menu

`quarry-grep-menu` is defined with `transient-define-prefix`. Every
entry is an existing command under the key it has in
`quarry-grep-mode-map`, written without the space for two-key bindings
(`-p` for `- p`). Pressing a key runs the command and closes the menu.

Groups and entries. *Value* is shown after the description; *Inactive
when* names the condition under which the entry is shown inactive
(transient's `:inapt-if`).

| Group | Key | Command | Value | Inactive when |
|---|---|---|---|---|
| Search | `g` | `quarry-grep-rerun` | | |
| | `r` | `quarry-grep-change-regexp` | | |
| | `t` | `quarry-grep-change-literal` | | |
| | `d` | `quarry-grep-change-directory` | the directory, abbreviated | |
| | `f` | `quarry-grep-change-files` | the file type as in the header line | |
| | `C-c C-k` | `quarry-grep-cancel` | | no search is running |
| Switches | `c` | `quarry-grep-cycle-case` | `smart`, `sensitive`, `insensitive` | |
| | `i` | `quarry-grep-toggle-ignore` | `on`, `off` | |
| | `H` | `quarry-grep-toggle-hidden` | `on`, `off` | |
| | `C` | `quarry-grep-set-context` | as the header's `ctx` part | |
| | `B` | `quarry-grep-set-context-before` | the count before | |
| | `A` | `quarry-grep-set-context-after` | the count after | |
| Include | `+l` `+L` `+p` `+P` | the four include commands | | |
| | `+d` | `quarry-grep-include-directory` | | no file at point, or the file is in the search directory itself |
| Exclude | `-l` `-L` `-p` `-P` | the four exclude commands | | |
| | `-f` | `quarry-grep-exclude-file` | | no file at point |
| | `-d` | `quarry-grep-exclude-directory` | | as `+d` |
| Filters | `%` | `quarry-grep-toggle-regexp` | what the filter at point becomes | no filter at point |
| | `x` | `quarry-grep-toggle-filter` | | no filter at point |
| | `!` | `quarry-grep-flip-filter` | | no filter at point |
| | `k` | `quarry-grep-remove-filter` | | no filter at point |
| | `K` | `quarry-grep-remove-other-filters` | | the search has no filter besides the primary one (the command does not need a filter at point) |
| Results | `RET` | `quarry-grep-visit` (visits a line, edits a filter) | | |
| | `n` `p` | next and previous match | | |
| | `}` `{` | next and previous file | | |
| | `TAB` | `quarry-grep-toggle-fold` | | no file block at point |
| | `<backtab>` | `quarry-grep-toggle-fold-all` | | |
| Edit | `e` | `quarry-grep-edit` (described as "edit the results (wgrep)") | | a search is running, there are no results, or wgrep is not installed |
| History | `C-c <` | `quarry-grep-history-back` | | no earlier search |
| | `C-c >` | `quarry-grep-history-forward` | | no later search |

- The values are those of the search of the buffer the menu was opened
  from.
- The description of a switch reads as label and value, for example
  `case: smart`, `ignore files: on`, `context: 1/3`.
- `M-N` and `M-P` (second keys for `}` and `{`) and the mouse bindings
  have no entry. (Changed after the review: `RET` is one entry for both
  of its uses and is always active; shown only as "edit the filter" it
  looked as if `RET` did nothing on a hit.)
- A numeric prefix argument typed before `?` or with `C-u` inside the
  menu reaches the command, so `C-u 3` then `C` in the menu sets the
  context to 3. Digits alone inside the menu are not prefix keys.
  (Found while implementing: transient does not pass on an argument
  typed before `?`, so the command hands it over itself; with such an
  argument `C-g` must be pressed twice to close the menu.)
- Whether wgrep is installed is asked with `featurep` and
  `locate-library`, so opening the menu does not load wgrep.
- An inactive entry cannot be run from the menu; its key in the buffer
  keeps signalling the command's `user-error`.
- Only what transient 0.7.2 (Emacs 30.1) has is used.

`quarry-grep-menu` is a `user-error` outside a `quarry-grep-mode` buffer
and while the results are being edited with wgrep (the check the change
commands use).

### The hint in the header line

The header line gets a last part, after the hits: `? menu`, with
`?` in the face of the other parts' values. A click on it runs
`quarry-grep-menu`; its help text is "show all keys (?)". (Changed after
the author tried it: the draft had the hint first, so that a long
directory could not push it out of the window; at the end it does not
shift the other parts, and a narrow window can cut it off.) While
the results are being edited the part is not shown, since `?` is then
text.

### In quarry-grep.el

- `"?" #'quarry-grep-menu` in `quarry-grep-mode-map`, and
  `(autoload 'quarry-grep-menu "quarry-grep-menu" nil t)`, so transient
  loads on the first `?`. `quarry-grep-menu.el` requires `quarry-grep`
  and `transient`.
- The conditions of the table are functions that return nil or non-nil
  and do not signal. Where a command has such a check only as code that
  signals a `user-error` (`quarry-grep--filter-at-point`,
  `quarry-grep--file-at-point`, `quarry-grep--directory-at-point`, the
  checks in `quarry-grep-edit`, the history commands and
  `quarry-grep-remove-other-filters`), the check is split so that the
  command and the menu use the same function. The messages of the
  commands do not change.
- The mode's docstring names `?`.

### Documentation

README: `?` in the keys table and a sentence that it lists all keys;
the hint in the description of the header line; that the mode help is
on `h`. `docs/architecture/grep.md`: the menu, its
file and the rule that it only runs existing commands.
`docs/architecture.md`: the new file in the file list, if it has one.
`docs/next-steps.md`: a new file in `lisp/` needs the build directory
removed and a `doom sync` in development mode (the existing note covers
it; name this file as the current case).

## Error handling

- transient cannot be loaded: `?` signals Emacs's load error. It ships
  with Emacs 30.1, so this needs a broken installation.
- The buffer's search changes while the menu is open (a running search
  finishes): the inactive state shown is that of the moment the menu
  opened. A command run in the wrong state signals its own `user-error`.

## Testing

- **ERT** (`tests/quarry-grep-tests.el`):
  - Every key of `quarry-grep-mode-map` that is bound to a `quarry-grep-`
    command, except `?`, `M-N`, `M-P` and the mouse bindings, has a menu
    entry with the same key and the same command, and the menu has no
    entry whose command the keymap does not bind to that key.
  - The descriptions of the switches show the values of the buffer's
    search, for two different searches.
  - Each condition function: non-nil and nil in a buffer that has the
    matching state (point on a filter line, on a result line, on a file
    heading, on a file in the search directory itself; search running;
    no results; history with and without an earlier and a later entry;
    one filter and several).
  - `quarry-grep-menu` is a `user-error` in another mode and in edit
    mode.
  - The header line ends with the hint, the hint carries the click
    binding for `quarry-grep-menu`, and it is absent in edit mode.
  - Opening the menu and pressing a key (`? c`) changes the search as
    `c` does, if transient can be driven in batch Emacs; if it cannot,
    the test is left out and the manual check below covers it.
  - The existing tests pass unchanged, including those of the commands
    whose checks were split.
- **Manual**, in terminal Emacs under a pty during the review: `?` shows
  the menu with the values of the search; `c`, `-p` and `C-u 3 C` from
  the menu; the filter entries are inactive on a result line and active
  on a filter line; `e` from the menu enters edit mode and the hint
  leaves the header line; `C-g` closes the menu.
- **Manual, by the author:** the menu in the author's Doom setup (evil,
  theme, GUI frame), and on Emacs 30.1 with its own transient, which was
  not run here.

## Tasks

In order.

- [x] 1. The condition functions in `quarry-grep.el`, with the commands
  changed to use them, and their tests. *Done when* the condition tests
  exist and `tests/run-ert.sh` passes with the existing tests unchanged.
- [x] 2. `lisp/quarry-grep-menu.el` with `quarry-grep-menu`, the `?`
  binding and the autoload, the hint in the header line, the mode
  docstring, the remaining tests of
  the Testing section, the README. *Done when* those tests exist,
  `tests/run-ert.sh` passes and the file byte-compiles without warnings.
- [x] 3. Docs: `docs/architecture/grep.md`, `docs/architecture.md`, the
  backlog item "A menu to make the keys discoverable" removed, the
  author's manual checks added to the backlog's "Manual checks not done
  yet", `docs/next-steps.md`. *Done when* `devflow:doc-checker` finds
  nothing stale for this change.
