# 0009 — The remap follows its option through a variable watcher

Date: 2026-10-09
Status: accepted

## Context

`projdex-find-file-command` chooses the command `projdex-mode` puts in
place of `project-find-file` (`projdex-find-file` or
`projdex-consult-find-file`). A plain `setq` should take effect at once,
before or after the mode is enabled, without a `:set` function that only
customize runs. The first version bound the remap to a `menu-item` whose
`:filter` returned the option's value. `command-remapping` follows such a
filter, but `where-is-internal` does not: with the consult command
chosen, `C-h w`, the `M-x` key hint and menu labels showed no key for it.
Found in the review of the consult spec.

## Decision

`projdex-mode-map` binds the remap directly to the option's value at
load time. A variable watcher (`add-variable-watcher`) rebinds it with
`keymap-set` on `set`, `let` and `unlet` of the global value; buffer-local
values, `makunbound` and `defvaralias` are ignored.

## Consequences

- `where-is` and the key hints show the key for the chosen command.
- `setq`, `let`, `customize` and use-package's `:custom` all update the
  binding at once; a `let` restores it on exit.
- A buffer-local value of the option has no effect, since the keymap is
  global.
