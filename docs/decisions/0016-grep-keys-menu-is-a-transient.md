# 0016 — The grep result buffer's key menu is a transient that runs the existing commands

Date: 2026-10-11
Status: accepted

## Context

`quarry-grep-mode` has some forty keys, several behind the `-` and `+`
prefixes and several that work only on a filter line or in a file block.
Nothing in the buffer shows them (backlog, "A menu to make the keys
discoverable"). Weighed: a transient menu as rg.el and Magit have; a
menu-bar and context menu; `which-key` descriptions for the prefix maps;
and, for a transient, whether its switches run a search at once or are
collected and applied with one final key, as `rg-menu` does.

## Decision

The menu is a transient prefix, `quarry-grep-menu`, on `?`. Each entry is
one of the existing commands under the key it has in the buffer; the menu
adds no command, no state and no second way to change a search. An entry
for a switch shows the current value; pressing its key runs the command,
which searches again, and the menu closes. Entries that do not apply at
point are shown inactive, not hidden.

The menu lives in its own file, `lisp/quarry-grep-menu.el`, which
`quarry-grep.el` autoloads, so transient is loaded on the first `?` and
not with the result buffer.

Only what the transient of Emacs 30.1 (0.7.2) has is used.

## Consequences

- No new dependency: transient ships with Emacs 30.1, which quarry
  requires.
- The menu and the keymap list the same keys twice. A test compares them,
  so a key added to one and not to the other fails the test run.
- Changing three switches takes three searches and three history
  entries, as it does without the menu. Accepted while a search takes
  under 100 ms; collecting changes would need a pending search next to
  the buffer's search.
- `?` no longer shows the mode's help; `h` and `C-h m` still do.
- A menu bar or context menu is not provided. It can be added later from
  the same commands.
