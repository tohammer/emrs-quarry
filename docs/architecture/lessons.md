# Architecture: lessons

Part of [the architecture](../architecture.md).

- **nucleo-matcher 0.3.1 has a prefix bug.** Case-sensitive prefix and
  postfix atoms on ASCII text compare the whole haystack, so `^Fo` does not
  match `Foo`. The crate is pinned to an upstream git commit that fixes it
  (ADR 0003). The narrowing tests assert the pinned version's behaviour and
  fail when an update changes it.
- **Smart normalization can widen the match set.** Typing a non-ASCII
  character switches normalization off for that atom, so a longer query can
  match paths the shorter one did not. Incremental narrowing therefore stops
  when both the last atom and the appended text are non-ASCII
  (`matcher::narrows`).
- **`notify-debouncer-full` is quadratic in the number of watches.** It
  keeps the watched roots in a `Vec` and scans it on every `watch` call,
  which is unusable with hundreds of thousands of directories. quarry uses
  the debouncer only for debouncing and adds and removes watches on the
  backend directly (`SharedWatcher` in `src/watch.rs`).
- **inotify limits matter on AOSP-sized trees.** One watch per indexed
  directory needs about 150,000 watches, more than many default
  configurations allow. The watch failure is handled by degrading to a
  rescan before each prompt, and the README tells users how to raise the
  limit.
- **The user's global gitignore changes counts.** The walk applies the
  user's global git excludes, also outside git repositories, so the number
  of indexed files can be lower than the number of files on disk, for
  example in a generated benchmark tree.
- **nucleo unescapes ASCII and non-ASCII needles differently.** `\ ` is a
  space only in an ASCII needle, and a backslash before another character
  is doubled in a non-ASCII one. A term with a backslash that turns
  non-ASCII changes its needle in the middle, which broke narrowing for
  substring terms; `matcher::narrows` excludes that case. The substring
  style reuses `Atom::parse` and only switches the kind, so it inherits
  nucleo's unescaping instead of rebuilding needles.
- **A category override does not replace `completion-styles`.** Emacs
  appends the user's styles behind the override's, and tries them when the
  first returns nothing. orderless then asked the table for the empty
  prefix and, since the table ignores `completion-regexp-list`, a query
  without matches listed every file. The prompt now sets
  `completion-styles` buffer-locally (ADR 0005).
- **Batch-mode `completing-read` reads stdin.** The ERT tests drive the
  minibuffer with `execute-kbd-macro` instead.
- **`project-read-file-name-function` cannot speed up `project-find-file`.**
  `project-find-file` builds the full file list with `project-files` before
  calling it, which is the slow part. quarry remaps the command instead
  (ADR 0001).
- **A walk's index must not replace the live one until it is complete.**
  Generations keep queries on the previous index and replay recorded
  changes onto the fresh one, because a change during a walk may or may not
  be seen by the walker.
- **`consult--read` wraps async tables by default.** Unless `:async-wrap`
  is given, it passes the table through `consult--async-wrap`, which adds
  split, indicator and refresh. A pipeline that already contains them
  needs `:async-wrap #'identity`; otherwise the split initialises twice.
- **`format-mode-line` returns an empty string in batch.** A header or
  mode line built with `(:eval …)` cannot be read through it in the ERT
  suite. The grep tests call the function behind the `:eval`
  (`quarry-grep--header`) directly; that it renders in a real frame was
  checked by hand in a terminal Emacs.
- **`C-u -` never reaches a key sequence that starts with `-`.** After a
  bare `C-u`, `universal-argument-map` takes `-` as the sign of the
  argument. The regexp variants of the grep filter commands therefore
  have their own keys (`- P`, `+ L`, ...) and no prefix argument.
- **wgrep has no hook for leaving its edit mode,** and it leaves its
  `read-only` and `wgrep-*` text properties behind. quarry-grep notices
  the end from a buffer-local `post-command-hook` (the local map is no
  longer `wgrep-mode-map`) and cleans up there.
- **wgrep's abort replaces the whole buffer text** with a copy taken on
  entry (`erase-buffer`, then the copy). Text properties come back,
  markers and overlays do not: the status line's marker must be found
  again.
- **Text typed in wgrep's edit mode has no text properties.** wgrep makes
  the last character of a line's prefix `rear-nonsticky`, so nothing is
  inherited at the start of the text. Code that follows a property over
  a block (folding) must re-apply it after a commit.
- **`read-only` text does not stop an insertion in front of it,** so the
  first character of the buffer needs `front-sticky (read-only)`; and
  `wgrep-ignore` on an empty line from its start to its end is no text
  at all. wgrep makes the newline before an ignored run read-only, so
  the run must include the empty line's newline, or the line above can
  be joined with it.
- **`wgrep-setup-internal` binds `wgrep-enable-key` in the mode's own
  map.** A mode that needs checks before edit mode sets
  `wgrep-original-mode-map` itself and calls
  `wgrep-change-to-wgrep-mode` from its own command.
