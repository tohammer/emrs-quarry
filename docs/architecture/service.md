# Architecture: the service

The Rust side: threads, messages, rescans, queries and watching. Part of
[the architecture](../architecture.md).

## Threads

| Thread | Runs | Talks to the service by |
|---|---|---|
| emrs worker pool | `Projdex::handle`, one message at a time per instance | owns the index |
| walk task (`ctx.spawn`) | `walk::walk_dirs`, which uses the `ignore` crate's parallel walker with one thread per core | `WalkBatch`, `WalkDone` self-messages |
| `:files` stream task (`ctx.spawn`) | Sends a snapshot of the index to the stream (capacity 4096), stops when the stream's token is cancelled | stream |
| `notify` backend thread, debouncer thread (100 ms window) | Collect and debounce file-system events | channel to `projdex-watch` |
| `projdex-watch` | Translates debounced events into changes, walking new directories itself | `FsChanges`, `FsRescan`, `WatchFailed` self-messages |
| scoring threads (`std::thread::scope`) | Score chunks of the index when more than 10,000 paths are to be scored | joined before the query returns |

## Message flow

Requests from Emacs: `:query`, `:files` (stream), `:rescan`, `:status`.
Internal requests, `#[serde(skip_deserializing)]` so Emacs cannot send
them: `WalkBatch`, `WalkDone`, `FsChanges`, `FsRescan`, `WatchFailed`.
Events to Emacs: `:indexed`, `:changed`, `:watch-failed`. The exact shapes
are in the module docs of `src/service.rs`.

`start` validates the root, creates the watcher (a failure only disables
watching), and spawns the first walk without waiting for it.

## Generations and rescans

Every walk has a generation number and builds a fresh index from its
batches. Until the walk's `WalkDone`, queries use the previous index (or,
during the first walk, the partial fresh one); batches and `WalkDone` of
any other generation are discarded. File-system changes during a walk are
applied to the index queries use and recorded; at `WalkDone` they are
replayed on the fresh index before it becomes current, so no change is
lost.

Rescans coalesce: a `:rescan` or watcher `FsRescan` while a walk runs only
sets "walk again", and one follow-up walk starts when the running walk
ends. Only `stop()` cancels a walk. `:rescan` replies are answered by the
first walk that started after the request; `:files` streams wait only for
the running walk. A walk that fails keeps the old index (or makes the
partial one current when there was none); the `:rescan` calls waiting for
it fail with the message. The exact rules are in the spec, section
"Rescans".

## Queries, narrowing and scoring

A query parses the text with nucleo's `Pattern` (smart case, smart
normalization) and ranks by score descending, then path length, then path.
In the substring style (`:substring t`, ADR 0004) `matcher::parse` builds
the pattern atom by atom and turns plain fuzzy atoms into substring atoms;
a leading `'` marks a fuzzy one. Match positions are computed only for the
returned paths, atom by atom, so each position carries its term number
(`:groups`).

The matcher remembers the last query, the index version and the full set of
matching paths, and the style. The next query of the same style scores only
that set when the index is unchanged and the new text extends the old text
in a way that cannot match more (`matcher::narrows`: no `!` or `$`
involved, the old text does not end in `\` or `$`, not both the last
atom and the appended text are non-ASCII, and not a backslash in the last
atom with non-ASCII appended text). Otherwise it scores the whole
index. When more than 10,000 paths are scored, the set is split into one
chunk per core, each chunk is scored on a scoped thread with its own
matcher, and the per-chunk top results are merged. Both optimisations
return exactly what single-threaded scoring of the whole index returns; a
Rust test checks it.

## Watching

The watcher covers exactly the directories the walk visits. On Linux that
is one non-recursive inotify watch per directory, plus `<dir>/.git/info`
where it exists. Elsewhere the root is watched recursively and events are
filtered (`Mode::Recursive`; never run on macOS or Windows).

The watcher keeps a set of known directories, each stamped with a clock
value. A full walk advances the clock and confirms every directory it
visits; when its index becomes current, directories with an older stamp are
dropped with their watches. This reconciles the watch set with the walk
without a second tree traversal.

Events are translated by comparing each affected path with the disk, which
makes paired and unpaired rename halves behave the same: a file that exists
and is not ignored is added, a missing path is removed (a missing known
directory removes everything below it), a new directory is walked and its
directories watched. `notify-debouncer-full` drops a create and remove
within its window, so raw remove and rename-away events also go straight
to the translating thread. A changed ignore file in a non-ignored
directory, a new `.git` that already has `info/exclude`, or lost events
produce a full rescan instead; after lost events, full walks re-add every
directory watch until a walk that began after the loss has become
current. When the inotify limit is reached or the backend fails,
the watcher is dropped and `WatchFailed` is sent once; the instance keeps
answering from the index it has, and `projdex-find-file` sends `:rescan`
before each prompt.
