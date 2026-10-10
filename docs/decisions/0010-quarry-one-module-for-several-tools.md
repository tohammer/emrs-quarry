# 0010 — The project becomes quarry: one repository and module for several tools

Date: 2026-10-10
Status: accepted

## Context

A second emrs-based tool is planned: an interactive grep with a result
buffer, filters and wgrep editing. The evaluation
(`GREP-EVALUATION.md` in the emrs repository, section 7) compared a
separate repository with a combined one.

Each emrs module links its own runtime and has its own statics. Two
modules can exchange data only through Lisp. A grep that is ever to use
the file index or the watcher (candidate files without a walk, stale
markers, live refresh) must therefore live in the same module as the
index. Moving code between repositories later is cheap; changing
user-visible names later is not.

Both tools also need the same things around the Rust code: the local
cargo build and install (ADR 0006), the module lookup, the test harness,
one emrs pin (ADR 0007), and one set of rules for which files count.

The name projdex means project index and does not fit a set of tools.

## Decision

- The repository holds several tools in one Cargo package and one module.
  Each tool is its own emrs service and has its own Elisp entry point. A
  tool works without the others being enabled.
- The project, the repository, the module and the Elisp prefix are renamed
  from projdex to quarry. The old names are removed without aliases; the
  only user so far is the author.
- Shared code is limited to what is concretely shared today: building and
  finding the module, and the walker rules. There is no shared UI layer
  until a third tool shows what is common.
- A tool does not depend on another tool's state. Grep gets its own
  directory walk; use of the index is a later, optional optimisation.

## Consequences

- One build step, one module file and one emrs pin for all tools.
- A compile error in one tool stops the build of all of them, and a Rust
  change to any tool needs an Emacs restart.
- Specs and ADRs written before this one (specs dated 2026-10-09, ADRs
  0001 to 0009) keep the name projdex. They are history; read `projdex`
  as `quarry` there. `README.md`, `docs/architecture*`, `docs/backlog.md`
  and `docs/next-steps.md` use the new name.
- Sharing the index between two services is not designed. emrs has no
  service-to-service calls, and the index is owned by one service without
  locks. This needs its own decision when it is wanted.
