//! Interactive grep: filters on lines and paths (`filter`), one search over a directory (`search`) and the
//! emrs service `grep` that runs searches for Emacs (`service`).

pub mod filter;
pub mod search;
pub mod service;
