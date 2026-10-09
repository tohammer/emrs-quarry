# 0008 — The consult adapter is its own step in consult's async pipeline

Date: 2026-10-09
Status: accepted

## Context

ADR 0001 deferred a consult front end. consult 2.0 (2025-01) replaced its
async API with `consult--async-pipeline`: composable steps of the form
`(lambda (sink) (lambda (action) ...))`, documented in that function's
docstring but internal (`consult--` prefix). Two ways to feed projdex
results into it were compared:

- **`consult--dynamic-collection` around `projdex-query`.** About 30
  lines. The query runs synchronously under `while-no-input`; consult
  forbids calling its callback after the function returns, so the
  asynchronous `projdex-query-async` cannot be used. Emacs blocks during
  each query, which gains little over `projdex-find-file`.
- **An own pipeline step.** It sends each input with
  `projdex-query-async` (`emrs-call`), cancels the previous call with
  `emrs-cancel`, and pushes the reply to the sink when it arrives. It is
  combined with consult's own split, throttle, indicator and refresh
  steps. Emacs never waits for the module.

## Decision

`lisp/projdex-consult.el` implements its own step and composes it with
`consult--async-split`, `consult--async-throttle`,
`consult--async-indicator` and `consult--async-refresh`, read with
`consult--read`. It requires consult 2.0 or later and checks for
`consult--async-pipeline` at run time.

## Consequences

- projdex depends on consult internals. A consult release that changes
  the pipeline protocol breaks the adapter; the ERT tests for it run
  against the consult found by `tests/run-ert.sh` and catch that.
- `consult--async-split` hands the user's completion styles only the
  filter part of the input (after the second separator, empty with split
  style `none`), so they never re-filter projdex's ranking. This meets
  ADR 0005's requirement for other callers without setting
  `completion-styles`.
- consult stays optional: `projdex.el` does not load it, and
  `projdex-consult.el` byte-compiles and loads without it.
