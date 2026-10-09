//! The `projdex` service: one instance per project root, owning the index of that project.
//!
//! Lisp shapes (spec "Start arguments", "Requests and replies", "Events"):
//!
//! | Request | Reply |
//! |---|---|
//! | `(:query :text S :limit N :positions BOOL :substring BOOL)` | `(:paths (P ...) :positions (POS ...) :groups (G ...) :total M :indexing BOOL)` |
//! | `(:files)` | stream of strings (relative paths), capacity 4096 |
//! | `(:rescan)` | number of files, once a walk that started after the request has finished |
//! | `(:status)` | `(:root R :files N :indexing BOOL :watching BOOL :walks K :skipped S)` |
//!
//! `:limit` defaults to 200 and is clamped to 1..=10000; `:positions` and `:substring` default to nil. `:substring` selects [`Style::Substring`].
//! `:groups` is parallel to `:positions`: for each path the term number of each matched character. Start arguments are
//! `(:root "/abs/dir/" :include-hidden t :ignores ("*.min.js"))`; `:include-hidden` defaults to t, `:ignores` to
//! nil. Events: `(:indexed :files N :millis T)`, `(:changed :added A :removed R)`, `(:watch-failed :message S)`.
//!
//! **Generations.** Every walk has a generation number and builds a fresh [`Index`] from its batches
//! (self-messages [`Request::WalkBatch`]); the fresh index becomes current at the walk's [`Request::WalkDone`].
//! Until then queries use the previous index, except during the first walk, when there is none and queries see
//! the partial fresh index. Batches and `WalkDone` of any generation other than the running walk's are
//! discarded. At most one walk runs; only `stop` cancels it (its per-walk flag).
//!
//! **Rescans coalesce.** A rescan — `(:rescan)` with or without a reply, or [`Request::FsRescan`] from the
//! watcher (ignore-file change, lost events) — starts a walk when none is running. While a walk runs it does not
//! cancel it but marks "walk again": when the running walk ends, its index becomes current as usual (with
//! `:indexed`), and then one follow-up walk starts, however many rescans were requested meanwhile. The running
//! walk may have used old ignore rules; the follow-up walk applies the new ones (and after lost events re-adds
//! watches, see `src/watch.rs`). Pending replies: a `(:rescan)` registered when its walk started (no walk was
//! running) is answered at that walk's `WalkDone`; one registered while a walk ran is answered at the end of the
//! follow-up walk; `(:files)` waits only for the running walk's `WalkDone` (it needs a consistent index, not a
//! new walk).
//!
//! **Watching** (`src/watch.rs`). `start` sets up the [`Watcher`]; if that fails the instance runs without it and
//! emits `(:watch-failed ...)`. The watcher thread sends [`Request::FsChanges`], [`Request::FsRescan`] and
//! [`Request::WatchFailed`] as self-messages. File-system changes are applied to the index queries use (the
//! current index, or during the first walk the partial fresh one) and `(:changed ...)` reports how many paths
//! that added and removed, when any. While a walk runs, the changes are also recorded in it and replayed on its
//! fresh index at its `WalkDone`, before that index becomes current, so a change the walk did or did not see is
//! never lost (adds and removes are idempotent). A rescan requested by the watcher starts a walk like
//! `(:rescan)` without a reply. Every full walk reports the directories it visits to the watcher, which watches
//! them; when the walk's index becomes current, the watcher drops the directories that walk did not see. After
//! the watcher fails (watch limit, backend error) it is dropped, `(:watch-failed ...)` is emitted once,
//! `:watching` is false and the index stays as it is.
//!
//! **Walk errors.** A walk that fails (`walk` returns an error) or reports itself cancelled although it is the
//! running walk does not replace an existing index: the error is logged, no `:indexed` event is emitted,
//! `:walks` and `:skipped` are unchanged, the `(:rescan)` replies waiting for that walk fail with the error, and
//! pending `(:files)` replies are streamed from the index queries currently use. If there is no index yet (the
//! first walk failed), the walk's partial index becomes current (`:files` and queries use it, still without
//! `:indexed`). A follow-up walk requested meanwhile starts as after a successful walk. With the start-time
//! checks in place failures are not expected; a vanished root makes the walk succeed with no files (counted as
//! skipped), not fail.

use crate::index::Index;
use crate::matcher::{Matcher, Style};
use crate::walk::{self, WalkConfig};
use crate::watch::{Change, Output, WalkStamp, Watcher};
use emrs::{Context, Error, Level, Reply, Service};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Capacity of the `(:files)` stream.
const FILES_CAPACITY: usize = 4096;

/// Default `:limit` of `(:query)`.
const DEFAULT_LIMIT: usize = 200;

fn default_limit() -> usize {
    DEFAULT_LIMIT
}

fn default_true() -> bool {
    true
}

/// Start arguments: `(:root "/abs/dir/" :include-hidden t :ignores ("*.min.js"))`.
#[derive(Debug, Clone, Deserialize)]
pub struct Args {
    /// Absolute path of an existing directory.
    pub root: String,
    #[serde(default = "default_true")]
    pub include_hidden: bool,
    /// Extra gitignore-syntax lines relative to the root.
    #[serde(default)]
    pub ignores: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub enum Request {
    /// `(:query :text S :limit N :positions BOOL :substring BOOL)`; replies with [`QueryReply`].
    Query {
        text: String,
        #[serde(default = "default_limit")]
        limit: usize,
        #[serde(default)]
        positions: bool,
        /// Plain terms match as substrings ([`Style::Substring`]) instead of fuzzily.
        #[serde(default)]
        substring: bool,
    },
    /// `(:files)`; replies with a stream of paths.
    Files,
    /// `(:rescan)`; replies with the number of files after the new walk.
    Rescan,
    /// `(:status)`; replies with [`Status`].
    Status,
    /// A batch of paths from the walk of `generation`.
    #[serde(skip_deserializing)]
    WalkBatch { generation: u64, paths: Vec<String> },
    /// The walk of `generation` has ended.
    #[serde(skip_deserializing)]
    WalkDone { generation: u64, skipped: usize, millis: u64, cancelled: bool, error: Option<String> },
    /// Index changes from the watcher.
    #[serde(skip_deserializing)]
    FsChanges(Vec<Change>),
    /// The watcher asks for a full walk (ignore file changed, events lost).
    #[serde(skip_deserializing)]
    FsRescan,
    /// The watcher stopped working.
    #[serde(skip_deserializing)]
    WatchFailed(String),
}

/// Reply to `(:query)`: `(:paths (P ...) :positions (POS ...) :groups (G ...) :total M :indexing BOOL)`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct QueryReply {
    pub paths: Vec<String>,
    /// Parallel to `paths`, or nil when not requested.
    pub positions: Option<Vec<Vec<u32>>>,
    /// Parallel to `positions`: the term number of each position.
    pub groups: Option<Vec<Vec<u32>>>,
    pub total: usize,
    pub indexing: bool,
}

/// Reply to `(:status)`: `(:root R :files N :indexing BOOL :watching BOOL :walks K :skipped S)`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    pub root: String,
    pub files: usize,
    pub indexing: bool,
    /// Whether the file watcher is working.
    pub watching: bool,
    /// Finished walks whose index became current.
    pub walks: u64,
    /// Paths skipped in the last such walk.
    pub skipped: usize,
}

/// Events for `on-event`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum Event {
    /// `(:indexed :files N :millis T)`: a walk finished and its index became current.
    Indexed { files: usize, millis: u64 },
    /// `(:changed :added A :removed R)`: file-system changes changed the index (`A + R > 0`).
    Changed { added: usize, removed: usize },
    /// `(:watch-failed :message S)`: the watcher could not be set up or stopped working.
    WatchFailed { message: String },
}

/// The running walk.
struct Walk {
    generation: u64,
    /// Set to cancel this walk; checked by the walker together with the spawn token.
    cancel: Arc<AtomicBool>,
    /// The fresh index its batches build.
    index: Index,
    /// File-system changes that arrived during the walk, replayed on `index` at `WalkDone`.
    changes: Vec<Change>,
    /// From [`Watcher::begin_walk`], for [`Watcher::walk_done`].
    watch_stamp: Option<WalkStamp>,
}

pub struct Projdex {
    root: String,
    config: Arc<WalkConfig>,
    /// The index of the last finished walk (empty before the first one).
    current: Index,
    /// Whether `current` comes from a finished walk.
    has_index: bool,
    walk: Option<Walk>,
    /// Generation of the most recently started walk.
    generation: u64,
    matcher: Matcher,
    /// `(:files)` replies waiting for the running walk to end.
    pending_files: Vec<Reply>,
    /// `(:rescan)` replies answered when the running walk ends.
    pending_rescans: Vec<Reply>,
    /// A rescan was requested while a walk ran: another walk starts when it ends.
    walk_again: bool,
    /// `(:rescan)` replies answered when that follow-up walk ends.
    next_rescans: Vec<Reply>,
    walks: u64,
    skipped: usize,
    /// The file watcher; `None` when set-up failed, after it failed, and after `stop`.
    watch: Option<Watcher>,
}

/// Applies `change` to `index`; returns the number of paths added and removed.
fn apply(index: &mut Index, change: &Change) -> (usize, usize) {
    match change {
        Change::Add(path) => (usize::from(index.add(path)), 0),
        Change::Remove(path) => (0, usize::from(index.remove(path))),
        Change::RemoveDir(dir) => (0, index.remove_dir(dir)),
    }
}

/// The index queries use: the current one, or during the first walk the partial fresh one.
fn view<'a>(current: &'a Index, has_index: bool, walk: &'a Option<Walk>) -> &'a Index {
    match walk {
        Some(walk) if !has_index => &walk.index,
        _ => current,
    }
}

impl Projdex {
    fn view(&self) -> &Index {
        view(&self.current, self.has_index, &self.walk)
    }

    /// Starts a full walk, or, while one runs, has another one start when it ends; `reply` (of `(:rescan)`) is
    /// answered when the walk that starts after this request ends.
    fn rescan(&mut self, reply: Option<Reply>, ctx: &Context<Self>) {
        if self.walk.is_some() {
            self.walk_again = true;
            self.next_rescans.extend(reply);
            #[cfg(test)]
            hook::walk_again(&self.config.root);
        } else {
            self.start_walk(ctx);
            self.pending_rescans.extend(reply);
        }
    }

    /// Starts a new walk generation; no walk is running.
    fn start_walk(&mut self, ctx: &Context<Self>) {
        debug_assert!(self.walk.is_none(), "a walk is running");
        self.generation += 1;
        let generation = self.generation;
        let cancel = Arc::new(AtomicBool::new(false));
        let (on_dir, watch_stamp) = match &self.watch {
            Some(watch) => {
                let (tracker, stamp) = watch.begin_walk();
                (Some(tracker.on_dir()), Some(stamp))
            }
            None => (None, None),
        };
        self.walk =
            Some(Walk { generation, cancel: cancel.clone(), index: Index::new(), changes: Vec::new(), watch_stamp });
        let config = self.config.clone();
        // `Address` is `Send` but not necessarily `Sync`; the walker calls `on_batch` from several threads.
        let address = Mutex::new(ctx.address());
        ctx.spawn(move |token| {
            let send = |request| address.lock().unwrap_or_else(|e| e.into_inner()).send(request);
            let is_cancelled = || cancel.load(Ordering::Relaxed) || token.is_cancelled();
            let on_batch = |paths| send(Request::WalkBatch { generation, paths });
            let done = match walk::walk_dirs(&config, None, &is_cancelled, &on_batch, on_dir) {
                Ok(stats) => Request::WalkDone {
                    generation,
                    skipped: stats.skipped,
                    millis: stats.millis,
                    cancelled: stats.cancelled,
                    error: None,
                },
                Err(error) => {
                    Request::WalkDone { generation, skipped: 0, millis: 0, cancelled: false, error: Some(error) }
                }
            };
            #[cfg(test)]
            hook::walk_finished(&config.root);
            send(done);
        });
    }

    fn walk_done(&mut self, failure: Option<String>, skipped: usize, millis: u64, ctx: &Context<Self>) {
        let Some(walk) = self.walk.take() else { return };
        let rescans = std::mem::take(&mut self.pending_rescans);
        match failure {
            Some(message) => {
                let message = format!("walk of {} failed: {message}", self.root);
                ctx.log(Level::Error, message.clone());
                for reply in rescans {
                    reply.err(Error::new(message.clone()));
                }
                if !self.has_index {
                    // Better than nothing: the partial index (which file-system changes already reached) stays.
                    self.current = walk.index;
                    self.has_index = true;
                }
            }
            None => {
                let mut index = walk.index;
                for change in &walk.changes {
                    apply(&mut index, change);
                }
                self.current = index;
                self.has_index = true;
                if let (Some(watch), Some(stamp)) = (&self.watch, walk.watch_stamp) {
                    watch.walk_done(stamp);
                }
                self.walks += 1;
                self.skipped = skipped;
                if skipped > 0 {
                    ctx.log(Level::Warn, format!("walk of {}: skipped {skipped} paths", self.root));
                }
                let files = self.current.len();
                ctx.emit(Event::Indexed { files, millis });
                for reply in rescans {
                    reply.ok(files);
                }
            }
        }
        for reply in std::mem::take(&mut self.pending_files) {
            self.stream_files(reply, ctx);
        }
        if std::mem::take(&mut self.walk_again) {
            self.pending_rescans = std::mem::take(&mut self.next_rescans);
            self.start_walk(ctx);
        }
    }

    /// Applies file-system changes to the index queries use, records them in the running walk, and emits
    /// `:changed` when the index changed.
    fn fs_changes(&mut self, changes: Vec<Change>, ctx: &Context<Self>) {
        let index = match &mut self.walk {
            Some(walk) if !self.has_index => &mut walk.index,
            _ => &mut self.current,
        };
        let (mut added, mut removed) = (0, 0);
        for change in &changes {
            let (a, r) = apply(index, change);
            added += a;
            removed += r;
        }
        if let Some(walk) = &mut self.walk {
            walk.changes.extend(changes);
        }
        if added + removed > 0 {
            ctx.emit(Event::Changed { added, removed });
        }
    }

    /// Logs and emits a watcher failure (the caller has dropped the watcher).
    fn watch_failed(&mut self, message: String, ctx: &Context<Self>) {
        ctx.log(Level::Warn, format!("not watching {}: {message}", self.root));
        ctx.emit(Event::WatchFailed { message });
    }

    /// Streams a snapshot of the index from a spawned task.
    fn stream_files(&self, reply: Reply, ctx: &Context<Self>) {
        let snapshot: Vec<String> = self.view().iter().map(String::from).collect();
        let out = reply.stream::<String>(FILES_CAPACITY);
        #[cfg(test)]
        let root = self.config.root.clone();
        ctx.spawn(move |_| {
            let token = out.token();
            let total = snapshot.len();
            let mut sent = 0;
            for path in snapshot {
                if token.is_cancelled() || out.send(path).is_err() {
                    break;
                }
                sent += 1;
            }
            #[cfg(test)]
            hook::files_task_ended(&root, sent, total);
            if sent == total {
                out.finish();
            }
        });
    }
}

impl Service for Projdex {
    const NAME: &'static str = "projdex";
    type Args = Args;
    type Request = Request;
    type Event = Event;

    fn start(args: Args, ctx: &Context<Self>) -> Result<Self, Error> {
        let root = PathBuf::from(&args.root);
        if !root.is_absolute() {
            return Err(Error::new(format!("projdex root is not an absolute path: {}", args.root)));
        }
        match std::fs::metadata(&root) {
            Err(e) => return Err(Error::new(format!("projdex root {} cannot be used: {e}", args.root))),
            Ok(meta) if !meta.is_dir() => {
                return Err(Error::new(format!("projdex root is not a directory: {}", args.root)));
            }
            Ok(_) => {}
        }
        let config = WalkConfig { root, include_hidden: args.include_hidden, ignores: args.ignores };
        walk::check_ignores(&config).map_err(Error::new)?;
        let config = Arc::new(config);
        // `Address` is `Send` but not necessarily `Sync`; the watcher sends from several threads.
        let address = Mutex::new(ctx.address());
        let sink = Arc::new(move |output| {
            let request = match output {
                Output::Changes(changes) => Request::FsChanges(changes),
                Output::Rescan => Request::FsRescan,
                Output::Failed(message) => Request::WatchFailed(message),
            };
            address.lock().unwrap_or_else(|e| e.into_inner()).send(request);
        });
        let watch = match Watcher::start(config.clone(), sink) {
            Ok(watch) => Some(watch),
            Err(message) => {
                ctx.log(Level::Warn, format!("not watching {}: {message}", args.root));
                ctx.emit(Event::WatchFailed { message });
                None
            }
        };
        let mut projdex = Projdex {
            root: args.root,
            config,
            current: Index::new(),
            has_index: false,
            walk: None,
            generation: 0,
            matcher: Matcher::new(),
            pending_files: Vec::new(),
            pending_rescans: Vec::new(),
            walk_again: false,
            next_rescans: Vec::new(),
            walks: 0,
            skipped: 0,
            watch,
        };
        projdex.start_walk(ctx);
        Ok(projdex)
    }

    fn handle(&mut self, request: Request, reply: Reply, ctx: &Context<Self>) {
        match request {
            Request::Query { text, limit, positions, substring } => {
                let index = view(&self.current, self.has_index, &self.walk);
                let style = if substring { Style::Substring } else { Style::Fuzzy };
                let result = self.matcher.query_styled(index, &text, style, limit, positions);
                reply.ok(QueryReply {
                    paths: result.paths,
                    positions: result.positions,
                    groups: result.groups,
                    total: result.total,
                    indexing: self.walk.is_some(),
                });
            }
            Request::Files => {
                if self.walk.is_some() {
                    self.pending_files.push(reply);
                } else {
                    self.stream_files(reply, ctx);
                }
            }
            Request::Rescan => self.rescan(Some(reply), ctx),
            Request::Status => reply.ok(Status {
                root: self.root.clone(),
                files: self.view().len(),
                indexing: self.walk.is_some(),
                watching: self.watch.as_ref().is_some_and(Watcher::is_active),
                walks: self.walks,
                skipped: self.skipped,
            }),
            Request::WalkBatch { generation, paths } => {
                if let Some(walk) = self.walk.as_mut().filter(|w| w.generation == generation) {
                    for path in &paths {
                        walk.index.add(path);
                    }
                }
            }
            Request::WalkDone { generation, skipped, millis, cancelled, error } => {
                if self.walk.as_ref().is_some_and(|w| w.generation == generation) {
                    let failure = error.or_else(|| cancelled.then(|| "the walk was cancelled".to_string()));
                    self.walk_done(failure, skipped, millis, ctx);
                }
            }
            Request::FsChanges(changes) => self.fs_changes(changes, ctx),
            Request::FsRescan => self.rescan(None, ctx),
            Request::WatchFailed(message) => {
                if self.watch.take().is_some() {
                    self.watch_failed(message, ctx);
                }
            }
        }
    }

    fn stop(&mut self) {
        if let Some(walk) = &self.walk {
            walk.cancel.store(true, Ordering::Relaxed);
        }
        self.watch = None;
    }
}

/// Test hooks keyed by the project root (each test uses its own temporary root): hold walks before they report
/// `WalkDone`, and observe `(:files)` stream tasks ending.
#[cfg(test)]
pub(crate) mod hook {
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Condvar, LazyLock, Mutex};
    use std::time::{Duration, Instant};

    /// How long a held walk or a waiting test waits at most.
    const LIMIT: Duration = Duration::from_secs(10);

    #[derive(Default)]
    struct State {
        held: bool,
        /// While held, the walks numbered up to this one (counting from 1 in the order they reach the hook) pass.
        released_through: usize,
        /// Walks that reached the point before sending `WalkDone`.
        reached: usize,
        /// Rescans requested while a walk ran.
        walks_again: usize,
        /// `(sent, total)` of each ended `(:files)` task.
        files_tasks: Vec<(usize, usize)>,
    }

    #[derive(Default)]
    pub struct Probe {
        state: Mutex<State>,
        changed: Condvar,
    }

    static PROBES: LazyLock<Mutex<HashMap<PathBuf, Arc<Probe>>>> = LazyLock::new(Default::default);

    /// Installs a probe for `root`.
    pub fn install(root: &Path) -> Arc<Probe> {
        let probe = Arc::new(Probe::default());
        PROBES.lock().unwrap().insert(root.to_path_buf(), probe.clone());
        probe
    }

    fn get(root: &Path) -> Option<Arc<Probe>> {
        PROBES.lock().unwrap().get(root).cloned()
    }

    impl Probe {
        /// Walks that finish from now on wait before sending `WalkDone` until [`Probe::release`].
        pub fn hold(&self) {
            self.state.lock().unwrap().held = true;
        }

        pub fn release(&self) {
            self.state.lock().unwrap().held = false;
            self.changed.notify_all();
        }

        /// Lets the held walks numbered up to `n` go on; later ones stay held.
        pub fn release_through(&self, n: usize) {
            self.state.lock().unwrap().released_through = n;
            self.changed.notify_all();
        }

        fn wait_until(&self, done: impl Fn(&State) -> bool) -> bool {
            let deadline = Instant::now() + LIMIT;
            let mut state = self.state.lock().unwrap();
            while !done(&state) {
                let now = Instant::now();
                if now >= deadline {
                    return false;
                }
                state = self.changed.wait_timeout(state, deadline - now).unwrap().0;
            }
            true
        }

        /// Waits until `n` walks have finished walking (all their batches are sent).
        pub fn wait_reached(&self, n: usize) -> bool {
            self.wait_until(|s| s.reached >= n)
        }

        /// Walks that reached the point before sending `WalkDone` so far.
        pub fn reached(&self) -> usize {
            self.state.lock().unwrap().reached
        }

        /// Waits until `n` rescans have been requested while a walk ran.
        pub fn wait_walks_again(&self, n: usize) -> bool {
            self.wait_until(|s| s.walks_again >= n)
        }

        /// Waits until `n` `(:files)` tasks have ended and returns their `(sent, total)`.
        pub fn wait_files_tasks(&self, n: usize) -> Vec<(usize, usize)> {
            assert!(self.wait_until(|s| s.files_tasks.len() >= n), "files tasks did not end");
            self.state.lock().unwrap().files_tasks.clone()
        }
    }

    pub(super) fn walk_finished(root: &Path) {
        let Some(probe) = get(root) else { return };
        let mut state = probe.state.lock().unwrap();
        state.reached += 1;
        let number = state.reached;
        probe.changed.notify_all();
        let deadline = Instant::now() + LIMIT;
        while state.held && number > state.released_through && Instant::now() < deadline {
            state = probe.changed.wait_timeout(state, deadline - Instant::now()).unwrap().0;
        }
    }

    pub(super) fn walk_again(root: &Path) {
        let Some(probe) = get(root) else { return };
        probe.state.lock().unwrap().walks_again += 1;
        probe.changed.notify_all();
    }

    pub(super) fn files_task_ended(root: &Path, sent: usize, total: usize) {
        let Some(probe) = get(root) else { return };
        probe.state.lock().unwrap().files_tasks.push((sent, total));
        probe.changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use emrs::testing::Host;
    use emrs::{State as InstanceState, StreamEnd};
    use std::collections::BTreeSet;
    use std::path::Path;
    use tempfile::TempDir;

    fn write(root: &Path, rel: &str) {
        let p = root.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, "").unwrap();
    }

    fn tree(files: &[&str]) -> TempDir {
        let t = TempDir::new().unwrap();
        for f in files {
            write(t.path(), f);
        }
        t
    }

    fn args(root: &Path) -> Args {
        Args { root: root.to_str().unwrap().to_string(), include_hidden: true, ignores: Vec::new() }
    }

    fn query(text: &str, limit: usize, positions: bool) -> Request {
        Request::Query { text: text.to_string(), limit, positions, substring: false }
    }

    fn status(host: &mut Host<Projdex>) -> Status {
        host.call::<Status>(Request::Status).unwrap()
    }

    fn all_paths(host: &mut Host<Projdex>) -> BTreeSet<String> {
        let result = host.call_stream::<String>(Request::Files).unwrap();
        assert_eq!(result.status, StreamEnd::Done);
        result.items.into_iter().collect()
    }

    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    /// Waits for the next `:indexed` event, skipping other events.
    fn indexed_files(host: &mut Host<Projdex>) -> usize {
        loop {
            match host.next_event() {
                Some(Event::Indexed { files, .. }) => return files,
                Some(_) => {}
                None => panic!("no :indexed event"),
            }
        }
    }

    /// Waits for an `:indexed` event with `files` files, skipping other events.
    fn wait_indexed(host: &mut Host<Projdex>, files: usize) {
        while indexed_files(host) != files {}
    }

    /// Starts an instance and waits for its first `:indexed` event.
    fn started(root: &Path) -> Host<Projdex> {
        let mut host = Host::<Projdex>::start(args(root));
        indexed_files(&mut host);
        host
    }

    fn start_error(args: Args) -> String {
        let mut host = Host::<Projdex>::start(args);
        let (state, error) = host.wait_exit();
        assert_eq!(state, InstanceState::Failed);
        error.expect("a start error").to_string()
    }

    #[test]
    fn bad_roots_fail_start() {
        let t = tree(&["file"]);
        let mut relative = args(t.path());
        relative.root = "relative/dir".into();
        assert!(start_error(relative).contains("not an absolute path"));

        let mut missing = args(t.path());
        missing.root = t.path().join("missing").to_str().unwrap().into();
        assert!(start_error(missing).contains("cannot be used"));

        let mut file = args(t.path());
        file.root = t.path().join("file").to_str().unwrap().into();
        assert!(start_error(file).contains("not a directory"));

        let mut bad_ignore = args(t.path());
        bad_ignore.ignores = vec!["ok.txt".into(), "[z-a]".into()];
        assert!(start_error(bad_ignore).contains("invalid ignore pattern"));
    }

    #[test]
    fn hidden_and_ignores_args() {
        let t = tree(&[".hidden", "visible", "other"]);
        let mut host = started(t.path());
        assert_eq!(all_paths(&mut host), set(&[".hidden", "visible", "other"]));

        let mut narrow = args(t.path());
        narrow.include_hidden = false;
        narrow.ignores = vec!["vis*".into()];
        let mut host = started_with(narrow);
        assert_eq!(all_paths(&mut host), set(&["other"]));
    }

    fn started_with(args: Args) -> Host<Projdex> {
        let mut host = Host::<Projdex>::start(args);
        indexed_files(&mut host);
        host
    }

    #[test]
    fn queries_during_and_after_first_walk() {
        let t = tree(&["src/main.rs", "src/lib.rs", "README.md"]);
        let probe = hook::install(t.path());
        probe.hold();
        let mut host = Host::<Projdex>::start(args(t.path()));
        assert!(probe.wait_reached(1));
        // Every batch of the first walk was queued before this query, so the partial index is complete here.
        let during = host.call::<QueryReply>(query("", 10, false)).unwrap();
        assert!(during.indexing);
        assert_eq!(during.total, 3);
        assert_eq!(during.positions, None);
        let st = status(&mut host);
        assert!(st.indexing);
        assert_eq!((st.files, st.walks), (3, 0));

        probe.release();
        assert_eq!(indexed_files(&mut host), 3);
        let after = host.call::<QueryReply>(query("mainrs", 10, true)).unwrap();
        assert!(!after.indexing);
        assert_eq!(after.paths, vec!["src/main.rs".to_string()]);
        assert_eq!(after.total, 1);
        assert_eq!(after.positions, Some(vec![vec![4, 5, 6, 7, 9, 10]]));
    }

    #[test]
    fn query_limit_and_total() {
        let names: Vec<String> = (0..30).map(|i| format!("dir/file{i:02}.txt")).collect();
        let t = tree(&names.iter().map(String::as_str).collect::<Vec<_>>());
        let mut host = started(t.path());
        let reply = host.call::<QueryReply>(query("file", 5, true)).unwrap();
        assert_eq!(reply.paths.len(), 5);
        assert_eq!(reply.positions.as_ref().map(Vec::len), Some(5));
        assert_eq!(reply.total, 30);
        assert_eq!(host.call::<QueryReply>(query("nomatchzz", 5, false)).unwrap().total, 0);
    }

    #[test]
    fn query_substring_and_groups() {
        let t = tree(&["src/act/manager.rs", "a/c/t/m/a/n"]);
        let mut host = started(t.path());
        let fuzzy = host.call::<QueryReply>(query("act man", 10, true)).unwrap();
        assert_eq!(fuzzy.total, 2);
        let request = Request::Query { text: "man act".into(), limit: 10, positions: true, substring: true };
        let reply = host.call::<QueryReply>(request).unwrap();
        assert_eq!(reply.paths, vec!["src/act/manager.rs".to_string()]);
        assert_eq!(reply.positions, Some(vec![vec![4, 5, 6, 8, 9, 10]]));
        assert_eq!(reply.groups, Some(vec![vec![1, 1, 1, 0, 0, 0]]));
    }

    #[test]
    fn status_fields() {
        let t = tree(&["a", "b/c"]);
        let mut host = started(t.path());
        let st = status(&mut host);
        assert_eq!(
            st,
            Status {
                root: t.path().to_str().unwrap().to_string(),
                files: 2,
                indexing: false,
                watching: true,
                walks: 1,
                skipped: 0,
            }
        );
    }

    #[test]
    fn files_waits_for_running_walk() {
        let t = tree(&["a", "b/c", "b/d/e"]);
        let probe = hook::install(t.path());
        probe.hold();
        let mut host = Host::<Projdex>::start(args(t.path()));
        assert!(probe.wait_reached(1));
        let call = host.begin_stream(Request::Files).unwrap();
        // The status request is handled after the files request; the stream has not started then.
        assert!(status(&mut host).indexing);
        assert_eq!(host.items_received(call), 0);
        probe.release();
        let result = host.finish_stream::<String>(call);
        assert_eq!(result.status, StreamEnd::Done);
        assert_eq!(result.items.into_iter().collect::<BTreeSet<_>>(), set(&["a", "b/c", "b/d/e"]));
        assert_eq!(probe.wait_files_tasks(1), vec![(3, 3)]);
    }

    #[test]
    fn cancelled_files_stream_stops_its_task() {
        let t = TempDir::new().unwrap();
        let count = FILES_CAPACITY + 1000;
        for i in 0..count {
            std::fs::write(t.path().join(format!("f{i}")), "").unwrap();
        }
        let probe = hook::install(t.path());
        let mut host = started(t.path());
        let call = host.begin_stream(Request::Files).unwrap();
        // Nothing is drained before the cancel, so the task cannot send more than the capacity.
        host.cancel(call);
        let tasks = probe.wait_files_tasks(1);
        assert_eq!(tasks.len(), 1);
        let (sent, total) = tasks[0];
        assert_eq!(total, count);
        assert!(sent <= FILES_CAPACITY, "sent {sent}");
        // The instance keeps answering.
        assert_eq!(status(&mut host).files, count);
    }

    #[test]
    fn rescan_answers_after_new_walk() {
        let t = tree(&["a", "b"]);
        let mut host = started(t.path());
        write(t.path(), "new/file.txt");
        std::fs::remove_file(t.path().join("a")).unwrap();
        assert_eq!(host.call::<usize>(Request::Rescan).unwrap(), 2);
        assert_eq!(indexed_files(&mut host), 2);
        assert_eq!(host.call::<QueryReply>(query("newfile", 10, false)).unwrap().paths, vec!["new/file.txt"]);
        assert_eq!(all_paths(&mut host), set(&["b", "new/file.txt"]));
        let st = status(&mut host);
        assert_eq!((st.walks, st.files, st.indexing), (2, 2, false));
    }

    /// Rescans during a walk do not cancel it: they start one follow-up walk when it ends.
    #[test]
    fn rescans_during_walk_coalesce() {
        let t = tree(&["a", "b"]);
        // Without a watcher, so that writing "c" changes nothing but the next walk.
        watch_hook::fail_setup(t.path());
        let probe = hook::install(t.path());
        let mut host = started(t.path());
        probe.hold();
        let first = host.begin_stream(Request::Rescan).unwrap();
        // Walk 2 has listed "a" and "b".
        assert!(probe.wait_reached(2));
        write(t.path(), "c");
        let second = host.begin_stream(Request::Rescan).unwrap();
        let files = host.begin_stream(Request::Files).unwrap();
        let third = host.begin_stream(Request::Rescan).unwrap();
        host.send(Request::FsRescan);
        assert!(probe.wait_walks_again(3));
        let st = status(&mut host);
        assert_eq!((st.walks, st.indexing), (1, true));
        // Walk 3 stays held until it is checked that walk 2 ended first.
        probe.release_through(2);
        // Requested before walk 2 started: answered from it, as is `(:files)`.
        assert_eq!(host.finish_stream::<usize>(first).items, vec![2]);
        assert_eq!(indexed_files(&mut host), 2);
        let result = host.finish_stream::<String>(files);
        assert_eq!(result.items.into_iter().collect::<BTreeSet<_>>(), set(&["a", "b"]));
        assert!(probe.wait_reached(3));
        let st = status(&mut host);
        assert_eq!((st.walks, st.files, st.indexing), (2, 2, true));
        probe.release();
        // Requested while walk 2 ran: answered from the single follow-up walk.
        for call in [second, third] {
            let result = host.finish_stream::<usize>(call);
            assert_eq!(result.status, StreamEnd::Done);
            assert_eq!(result.items, vec![3]);
        }
        assert_eq!(indexed_files(&mut host), 3);
        let st = status(&mut host);
        assert_eq!((st.walks, st.files, st.indexing), (3, 3, false));
        assert_eq!(probe.reached(), 3);
        assert_eq!(all_paths(&mut host), set(&["a", "b", "c"]));
    }

    /// A rescan during the first walk runs after it; the first walk's index becomes current meanwhile.
    #[test]
    fn rescan_during_first_walk() {
        let t = tree(&["a"]);
        watch_hook::fail_setup(t.path());
        let probe = hook::install(t.path());
        probe.hold();
        let mut host = Host::<Projdex>::start(args(t.path()));
        assert!(probe.wait_reached(1));
        write(t.path(), "b");
        let rescan = host.begin_stream(Request::Rescan).unwrap();
        assert!(probe.wait_walks_again(1));
        probe.release();
        assert_eq!(indexed_files(&mut host), 1);
        assert_eq!(host.finish_stream::<usize>(rescan).items, vec![2]);
        assert_eq!(indexed_files(&mut host), 2);
        assert_eq!(status(&mut host).walks, 2);
    }

    #[test]
    fn stale_generation_messages_are_discarded() {
        let t = tree(&["a", "b"]);
        let mut host = started(t.path());
        // Generation 1 has finished; generation 9 was never started.
        for generation in [1, 9] {
            host.send(Request::WalkBatch { generation, paths: vec!["ghost".into()] });
            host.send(Request::WalkDone { generation, skipped: 0, millis: 0, cancelled: false, error: None });
        }
        let st = status(&mut host);
        assert_eq!((st.walks, st.files, st.indexing), (1, 2, false));
        assert_eq!(host.call::<QueryReply>(query("ghost", 10, false)).unwrap().total, 0);
        assert_eq!(all_paths(&mut host), set(&["a", "b"]));
    }

    #[test]
    fn walk_error_fails_rescans_and_streams_current_index() {
        let t = tree(&["a", "b"]);
        // Without a watcher, so that writing "c" does not change the current index.
        crate::watch::hook::fail_setup(t.path());
        let probe = hook::install(t.path());
        let mut host = started(t.path());
        probe.hold();
        let rescan = host.begin_stream(Request::Rescan).unwrap();
        let files = host.begin_stream(Request::Files).unwrap();
        write(t.path(), "c");
        assert!(probe.wait_reached(2));
        // Generation 2 is the running walk; report it failed before its real WalkDone.
        host.send(Request::WalkDone {
            generation: 2,
            skipped: 0,
            millis: 0,
            cancelled: false,
            error: Some("boom".into()),
        });
        let result = host.finish_stream::<usize>(rescan);
        assert_eq!(result.status, StreamEnd::Failed);
        assert!(result.error.unwrap().message().contains("boom"));
        let result = host.finish_stream::<String>(files);
        assert_eq!(result.status, StreamEnd::Done);
        assert_eq!(result.items.into_iter().collect::<BTreeSet<_>>(), set(&["a", "b"]));
        let st = status(&mut host);
        assert_eq!((st.walks, st.files, st.indexing), (1, 2, false));
        assert!(host.logs().iter().any(|l| l.starts_with("[error]") && l.contains("boom")));
        probe.release();
    }

    /// A failed first walk leaves its partial index current, without an `:indexed` event.
    #[test]
    fn first_walk_error_keeps_partial_index() {
        let t = tree(&["a", "b"]);
        watch_hook::fail_setup(t.path());
        let probe = hook::install(t.path());
        probe.hold();
        let mut host = Host::<Projdex>::start(args(t.path()));
        assert!(probe.wait_reached(1));
        let files = host.begin_stream(Request::Files).unwrap();
        let rescan = host.begin_stream(Request::Rescan).unwrap();
        host.send(Request::WalkDone {
            generation: 1,
            skipped: 0,
            millis: 0,
            cancelled: false,
            error: Some("boom".into()),
        });
        let result = host.finish_stream::<String>(files);
        assert_eq!(result.status, StreamEnd::Done);
        assert_eq!(result.items.into_iter().collect::<BTreeSet<_>>(), set(&["a", "b"]));
        // The rescan requested during the failed walk starts the next walk, whose `:indexed` is the first one.
        probe.release();
        assert_eq!(host.finish_stream::<usize>(rescan).items, vec![2]);
        loop {
            match host.next_event() {
                Some(Event::Indexed { files, .. }) => break assert_eq!(files, 2),
                Some(Event::WatchFailed { .. }) => {}
                other => panic!("expected :indexed, got {other:?}"),
            }
        }
        assert_eq!(status(&mut host).walks, 1);
        assert!(host.logs().iter().any(|l| l.starts_with("[error]") && l.contains("boom")));
    }

    #[test]
    fn first_walk_error_without_rescan_keeps_partial_index() {
        let t = tree(&["a", "b"]);
        watch_hook::fail_setup(t.path());
        let probe = hook::install(t.path());
        probe.hold();
        let mut host = Host::<Projdex>::start(args(t.path()));
        assert!(probe.wait_reached(1));
        host.send(Request::WalkDone {
            generation: 1,
            skipped: 0,
            millis: 0,
            cancelled: false,
            error: Some("boom".into()),
        });
        let st = status(&mut host);
        assert_eq!((st.files, st.walks, st.indexing), (2, 0, false));
        assert_eq!(all_paths(&mut host), set(&["a", "b"]));
        assert_eq!(host.call::<QueryReply>(query("b", 10, false)).unwrap().paths, vec!["b"]);
        probe.release();
    }

    #[cfg(unix)]
    #[test]
    fn skipped_paths_are_counted_and_logged() {
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;
        let t = tree(&["good"]);
        std::fs::write(t.path().join(OsStr::from_bytes(b"bad_\xff")), "").unwrap();
        let mut host = started(t.path());
        let st = status(&mut host);
        assert_eq!((st.files, st.skipped), (1, 1));
        let warnings: Vec<String> = host.logs().into_iter().filter(|l| l.starts_with("[warn]")).collect();
        assert_eq!(warnings.len(), 1, "{warnings:?}");
        assert!(warnings[0].contains("skipped 1 paths"));
    }

    #[test]
    fn stop_during_walk() {
        let t = tree(&["a"]);
        let probe = hook::install(t.path());
        probe.hold();
        let mut host = Host::<Projdex>::start(args(t.path()));
        assert!(probe.wait_reached(1));
        let files = host.begin_stream(Request::Files).unwrap();
        assert_eq!(host.stop(), InstanceState::Stopped);
        probe.release();
        assert_eq!(host.finish_stream::<String>(files).status, StreamEnd::Failed);
    }

    // ---- Watcher through Host, with real file-system changes ----

    use crate::watch::hook as watch_hook;
    use std::time::{Duration, Instant};

    /// How long a test waits for the watcher at most.
    const WAIT: Duration = Duration::from_secs(10);

    /// Polls `check` until it holds; panics after [`WAIT`].
    fn eventually(what: &str, mut check: impl FnMut() -> bool) {
        let deadline = Instant::now() + WAIT;
        while !check() {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// The paths queries see now (does not wait for a running walk).
    fn view_paths(host: &mut Host<Projdex>) -> BTreeSet<String> {
        host.call::<QueryReply>(query("", 10_000, false)).unwrap().paths.into_iter().collect()
    }

    /// Polls queries until the paths are exactly `want`.
    fn wait_paths(host: &mut Host<Projdex>, want: &[&str]) {
        let want = set(want);
        let deadline = Instant::now() + WAIT;
        loop {
            let got = view_paths(host);
            if got == want {
                return;
            }
            assert!(Instant::now() < deadline, "paths: got {got:?}, want {want:?}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// Collects `:changed` events until they add up to (`added`, `removed`); skips other events.
    fn wait_changed(host: &mut Host<Projdex>, added: usize, removed: usize) {
        let (mut a, mut r) = (0, 0);
        while (a, r) != (added, removed) {
            match host.next_event() {
                Some(Event::Changed { added, removed }) => {
                    assert!(added + removed > 0, "empty :changed event");
                    a += added;
                    r += removed;
                }
                Some(_) => {}
                None => panic!(":changed events add up to ({a}, {r}), want ({added}, {removed})"),
            }
            assert!(a <= added && r <= removed, ":changed events add up to ({a}, {r}), want ({added}, {removed})");
        }
    }

    fn watched(root: &Path) -> BTreeSet<String> {
        watch_hook::watched(root).expect("a live watcher")
    }

    fn rename(root: &Path, from: &str, to: &str) {
        std::fs::rename(root.join(from), root.join(to)).unwrap();
    }

    #[test]
    fn watch_files_created_deleted_renamed() {
        let t = tree(&["a.txt", "src/main.rs"]);
        let r = t.path();
        let mut host = started(r);
        assert!(status(&mut host).watching);
        write(r, "src/new.rs");
        wait_changed(&mut host, 1, 0);
        wait_paths(&mut host, &["a.txt", "src/main.rs", "src/new.rs"]);
        std::fs::remove_file(r.join("a.txt")).unwrap();
        wait_changed(&mut host, 0, 1);
        wait_paths(&mut host, &["src/main.rs", "src/new.rs"]);
        rename(r, "src/new.rs", "renamed.rs");
        wait_changed(&mut host, 1, 1);
        wait_paths(&mut host, &["src/main.rs", "renamed.rs"]);
        // A modification changes nothing; a later creation's event is the next one.
        std::fs::write(r.join("renamed.rs"), "content").unwrap();
        write(r, "last");
        wait_changed(&mut host, 1, 0);
        wait_paths(&mut host, &["src/main.rs", "renamed.rs", "last"]);
        let st = status(&mut host);
        assert_eq!((st.files, st.walks, st.watching), (3, 1, true));
    }

    #[test]
    fn watch_directories() {
        let t = tree(&["keep", "x/f1", "x/deep/f2"]);
        let r = t.path();
        let outside = tree(&["moved/one", "moved/sub/two", "moved/sub/deeper/three"]);
        let mut host = started(r);
        assert_eq!(watched(r), set(&["", "x", "x/deep"]));

        // Moved in from outside the tree, with nested files.
        std::fs::rename(outside.path().join("moved"), r.join("moved")).unwrap();
        wait_paths(&mut host, &["keep", "x/f1", "x/deep/f2", "moved/one", "moved/sub/two", "moved/sub/deeper/three"]);
        assert_eq!(watched(r), set(&["", "x", "x/deep", "moved", "moved/sub", "moved/sub/deeper"]));
        // Its directories are watched.
        write(r, "moved/sub/deeper/four");
        wait_paths(
            &mut host,
            &[
                "keep",
                "x/f1",
                "x/deep/f2",
                "moved/one",
                "moved/sub/two",
                "moved/sub/deeper/three",
                "moved/sub/deeper/four",
            ],
        );

        // Renamed within the tree.
        rename(r, "x", "y");
        wait_paths(
            &mut host,
            &[
                "keep",
                "y/f1",
                "y/deep/f2",
                "moved/one",
                "moved/sub/two",
                "moved/sub/deeper/three",
                "moved/sub/deeper/four",
            ],
        );
        eventually("watches follow the rename", || {
            watched(r) == set(&["", "y", "y/deep", "moved", "moved/sub", "moved/sub/deeper"])
        });
        write(r, "y/deep/new");

        // Moved out of the tree.
        std::fs::rename(r.join("moved"), outside.path().join("back")).unwrap();
        wait_paths(&mut host, &["keep", "y/f1", "y/deep/f2", "y/deep/new"]);
        eventually("watches of the moved-out directory are dropped", || watched(r) == set(&["", "y", "y/deep"]));

        // Deleted.
        std::fs::remove_dir_all(r.join("y")).unwrap();
        wait_paths(&mut host, &["keep"]);
        eventually("watches of the deleted directory are dropped", || watched(r) == set(&[""]));
    }

    #[test]
    fn watch_directory_created_after_start() {
        let t = tree(&["a"]);
        let r = t.path();
        let mut host = started(r);
        std::fs::create_dir(r.join("later")).unwrap();
        eventually("the new directory is watched", || watched(r).contains("later"));
        write(r, "later/file");
        wait_paths(&mut host, &["a", "later/file"]);
        // Nested directories created at once, with a file at the bottom.
        write(r, "p/q/s/file");
        wait_paths(&mut host, &["a", "later/file", "p/q/s/file"]);
        eventually("nested directories are watched", || watched(r) == set(&["", "later", "p", "p/q", "p/q/s"]));
        write(r, "p/q/other");
        wait_paths(&mut host, &["a", "later/file", "p/q/s/file", "p/q/other"]);
    }

    #[test]
    fn watch_ignored_directories() {
        let t = tree(&["src/main.rs", "build/out.o", ".hidden/h", ".git/HEAD", "x.skip", "lib/.git/HEAD"]);
        let r = t.path();
        std::fs::write(r.join(".gitignore"), "build/\n*.skip\n").unwrap();
        std::fs::create_dir_all(r.join(".git/info")).unwrap();
        let mut narrow = args(r);
        narrow.include_hidden = false;
        let mut host = started_with(narrow);
        assert_eq!(view_paths(&mut host), set(&["src/main.rs"]));
        // Ignored, hidden and VCS directories are not watched; `.git/info` is (for `exclude`).
        assert_eq!(watched(r), set(&["", ".git/info", "lib", "src"]));

        write(r, "build/new.o");
        write(r, "src/y.skip");
        write(r, ".hidden/new");
        std::fs::create_dir(r.join("dir.skip")).unwrap();
        write(r, "dir.skip/inner");
        std::fs::create_dir(r.join(".newhidden")).unwrap();
        // Events are handled in order: once the marker is in, the ignored paths have been handled.
        write(r, "src/marker");
        wait_paths(&mut host, &["src/main.rs", "src/marker"]);
        assert_eq!(watched(r), set(&["", ".git/info", "lib", "src"]));
    }

    #[test]
    fn watch_ignore_file_change_rescans() {
        let t = tree(&["a.zz", "b.txt", "c.txt"]);
        let r = t.path();
        std::fs::write(r.join(".gitignore"), "").unwrap();
        std::fs::create_dir_all(r.join(".git/info")).unwrap();
        std::fs::write(r.join(".git/info/exclude"), "").unwrap();
        let mut host = started(r);
        assert_eq!(view_paths(&mut host), set(&[".gitignore", "a.zz", "b.txt", "c.txt"]));

        std::fs::write(r.join(".gitignore"), "*.zz\n").unwrap();
        assert_eq!(indexed_files(&mut host), 3);
        assert_eq!(view_paths(&mut host), set(&[".gitignore", "b.txt", "c.txt"]));
        assert_eq!(status(&mut host).walks, 2);
        // Incremental changes follow the new rules.
        write(r, "new.zz");
        write(r, "new.txt");
        wait_paths(&mut host, &[".gitignore", "b.txt", "c.txt", "new.txt"]);

        std::fs::write(r.join(".git/info/exclude"), "b.txt\n").unwrap();
        assert_eq!(indexed_files(&mut host), 3);
        assert_eq!(view_paths(&mut host), set(&[".gitignore", "c.txt", "new.txt"]));

        // Removing the rule brings the files back.
        std::fs::remove_file(r.join(".gitignore")).unwrap();
        assert_eq!(indexed_files(&mut host), 4);
        assert_eq!(view_paths(&mut host), set(&["a.zz", "new.zz", "c.txt", "new.txt"]));
        assert_eq!(status(&mut host).walks, 4);

        // A directory that a new rule ignores loses its watch when the rescan's index becomes current.
        write(r, "gen/out");
        wait_paths(&mut host, &["a.zz", "new.zz", "c.txt", "new.txt", "gen/out"]);
        assert!(watched(r).contains("gen"));
        std::fs::write(r.join(".gitignore"), "gen/\n").unwrap();
        assert_eq!(indexed_files(&mut host), 5);
        eventually("the ignored directory's watch is dropped", || watched(r) == set(&["", ".git/info"]));
    }

    /// An ignore-file change during a walk does not cancel it; the follow-up walk applies the new rules.
    #[test]
    fn watch_ignore_change_during_walk_walks_again() {
        let t = tree(&["a.zz", "b.txt"]);
        let r = t.path();
        std::fs::write(r.join(".gitignore"), "").unwrap();
        let probe = hook::install(r);
        let mut host = started(r);
        probe.hold();
        let rescan = host.begin_stream(Request::Rescan).unwrap();
        assert!(probe.wait_reached(2));
        std::fs::write(r.join(".gitignore"), "*.zz\n").unwrap();
        assert!(probe.wait_walks_again(1));
        probe.release();
        // Walk 2 used the old rules.
        assert_eq!(host.finish_stream::<usize>(rescan).items, vec![3]);
        assert_eq!(indexed_files(&mut host), 3);
        assert_eq!(indexed_files(&mut host), 2);
        assert_eq!(view_paths(&mut host), set(&[".gitignore", "b.txt"]));
        assert_eq!(status(&mut host).walks, 3);
    }

    /// Events lost during a walk: the follow-up walk re-adds the watches of directories it already knows.
    #[test]
    fn watch_lost_events_during_walk_rewatch() {
        let t = tree(&["a", "d/x"]);
        let r = t.path();
        let probe = hook::install(r);
        let mut host = started(r);
        probe.hold();
        let rescan = host.begin_stream(Request::Rescan).unwrap();
        assert!(probe.wait_reached(2));
        // As if "d" had been replaced while events were lost: known, but no longer watched.
        watch_hook::drop_watch(r, "d");
        watch_hook::lose_events(r);
        assert!(probe.wait_walks_again(1));
        probe.release();
        assert_eq!(host.finish_stream::<usize>(rescan).items, vec![2]);
        assert_eq!(indexed_files(&mut host), 2);
        assert_eq!(indexed_files(&mut host), 2);
        write(r, "d/new");
        wait_paths(&mut host, &["a", "d/x", "d/new"]);
    }

    /// `git init` in an indexed tree: `.git/info` is watched, so later `exclude` edits rescan.
    #[test]
    fn watch_git_info_created_after_start() {
        let t = tree(&["a.zz", "b.txt", "sub/c.zz", "sub/d.txt"]);
        let r = t.path();
        let mut host = started(r);
        assert_eq!(watched(r), set(&["", "sub"]));
        // At the root, as `git init` does it: `.git` first, `exclude` later.
        std::fs::create_dir_all(r.join(".git/info")).unwrap();
        eventually("the root's .git/info is watched", || watched(r).contains(".git/info"));
        std::fs::write(r.join(".git/info/exclude"), "*.zz\n").unwrap();
        wait_indexed(&mut host, 2);
        assert_eq!(view_paths(&mut host), set(&["b.txt", "sub/d.txt"]));
        // In a subdirectory, with `exclude` already there when `.git` appears: a rescan applies it.
        std::fs::create_dir_all(r.join("sub/.tmp-git/info")).unwrap();
        std::fs::write(r.join("sub/.tmp-git/info/exclude"), "d.txt\n").unwrap();
        rename(r, "sub/.tmp-git", "sub/.git");
        wait_indexed(&mut host, 1);
        assert_eq!(view_paths(&mut host), set(&["b.txt"]));
        eventually("sub/.git/info is watched", || watched(r).contains("sub/.git/info"));
        std::fs::write(r.join("sub/.git/info/exclude"), "").unwrap();
        wait_indexed(&mut host, 2);
        assert_eq!(view_paths(&mut host), set(&["b.txt", "sub/d.txt"]));
    }

    /// A `.git/info` that appeared unseen is watched when a walk confirms its directory.
    #[test]
    fn watch_git_info_found_by_walk() {
        let t = tree(&["a.zz", "b.txt"]);
        let r = t.path();
        let mut host = started(r);
        std::fs::create_dir_all(r.join(".git/info")).unwrap();
        eventually("the root's .git/info is watched", || watched(r).contains(".git/info"));
        // As if its creation had been missed.
        watch_hook::forget_git_info(r, "");
        assert_eq!(host.call::<usize>(Request::Rescan).unwrap(), 2);
        assert!(watched(r).contains(".git/info"));
        std::fs::write(r.join(".git/info/exclude"), "*.zz\n").unwrap();
        wait_indexed(&mut host, 1);
        assert_eq!(view_paths(&mut host), set(&["b.txt"]));
    }

    #[test]
    fn watch_changes_during_walk_are_kept() {
        let t = tree(&["a", "b", "d/x"]);
        let r = t.path();
        let probe = hook::install(r);
        let mut host = started(r);
        probe.hold();
        let rescan = host.begin_stream(Request::Rescan).unwrap();
        // The new walk has listed everything; it sees none of the changes below.
        assert!(probe.wait_reached(2));
        write(r, "c");
        std::fs::remove_file(r.join("a")).unwrap();
        std::fs::remove_dir_all(r.join("d")).unwrap();
        // Applied to the current index while the walk is open.
        wait_paths(&mut host, &["b", "c"]);
        assert!(status(&mut host).indexing);
        probe.release();
        let result = host.finish_stream::<usize>(rescan);
        assert_eq!(result.items, vec![2]);
        assert_eq!(indexed_files(&mut host), 2);
        assert_eq!(all_paths(&mut host), set(&["b", "c"]));
    }

    /// The debouncer drops every event of a path created and removed within its window; a walk that listed the
    /// file in between must not leave it in the index.
    #[test]
    fn watch_file_created_and_removed_during_walk() {
        let t = tree(&["a"]);
        let r = t.path();
        let probe = hook::install(r);
        let mut host = started(r);
        probe.hold();
        write(r, "tmp");
        let created = Instant::now();
        let rescan = host.begin_stream(Request::Rescan).unwrap();
        // The walk has listed "tmp".
        assert!(probe.wait_reached(2));
        // Well inside the debouncing window, so the debouncer swallows both events.
        std::thread::sleep(Duration::from_millis(4).saturating_sub(created.elapsed()));
        std::fs::remove_file(r.join("tmp")).unwrap();
        probe.release();
        assert_eq!(host.finish_stream::<usize>(rescan).status, StreamEnd::Done);
        wait_paths(&mut host, &["a"]);
    }

    #[test]
    fn watch_changes_during_first_walk_are_kept() {
        let t = tree(&["a", "b"]);
        let r = t.path();
        let probe = hook::install(r);
        probe.hold();
        let mut host = Host::<Projdex>::start(args(r));
        assert!(probe.wait_reached(1));
        write(r, "c");
        std::fs::remove_file(r.join("a")).unwrap();
        // Queries see the partial fresh index, and the changes reach it.
        wait_paths(&mut host, &["b", "c"]);
        probe.release();
        assert_eq!(indexed_files(&mut host), 2);
        assert_eq!(all_paths(&mut host), set(&["b", "c"]));
    }

    #[test]
    fn watch_setup_failure() {
        let t = tree(&["a", "b"]);
        let r = t.path();
        watch_hook::fail_setup(r);
        let mut host = Host::<Projdex>::start(args(r));
        match host.next_event() {
            Some(Event::WatchFailed { message }) => assert!(message.contains("simulated"), "{message}"),
            other => panic!("expected :watch-failed, got {other:?}"),
        }
        assert_eq!(indexed_files(&mut host), 2);
        let st = status(&mut host);
        assert_eq!((st.files, st.watching), (2, false));
        assert_eq!(host.call::<QueryReply>(query("a", 10, false)).unwrap().paths, vec!["a"]);
        assert!(host.logs().iter().any(|l| l.starts_with("[warn]") && l.contains("simulated")));
        // Rescans still work.
        write(r, "c");
        assert_eq!(host.call::<usize>(Request::Rescan).unwrap(), 3);
    }

    #[test]
    fn watch_later_failure() {
        let t = tree(&["a", "d/b"]);
        let r = t.path();
        let mut host = started(r);
        assert!(status(&mut host).watching);
        watch_hook::fail_now(r, "backend broke");
        match host.next_event() {
            Some(Event::WatchFailed { message }) => assert_eq!(message, "backend broke"),
            other => panic!("expected :watch-failed, got {other:?}"),
        }
        let st = status(&mut host);
        assert_eq!((st.files, st.watching), (2, false));
        // A second report does not produce a second event.
        host.send(Request::WatchFailed("again".into()));
        assert_eq!(host.call::<QueryReply>(query("b", 10, false)).unwrap().paths, vec!["d/b"]);
        // The watcher and its watches are gone.
        eventually("the watcher is dropped", || watch_hook::watched(r).is_none());
        write(r, "c");
        assert_eq!(host.call::<usize>(Request::Rescan).unwrap(), 3);
        // Events arrive in order: a second `:watch-failed` would come before this walk's `:indexed`.
        loop {
            match host.next_event() {
                Some(Event::Indexed { files, .. }) => break assert_eq!(files, 3),
                Some(Event::WatchFailed { message }) => panic!("second :watch-failed: {message}"),
                Some(_) => {}
                None => panic!("no :indexed event"),
            }
        }
        assert!(!status(&mut host).watching);
    }

    /// The recursive mode used on macOS and Windows, exercised with inotify.
    #[test]
    fn watch_recursive_mode() {
        let t = tree(&["a", "src/main.rs", "build/out.o"]);
        let r = t.path();
        std::fs::write(r.join(".gitignore"), "build/\n").unwrap();
        watch_hook::recursive(r);
        let outside = tree(&["moved/one", "moved/sub/two"]);
        let mut host = started(r);
        assert!(status(&mut host).watching);
        write(r, "src/new.rs");
        write(r, "build/ignored.o");
        write(r, "build/deep/ignored");
        std::fs::remove_file(r.join("a")).unwrap();
        wait_paths(&mut host, &[".gitignore", "src/main.rs", "src/new.rs"]);
        std::fs::rename(outside.path().join("moved"), r.join("moved")).unwrap();
        wait_paths(&mut host, &[".gitignore", "src/main.rs", "src/new.rs", "moved/one", "moved/sub/two"]);
        write(r, "moved/sub/three");
        rename(r, "src", "lib");
        wait_paths(
            &mut host,
            &[".gitignore", "lib/main.rs", "lib/new.rs", "moved/one", "moved/sub/two", "moved/sub/three"],
        );
        std::fs::remove_dir_all(r.join("moved")).unwrap();
        wait_paths(&mut host, &[".gitignore", "lib/main.rs", "lib/new.rs"]);
        eventually("known directories follow", || watched(r) == set(&["", "lib"]));
        std::fs::write(r.join(".gitignore"), "build/\n*.rs\n").unwrap();
        wait_paths(&mut host, &[".gitignore"]);
        assert!(status(&mut host).walks >= 2);
    }
}
