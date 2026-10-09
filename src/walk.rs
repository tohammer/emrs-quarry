//! The file walker: lists the indexed files below a project root.
//!
//! Rules (spec "What is indexed"):
//! - Regular files and symbolic links to files are entries. Directories are not. Symbolic links are never
//!   followed: a symlink to a directory is not descended into and is not listed (directories are not entries); a
//!   dangling symlink (or any symlink whose target cannot be stat'ed) is not a link to a file and is skipped
//!   silently, not counted.
//! - `.gitignore`, `.ignore`, `.git/info/exclude` and the global git excludes apply even outside a git
//!   repository (`require_git(false)`), including such files in directories above the root (as the `ignore`
//!   crate does for `parents(true)`).
//! - Hidden files are included unless `include_hidden` is false.
//! - Directories named `.git`, `.hg`, `.svn`, `.jj` are never walked, at any depth. A plain *file* with such a
//!   name (e.g. the `.git` pointer file of a worktree) is a normal file.
//! - `ignores` are extra gitignore-syntax lines relative to the root. They are compiled into one
//!   `ignore::gitignore::Gitignore` rooted at the root and applied in `filter_entry`. They act as an additional
//!   exclusion layer: an ignored path stays ignored, and a `!negation` in `ignores` only cancels other extra
//!   lines, it cannot re-include a path hidden by a `.gitignore`.
//! - Paths are reported relative to the root with `/` as separator and no leading `./`.
//! - File names that are not valid UTF-8 and walk errors (e.g. unreadable directories) are skipped and counted
//!   in [`WalkStats::skipped`].

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use ignore::{WalkBuilder, WalkState};
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Instant;

/// Version control directories that are never walked.
pub const VCS_DIRS: [&str; 4] = [".git", ".hg", ".svn", ".jj"];

/// Maximum number of paths per batch passed to the callback.
pub const BATCH_SIZE: usize = 1000;

/// Called with the root-relative path of every directory a walk descends into (see [`walk_dirs`]).
pub type OnDir = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Debug, Clone)]
pub struct WalkConfig {
    /// Absolute path of the project root.
    pub root: PathBuf,
    pub include_hidden: bool,
    /// Extra gitignore-syntax lines relative to the root.
    pub ignores: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WalkStats {
    /// Paths sent to the callback.
    pub files: usize,
    /// Non-UTF-8 names and walk errors.
    pub skipped: usize,
    pub millis: u64,
    /// The cancellation predicate fired; the listing is incomplete.
    pub cancelled: bool,
}

fn build_extra(config: &WalkConfig) -> Result<Gitignore, String> {
    let mut b = GitignoreBuilder::new(&config.root);
    for line in &config.ignores {
        b.add_line(None, line).map_err(|e| format!("invalid ignore pattern {line:?}: {e}"))?;
    }
    b.build().map_err(|e| e.to_string())
}

/// Checks that the extra `ignores` of `config` are valid gitignore lines (the error [`walk`] would report).
pub fn check_ignores(config: &WalkConfig) -> Result<(), String> {
    build_extra(config).map(|_| ())
}

/// Root-relative, `/`-separated form of `path`; `None` if it is not below `root` or not valid UTF-8.
fn rel_string(root: &Path, path: &Path) -> Option<String> {
    let rel = path.strip_prefix(root).ok()?;
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

/// The configured walk builder (shared by the parallel walk and the test reference walk).
fn make_builder(config: &WalkConfig, start: &Path, extra: Gitignore, on_dir: Option<OnDir>) -> WalkBuilder {
    let mut b = WalkBuilder::new(start);
    b.hidden(!config.include_hidden)
        .parents(true)
        .ignore(true)
        .git_ignore(true)
        .git_exclude(true)
        .git_global(true)
        .require_git(false)
        .follow_links(false)
        .threads(std::thread::available_parallelism().map_or(1, |n| n.get()));
    let extra = Arc::new(extra);
    let root = config.root.clone();
    // `filter_entry` runs after the `ignore` crate's own rules (hidden, ignore files) and before a directory's
    // contents are read, so `on_dir` sees exactly the directories the walk descends into, before it lists them.
    b.filter_entry(move |entry| {
        if entry.depth() == 0 {
            return true;
        }
        let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
        if is_dir && entry.file_name().to_str().is_some_and(|n| VCS_DIRS.contains(&n)) {
            return false;
        }
        let keep = !extra.matched(entry.path(), is_dir).is_ignore();
        if keep
            && is_dir
            && let Some(on_dir) = &on_dir
            && let Some(rel) = rel_string(&root, entry.path())
        {
            on_dir(&rel);
        }
        keep
    });
    b
}

/// Is this walk entry an index entry (regular file or symlink to a file)?
fn is_file_entry(entry: &ignore::DirEntry) -> bool {
    match entry.file_type() {
        Some(t) if t.is_file() => true,
        Some(t) if t.is_symlink() => std::fs::metadata(entry.path()).is_ok_and(|m| m.is_file()),
        _ => false,
    }
}

struct Batcher<'a> {
    buf: Vec<String>,
    on_batch: &'a (dyn Fn(Vec<String>) + Sync),
    cancelled: &'a AtomicBool,
}

impl Batcher<'_> {
    fn push(&mut self, path: String) {
        self.buf.push(path);
        if self.buf.len() >= BATCH_SIZE {
            self.flush();
        }
    }
    fn flush(&mut self) {
        if !self.buf.is_empty() && !self.cancelled.load(Ordering::Relaxed) {
            (self.on_batch)(std::mem::take(&mut self.buf));
        }
    }
}

impl Drop for Batcher<'_> {
    fn drop(&mut self) {
        self.flush();
    }
}

/// Walk the project and send root-relative paths to `on_batch` in batches of at most [`BATCH_SIZE`] (from several
/// threads; order is not significant). `dir` restricts the walk to a subdirectory (absolute or relative to the
/// root) with the same rules and the same root-relative output; it yields nothing if that directory is itself
/// ignored. When `is_cancelled` returns true the walk stops promptly, pending batches are dropped and
/// `cancelled` is set in the stats.
#[allow(dead_code)] // the service and the watcher call `walk_dirs`; the tests use this form
pub fn walk(
    config: &WalkConfig,
    dir: Option<&Path>,
    is_cancelled: &(dyn Fn() -> bool + Sync),
    on_batch: &(dyn Fn(Vec<String>) + Sync),
) -> Result<WalkStats, String> {
    walk_dirs(config, dir, is_cancelled, on_batch, None)
}

/// [`walk`], also calling `on_dir` (from several threads) with the root-relative path of every directory below
/// the start directory that the walk descends into: not ignored, not a VCS directory, not hidden when
/// `include_hidden` is false, not a symbolic link, valid UTF-8. It is called before the directory's contents
/// are listed. The start directory itself is not reported.
pub fn walk_dirs(
    config: &WalkConfig,
    dir: Option<&Path>,
    is_cancelled: &(dyn Fn() -> bool + Sync),
    on_batch: &(dyn Fn(Vec<String>) + Sync),
    on_dir: Option<OnDir>,
) -> Result<WalkStats, String> {
    let started = Instant::now();
    let extra = build_extra(config)?;
    let start = match dir {
        Some(d) => config.root.join(d),
        None => config.root.clone(),
    };
    let start_rel = rel_string(&config.root, &start)
        .ok_or_else(|| format!("{} is not below the root {}", start.display(), config.root.display()))?;
    let mut stats = WalkStats::default();
    if !start_rel.is_empty() && is_ignored(config, &start_rel, true) {
        stats.millis = started.elapsed().as_millis() as u64;
        return Ok(stats);
    }

    let files = AtomicUsize::new(0);
    let skipped = AtomicUsize::new(0);
    let cancelled = AtomicBool::new(false);
    let root = config.root.as_path();

    make_builder(config, &start, extra, on_dir).build_parallel().run(|| {
        let mut batcher = Batcher { buf: Vec::new(), on_batch, cancelled: &cancelled };
        let (files, skipped, cancelled) = (&files, &skipped, &cancelled);
        Box::new(move |res| {
            if cancelled.load(Ordering::Relaxed) || is_cancelled() {
                cancelled.store(true, Ordering::Relaxed);
                return WalkState::Quit;
            }
            match res {
                Err(_) => {
                    skipped.fetch_add(1, Ordering::Relaxed);
                }
                Ok(entry) => {
                    if entry.depth() > 0 && is_file_entry(&entry) {
                        match rel_string(root, entry.path()) {
                            Some(rel) => {
                                files.fetch_add(1, Ordering::Relaxed);
                                batcher.push(rel);
                            }
                            None => {
                                skipped.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                    }
                }
            }
            WalkState::Continue
        })
    });

    stats.files = files.load(Ordering::Relaxed);
    stats.skipped = skipped.load(Ordering::Relaxed);
    stats.cancelled = cancelled.load(Ordering::Relaxed);
    stats.millis = started.elapsed().as_millis() as u64;
    Ok(stats)
}

/// The per-directory rule sets the `ignore` crate loads for each directory.
#[derive(Default)]
struct DirRules {
    ignore: Option<Gitignore>,
    gitignore: Option<Gitignore>,
    exclude: Option<Gitignore>,
}

fn load_file(dir: &Path, file: &Path) -> Option<Gitignore> {
    if !file.is_file() {
        return None;
    }
    let mut b = GitignoreBuilder::new(dir);
    let _ = b.add(file); // partial errors (bad globs) leave the valid lines, as in the walker
    b.build().ok()
}

fn load_dir_rules(dir: &Path) -> DirRules {
    DirRules {
        ignore: load_file(dir, &dir.join(".ignore")),
        gitignore: load_file(dir, &dir.join(".gitignore")),
        exclude: load_file(dir, &dir.join(".git").join("info").join("exclude")),
    }
}

/// Decide whether a single path (relative to the root, `/`-separated) is excluded, without walking.
///
/// Mirrors the walker: the path is ignored if it or any ancestor directory is excluded by the hidden rule, the
/// VCS directory rule, the extra `ignores`, or the ignore files. Ignore files are read from disk on every call,
/// from each ancestor directory of the path including the directories above the root (like `parents(true)`).
/// Per category the deepest directory with a matching rule wins; categories take precedence in the order
/// `.ignore`, `.gitignore`, `.git/info/exclude`, global excludes, as in the `ignore` crate.
///
/// Known differences from the walker: the global excludes are matched relative to the process's working
/// directory by `Gitignore::global` (the walker also uses the working directory, so they agree unless it changes
/// during the process); rules are read at call time, so a file changed between the walk and the call is seen
/// differently; invalid extra `ignores` are treated as absent (`walk` rejects them). Symlinks and file types are
/// not considered, only the name and `is_dir`.
///
/// [`IgnoreRules`] answers the same question with the rule sets cached across calls.
pub fn is_ignored(config: &WalkConfig, rel_path: &str, is_dir: bool) -> bool {
    IgnoreRules::new(config).is_ignored(rel_path, is_dir)
}

/// [`is_ignored`] with the ignore files of each directory (and the global excludes) read once and cached until
/// [`IgnoreRules::clear`] or [`IgnoreRules::forget_below`]. The watcher keeps one of these, so a burst of
/// file-system events does not read every ancestor's ignore files once per event.
pub struct IgnoreRules {
    root: PathBuf,
    include_hidden: bool,
    extra: Gitignore,
    global: Option<Gitignore>,
    /// Rule sets by absolute directory path.
    dirs: HashMap<PathBuf, DirRules>,
}

impl IgnoreRules {
    pub fn new(config: &WalkConfig) -> Self {
        IgnoreRules {
            root: config.root.clone(),
            include_hidden: config.include_hidden,
            extra: build_extra(config).unwrap_or_else(|_| Gitignore::empty()),
            global: None,
            dirs: HashMap::new(),
        }
    }

    /// Forgets every cached rule set.
    pub fn clear(&mut self) {
        self.dirs.clear();
        self.global = None;
    }

    /// Forgets the cached rule sets of `dir` (absolute) and of the directories below it.
    pub fn forget_below(&mut self, dir: &Path) {
        self.dirs.retain(|d, _| !d.starts_with(dir));
    }

    /// Whether `rel_path` is excluded; see [`is_ignored`].
    pub fn is_ignored(&mut self, rel_path: &str, is_dir: bool) -> bool {
        let comps: Vec<&str> = rel_path.split('/').filter(|c| !c.is_empty() && *c != ".").collect();
        if comps.is_empty() {
            return false;
        }
        let global = self.global.get_or_insert_with(|| Gitignore::global().0);

        // Rule sets of all directories from the filesystem root down to the deepest directory of the path.
        let deepest_dir = self.root.join(comps[..comps.len() - 1].join("/"));
        let mut dirs: Vec<&Path> = deepest_dir.ancestors().collect();
        dirs.reverse(); // shallow -> deep
        for d in &dirs {
            if !self.dirs.contains_key(*d) {
                self.dirs.insert(d.to_path_buf(), load_dir_rules(d));
            }
        }
        let rules: Vec<(&Path, &DirRules)> = dirs.iter().map(|d| (*d, &self.dirs[*d])).collect();

        let mut current = self.root.clone();
        for (i, comp) in comps.iter().enumerate() {
            current.push(comp);
            let last = i + 1 == comps.len();
            let dir = !last || is_dir;
            if (!self.include_hidden && comp.starts_with('.'))
                || (dir && VCS_DIRS.contains(comp))
                || self.extra.matched(&current, dir).is_ignore()
            {
                return true;
            }
            // Only directories that are ancestors of `current` apply to it.
            let applicable = || rules.iter().rev().filter(|(d, _)| current.starts_with(d) && *d != current);
            let first = |pick: fn(&DirRules) -> &Option<Gitignore>| {
                applicable()
                    .map(|(_, r)| pick(r).as_ref().map_or(ignore::Match::None, |g| g.matched(&current, dir)))
                    .find(|m| !m.is_none())
                    .unwrap_or(ignore::Match::None)
            };
            let m = first(|r| &r.ignore)
                .or(first(|r| &r.gitignore))
                .or(first(|r| &r.exclude))
                .or(global.matched(&current, dir));
            if m.is_ignore() {
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::sync::Mutex;
    use tempfile::TempDir;

    fn write(root: &Path, rel: &str, content: &str) {
        let p = root.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, content).unwrap();
    }

    fn cfg(root: &Path, include_hidden: bool, ignores: &[&str]) -> WalkConfig {
        WalkConfig {
            root: root.to_path_buf(),
            include_hidden,
            ignores: ignores.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn run(config: &WalkConfig, dir: Option<&Path>) -> (BTreeSet<String>, WalkStats, Vec<usize>) {
        let out = Mutex::new((BTreeSet::new(), Vec::new()));
        let stats = walk(config, dir, &|| false, &|batch| {
            let mut g = out.lock().unwrap();
            g.1.push(batch.len());
            g.0.extend(batch);
        })
        .unwrap();
        let (set, sizes) = out.into_inner().unwrap();
        (set, stats, sizes)
    }

    fn paths(config: &WalkConfig) -> BTreeSet<String> {
        run(config, None).0
    }

    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    /// Single-threaded reference walk with the same builder.
    fn reference(config: &WalkConfig) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        for res in make_builder(config, &config.root, build_extra(config).unwrap(), None).build() {
            let e = res.unwrap();
            if e.depth() > 0 && is_file_entry(&e) {
                out.insert(rel_string(&config.root, e.path()).unwrap());
            }
        }
        out
    }

    #[test]
    fn matches_single_threaded_reference() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, ".gitignore", "*.log\n/build/\n");
        for a in 0..8 {
            write(r, &format!("d{a}/.gitignore"), "gen_*\n!keep.log\n");
            for b in 0..5 {
                for f in 0..10 {
                    write(r, &format!("d{a}/s{b}/f{f}.rs"), "x");
                    write(r, &format!("d{a}/s{b}/gen_{f}.rs"), "x");
                    write(r, &format!("d{a}/s{b}/f{f}.log"), "x");
                }
                write(r, &format!("d{a}/s{b}/keep.log"), "x");
                write(r, &format!("d{a}/s{b}/.hid{b}"), "x");
            }
        }
        write(r, "build/out.o", "x");
        let c = cfg(r, true, &["s3/", "*.tmp"]);
        let got = paths(&c);
        assert!(got.len() > 300, "{}", got.len());
        assert_eq!(got, reference(&c));
        let c = cfg(r, false, &[]);
        assert_eq!(paths(&c), reference(&c));
        assert!(!paths(&c).iter().any(|p| p.contains(".hid")));
    }

    #[test]
    fn gitignore_levels_and_negation() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, ".gitignore", "*.log\nout/\n");
        write(r, "a/.gitignore", "!keep.log\nsecret.txt\n");
        write(r, "a/keep.log", "");
        write(r, "a/drop.log", "");
        write(r, "a/secret.txt", "");
        write(r, "a/b/secret.txt", "");
        write(r, "b/secret.txt", "");
        write(r, "out/x", "");
        write(r, "a/out/x", "");
        assert_eq!(paths(&cfg(r, true, &[])), set(&[".gitignore", "a/.gitignore", "a/keep.log", "b/secret.txt"]));
    }

    #[test]
    fn dot_ignore_and_git_info_exclude() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, ".ignore", "zz_ignored_by_dot_ignore\n");
        write(r, ".git/info/exclude", "zz_excluded\n");
        write(r, "zz_ignored_by_dot_ignore", "");
        write(r, "sub/zz_ignored_by_dot_ignore", "");
        write(r, "sub/zz_excluded", "");
        write(r, "zz_excluded", "");
        write(r, "plain", "");
        // No real repository: the exclude file is honoured because a `.git` entry exists.
        assert_eq!(paths(&cfg(r, true, &[])), set(&[".ignore", "plain"]));
    }

    #[test]
    fn extra_ignores() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, "a.min.js", "");
        write(r, "src/b.min.js", "");
        write(r, "src/b.js", "");
        write(r, "vendor/x.js", "");
        write(r, "src/vendor/y.js", "");
        let got = paths(&cfg(r, true, &["*.min.js", "/vendor/", "# comment", ""]));
        assert_eq!(got, set(&["src/b.js", "src/vendor/y.js"]));
        assert!(walk(&cfg(r, true, &["[z-a]"]), None, &|| false, &|_| {}).is_err());
    }

    #[test]
    fn hidden_on_and_off() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, ".env", "");
        write(r, ".config/app.toml", "");
        write(r, "src/.hidden", "");
        write(r, "src/main.rs", "");
        assert_eq!(paths(&cfg(r, true, &[])), set(&[".env", ".config/app.toml", "src/.hidden", "src/main.rs"]));
        assert_eq!(paths(&cfg(r, false, &[])), set(&["src/main.rs"]));
    }

    #[test]
    fn vcs_dirs_excluded_at_depth() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        for v in VCS_DIRS {
            write(r, &format!("{v}/x"), "");
            write(r, &format!("a/b/{v}/x"), "");
        }
        write(r, "a/b/ok", "");
        assert_eq!(paths(&cfg(r, true, &[])), set(&["a/b/ok"]));
    }

    #[test]
    fn relative_slash_paths() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, "top", "");
        write(r, "a/b/c.txt", "");
        let (got, stats, _) = run(&cfg(r, true, &[]), None);
        assert_eq!(got, set(&["top", "a/b/c.txt"]));
        assert_eq!(stats.files, 2);
        assert_eq!(stats.skipped, 0);
        assert!(!stats.cancelled);
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_not_followed() {
        use std::os::unix::fs::symlink;
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, "real/f.txt", "");
        write(r, "file.txt", "");
        symlink("file.txt", r.join("link_to_file")).unwrap();
        symlink("real", r.join("link_to_dir")).unwrap();
        symlink("missing", r.join("dangling")).unwrap();
        // loop
        symlink(".", r.join("real/loop")).unwrap();
        let (got, stats, _) = run(&cfg(r, true, &[]), None);
        assert_eq!(got, set(&["real/f.txt", "file.txt", "link_to_file"]));
        assert_eq!(stats.skipped, 0);
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_names_skipped_and_counted() {
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, "good", "");
        std::fs::write(r.join(OsStr::from_bytes(b"bad_\xff\xfe")), "").unwrap();
        std::fs::create_dir(r.join(OsStr::from_bytes(b"dir_\xff"))).unwrap();
        std::fs::write(r.join(OsStr::from_bytes(b"dir_\xff")).join("inner"), "").unwrap();
        let (got, stats, _) = run(&cfg(r, true, &[]), None);
        assert_eq!(got, set(&["good"]));
        assert_eq!(stats.skipped, 2); // the bad file and the inner file below the bad dir
        assert_eq!(stats.files, 1);
    }

    #[cfg(unix)]
    #[test]
    fn unreadable_directory_counted() {
        use std::os::unix::fs::PermissionsExt;
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, "ok", "");
        write(r, "locked/x", "");
        let locked = r.join("locked");
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
        let readable = std::fs::read_dir(&locked).is_ok(); // running as root
        let (got, stats, _) = run(&cfg(r, true, &[]), None);
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();
        if !readable {
            assert_eq!(got, set(&["ok"]));
            assert_eq!(stats.skipped, 1);
        }
    }

    #[test]
    fn cancelled_from_the_start() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        for i in 0..200 {
            write(r, &format!("d{}/f{i}", i % 10), "");
        }
        let n = AtomicUsize::new(0);
        let stats = walk(&cfg(r, true, &[]), None, &|| true, &|b| {
            n.fetch_add(b.len(), Ordering::Relaxed);
        })
        .unwrap();
        assert!(stats.cancelled);
        assert_eq!(n.load(Ordering::Relaxed), 0);
        assert_eq!(stats.files, 0);
    }

    #[test]
    fn cancelled_midway_stops() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        for i in 0..3000 {
            write(r, &format!("d{}/f{i}", i % 30), "");
        }
        let calls = AtomicUsize::new(0);
        let seen = AtomicUsize::new(0);
        let stats = walk(&cfg(r, true, &[]), None, &|| calls.fetch_add(1, Ordering::Relaxed) >= 500, &|b| {
            seen.fetch_add(b.len(), Ordering::Relaxed);
        })
        .unwrap();
        assert!(stats.cancelled);
        assert!(stats.files < 3000, "{}", stats.files);
    }

    #[test]
    fn batches_at_most_1000() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        for i in 0..2300 {
            write(r, &format!("d{}/f{i}", i % 7), "");
        }
        let (got, stats, sizes) = run(&cfg(r, true, &[]), None);
        assert_eq!(got.len(), 2300);
        assert_eq!(stats.files, 2300);
        assert!(sizes.iter().all(|&s| (1..=BATCH_SIZE).contains(&s)), "{sizes:?}");
        assert_eq!(sizes.iter().sum::<usize>(), 2300);
    }

    #[test]
    fn subdirectory_walk() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, ".gitignore", "*.log\n");
        write(r, "a/.gitignore", "gen\n");
        write(r, "a/b/x.rs", "");
        write(r, "a/b/x.log", "");
        write(r, "a/b/gen", "");
        write(r, "a/b/skip.dat", "");
        write(r, "a/other", "");
        write(r, "z", "");
        let c = cfg(r, true, &["*.dat"]);
        let want = set(&["a/b/x.rs"]);
        assert_eq!(run(&c, Some(Path::new("a/b"))).0, want);
        assert_eq!(run(&c, Some(&r.join("a/b"))).0, want);
        assert_eq!(run(&c, Some(Path::new("a"))).0, set(&["a/.gitignore", "a/b/x.rs", "a/other"]));
        // outside the root is an error; an ignored directory yields nothing
        assert!(walk(&c, Some(Path::new("../elsewhere")), &|| false, &|_| {}).is_err());
        write(r, "a/ign/q", "");
        let c2 = cfg(r, true, &["ign/"]);
        assert!(run(&c2, Some(Path::new("a/ign"))).0.is_empty());
    }

    #[test]
    fn is_ignored_agrees_with_walker() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, ".gitignore", "*.log\n/build/\nzz_root_only\n");
        write(r, ".ignore", "zz_dot_ignore\n");
        write(r, ".git/info/exclude", "zz_excluded\n");
        write(r, "a/.gitignore", "!keep.log\nzz_a\n");
        write(r, "a/b/.ignore", "!zz_dot_ignore\n");
        let files = [
            "a/keep.log",
            "a/drop.log",
            "a/zz_a",
            "a/b/zz_a",
            "zz_a",
            "build/out.o",
            "a/build/out.o",
            "zz_root_only",
            "a/zz_root_only",
            "zz_dot_ignore",
            "a/zz_dot_ignore",
            "a/b/zz_dot_ignore",
            "zz_excluded",
            "a/b/zz_excluded",
            "a/b/.hidden",
            ".hid/f",
            "src/main.rs",
            "src/min.js",
            "src/vendor/v.js",
            "x/.git/config",
            "x/.svn/entries",
            "x/y.tmp",
            "plain",
        ];
        for f in files {
            write(r, f, "");
        }
        for hidden in [true, false] {
            let c = cfg(r, hidden, &["*.js", "!min.js", "vendor/", "*.tmp"]);
            let walked = paths(&c);
            assert_eq!(walked, reference(&c));
            let mut dirs = BTreeSet::new();
            for f in files {
                let mut p = f;
                while let Some((parent, _)) = p.rsplit_once('/') {
                    dirs.insert(parent.to_string());
                    p = parent;
                }
                assert_eq!(!is_ignored(&c, f, false), walked.contains(f), "file {f} hidden={hidden}");
            }
            for d in &dirs {
                // a directory is ignored iff no file below it was walked, given each has a file
                let any = walked.iter().any(|w| w.starts_with(&format!("{d}/")));
                if is_ignored(&c, d, true) {
                    assert!(!any, "dir {d} ignored but has walked files");
                }
            }
            assert!(is_ignored(&c, "x/.git", true));
            assert!(is_ignored(&c, "build", true));
            assert!(!is_ignored(&c, "a", true));
            assert!(!is_ignored(&c, "", true));
        }
    }

    #[test]
    fn ignore_rules_cache() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, ".gitignore", "*.zz1\n");
        write(r, "a/.gitignore", "gen\n");
        let c = cfg(r, true, &["*.tmp"]);
        let mut rules = IgnoreRules::new(&c);
        for (p, d) in [("x.zz1", false), ("a/gen", false), ("a/b/gen", true), ("a/x.tmp", false), ("a/ok", false)] {
            assert_eq!(rules.is_ignored(p, d), is_ignored(&c, p, d), "{p}");
        }
        // Cached: a changed ignore file is not seen until the cache is cleared.
        write(r, ".gitignore", "*.zz2\n");
        assert!(rules.is_ignored("x.zz1", false));
        assert!(!rules.is_ignored("x.zz2", false));
        rules.clear();
        assert!(!rules.is_ignored("x.zz1", false));
        assert!(rules.is_ignored("x.zz2", false));
        // Forgetting a directory reloads it and the directories below it only.
        write(r, "a/.gitignore", "other\n");
        write(r, ".gitignore", "*.zz3\n");
        rules.forget_below(&r.join("a"));
        assert!(!rules.is_ignored("a/gen", false));
        assert!(rules.is_ignored("a/other", false));
        assert!(rules.is_ignored("a/y.zz2", false)); // the root's rules are still the cached ones
    }

    #[test]
    fn walk_dirs_reports_descended_directories() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, ".gitignore", "build/\n");
        for f in ["a/b/f", "a/c/f", "build/x/f", ".hid/f", ".git/f", "skip/f", "top"] {
            write(r, f, "");
        }
        let run_dirs = |c: &WalkConfig, dir: Option<&Path>| {
            let dirs = Arc::new(Mutex::new(BTreeSet::new()));
            let sink = dirs.clone();
            let on_dir: OnDir = Arc::new(move |d: &str| {
                sink.lock().unwrap().insert(d.to_string());
            });
            walk_dirs(c, dir, &|| false, &|_| {}, Some(on_dir)).unwrap();
            dirs.lock().unwrap().clone()
        };
        assert_eq!(run_dirs(&cfg(r, true, &["skip/"]), None), set(&["a", "a/b", "a/c", ".hid"]));
        assert_eq!(run_dirs(&cfg(r, false, &[]), None), set(&["a", "a/b", "a/c", "skip"]));
        assert_eq!(run_dirs(&cfg(r, true, &[]), Some(Path::new("a"))), set(&["a/b", "a/c"]));
    }

    #[test]
    fn is_ignored_basic() {
        let t = TempDir::new().unwrap();
        let r = t.path();
        write(r, ".gitignore", "zz_target/\n");
        let c = cfg(r, false, &["*.bak"]);
        assert!(is_ignored(&c, "zz_target", true));
        assert!(!is_ignored(&c, "zz_target", false));
        assert!(is_ignored(&c, "zz_target/deep/file.rs", false));
        assert!(is_ignored(&c, "a/b.bak", false));
        assert!(is_ignored(&c, ".hidden", false));
        assert!(is_ignored(&c, "a/.git", true));
        assert!(!is_ignored(&c, "a/b.rs", false));
        assert!(!is_ignored(&cfg(r, true, &[]), ".hidden", false));
    }
}
