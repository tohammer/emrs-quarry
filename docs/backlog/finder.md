# Backlog: file finder

The index service and `quarry.el`. Part of [the backlog](../backlog.md).

## nucleo-matcher back to a crates.io release

quarry pins `nucleo-matcher` to an upstream git commit because 0.3.1 has
the case-sensitive prefix bug (ADR 0003). Revisit when a release after
0.3.1 appears on crates.io.

## Watcher on macOS and Windows

The recursive-watch path for non-Linux platforms is type-checked for
Windows and exercised on Linux through a test hook. On macOS it runs
against FSEvents only in the ERT suite in CI, where the Rust tests do not
run; it never ran on Windows. Suspected issues: FSEvents' sticky flags causing extra
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
