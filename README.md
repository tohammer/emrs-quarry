# projdex

A fast project file finder for Emacs. A Rust module keeps a live index of
each project's files, updated by a file watcher, and answers fuzzy queries
from it, so `project-find-file` stays instant on large repositories.

projdex is built on [emrs](https://github.com/tohammer/emrs), which runs the
Rust side as a message-passing service outside the Emacs thread.

Status: scaffolding only. Nothing is usable yet; the first version is being
specified (`docs/next-steps.md`).

## Requirements

- Emacs 30.1 or later, built with module support.
- Rust 1.85 or later.

## Building

```sh
cargo build --release
```

Copy the library to a directory on `load-path` as `projdex-module` plus
Emacs's `module-file-suffix`, for example `target/release/libprojdex.so` to
`projdex-module.so`. Put `lisp/projdex.el` and `emrs.el` (from the emrs
repository, `elisp/emrs.el`, at the commit pinned in `Cargo.toml`) on
`load-path` as well.

## Usage

Not available yet.

## Tests

```sh
cargo test
tests/run-ert.sh    # builds the module and runs the ERT suite in Emacs
```

Set `EMACS` to use another Emacs binary.

## Documentation

- `docs/architecture.md`: how the system is built now.
- `docs/specs/`: specifications; `docs/decisions/`: decision records.
- `docs/backlog.md` and `docs/next-steps.md`: open points and what comes next.

## Licence

The Rust code is licensed under either MIT or Apache-2.0, at your option.
`lisp/projdex.el` is licensed under GPL-3.0-or-later.
