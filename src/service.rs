//! The `projdex` service: one instance per project root, owning the index of that project.
//!
//! Lisp shapes (spec "Start arguments", "Requests and replies", "Events"):
//!
//! | Request | Reply |
//! |---|---|
//! | `(:query :text S :limit N :positions BOOL)` | `(:paths (P ...) :positions (POS ...) :total M :indexing BOOL)` |
//! | `(:files)` | stream of strings (relative paths), capacity 4096 |
//! | `(:rescan)` | number of files, once the walk it started has finished |
//! | `(:status)` | `(:root R :files N :indexing BOOL :watching BOOL :walks K :skipped S)` |
//!
//! `:limit` defaults to 200 and `:positions` to nil. Start arguments are
//! `(:root "/abs/dir/" :include-hidden t :ignores ("*.min.js"))`; `:include-hidden` defaults to t, `:ignores` to
//! nil. The only event so far is `(:indexed :files N :millis T)`.
//!
//! **Generations.** Every walk has a generation number and builds a fresh [`Index`] from its batches
//! (self-messages [`Request::WalkBatch`]); the fresh index becomes current at the walk's [`Request::WalkDone`].
//! Until then queries use the previous index, except during the first walk, when there is none and queries see
//! the partial fresh index. Starting a walk cancels the running one (its per-walk flag); batches and `WalkDone`
//! of any generation other than the running walk's are discarded. Pending `(:rescan)` and `(:files)` replies are
//! answered only at the `WalkDone` of the running (newest) walk.
//!
//! **Walk errors.** A walk that fails (`walk` returns an error) or reports itself cancelled although it is the
//! newest walk does not replace the index: the error is logged, no `:indexed` event is emitted, `:walks` and
//! `:skipped` are unchanged, pending `(:rescan)` replies fail with the error, and pending `(:files)` replies are
//! streamed from the index queries currently use. With the start-time checks in place this is not expected to
//! happen; a vanished root makes the walk succeed with no files (counted as skipped), not fail.

use crate::index::Index;
use crate::matcher::Matcher;
use crate::walk::{self, WalkConfig};
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
    /// `(:query :text S :limit N :positions BOOL)`; replies with [`QueryReply`].
    Query {
        text: String,
        #[serde(default = "default_limit")]
        limit: usize,
        #[serde(default)]
        positions: bool,
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
}

/// Reply to `(:query)`: `(:paths (P ...) :positions (POS ...) :total M :indexing BOOL)`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct QueryReply {
    pub paths: Vec<String>,
    /// Parallel to `paths`, or nil when not requested.
    pub positions: Option<Vec<Vec<u32>>>,
    pub total: usize,
    pub indexing: bool,
}

/// Reply to `(:status)`: `(:root R :files N :indexing BOOL :watching BOOL :walks K :skipped S)`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    pub root: String,
    pub files: usize,
    pub indexing: bool,
    /// Always false until the watcher exists (task 4).
    pub watching: bool,
    /// Finished walks whose index became current.
    pub walks: u64,
    /// Paths skipped in the last such walk.
    pub skipped: usize,
}

/// Events for `on-event`. The watcher (task 4) adds `Changed` and `WatchFailed`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum Event {
    /// `(:indexed :files N :millis T)`: a walk finished and its index became current.
    Indexed { files: usize, millis: u64 },
}

/// The running walk.
struct Walk {
    generation: u64,
    /// Set to cancel this walk; checked by the walker together with the spawn token.
    cancel: Arc<AtomicBool>,
    /// The fresh index its batches build.
    index: Index,
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
    pending_files: Vec<Reply>,
    pending_rescans: Vec<Reply>,
    walks: u64,
    skipped: usize,
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

    /// Starts a new walk generation, cancelling the running walk.
    fn start_walk(&mut self, ctx: &Context<Self>) {
        if let Some(old) = self.walk.take() {
            old.cancel.store(true, Ordering::Relaxed);
        }
        self.generation += 1;
        let generation = self.generation;
        let cancel = Arc::new(AtomicBool::new(false));
        self.walk = Some(Walk { generation, cancel: cancel.clone(), index: Index::new() });
        let config = self.config.clone();
        // `Address` is `Send` but not necessarily `Sync`; the walker calls `on_batch` from several threads.
        let address = Mutex::new(ctx.address());
        ctx.spawn(move |token| {
            let send = |request| address.lock().unwrap_or_else(|e| e.into_inner()).send(request);
            let is_cancelled = || cancel.load(Ordering::Relaxed) || token.is_cancelled();
            let on_batch = |paths| send(Request::WalkBatch { generation, paths });
            let done = match walk::walk(&config, None, &is_cancelled, &on_batch) {
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
            }
            None => {
                self.current = walk.index;
                self.has_index = true;
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
        let mut projdex = Projdex {
            root: args.root,
            config: Arc::new(config),
            current: Index::new(),
            has_index: false,
            walk: None,
            generation: 0,
            matcher: Matcher::new(),
            pending_files: Vec::new(),
            pending_rescans: Vec::new(),
            walks: 0,
            skipped: 0,
        };
        projdex.start_walk(ctx);
        Ok(projdex)
    }

    fn handle(&mut self, request: Request, reply: Reply, ctx: &Context<Self>) {
        match request {
            Request::Query { text, limit, positions } => {
                let index = view(&self.current, self.has_index, &self.walk);
                let result = self.matcher.query(index, &text, limit, positions);
                reply.ok(QueryReply {
                    paths: result.paths,
                    positions: result.positions,
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
            Request::Rescan => {
                self.start_walk(ctx);
                self.pending_rescans.push(reply);
            }
            Request::Status => reply.ok(Status {
                root: self.root.clone(),
                files: self.view().len(),
                indexing: self.walk.is_some(),
                watching: false,
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
        }
    }

    fn stop(&mut self) {
        if let Some(walk) = &self.walk {
            walk.cancel.store(true, Ordering::Relaxed);
        }
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
        /// Walks that reached the point before sending `WalkDone`.
        reached: usize,
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
        probe.changed.notify_all();
        let deadline = Instant::now() + LIMIT;
        while state.held && Instant::now() < deadline {
            state = probe.changed.wait_timeout(state, deadline - Instant::now()).unwrap().0;
        }
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
        Request::Query { text: text.to_string(), limit, positions }
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

    fn indexed_files(host: &mut Host<Projdex>) -> usize {
        match host.next_event() {
            Some(Event::Indexed { files, .. }) => files,
            None => panic!("no :indexed event"),
        }
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
                watching: false,
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

    #[test]
    fn two_rescans_answered_from_newest_walk() {
        let t = tree(&["a", "b"]);
        let probe = hook::install(t.path());
        let mut host = started(t.path());
        probe.hold();
        let first = host.begin_stream(Request::Rescan).unwrap();
        write(t.path(), "c");
        let second = host.begin_stream(Request::Rescan).unwrap();
        // Both new walks have finished walking (the first possibly cut short by its cancellation).
        assert!(probe.wait_reached(3));
        probe.release();
        for call in [first, second] {
            let result = host.finish_stream::<usize>(call);
            assert_eq!(result.status, StreamEnd::Done);
            assert_eq!(result.items, vec![3]);
        }
        assert_eq!(indexed_files(&mut host), 3);
        let st = status(&mut host);
        assert_eq!((st.walks, st.files, st.indexing), (2, 3, false));
        assert_eq!(all_paths(&mut host), set(&["a", "b", "c"]));
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
}
