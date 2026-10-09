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
