//! projdex: a live file index of a project with fuzzy matching, as an Emacs
//! module built on emrs.
//!
//! The module `projdex-module` provides one service, `projdex`
//! ([`service::Projdex`]): one instance per project root, started from Elisp
//! with `(emrs-start 'projdex "projdex" (list :root ROOT))`. Requests,
//! replies and events are documented in `src/service.rs` and in the v1 spec
//! (`docs/specs/2026-10-09-projdex-v1.md`).

mod index;
mod matcher;
mod service;
mod walk;
mod watch;

emrs::module!("projdex", [service::Projdex]);
