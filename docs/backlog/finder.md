# Backlog: file finder

The index service and `quarry.el`. Part of [the backlog](../backlog.md).

## nucleo-matcher back to a crates.io release

quarry pins `nucleo-matcher` to an upstream git commit because 0.3.1 has
the case-sensitive prefix bug (ADR 0003). Revisit when a release after
0.3.1 appears on crates.io.

## Watcher on macOS and Windows

The recursive-watch path for non-Linux platforms is type-checked for
Windows and exercised on Linux through a test hook, but never run against
FSEvents or Windows. Suspected issues: FSEvents' sticky flags causing extra
directory walks; Windows buffer overflows, which notify does not report as
lost events. Also, when creating the backend watcher fails,
notify-debouncer-full leaves its own thread running (upstream). Origin:
task 4, 2026-10-09. Revisit before claiming macOS or Windows support.

On Windows, rebuilding the module while it is loaded fails at the install
step: `rename-file` cannot replace a loaded DLL. Renaming the old file
aside first would work. Origin: review of the install-from-GitHub spec
(2026-10-09); deferred because Windows is untested anyway. Revisit with
Windows support.

## Faster scoring for very large indexes

On 1M files, short queries (2–4 characters) still match most paths and
exact nucleo scoring costs ~180 ms p99 on a 4-core laptop at low clock
(benchmark, 2026-10-09). Option: above ~200k candidates, preselect the top
10×limit with nucleo's greedy scoring (4–7× faster) and rank those exactly;
needs a greedy mode on `Pattern`/`Atom` (private fields in nucleo) or our
own per-atom dispatch, and relaxes the "identical to exact scoring"
guarantee for huge sets. Origin: task 8 of the v1 spec. Revisit if the 1M
target is missed on a quiet machine or users report slow prompts.

## Ranking of equal scores

Equal nucleo scores fall back to the shorter path, so `activitymanager`
ranks `external/mesa3d/.../ActivityManager.h` above
`frameworks/base/.../ActivityManager.java`. A tie-break or bonus that
prefers more prominent paths (recently visited, shallower in a well-known
tree) may help. Origin: task 8 benchmark observation, 2026-10-09.
Revisit with real use.

## `remove_dir` scans the whole index

`Index::remove_dir` is O(n). A batch with many sibling directory removals
on a 1M-path index (`rm -rf` of a large non-ignored tree) costs k × n inside
`handle`, twice during a walk (apply and replay), and can stall queries.
Origin: v1 review (Rust correctness), 2026-10-09; deferred because large
deletions usually happen in ignored build directories. Revisit with a
prefix structure or one combined scan per `FsChanges` batch if prompts
stall after big deletions.

## Watches left on newly ignored directories

A cancelled walk's worker threads finish the directory listings they have
started and can mark directories that the new ignore rules exclude, so they
keep their watches until the next walk. Only wasted watches; events there
are still ignored. Origin: v1 review (Rust correctness), 2026-10-09;
deferred as low impact (rarer still since rescans coalesce). Revisit if
watch limits become tight.

## Unbounded memory during walks and `(:files)`

Changes recorded during a walk (`Walk.changes`) grow without a cap, and
each `(:files)` call copies the whole index into a `Vec<String>`. Origin:
v1 review (Rust correctness), 2026-10-09; deferred because walks are
seconds long and `(:files)` is opt-in. Revisit if memory use is reported
on huge trees (cap the change log and force a follow-up walk; snapshot
shared strings).

## Collect `(:files)` with `emrs-call-stream-sync`

`quarry--collect-files` waits with `(accept-process-output nil 0.05)`,
so other processes' filters and timers can run inside `project-files`.
emrs now has `emrs-call-stream-sync` (emrs PR #5, merged 2026-10-12),
which waits on the module pipe only, returns all items as one list in
order, and signals `emrs-error` on failure, on timeout (kind `timeout`)
and when the instance stops. To do:

- Move the emrs pin in `Cargo.toml` from `b824f9f` to `6d8f550`
  (`6d8f5503127c7a1121210cb4afe2956386933155`) or later on emrs's default
  branch (ADR 0007); there is no Rust or protocol change in between, only
  `emrs.el`. Rerun `cargo test` and `tests/run-ert.sh`.
- Replace the batch collecting, the polling loop and the cancel in
  `quarry--collect-files` with one call with `quarry-files-timeout`, and
  map every `emrs-error` to `fail` as today.
- Users need the matching `emrs.el`: an older one lacks the function.

Origin: v1 review (Elisp), 2026-10-09, deferred then because emrs had no
public helper; unblocked on 2026-10-12.

## Symlinked project roots get separate instances

`quarry--root` does not resolve symlinks, so one directory reached by two
spellings gets two instances and two sets of watches. Using
`file-truename` only for the instance key would fix it, but
`project-files` must keep returning paths under the project's own
spelling. Origin: v1 review (Elisp), 2026-10-09; deferred as rare.
Revisit on a report.

## Generic message when an instance dies during a consult prompt

When the instance exits while `quarry-consult-find-file` waits for a
reply, the step reports "quarry: The instance terminated" instead of the
reason: emrs fails open calls before it runs `on-exit`, where
`quarry--on-exit` records the reason in `quarry--failures`. The
`display-warning` from `on-exit` still shows the reason. Fix: report from
a `run-at-time 0` timer, after `on-exit` ran. Origin: review of the
consult spec (2026-10-09); deferred because the warning already carries
the reason. Revisit if users find the message confusing.
