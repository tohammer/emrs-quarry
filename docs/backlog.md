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
installed by hand (README, "Building"). Depends on emrs's own distribution
work (emrs backlog, "Prebuilt artifacts and distribution"). Revisit before
announcing projdex to users.

## nucleo-matcher back to a crates.io release

projdex pins `nucleo-matcher` to an upstream git commit because 0.3.1 has
the case-sensitive prefix bug (ADR 0003). Revisit when a release after
0.3.1 appears on crates.io.

## TAB completion in the default completion UI

The `projdex` style's try-completion returns the input unchanged unless it
already equals the only match (spec, "Completion table"). In the default
UI, TAB therefore never expands `main` to `src/main.rs` even when that is
the only match; vertico and similar UIs select candidates instead and are
unaffected. Origin: task 6 of the v1 spec, 2026-10-09. Revisit after the
manual UI checks: returning the sole match when `:total` is 1 is a likely
fix.

## `.git/info/exclude` created after the first walk

The watcher watches each repository's `.git/info` only if it existed when
its directory was walked. After `git init` in an indexed tree, edits to
`.git/info/exclude` go unnoticed until the next full rescan
(`projdex-rescan`, a `.gitignore` change, or lost events). Origin: task 4
of the v1 spec, 2026-10-09. Revisit if users report it.

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
