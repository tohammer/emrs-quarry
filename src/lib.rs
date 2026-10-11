//! quarry: tools for Emacs that work on the files of a project, as an Emacs
//! module built on emrs: a live file index with fuzzy matching, and an
//! interactive grep.
//!
//! The module `quarry-module` provides two services, each used by its own
//! Elisp entry point and independent of the other (ADR 0010):
//!
//! - `index` ([`service::IndexService`]): one instance per project root,
//!   started from Elisp with `(emrs-start 'quarry "index" (list :root ROOT))`.
//!   Requests, replies and events are documented in `src/service.rs` and in
//!   the version 1 spec in `docs/specs/`.
//! - `grep` ([`grep::service::GrepService`]): one instance for all searches,
//!   started with `(emrs-start 'quarry "grep" nil)`. It searches a directory
//!   for lines and streams the matches; it keeps no state and does not use
//!   the index. Requests and stream items are documented in
//!   `src/grep/service.rs`.

mod grep;
mod index;
mod matcher;
mod service;
mod walk;
mod watch;

emrs::module!("quarry", [service::IndexService, grep::service::GrepService]);
