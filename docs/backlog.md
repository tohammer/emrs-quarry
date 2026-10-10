# Backlog

Open points only. Delete an item when it is done; git keeps the history.
Deferred review findings name their origin, the reason and when to revisit.

## Continuous integration

No CI yet. The emrs repository had to disable GitHub Actions for lack of
quota (2026-10-04), and the same account would pay for this one. Revisit
when quota allows; then mirror emrs's matrix (Linux, macOS, Emacs 30.1 and
31.1).

## Distribution

Installation from GitHub works through package recipes and a local cargo
build (spec 2026-10-09-install-from-github, README "Installation"). Open:
prebuilt binaries, which need CI (see above) and would replace the cargo
build and its Rust requirement, and a package archive (MELPA) for quarry
and emrs. Depends on emrs's own distribution work (emrs backlog, "Prebuilt
artifacts and distribution"). Origin: the install-from-GitHub spec, which
left both out of scope. Revisit before announcing quarry to users.

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

## Waiting for `(:files)` runs other process filters

`quarry--collect-files` waits with `(accept-process-output nil 0.05)`,
so other processes' filters and timers can run inside `project-files`.
`emrs-call-sync` waits on the module pipe only, but that pipe is private
to emrs. Origin: v1 review (Elisp), 2026-10-09; deferred because it needs
a public helper in emrs (a synchronous stream collect, or access to the
pipe). Revisit with the next emrs change.

## Symlinked project roots get separate instances

`quarry--root` does not resolve symlinks, so one directory reached by two
spellings gets two instances and two sets of watches. Using
`file-truename` only for the instance key would fix it, but
`project-files` must keep returning paths under the project's own
spelling. Origin: v1 review (Elisp), 2026-10-09; deferred as rare.
Revisit on a report.

## Order-dependent ERT test

`quarry-test-build-async-installs` passes only while no quarry module is
loaded: with one loaded, the message gains "; restart Emacs to use it".
ERT runs tests alphabetically, so a test that loads the module and sorts
before it breaks it. The consult tests (`quarry-test-consult-*`) and all
grep tests (`quarry-test-grep-*`) are named to sort after it; a new test
file must follow the same rule. Origin: task 2 of the consult spec
(2026-10-09); extended by the grep spec (2026-10-10). Fix the test to
accept both messages when the naming rule first gets in the way.

## Generic message when an instance dies during a consult prompt

When the instance exits while `quarry-consult-find-file` waits for a
reply, the step reports "quarry: The instance terminated" instead of the
reason: emrs fails open calls before it runs `on-exit`, where
`quarry--on-exit` records the reason in `quarry--failures`. The
`display-warning` from `on-exit` still shows the reason. Fix: report from
a `run-at-time 0` timer, after `on-exit` ran. Origin: review of the
consult spec (2026-10-09); deferred because the warning already carries
the reason. Revisit if users find the message confusing.

## Grep: delivery of very large results is slower than the search

A search for `defun` in a tree of 19,800 files finds 33,800 lines in
about 100 ms inside the service, but takes 200 to 260 ms until the last
item has reached Lisp (release build, batch Emacs, without inserting
anything): emrs converts one plist per line on the Emacs thread, and the
search waits for it at the stream's capacity. Inserting the lines into
the buffer comes on top and was not measured with the real renderer. Ordinary searches (hundreds of
lines) are not affected. Option: send each file's lines as one string
with parallel integer lists for line numbers and match positions, so
the conversion cost is per file, not per line; this changes the item
shape. Origin: task 4 of the grep spec (2026-10-10), measurement by the
implementer. Revisit when the result buffer is in daily use and large
searches feel slow.

## Grep: context lines before and after a match

Let the user set how many lines are shown before and after each match,
as `-B`, `-A` and `-C` do in grep and rg. `grep-searcher` supports it
(`before_context`, `after_context`, `Sink::context`). To design: the
request fields and the item shape for context lines; how they look in a
file block (separator between groups, a different face); keys to change
the counts from the result buffer; that context lines are not matches
for `next-error` and the hit counts; whether line filters apply to them
(they should not); and wgrep, where context lines could be editable like
match lines. Origin: requested by the author on 2026-10-10, during the
grep spec's implementation; the spec lists context lines as out of
scope. Revisit as the next grep feature.

## Grep: manual checks not done yet

The grep spec lists manual checks that batch tests cannot replace, and
only terminal Emacs under a pty was tried: mouse clicks on line numbers
and header parts in a GUI frame, folding and the three highlight faces in
the author's theme, point and scrolling with two windows on the result
buffer during a slow search, the file type prompt under vertico, a
search for a common word in a tree of 20,000 files compared by feel with
`M-x rg`, and a search that reaches the line cap. Emacs 30 was not run
at all. Origin: grep spec, Testing section, and its review
(2026-10-10). Do these once quarry-grep is in daily use; turn what
fails into backlog items or fixes.

## Grep: wgrep on other line ends and encodings, and on huge results

Editing through wgrep was tested on UTF-8 files with `\n` line ends.
Not tested: files with `\r\n` line ends (quarry shows the line without
the `\r`), UTF-16 files found through their byte order mark, and files
in other 8-bit encodings whose lines are valid UTF-8 by accident. wgrep
compares the old line text before it applies a change and should reject
a mismatch, but that was not checked. Entering edit mode walks every
result line and the stale check stats every file, so `e` on tens of
thousands of lines may be slow; not measured. Origin: task 7 of the grep
spec and its review (2026-10-10). Revisit on the first report, or test
the three file kinds before announcing quarry-grep to others.

## Grep: a file that fills the line cap before its NUL byte counts as text

A binary file gives no lines, but when its first lines fill the rest of
the line cap before the NUL byte is read, those lines are delivered.
Origin: task 4 of the grep spec (2026-10-10); accepted because the
search has stopped at that point anyway. Revisit if binary lines show up
in capped results.
