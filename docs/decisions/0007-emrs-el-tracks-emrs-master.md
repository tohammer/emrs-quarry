# 0007 — emrs.el tracks emrs master; projdex pins only master commits

Date: 2026-10-09
Status: accepted

## Context

emrs reaches projdex twice. The Rust crate is compiled into the module and
pinned by `Cargo.toml` (`rev = ...`) and `Cargo.lock`. `emrs.el` is a
separate Elisp package (`Package-Requires: (emrs "0.1.0")`) that must speak
the module's protocol. Package managers install it but do not tie it to
the crate's commit. Both carry version 0.1.0 across commits, so a version
comparison would not detect drift.

`emrs-load-module` refuses a module whose protocol is newer than the
loaded `emrs.el` supports. emrs keeps the code paths of older protocols in
`emrs.el` (emrs spec, section 6.2), so a newer `emrs.el` runs older
modules.

Pinning the emrs recipe to the `Cargo.toml` commit would make every emrs
bump in projdex a manual change to each user's config, and a stale pin
would break the next projdex update.

## Decision

- The README's emrs recipe is not pinned: `emrs.el` follows emrs's default
  branch.
- projdex's `Cargo.toml` pins only commits that are on emrs's default
  branch, so the `emrs.el` a user installs is never older than the crate
  in the module.
- The protocol check in `emrs-load-module` is the safety net. projdex adds
  no version check of its own.

## Consequences

- Updating packages (`doom sync -u`) updates both; an update of emrs alone
  never breaks projdex as long as emrs keeps older protocols.
- A user who pins emrs older than projdex's crate gets the protocol error,
  which names the fix ("upgrade the emrs Elisp package").
- Bumping emrs in projdex requires the commit to be pushed to emrs's
  default branch first; next-steps "Watch out for" says so.
