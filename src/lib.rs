//! quarry: a live file index of a project with fuzzy matching, as an Emacs
//! module built on emrs.
//!
//! The module `quarry-module` provides one service, named `index`
//! ([`service::IndexService`]): one instance per project root, started from Elisp
//! with `(emrs-start 'quarry "index" (list :root ROOT))`. Requests,
//! replies and events are documented in `src/service.rs` and in the version 1
//! spec in `docs/specs/`.

mod grep;
mod index;
mod matcher;
mod service;
mod walk;
mod watch;

emrs::module!("quarry", [service::IndexService]);
