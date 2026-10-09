# Architecture

This document describes the system as it is now.

## Overview

projdex is an Emacs package with two parts: a Rust `cdylib` built on emrs
(`src/`) and the Elisp library `lisp/projdex.el`. Today both are empty
skeletons: the crate builds but defines no module, and `projdex.el` only
loads `emrs`. The first version is being specified (`docs/next-steps.md`).

## Components

| Component | Responsibility | Depends on |
|---|---|---|
| `src/lib.rs` | Rust module; no service yet | `emrs` (git, pinned commit), `serde` |
| `lisp/projdex.el` | Elisp front end; no commands yet | `emrs.el` |
| `tests/run-ert.sh`, `tests/projdex-tests.el` | Builds the module, installs it as `projdex-module`, runs ERT with `--module-assertions`; takes `emrs.el` from the emrs checkout Cargo resolved | Cargo, Emacs |

## How it fits together

`emrs.el` loads `projdex-module` and talks to its services; `projdex.el`
uses the emrs API (`emrs-start`, `emrs-call`, `emrs-call-sync`, ...) and
never calls the module functions directly. The emrs version is fixed by the
commit pinned in `Cargo.toml`, and the test script uses the `emrs.el` from
that same checkout so the Lisp and Rust halves always match.

## Lessons

None yet.
