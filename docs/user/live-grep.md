# Live grep

`quarry-consult-grep` and `quarry-consult-grep-project` search while you
type in the minibuffer and show the hits as candidates, in the manner of
`consult-ripgrep`. Each input cancels the search for the previous one.
`RET` visits the hit.

Prerequisite: [consult](https://github.com/minad/consult). Tested with
consult 3.7 only; without consult the commands say so.

| Command | Searches | With a prefix argument |
|---|---|---|
| `quarry-consult-grep` | `default-directory` | asks for the directory |
| `quarry-consult-grep-project` | the project root, or `default-directory` outside a project | asks for a project |

An active region is the initial input, quoted to be searched literally.
`M-n` inserts the symbol at point. The history is
`quarry-consult-grep-history`. Remote (TRAMP) directories are refused.

The package binds no keys. For Doom see [Doom Emacs](#doom-emacs); else,
for example:

```elisp
(keymap-global-set "C-c s" #'quarry-consult-grep-project)
```

For the result buffer with filters, editing and replace, see the
[grep guide](grep.md).

## Input

With consult's default split style `perl`, the input reads
`#search part#filter part`. The search part goes to quarry; the filter
part filters the candidates in Emacs with your completion styles. A
search starts when the search part has `consult-async-min-input`
characters (3 by default).

The search part is a list of terms, then, after ` -- `, options:

```text
#fn walk !test -- -t rust -g !gen/**#async
```

- A line must match every term, in any order.
- A line must not match a term with `!` in front (`!test`).
- `\ ` is a space inside a term (`foo\ bar`); `\!` at the start of a
  term is a literal `!`. Any other backslash stays part of the pattern.
- Terms are Rust regexps, or literals with `-F`.
- Files are searched for the first term, so a rare first term is
  faster. The preview goes to the first term's match.
- Case follows `quarry-grep-case` (smart by default), and hidden files
  are searched when `quarry-include-hidden` is non-nil, unless an option
  says otherwise.

A search collects at most `quarry-consult-grep-max-lines` hits (1000); a
search that stopped there shows `[first 1000 hits]` after the input.
Errors, such as an invalid regexp or an unknown option, show in the same
place.

### Options

Spelled as in rg. A value is the next word, or attached (`-trust`,
`--type=rust`).

| Option | Meaning |
|---|---|
| `-t TYPE`, `--type TYPE` | Search files of this type; repeatable |
| `-T TYPE`, `--type-not TYPE` | Leave out files of this type; repeatable |
| `-g GLOB`, `--glob GLOB` | Search only files the glob selects; repeatable |
| `-F`, `--fixed-strings` | Terms are literals, not regexps |
| `-i`, `--ignore-case` | Case rule `insensitive` |
| `-s`, `--case-sensitive` | Case rule `sensitive` |
| `-S`, `--smart-case` | Case rule `smart` |
| `-u`, `--no-ignore` | Do not use ignore files |
| `-.`, `--hidden` | Search hidden files |
| `--no-hidden` | Do not search hidden files |
| `-uu` | `-u` and `-.` |

Of several case options, the last counts. No other rg option is
supported (`-w`, `-C`, `-m`, `--pcre2`, ...), nor clusters such as `-Fi`
(write `-F -i`). An unknown option is shown as an error and nothing is
searched. While you type, an option without its value, a partial option
such as `--hid`, a lone `!` and a trailing backslash are ignored.

### Types and globs

They combine as in the files prompt of the
[result buffer](grep.md#file-types-and-globs):

| You give | A file is searched if |
|---|---|
| several `-t` | it is of one of the types |
| several including `-g` | it matches one of the globs |
| `-t` and `-g` | it passes the types and the globs |
| an excluding `-g !...` | no excluding glob matches it; the last matching glob decides |
| `-T` | it is not of that type; with only `-T`, files of no type are searched too |
| a file of several `-t` and `-T` types | the last of them decides: `-t cpp -T c` leaves out `.h` files |

This differs from rg, where an including `-g` overrules `-t`. Here only
options of the same kind are alternatives, and every kind narrows:
`quarry -- -t elisp -g *test*` searches Elisp files whose name contains
`test`.

`-g` also differs from rg's:

- A glob never brings back an ignored or hidden file; use `-u` and `-.`.
- A glob with a `/` at the start or inside is anchored at the searched
  directory: `!gen/**` excludes a top-level `gen/`, `!**/gen/**` one at
  any depth. A glob without such a `/` matches a name at any depth
  (`*.el`, and `!gen/` for every directory `gen`).
- To search one directory, name its files: `-g src/**`. `-g src/`
  selects nothing.
- `!gen/` skips the directory; `!gen/**` gives the same hits more
  slowly.
- A glob that starts with `#` is a glob (`#*#`), not a comment.

## Continue in the result buffer

Press `C-c C-o` (`quarry-consult-grep-to-buffer`) to leave the prompt
and run the typed search in the `*quarry-grep*` buffer, where you can
add filters, edit and replace.

- The terms become filters, in their order. File types, globs, case
  rule and the ignore and hidden switches carry over.
- Context lines come from `quarry-grep-context-before` and
  `quarry-grep-context-after`; the limit is `quarry-grep-max-lines`.
- The filter part of the input does not carry over; the echo area says
  so.
- Input that is no search, such as one with an unknown option, keeps the
  prompt open.

To use another key, bind the command in `quarry-consult-grep-map`.

The candidates have the format and category of `consult-ripgrep`, so
preview, grouping by file, `embark-export` to a `grep-mode` buffer and
wgrep on that buffer work as for `consult-ripgrep`. `embark-export`
exports only the candidates shown; `C-c C-o` searches again without the
live limit.

## Call from Lisp

Both commands take the directory and the initial input:
`(quarry-consult-grep <dir> <initial>)`. `<initial>` uses the input
syntax without the leading `#`. To search a string literally, quote it
with `quarry-consult-grep-quote`:

```elisp
(defun my/grep-isearch-string ()
  "Search the project for the last isearch string, literally."
  (interactive)
  (quarry-consult-grep-project
   nil (quarry-consult-grep-quote isearch-string)))
```

## Doom Emacs

To use the commands for `SPC s p` and `SPC s d`, add to `config.el`:

```elisp
(map! [remap +default/search-project] #'quarry-consult-grep-project
      [remap +default/search-cwd]     #'quarry-consult-grep)
```

- Commands that call the Doom functions by name, such as
  `+default/search-project-for-symbol-at-point`, still run rg.
- With a prefix argument, `quarry-consult-grep-project` asks for another
  project, where Doom's command searches ignored and hidden files. For
  that, type ` -- -uu` after the terms.

Doom previews hits of its search commands only on `C-SPC`. To get that
for quarry's commands, and for your own commands that call them:

```elisp
(after! consult
  (consult-customize
   quarry-consult-grep quarry-consult-grep-project
   :preview-key "C-SPC"))
```

`:preview-key nil` switches the preview off. Outside Doom, use the same
form without `after!`, once consult is loaded.

## User options

Group `quarry`.

| Option | Default | Description |
|---|---|---|
| `quarry-consult-grep-max-lines` | `1000` | Hits a live search collects before it stops. |
| `quarry-consult-grep-input-debounce` | `0.05` | Seconds without typing before a search. |
| `quarry-consult-grep-input-throttle` | `0.1` | Minimum seconds between two searches. |

`quarry-grep-case` and `quarry-include-hidden` set the defaults of the
case rule and the hidden switch (see the
[grep options](grep.md#options)).

## Limitations

- Uses consult internals: a consult upgrade can break the commands until
  quarry is updated. Versions older than 3.7 are untested.
- The live search stops at `quarry-consult-grep-max-lines` hits; use
  `C-c C-o` for more.
- Same regexp and file limits as the result buffer (see
  [grep limitations](grep.md#limitations)).
