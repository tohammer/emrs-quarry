# Backlog

Open points only. Delete an item when it is done; git keeps the history.
Deferred review findings name their origin, the reason and when to revisit.

## consult async source

An optional `projdex-consult.el` that adapts the asynchronous core to
consult: debounced queries, one cancellable stream per query, results shown
while indexing runs. Deferred by ADR 0001. Revisit after version 1 works.

## Continuous integration

No CI yet. The emrs repository had to disable GitHub Actions for lack of
quota (2026-10-04), and the same account would pay for this one. Revisit
when quota allows; then mirror emrs's matrix (Linux, macOS, Emacs 30.1 and
31.1).

## Distribution

No package recipe, no prebuilt binaries, and the module and `emrs.el` are
installed by hand (README, "Installation"). Depends on emrs's own
distribution work (emrs backlog, "Prebuilt artifacts and distribution").
Revisit before announcing projdex to users.

## Install from GitHub with one `package!` declaration

Goal: a Doom user (or straight/elpaca user) installs projdex with a
recipe pointing at the GitHub repo, without a local checkout:

```elisp
(package! projdex
  :recipe (:host github :repo "tohammer/emacs-projdex" :files ("lisp/*.el")))
```

Today this does not work: the Rust module must be built and placed on
`load-path` as `projdex-module.so`, and `emrs.el` comes from a separate
local checkout (the developer's config uses `:local-repo` for both, plus a
`target/emacs` symlink to the module). Needed:

- Getting the module: either build it during the package build (straight
  `:pre-build` running `cargo build --release` and copying the library into
  the build directory as `projdex-module` plus `module-file-suffix`), or a
  command such as `projdex-install-module` that builds it, or downloads a
  prebuilt release binary on first use (see Distribution).
- `emrs.el` must come with it at the commit `Cargo.toml` pins: its own
  recipe (`:repo "tohammer/emrs" :files ("elisp/emrs.el")`) with a matching
  pin, or a copy shipped in this repo.
- README: document the recipe for Doom, straight and elpaca.

Origin: the user's request when setting projdex up in their Doom config
(2026-10-09). Revisit together with Distribution, before announcing
projdex.

## nucleo-matcher back to a crates.io release

projdex pins `nucleo-matcher` to an upstream git commit because 0.3.1 has
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

## Waiting for `(:files)` runs other process filters

`projdex--collect-files` waits with `(accept-process-output nil 0.05)`,
so other processes' filters and timers can run inside `project-files`.
`emrs-call-sync` waits on the module pipe only, but that pipe is private
to emrs. Origin: v1 review (Elisp), 2026-10-09; deferred because it needs
a public helper in emrs (a synchronous stream collect, or access to the
pipe). Revisit with the next emrs change.

## Symlinked project roots get separate instances

`projdex--root` does not resolve symlinks, so one directory reached by two
spellings gets two instances and two sets of watches. Using
`file-truename` only for the instance key would fix it, but
`project-files` must keep returning paths under the project's own
spelling. Origin: v1 review (Elisp), 2026-10-09; deferred as rare.
Revisit on a report.
