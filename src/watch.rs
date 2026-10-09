//! The file watcher: keeps the index current between walks (spec "Watching").
//!
//! **What is watched.** Exactly the directories the walk descends into (not ignored, not a VCS directory, not
//! hidden when `include_hidden` is false). On Linux every such directory gets its own non-recursive inotify
//! watch ([`Mode::PerDir`]): the root when the watcher starts, the others from the walk's directory callback
//! ([`walk::walk_dirs`]), which runs before the walker lists the directory, so nothing created in it after
//! that point is missed. In addition, `<dir>/.git/info` is watched when it exists, so a change to
//! `.git/info/exclude` is seen although `.git` itself is not watched. Elsewhere (macOS FSEvents, Windows) the
//! root is watched recursively and events below ignored directories are filtered ([`Mode::Recursive`]).
//!
//! In both modes the watcher keeps the set of known directories (root-relative), each stamped with the value of
//! a clock when it was last confirmed by a walk or added by the watcher. A full walk starts by advancing the
//! clock ([`Watcher::begin_walk`]) and confirms every directory it visits; when it finishes and its index
//! becomes current, directories with an older stamp are dropped together with their watches
//! ([`Watcher::walk_done`]). After lost events the next walk re-adds the watch of every directory it visits,
//! because a directory may have been replaced while events were lost.
//!
//! **Threads.** `notify` runs its backend thread and the debouncer's thread. The debouncer hands each batch of
//! debounced events to a channel; the watcher's own thread (`projdex-watch`) translates them into index
//! changes, walking new directories itself, and sends the results to the service through a [`Sink`]. Nothing
//! here touches the index: the service applies the changes in `handle`.
//!
//! **Translation** ([`translate`]). Only creations, removals and renames are considered; content and metadata
//! changes are ignored. Each affected path is compared with the disk at translation time, which makes the
//! result independent of how the backend reports (or pairs) renames: a path that is a file now and not
//! ignored is added; a path that no longer exists is removed (or, if it was a known directory, every path
//! below it is removed and its watches dropped); a directory that exists now and is not ignored is walked
//! with the same rules, its files added and its directories watched. A rename is thus a remove of the old
//! path and an add of the new one, paired or not. All changes are idempotent.
//!
//! **Full rescans.** A change to `.gitignore`, `.ignore` or `.git/info/exclude` in a directory that is not
//! ignored, or lost events (notify's rescan flag, which inotify sets on queue overflow and FSEvents on dropped
//! events), produce [`Output::Rescan`] instead of incremental changes; the rest of that batch is dropped,
//! since the walk starts after those events and sees their effect. Ignore rules are cached per directory
//! ([`IgnoreRules`]) and the cache is cleared at every full walk; the rules of a directory that is created or
//! removed are dropped from the cache.
//!
//! **Failures.** Reaching the inotify watch limit, or an error from the backend, stops watching: every watch
//! is dropped and [`Output::Failed`] is sent once. Errors about a single path that vanished or cannot be
//! watched (for example an unreadable directory) only leave that directory unwatched.
//!
//! Implementation note: `notify-debouncer-full` keeps the list of watched roots in a `Vec` and scans it on
//! every `watch` call, which is quadratic for the hundreds of thousands of directories of a large tree. The
//! debouncer is therefore only used for debouncing: it is built over [`SharedWatcher`], whose backend watcher
//! is shared with this module, and every watch is added and removed on the backend directly.

use crate::walk::{self, IgnoreRules, OnDir, WalkConfig};
use notify::event::{EventKind, ModifyKind, RenameMode};
use notify::{RecommendedWatcher, RecursiveMode, Watcher as _};
use notify_debouncer_full::{DebounceEventResult, DebouncedEvent, Debouncer, NoCache, new_debouncer_opt};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

/// The debouncing window.
const DEBOUNCE: Duration = Duration::from_millis(100);

/// One change to the index, with a root-relative path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    Add(String),
    Remove(String),
    /// Remove every path below this directory.
    RemoveDir(String),
}

/// What the watcher reports to the service.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Output {
    Changes(Vec<Change>),
    /// Start a full walk.
    Rescan,
    /// Watching has stopped for good; the message says why.
    Failed(String),
}

pub type Sink = Arc<dyn Fn(Output) + Send + Sync>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// One non-recursive watch per directory (Linux).
    PerDir,
    /// One recursive watch on the root; events are filtered (macOS, Windows).
    Recursive,
}

fn mode_for(_root: &Path) -> Mode {
    #[cfg(test)]
    if hook::is_recursive(_root) {
        return Mode::Recursive;
    }
    if cfg!(target_os = "linux") { Mode::PerDir } else { Mode::Recursive }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

/// The backend watcher, shared between the debouncer and this module (see the module docs).
type Backend = Arc<Mutex<Option<RecommendedWatcher>>>;

thread_local! {
    /// Hands the backend created inside `new_debouncer_opt` back to [`Watcher::start`] on the same thread.
    static CREATED: RefCell<Option<Backend>> = const { RefCell::new(None) };
}

/// The watcher type given to the debouncer: a handle on the shared backend.
struct SharedWatcher(Backend);

impl notify::Watcher for SharedWatcher {
    fn new<F: notify::EventHandler>(handler: F, config: notify::Config) -> notify::Result<Self> {
        let backend = Arc::new(Mutex::new(Some(RecommendedWatcher::new(handler, config)?)));
        CREATED.with(|c| *c.borrow_mut() = Some(backend.clone()));
        Ok(SharedWatcher(backend))
    }

    fn watch(&mut self, path: &Path, recursive_mode: RecursiveMode) -> notify::Result<()> {
        match lock(&self.0).as_mut() {
            Some(w) => w.watch(path, recursive_mode),
            None => Err(notify::Error::generic("the watcher is closed")),
        }
    }

    fn unwatch(&mut self, path: &Path) -> notify::Result<()> {
        match lock(&self.0).as_mut() {
            Some(w) => w.unwatch(path),
            None => Err(notify::Error::generic("the watcher is closed")),
        }
    }

    fn kind() -> notify::WatcherKind {
        RecommendedWatcher::kind()
    }
}

/// Is an error from adding a watch fatal for the whole watcher (rather than for one directory)?
fn watch_error_is_fatal(e: &notify::Error) -> bool {
    matches!(e.kind, notify::ErrorKind::MaxFilesWatch | notify::ErrorKind::Generic(_))
}

fn describe(e: &notify::Error) -> String {
    match e.kind {
        notify::ErrorKind::MaxFilesWatch => {
            "the file watch limit is reached (raise fs.inotify.max_user_watches)".to_string()
        }
        _ => e.to_string(),
    }
}

/// The message for an asynchronous error batch from the debouncer, if it stops watching. Errors about a single
/// path that vanished are not fatal.
fn fatal_errors(errors: &[notify::Error]) -> Option<String> {
    errors
        .iter()
        .find(|e| !matches!(e.kind, notify::ErrorKind::PathNotFound | notify::ErrorKind::WatchNotFound))
        .map(|e| format!("file watcher error: {}", describe(e)))
}

#[derive(Default)]
struct DirState {
    /// Known directories (root-relative; "" is the root) and the clock value when each was last confirmed.
    /// In [`Mode::PerDir`] each has a watch; so does a `<dir>/.git/info` entry.
    dirs: BTreeMap<String, u64>,
    clock: u64,
    failed: bool,
}

/// State shared by the service's handle, the walk tasks and the watcher thread.
struct Shared {
    root: PathBuf,
    /// The root as configured and canonicalized: backends may report either form (FSEvents reports
    /// `/private/var/...` for `/var/...`).
    roots: Vec<PathBuf>,
    mode: Mode,
    backend: Backend,
    state: Mutex<DirState>,
    /// Watching and not failed.
    active: AtomicBool,
    /// The service dropped the watcher.
    closed: AtomicBool,
    /// Events were lost: the next full walk re-adds the watches of the directories it visits.
    force_rewatch: AtomicBool,
    /// Counts full walks; the watcher thread clears its rule cache when it changes.
    walks: AtomicU64,
    sink: Sink,
}

/// Root-relative, `/`-separated form of `path` under one of `roots`.
fn relative(roots: &[PathBuf], path: &Path) -> Option<String> {
    let rel = roots.iter().find_map(|r| path.strip_prefix(r).ok())?;
    let mut out = String::new();
    for c in rel.components() {
        match c {
            Component::Normal(s) => {
                if !out.is_empty() {
                    out.push('/');
                }
                out.push_str(s.to_str()?);
            }
            Component::CurDir => {}
            _ => return None,
        }
    }
    Some(out)
}

/// Is `path` (root-relative) equal to or below the directory `dir`?
fn at_or_below(path: &str, dir: &str) -> bool {
    dir.is_empty() || path == dir || (path.starts_with(dir) && path.as_bytes().get(dir.len()) == Some(&b'/'))
}

/// The `.git/info` entry of the directory `rel`.
fn git_info(rel: &str) -> String {
    if rel.is_empty() { ".git/info".to_string() } else { format!("{rel}/.git/info") }
}

impl Shared {
    fn abs(&self, rel: &str) -> PathBuf {
        if rel.is_empty() { self.root.clone() } else { self.root.join(rel) }
    }

    fn is_active(&self) -> bool {
        self.active.load(Ordering::Relaxed)
    }

    /// Adds a watch on `abs`; `Ok(false)` if that directory cannot be watched (vanished, unreadable).
    fn watch(&self, abs: &Path) -> Result<bool, String> {
        let mut backend = lock(&self.backend);
        let Some(watcher) = backend.as_mut() else { return Ok(false) };
        match watcher.watch(abs, RecursiveMode::NonRecursive) {
            Ok(()) => Ok(true),
            Err(e) if watch_error_is_fatal(&e) => Err(format!("cannot watch {}: {}", abs.display(), describe(&e))),
            Err(_) => Ok(false),
        }
    }

    fn unwatch_all(&self, rels: &[String]) {
        if self.mode != Mode::PerDir || rels.is_empty() {
            return;
        }
        let mut backend = lock(&self.backend);
        if let Some(watcher) = backend.as_mut() {
            for rel in rels {
                // Fails harmlessly when the backend already dropped the watch of a removed directory.
                let _ = watcher.unwatch(&self.abs(rel));
            }
        }
    }

    /// Records the directory `rel` as known (and watches it in [`Mode::PerDir`]). With `force` the watch is
    /// added again even if the directory is already known.
    fn mark(&self, rel: &str, force: bool) {
        if self.closed.load(Ordering::Relaxed) {
            return;
        }
        let failure = {
            let mut st = lock(&self.state);
            if st.failed {
                return;
            }
            let clock = st.clock;
            if let Some(stamp) = st.dirs.get_mut(rel) {
                *stamp = clock;
                if !force {
                    return;
                }
            }
            match self.mode {
                Mode::Recursive => {
                    st.dirs.insert(rel.to_string(), clock);
                    None
                }
                Mode::PerDir => match self.watch(&self.abs(rel)) {
                    Ok(true) => {
                        st.dirs.insert(rel.to_string(), clock);
                        let info = git_info(rel);
                        let info_abs = self.abs(&info);
                        if info_abs.is_dir() {
                            match self.watch(&info_abs) {
                                Ok(true) => {
                                    st.dirs.insert(info, clock);
                                    None
                                }
                                Ok(false) => None,
                                Err(message) => Some(message),
                            }
                        } else {
                            None
                        }
                    }
                    Ok(false) => {
                        st.dirs.remove(rel);
                        None
                    }
                    Err(message) => Some(message),
                },
            }
        };
        if let Some(message) = failure {
            self.fail(message);
        }
    }

    fn is_known(&self, rel: &str) -> bool {
        lock(&self.state).dirs.contains_key(rel)
    }

    /// Forgets the directory `rel` and every directory below it, dropping their watches.
    fn forget(&self, rel: &str) {
        let removed: Vec<String> = {
            let mut st = lock(&self.state);
            let keys: Vec<String> = if rel.is_empty() {
                st.dirs.keys().cloned().collect()
            } else {
                let mut keys: Vec<String> = st.dirs.get_key_value(rel).map(|(k, _)| k.clone()).into_iter().collect();
                let prefix = format!("{rel}/");
                keys.extend(
                    st.dirs.range(prefix.clone()..).take_while(|(k, _)| k.starts_with(&prefix)).map(|(k, _)| k.clone()),
                );
                keys
            };
            for k in &keys {
                st.dirs.remove(k);
            }
            keys
        };
        self.unwatch_all(&removed);
    }

    /// Drops the directories not confirmed since the clock value `stamp` (the root and the `.git/info` entries
    /// of kept directories stay).
    fn prune(&self, stamp: u64) {
        let removed: Vec<String> = {
            let mut st = lock(&self.state);
            // A `.git/info` entry lives and dies with the directory holding `.git`.
            let stale = |st: &DirState, k: &str| {
                let owner = if k == ".git/info" { Some("") } else { k.strip_suffix("/.git/info") };
                !k.is_empty() && st.dirs.get(owner.unwrap_or(k)).is_none_or(|&s| s < stamp)
            };
            let keys: Vec<String> = st.dirs.keys().filter(|k| stale(&st, k)).cloned().collect();
            for k in &keys {
                st.dirs.remove(k);
            }
            keys
        };
        self.unwatch_all(&removed);
    }

    /// Stops watching for good and reports `message` once.
    fn fail(&self, message: String) {
        {
            let mut st = lock(&self.state);
            if st.failed {
                return;
            }
            st.failed = true;
            st.dirs.clear();
        }
        self.active.store(false, Ordering::Relaxed);
        drop(lock(&self.backend).take());
        if !self.closed.load(Ordering::Relaxed) {
            (self.sink)(Output::Failed(message));
        }
    }

    fn close(&self) {
        self.closed.store(true, Ordering::Relaxed);
        self.active.store(false, Ordering::Relaxed);
        drop(lock(&self.backend).take());
    }
}

/// Messages to the watcher thread.
enum Msg {
    Events(DebounceEventResult),
    /// A full walk that began at this clock value finished and its index became current.
    Prune(u64),
}

/// The watcher of one project; dropping it stops watching.
pub struct Watcher {
    debouncer: Option<Debouncer<SharedWatcher, NoCache>>,
    tx: Sender<Msg>,
    shared: Arc<Shared>,
}

/// Handed to a full walk: records the directories it visits.
pub struct DirTracker {
    shared: Arc<Shared>,
    force: bool,
}

impl DirTracker {
    /// The directory callback for [`walk::walk_dirs`].
    pub fn on_dir(self) -> OnDir {
        Arc::new(move |rel: &str| self.shared.mark(rel, self.force))
    }
}

impl Watcher {
    /// Sets up watching of `config.root` and starts the watcher thread. Outputs go to `sink`, from the watcher
    /// thread and from walk threads.
    pub fn start(config: Arc<WalkConfig>, sink: Sink) -> Result<Watcher, String> {
        #[cfg(test)]
        if hook::setup_fails(&config.root) {
            return Err("simulated watcher set-up failure".to_string());
        }
        let mode = mode_for(&config.root);
        let (tx, rx) = channel();
        let handler_tx = tx.clone();
        let handler = move |result: DebounceEventResult| {
            let _ = handler_tx.send(Msg::Events(result));
        };
        let debouncer = new_debouncer_opt::<_, SharedWatcher, NoCache>(
            DEBOUNCE,
            None,
            handler,
            NoCache::new(),
            notify::Config::default(),
        )
        .map_err(|e| format!("cannot start the file watcher: {}", describe(&e)))?;
        let backend = CREATED.with(|c| c.borrow_mut().take()).expect("the backend was created on this thread");

        let root = config.root.clone();
        let mut roots = vec![root.clone()];
        if let Ok(canonical) = root.canonicalize()
            && canonical != root
        {
            roots.push(canonical);
        }
        let shared = Arc::new(Shared {
            root: root.clone(),
            roots,
            mode,
            backend,
            state: Mutex::new(DirState::default()),
            active: AtomicBool::new(true),
            closed: AtomicBool::new(false),
            force_rewatch: AtomicBool::new(false),
            walks: AtomicU64::new(0),
            sink,
        });
        let fail = |e: notify::Error| format!("cannot watch {}: {}", root.display(), describe(&e));
        match mode {
            Mode::PerDir => {
                lock(&shared.backend)
                    .as_mut()
                    .expect("open")
                    .watch(&root, RecursiveMode::NonRecursive)
                    .map_err(fail)?;
                lock(&shared.state).dirs.insert(String::new(), 0);
                // `.git/info` of the root, if any.
                let info = shared.abs(&git_info(""));
                if info.is_dir() && matches!(shared.watch(&info), Ok(true)) {
                    lock(&shared.state).dirs.insert(git_info(""), 0);
                }
            }
            Mode::Recursive => {
                lock(&shared.backend).as_mut().expect("open").watch(&root, RecursiveMode::Recursive).map_err(fail)?;
                lock(&shared.state).dirs.insert(String::new(), 0);
            }
        }
        #[cfg(test)]
        hook::register(&root, &shared);

        let thread_shared = shared.clone();
        std::thread::Builder::new()
            .name("projdex-watch".to_string())
            .spawn(move || run(thread_shared, config, rx))
            .map_err(|e| format!("cannot start the watcher thread: {e}"))?;
        Ok(Watcher { debouncer: Some(debouncer), tx, shared })
    }

    /// Watching, not failed.
    pub fn is_active(&self) -> bool {
        self.shared.is_active()
    }

    /// Called when a full walk starts; returns its directory tracker and the clock value to pass to
    /// [`Watcher::walk_done`].
    pub fn begin_walk(&self) -> (DirTracker, u64) {
        let stamp = {
            let mut st = lock(&self.shared.state);
            st.clock += 1;
            let clock = st.clock;
            if let Some(root) = st.dirs.get_mut("") {
                *root = clock;
            }
            clock
        };
        self.shared.walks.fetch_add(1, Ordering::Relaxed);
        let force = self.shared.force_rewatch.swap(false, Ordering::Relaxed);
        (DirTracker { shared: self.shared.clone(), force }, stamp)
    }

    /// Called when the full walk begun with `stamp` finished and its index became current: drops the
    /// directories (and watches) it did not see, unless the watcher added them since.
    pub fn walk_done(&self, stamp: u64) {
        let _ = self.tx.send(Msg::Prune(stamp));
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        self.shared.close();
        // Stops the debouncer thread, which drops the event handler and so ends the watcher thread.
        drop(self.debouncer.take());
    }
}

/// The watcher thread.
fn run(shared: Arc<Shared>, config: Arc<WalkConfig>, rx: Receiver<Msg>) {
    let mut rules = IgnoreRules::new(&config);
    let mut walks = shared.walks.load(Ordering::Relaxed);
    for msg in rx {
        if shared.closed.load(Ordering::Relaxed) {
            break;
        }
        match msg {
            Msg::Prune(stamp) => shared.prune(stamp),
            Msg::Events(Err(errors)) => {
                if let Some(message) = fatal_errors(&errors) {
                    shared.fail(message);
                }
            }
            Msg::Events(Ok(events)) => {
                if !shared.is_active() {
                    continue;
                }
                let now = shared.walks.load(Ordering::Relaxed);
                if now != walks {
                    rules.clear();
                    walks = now;
                }
                let mut fs = DiskFs { shared: &shared, config: &config, rules: &mut rules };
                match translate(&events, &shared.roots, &mut fs) {
                    Outcome::Rescan { lost } => {
                        rules.clear();
                        if lost {
                            shared.force_rewatch.store(true, Ordering::Relaxed);
                        }
                        (shared.sink)(Output::Rescan);
                    }
                    Outcome::Changes(changes) => {
                        if !changes.is_empty() && !shared.closed.load(Ordering::Relaxed) {
                            (shared.sink)(Output::Changes(changes));
                        }
                    }
                }
            }
        }
    }
}

/// What a path is on disk now. Symbolic links are not followed, except to tell a link to a file (an index
/// entry, like in the walk) from other links.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Missing,
    File,
    Dir,
    /// A symbolic link to a directory or to nothing, a socket, ...: not an entry.
    Other,
}

/// The disk and watch state translation consults; faked in unit tests.
pub(crate) trait Fs {
    fn kind(&self, rel: &str) -> Kind;
    fn is_ignored(&mut self, rel: &str, is_dir: bool) -> bool;
    fn is_known_dir(&self, rel: &str) -> bool;
    /// Forgets the known directory `rel` and the directories below it, dropping their watches.
    fn forget_dir(&mut self, rel: &str);
    /// Watches the directory `rel` and the directories below it, and returns the files below it.
    fn add_dir(&mut self, rel: &str) -> Vec<String>;
}

struct DiskFs<'a> {
    shared: &'a Arc<Shared>,
    config: &'a WalkConfig,
    rules: &'a mut IgnoreRules,
}

impl Fs for DiskFs<'_> {
    fn kind(&self, rel: &str) -> Kind {
        let abs = self.shared.abs(rel);
        match std::fs::symlink_metadata(&abs) {
            Err(_) => Kind::Missing,
            Ok(m) if m.is_dir() => Kind::Dir,
            Ok(m) if m.is_file() => Kind::File,
            Ok(m) if m.file_type().is_symlink() => {
                if std::fs::metadata(&abs).is_ok_and(|t| t.is_file()) {
                    Kind::File
                } else {
                    Kind::Other
                }
            }
            Ok(_) => Kind::Other,
        }
    }

    fn is_ignored(&mut self, rel: &str, is_dir: bool) -> bool {
        self.rules.is_ignored(rel, is_dir)
    }

    fn is_known_dir(&self, rel: &str) -> bool {
        self.shared.is_known(rel)
    }

    fn forget_dir(&mut self, rel: &str) {
        self.rules.forget_below(&self.shared.abs(rel));
        self.shared.forget(rel);
    }

    fn add_dir(&mut self, rel: &str) -> Vec<String> {
        self.rules.forget_below(&self.shared.abs(rel));
        self.shared.mark(rel, false);
        let files = Mutex::new(Vec::new());
        let shared = self.shared.clone();
        let on_dir: OnDir = Arc::new(move |d: &str| shared.mark(d, false));
        let closed = || self.shared.closed.load(Ordering::Relaxed);
        let on_batch = |paths: Vec<String>| lock(&files).extend(paths);
        // An error here is an invalid extra ignore pattern, which `start` already rejected.
        let _ = walk::walk_dirs(self.config, Some(Path::new(rel)), &closed, &on_batch, Some(on_dir));
        files.into_inner().unwrap_or_else(|e| e.into_inner())
    }
}

/// The result of translating one batch of debounced events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// Start a full walk; `lost` when events were lost.
    Rescan {
        lost: bool,
    },
    Changes(Vec<Change>),
}

/// The directory whose ignore rules a change to `rel` affects, if `rel` is an ignore file: the parent of a
/// `.gitignore` or `.ignore`, the directory holding `.git` for `.git/info/exclude`.
fn ignore_file_owner(rel: &str) -> Option<&str> {
    let (parent, name) = rel.rsplit_once('/').unwrap_or(("", rel));
    if name == ".gitignore" || name == ".ignore" {
        return Some(parent);
    }
    let owner = rel.strip_suffix(".git/info/exclude")?;
    match owner.strip_suffix('/') {
        Some(owner) => Some(owner),
        None if owner.is_empty() => Some(""),
        None => None,
    }
}

/// Translates one batch of debounced events (see the module docs).
pub(crate) fn translate(events: &[DebouncedEvent], roots: &[PathBuf], fs: &mut impl Fs) -> Outcome {
    if events.iter().any(|e| e.need_rescan()) {
        return Outcome::Rescan { lost: true };
    }
    // Paths to compare with the disk, in order of first appearance, with whether a removal was reported.
    let mut paths: Vec<(String, bool)> = Vec::new();
    for event in events {
        let structural = matches!(event.kind, EventKind::Create(_) | EventKind::Remove(_) | EventKind::Any)
            || matches!(event.kind, EventKind::Modify(ModifyKind::Name(_)));
        let content =
            matches!(event.kind, EventKind::Modify(ModifyKind::Data(_) | ModifyKind::Any | ModifyKind::Other));
        if !structural && !content {
            continue;
        }
        for (i, path) in event.paths.iter().enumerate() {
            let Some(rel) = relative(roots, path) else { continue };
            if rel.is_empty() {
                continue;
            }
            if let Some(owner) = ignore_file_owner(&rel)
                && (owner.is_empty() || !fs.is_ignored(owner, true))
            {
                return Outcome::Rescan { lost: false };
            }
            if !structural {
                continue;
            }
            let removed = match event.kind {
                EventKind::Create(_) | EventKind::Modify(ModifyKind::Name(RenameMode::To)) => false,
                EventKind::Modify(ModifyKind::Name(RenameMode::Both)) => i == 0,
                _ => true,
            };
            match paths.iter_mut().find(|(p, _)| *p == rel) {
                Some((_, r)) => *r |= removed,
                None => paths.push((rel, removed)),
            }
        }
    }

    let mut changes = Vec::new();
    // Directories already brought in line with the disk in this batch; paths below them need nothing more.
    let mut covered: Vec<String> = Vec::new();
    for (rel, removed) in paths {
        if covered.iter().any(|d| at_or_below(&rel, d)) {
            continue;
        }
        let kind = fs.kind(&rel);
        let known = fs.is_known_dir(&rel);
        if known && (kind != Kind::Dir || removed) {
            changes.push(Change::RemoveDir(rel.clone()));
            fs.forget_dir(&rel);
        }
        match kind {
            Kind::Missing | Kind::Other => {
                if known {
                    covered.push(rel);
                } else if !fs.is_ignored(&rel, false) {
                    changes.push(Change::Remove(rel));
                }
            }
            Kind::File => {
                if !fs.is_ignored(&rel, false) {
                    changes.push(Change::Add(rel));
                }
            }
            Kind::Dir => {
                if !fs.is_ignored(&rel, true) {
                    changes.extend(fs.add_dir(&rel).into_iter().map(Change::Add));
                    covered.push(rel);
                }
            }
        }
    }
    Outcome::Changes(changes)
}

/// Test hooks keyed by the project root: make set-up fail, force [`Mode::Recursive`], and inspect the known
/// (watched) directories.
#[cfg(test)]
pub(crate) mod hook {
    use super::Shared;
    use std::collections::{BTreeSet, HashMap, HashSet};
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, LazyLock, Mutex, Weak};

    static FAIL_SETUP: LazyLock<Mutex<HashSet<PathBuf>>> = LazyLock::new(Default::default);
    static RECURSIVE: LazyLock<Mutex<HashSet<PathBuf>>> = LazyLock::new(Default::default);
    static WATCHERS: LazyLock<Mutex<HashMap<PathBuf, Weak<Shared>>>> = LazyLock::new(Default::default);

    /// Watcher set-up for `root` fails from now on.
    pub fn fail_setup(root: &Path) {
        FAIL_SETUP.lock().unwrap().insert(root.to_path_buf());
    }

    /// The watcher for `root` uses one recursive watch, as on macOS and Windows.
    pub fn recursive(root: &Path) {
        RECURSIVE.lock().unwrap().insert(root.to_path_buf());
    }

    pub(super) fn setup_fails(root: &Path) -> bool {
        FAIL_SETUP.lock().unwrap().contains(root)
    }

    pub(super) fn is_recursive(root: &Path) -> bool {
        RECURSIVE.lock().unwrap().contains(root)
    }

    pub(super) fn register(root: &Path, shared: &Arc<Shared>) {
        WATCHERS.lock().unwrap().insert(root.to_path_buf(), Arc::downgrade(shared));
    }

    /// Makes the live watcher for `root` fail as after a backend error.
    pub fn fail_now(root: &Path, message: &str) {
        let shared = WATCHERS.lock().unwrap().get(root).and_then(Weak::upgrade).expect("a live watcher");
        shared.fail(message.to_string());
    }

    /// The known directories of the live watcher for `root` (each watched in per-directory mode).
    pub fn watched(root: &Path) -> Option<BTreeSet<String>> {
        let shared = WATCHERS.lock().unwrap().get(root)?.upgrade()?;
        let dirs = super::lock(&shared.state).dirs.keys().cloned().collect();
        Some(dirs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use notify::Event;
    use notify::event::{CreateKind, DataChange, Flag, MetadataKind, RemoveKind};
    use std::collections::{BTreeMap, BTreeSet};
    use std::time::Instant;

    const ROOT: &str = "/proj";

    /// A fake file system: paths with their kind, ignored paths, known directories.
    #[derive(Default)]
    struct FakeFs {
        kinds: BTreeMap<String, Kind>,
        ignored: BTreeSet<String>,
        known: BTreeSet<String>,
        /// Calls of `add_dir` and `forget_dir`, in order.
        log: Vec<String>,
    }

    impl FakeFs {
        fn with(mut self, rel: &str, kind: Kind) -> Self {
            self.kinds.insert(rel.to_string(), kind);
            self
        }
        fn known(mut self, rel: &str) -> Self {
            self.known.insert(rel.to_string());
            self
        }
        fn ignore(mut self, rel: &str) -> Self {
            self.ignored.insert(rel.to_string());
            self
        }
    }

    impl Fs for FakeFs {
        fn kind(&self, rel: &str) -> Kind {
            self.kinds.get(rel).copied().unwrap_or(Kind::Missing)
        }
        fn is_ignored(&mut self, rel: &str, _is_dir: bool) -> bool {
            self.ignored.iter().any(|i| at_or_below(rel, i))
        }
        fn is_known_dir(&self, rel: &str) -> bool {
            self.known.contains(rel)
        }
        fn forget_dir(&mut self, rel: &str) {
            self.log.push(format!("forget {rel}"));
            self.known.retain(|k| !at_or_below(k, rel));
        }
        fn add_dir(&mut self, rel: &str) -> Vec<String> {
            self.log.push(format!("add {rel}"));
            self.known.insert(rel.to_string());
            let prefix = format!("{rel}/");
            let below: Vec<(String, Kind)> = self
                .kinds
                .range(prefix.clone()..)
                .take_while(|(k, _)| k.starts_with(&prefix))
                .map(|(k, v)| (k.clone(), *v))
                .collect();
            let mut files = Vec::new();
            for (k, kind) in below {
                if self.ignored.iter().any(|i| at_or_below(&k, i)) {
                    continue;
                }
                match kind {
                    Kind::File => files.push(k),
                    Kind::Dir => {
                        self.known.insert(k);
                    }
                    _ => {}
                }
            }
            files
        }
    }

    fn ev(kind: EventKind, paths: &[&str]) -> DebouncedEvent {
        let mut event = Event::new(kind);
        for p in paths {
            event = event.add_path(PathBuf::from(format!("{ROOT}/{p}")));
        }
        DebouncedEvent::new(event, Instant::now())
    }

    fn run(events: &[DebouncedEvent], fs: &mut FakeFs) -> Outcome {
        translate(events, &[PathBuf::from(ROOT)], fs)
    }

    fn changes(events: &[DebouncedEvent], fs: &mut FakeFs) -> Vec<Change> {
        match run(events, fs) {
            Outcome::Changes(c) => c,
            other => panic!("expected changes, got {other:?}"),
        }
    }

    fn add(p: &str) -> Change {
        Change::Add(p.to_string())
    }
    fn rm(p: &str) -> Change {
        Change::Remove(p.to_string())
    }
    fn rmdir(p: &str) -> Change {
        Change::RemoveDir(p.to_string())
    }

    const CREATE_FILE: EventKind = EventKind::Create(CreateKind::File);
    const CREATE_DIR: EventKind = EventKind::Create(CreateKind::Folder);
    const REMOVE: EventKind = EventKind::Remove(RemoveKind::Any);
    const RENAME_BOTH: EventKind = EventKind::Modify(ModifyKind::Name(RenameMode::Both));
    const RENAME_FROM: EventKind = EventKind::Modify(ModifyKind::Name(RenameMode::From));
    const RENAME_TO: EventKind = EventKind::Modify(ModifyKind::Name(RenameMode::To));
    const RENAME_ANY: EventKind = EventKind::Modify(ModifyKind::Name(RenameMode::Any));
    const DATA: EventKind = EventKind::Modify(ModifyKind::Data(DataChange::Any));

    #[test]
    fn files_created_removed_renamed() {
        let mut fs = FakeFs::default().with("a.rs", Kind::File).with("new.rs", Kind::File);
        let got = changes(
            &[ev(CREATE_FILE, &["a.rs"]), ev(REMOVE, &["gone.rs"]), ev(RENAME_BOTH, &["old.rs", "new.rs"])],
            &mut fs,
        );
        assert_eq!(got, vec![add("a.rs"), rm("gone.rs"), rm("old.rs"), add("new.rs")]);
    }

    #[test]
    fn unpaired_rename_halves_and_any() {
        let mut fs = FakeFs::default().with("in.rs", Kind::File).with("here.rs", Kind::File);
        let got = changes(
            &[
                ev(RENAME_FROM, &["out.rs"]),
                ev(RENAME_TO, &["in.rs"]),
                ev(RENAME_ANY, &["here.rs"]),
                ev(RENAME_ANY, &["away.rs"]),
            ],
            &mut fs,
        );
        assert_eq!(got, vec![rm("out.rs"), add("in.rs"), add("here.rs"), rm("away.rs")]);
    }

    #[test]
    fn disk_state_decides() {
        // A "created" path that is gone again is removed; a "removed" file that exists again is added.
        let mut fs = FakeFs::default().with("back.rs", Kind::File).with("link_to_dir", Kind::Other);
        let got = changes(
            &[ev(CREATE_FILE, &["vanished.rs"]), ev(REMOVE, &["back.rs"]), ev(CREATE_FILE, &["link_to_dir"])],
            &mut fs,
        );
        assert_eq!(got, vec![rm("vanished.rs"), add("back.rs"), rm("link_to_dir")]);
    }

    #[test]
    fn content_and_metadata_changes_ignored() {
        let mut fs = FakeFs::default().with("a.rs", Kind::File);
        let meta = EventKind::Modify(ModifyKind::Metadata(MetadataKind::Any));
        let access = EventKind::Access(notify::event::AccessKind::Any);
        assert_eq!(changes(&[ev(DATA, &["a.rs"]), ev(meta, &["a.rs"]), ev(access, &["a.rs"])], &mut fs), vec![]);
    }

    #[test]
    fn ignored_paths_produce_nothing() {
        let mut fs = FakeFs::default()
            .with("target/x.o", Kind::File)
            .with("target/new", Kind::Dir)
            .with("a.log", Kind::File)
            .ignore("target")
            .ignore("a.log");
        let got = changes(
            &[
                ev(CREATE_FILE, &["target/x.o"]),
                ev(CREATE_DIR, &["target/new"]),
                ev(CREATE_FILE, &["a.log"]),
                ev(REMOVE, &["target/y.o"]),
            ],
            &mut fs,
        );
        assert_eq!(got, vec![]);
        assert!(fs.log.is_empty(), "{:?}", fs.log);
    }

    #[test]
    fn directory_created_is_walked_once() {
        let mut fs = FakeFs::default()
            .with("d", Kind::Dir)
            .with("d/f1", Kind::File)
            .with("d/sub", Kind::Dir)
            .with("d/sub/f2", Kind::File)
            .with("d/build", Kind::Dir)
            .with("d/build/out", Kind::File)
            .ignore("d/build");
        let got = changes(&[ev(CREATE_DIR, &["d"]), ev(CREATE_FILE, &["d/f1"]), ev(CREATE_DIR, &["d/sub"])], &mut fs);
        assert_eq!(got, vec![add("d/f1"), add("d/sub/f2")]);
        assert_eq!(fs.log, vec!["add d"]);
        assert!(fs.known.contains("d/sub") && !fs.known.contains("d/build"));
    }

    #[test]
    fn directory_removed_or_moved_out() {
        let mut fs = FakeFs::default().known("d").known("d/sub").known("e");
        let got = changes(&[ev(REMOVE, &["d/sub/f"]), ev(REMOVE, &["d"]), ev(RENAME_FROM, &["e"])], &mut fs);
        // "d/sub/f" comes first and is not a known directory: a plain remove, then the directory goes.
        assert_eq!(got, vec![rm("d/sub/f"), rmdir("d"), rmdir("e")]);
        assert_eq!(fs.log, vec!["forget d", "forget e"]);
        assert!(fs.known.is_empty());
    }

    #[test]
    fn paths_below_a_handled_directory_are_skipped() {
        let mut fs = FakeFs::default().known("d").known("d/sub");
        let got = changes(&[ev(REMOVE, &["d"]), ev(REMOVE, &["d/sub"]), ev(REMOVE, &["d/sub/f"])], &mut fs);
        assert_eq!(got, vec![rmdir("d")]);
    }

    #[test]
    fn directory_renamed_within_tree() {
        let mut fs = FakeFs::default().known("old").with("new", Kind::Dir).with("new/f", Kind::File);
        let got = changes(&[ev(RENAME_BOTH, &["old", "new"])], &mut fs);
        assert_eq!(got, vec![rmdir("old"), add("new/f")]);
        assert_eq!(fs.log, vec!["forget old", "add new"]);
    }

    #[test]
    fn directory_replaced() {
        // Removed and created again within one batch: old contents go, new ones come.
        let mut fs = FakeFs::default().known("d").with("d", Kind::Dir).with("d/new", Kind::File);
        let got = changes(&[ev(REMOVE, &["d"]), ev(CREATE_DIR, &["d"])], &mut fs);
        assert_eq!(got, vec![rmdir("d"), add("d/new")]);
        assert_eq!(fs.log, vec!["forget d", "add d"]);
        // A creation reported for a known directory that was not removed walks it again without removing.
        let mut fs = FakeFs::default().known("d").with("d", Kind::Dir).with("d/f", Kind::File);
        assert_eq!(changes(&[ev(CREATE_DIR, &["d"])], &mut fs), vec![add("d/f")]);
        // A known directory replaced by a file.
        let mut fs = FakeFs::default().known("d").with("d", Kind::File);
        assert_eq!(changes(&[ev(CREATE_FILE, &["d"])], &mut fs), vec![rmdir("d"), add("d")]);
    }

    #[test]
    fn ignore_file_changes_rescan() {
        for path in [".gitignore", "a/b/.gitignore", "a/.ignore", ".git/info/exclude", "sub/.git/info/exclude"] {
            for kind in [CREATE_FILE, REMOVE, DATA, RENAME_TO] {
                let mut fs = FakeFs::default().with("x", Kind::File);
                let events = [ev(CREATE_FILE, &["x"]), ev(kind, &[path])];
                assert_eq!(run(&events, &mut fs), Outcome::Rescan { lost: false }, "{path} {kind:?}");
            }
        }
        // As the target of a rename (atomic save).
        let mut fs = FakeFs::default();
        assert_eq!(
            run(&[ev(RENAME_BOTH, &["a/.gitignore.tmp", "a/.gitignore"])], &mut fs),
            Outcome::Rescan { lost: false }
        );
        // Reading an ignore file, or one inside an ignored directory, changes nothing.
        let access = EventKind::Access(notify::event::AccessKind::Any);
        let mut fs = FakeFs::default().ignore("node_modules");
        assert_eq!(run(&[ev(access, &[".gitignore"])], &mut fs), Outcome::Changes(vec![]));
        assert_eq!(run(&[ev(DATA, &["node_modules/p/.gitignore"])], &mut fs), Outcome::Changes(vec![]));
        // Not ignore files.
        let mut fs = FakeFs::default().ignore(".git");
        let got = run(
            &[ev(DATA, &["x.gitignore"]), ev(DATA, &[".git/info/excludes"]), ev(DATA, &["git/info/exclude"])],
            &mut fs,
        );
        assert_eq!(got, Outcome::Changes(vec![]));
    }

    #[test]
    fn lost_events_rescan() {
        let mut fs = FakeFs::default();
        let lost = DebouncedEvent::new(Event::new(EventKind::Other).set_flag(Flag::Rescan), Instant::now());
        assert_eq!(run(&[ev(CREATE_FILE, &["x"]), lost], &mut fs), Outcome::Rescan { lost: true });
    }

    #[test]
    fn paths_outside_the_root_and_the_root_itself_are_skipped() {
        let mut fs = FakeFs::default();
        let outside = DebouncedEvent::new(Event::new(CREATE_FILE).add_path("/elsewhere/x".into()), Instant::now());
        let root = DebouncedEvent::new(Event::new(REMOVE).add_path(ROOT.into()), Instant::now());
        assert_eq!(run(&[outside, root], &mut fs), Outcome::Changes(vec![]));
        // A second root form (canonical path) is accepted.
        let mut fs = FakeFs::default().with("a", Kind::File);
        let event = DebouncedEvent::new(Event::new(CREATE_FILE).add_path("/private/proj/a".into()), Instant::now());
        let got = translate(&[event], &[PathBuf::from(ROOT), PathBuf::from("/private/proj")], &mut fs);
        assert_eq!(got, Outcome::Changes(vec![add("a")]));
    }

    #[test]
    fn fatal_error_classification() {
        assert_eq!(fatal_errors(&[notify::Error::path_not_found(), notify::Error::watch_not_found()]), None);
        let limit = notify::Error::new(notify::ErrorKind::MaxFilesWatch);
        assert!(fatal_errors(&[notify::Error::path_not_found(), limit]).unwrap().contains("max_user_watches"));
        assert!(fatal_errors(&[notify::Error::io(std::io::Error::other("boom"))]).unwrap().contains("boom"));
        assert!(watch_error_is_fatal(&notify::Error::new(notify::ErrorKind::MaxFilesWatch)));
        assert!(!watch_error_is_fatal(&notify::Error::io(std::io::Error::from(std::io::ErrorKind::PermissionDenied))));
        assert!(!watch_error_is_fatal(&notify::Error::path_not_found()));
    }

    #[test]
    fn ignore_file_owners() {
        assert_eq!(ignore_file_owner(".gitignore"), Some(""));
        assert_eq!(ignore_file_owner("a/b/.ignore"), Some("a/b"));
        assert_eq!(ignore_file_owner(".git/info/exclude"), Some(""));
        assert_eq!(ignore_file_owner("a/.git/info/exclude"), Some("a"));
        assert_eq!(ignore_file_owner("a.git/info/exclude"), None);
        assert_eq!(ignore_file_owner("a/x.gitignore"), None);
        assert_eq!(ignore_file_owner("a/.gitignore/x"), None);
    }

    #[test]
    fn relative_paths() {
        let roots = [PathBuf::from("/r")];
        assert_eq!(relative(&roots, Path::new("/r/a/b")), Some("a/b".to_string()));
        assert_eq!(relative(&roots, Path::new("/r")), Some(String::new()));
        assert_eq!(relative(&roots, Path::new("/rx/a")), None);
        assert!(at_or_below("a/b", "a") && at_or_below("a", "a") && at_or_below("x", ""));
        assert!(!at_or_below("ab", "a") && !at_or_below("a", "a/b"));
    }
}
