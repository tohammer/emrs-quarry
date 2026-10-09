//! projdex: a live file index of a project with fuzzy matching, as an Emacs
//! module built on emrs.
//!
//! The service and the `emrs::module!` line are added by the v1 spec
//! (docs/next-steps.md). Until then the library builds but Emacs cannot load
//! it as a module.

mod index;
mod matcher;
mod walk;
