//! One search of the grep service: walk a directory, search each file for the primary filter, collect the kept
//! lines with their match positions, and hand the results to an [`Output`] (spec `2026-10-10-grep.md`, "The
//! service"). The engine is ripgrep's library crates (ADR 0011); this file has no emrs types in it.
//!
//! **Threads.** [`Search::run`] blocks its caller while the `ignore` crate's parallel walker runs one thread per
//! core. Each walker thread has its own `grep_searcher::Searcher` and its own clone of the [`Filters`], opens the
//! file entries it is given and searches them. There is no other thread and no queue between the walker threads
//! and the output.
//!
//! **What is searched.** The walker of `src/walk.rs` with an entry filter built from the path filters: a
//! directory is entered unless [`Filters::skip_dir`] (literal exclude path filters only), a file is kept when
//! [`Filters::keep_file`]. Only regular
//! files are opened. Symbolic links are left out altogether, also those to files, as `rg` does (the index lists
//! links to files): a file reached through a link would be found twice, and an edit of the results would
//! reach it by two paths. A link is not counted as searched or skipped. A file in which the searcher meets a NUL byte is binary and
//! gives no lines, also not those found before that byte. (The searcher does not look further than it reads: a
//! file that fills the line cap before its NUL byte is read counts as text.) A byte order mark selects the
//! encoding, otherwise the bytes are taken as UTF-8. A file that fails while it is read gives no lines either
//! and is counted as skipped.
//!
//! **Lines.** For every line the primary filter matches, the terminator (`\n` and a `\r` before it) is removed
//! and [`Filters::keep_line`] decides on the whole line. The text that is sent is the line as UTF-8, converted
//! lossily when it is not valid, and cut after `max_columns` characters; either sets `inexact`. The matches are
//! found on the whole line ([`Filters::line_spans`]) and reported as positions in the text that is sent: a
//! match that crosses the cut ends at the cut, one beyond it is not reported.
//!
//! **Cap.** A counter shared by all threads holds the lines of the finished files. A thread collects the lines of
//! its file privately and stops reading the file when they and the counter together reach `max_lines`. When
//! the file is done, it adds to the counter what still fits and keeps only that many of its lines, the first
//! ones. So the counter never exceeds `max_lines`, and every counted line is delivered. The thread whose lines
//! bring the counter to `max_lines` sets `truncated` and the stop flag; every thread returns `WalkState::Quit`
//! at its next entry and stops reading its current file at the next matching line. `truncated` therefore also
//! is true when the tree holds exactly `max_lines` matching lines.
//!
//! **Order.** Finished file items go into a buffer behind a mutex until `sort_budget` has passed since the
//! search started. The first thread that notices the deadline (at a walk entry or when it has an item) sorts
//! the buffer by path and sends it; from then on every thread sends its items itself, in the order they are
//! found. If the walk ends while the buffer still exists, it is sent sorted and the summary says `sorted`.
//! A thread inside a large file does not notice the deadline until that file is done.
//!
//! **Backpressure.** All sends happen while holding the buffer's mutex, and [`Output::send`] may block. While
//! the consumer is slow, one thread waits in `send` and each other thread that has finished a file with matches
//! waits for the mutex, holding that one item; threads without matches go on. Nothing else is queued.
//!
//! **Cancellation.** [`Output::is_cancelled`] is asked at every walk entry, and a `send` that reports the
//! output closed has the same effect: the stop flag is set, the walk quits, and no summary is sent.

use crate::grep::filter::{Filters, Span};
use crate::walk::{self, EntryFilter, WalkOptions};
use grep_matcher::LineTerminator;
use grep_searcher::{BinaryDetection, Searcher, SearcherBuilder, Sink, SinkFinish, SinkMatch};
use ignore::{WalkParallel, WalkState};
use serde::Serialize;
use std::borrow::Cow;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// What one search is asked to do; the checked form of the `(:search …)` request.
pub struct Config {
    /// Absolute path of an existing directory.
    pub dir: PathBuf,
    pub filters: Filters,
    /// Restricts the files to these types; `None` means all files.
    pub types: Option<ignore::types::Types>,
    /// false: `.gitignore`, `.ignore` and the git exclude files are not applied.
    pub use_ignore_files: bool,
    pub include_hidden: bool,
    /// Extra gitignore-syntax lines relative to `dir`.
    pub ignores: Vec<String>,
    /// The search stops when this many lines have been collected.
    pub max_lines: usize,
    /// Longer lines are cut after this many characters.
    pub max_columns: usize,
    /// How long file items are collected for sorting, counted from `started`.
    pub sort_budget: Duration,
    /// When the request arrived; `millis` in the summary counts from here.
    pub started: Instant,
}

/// One matching line of a file: `(:n 12 :text "let x = 1;" :spans ((4 5)) :secondary nil :inexact nil)`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Line {
    /// Line number, counted from 1.
    pub n: u64,
    /// The line without its terminator, possibly cut (see `inexact`).
    pub text: String,
    /// Matches of the primary filter: `(START END)` character offsets into `text`, `END` exclusive, ascending.
    pub spans: Vec<(u32, u32)>,
    /// Matches of the other include line filters outside the primary matches, in the same form.
    pub secondary: Vec<(u32, u32)>,
    /// `text` is not exactly the file's line: it was cut at `max_columns` characters or held invalid UTF-8.
    pub inexact: bool,
}

/// A file with kept lines; sent as [`Item::File`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileItem {
    pub path: String,
    pub path_spans: Vec<(u32, u32)>,
    pub mtime: Option<i64>,
    pub lines: Vec<Line>,
}

/// The counts of a finished search; sent as [`Item::Summary`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    pub files_searched: usize,
    pub files_matched: usize,
    pub lines: usize,
    pub truncated: bool,
    pub sorted: bool,
    pub millis: u64,
    pub skipped: usize,
}

/// A stream item. The Lisp shapes are in the module docs of `src/grep/service.rs`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum Item {
    /// A file and its kept lines, in ascending line number. There is no item for a file without kept lines.
    File {
        /// Relative to the search directory, `/`-separated.
        path: String,
        /// The parts of `path` matched by include path filters ([`Filters::path_spans`]).
        path_spans: Vec<(u32, u32)>,
        /// Modification time in milliseconds since the Unix epoch, rounded down, read when the file was opened
        /// for the search; nil if the file system did not tell.
        mtime: Option<i64>,
        lines: Vec<Line>,
    },
    /// The last item of a search that was not cancelled.
    Summary {
        /// Files that were opened and read without an error: to their end, to the NUL byte that marks them as
        /// binary, or to the line where the cap stopped the search.
        files_searched: usize,
        /// File items sent.
        files_matched: usize,
        /// Lines sent, over all file items.
        lines: usize,
        /// The line cap was reached and the search stopped there.
        truncated: bool,
        /// All file items were sent in order of their paths (byte order).
        sorted: bool,
        /// Time from the arrival of the request to this item.
        millis: u64,
        /// Files that could not be opened or read, walk errors (such as unreadable directories) and files
        /// whose path is not valid UTF-8.
        skipped: usize,
    },
}

impl From<FileItem> for Item {
    fn from(file: FileItem) -> Item {
        let FileItem { path, path_spans, mtime, lines } = file;
        Item::File { path, path_spans, mtime, lines }
    }
}

impl From<Summary> for Item {
    fn from(summary: Summary) -> Item {
        let Summary { files_searched, files_matched, lines, truncated, sorted, millis, skipped } = summary;
        Item::Summary { files_searched, files_matched, lines, truncated, sorted, millis, skipped }
    }
}

/// Where a search sends its items. Called from several threads.
pub trait Output: Sync {
    /// Hands over an item; may block while the consumer is slow. False when nobody takes items any more.
    fn send(&self, item: Item) -> bool;
    /// The search is no longer wanted.
    fn is_cancelled(&self) -> bool;
    /// The clock the sort budget is measured with. Tests replace it to decide when the budget is used up.
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// A search that is ready to run: everything that can be wrong with the request has been checked.
pub struct Search {
    config: Config,
    walker: WalkParallel,
}

impl Search {
    /// Errors: an invalid line in `config.ignores`.
    pub fn new(mut config: Config) -> Result<Search, String> {
        let options = WalkOptions {
            root: config.dir.clone(),
            include_hidden: config.include_hidden,
            ignores: std::mem::take(&mut config.ignores),
            use_ignore_files: config.use_ignore_files,
            types: config.types.take(),
        };
        let filters = config.filters.clone();
        let filter: EntryFilter =
            Arc::new(move |rel, is_dir| if is_dir { !filters.skip_dir(rel) } else { filters.keep_file(rel) });
        let walker = walk::walker(&options, Some(filter))?;
        Ok(Search { config, walker })
    }

    /// Runs the search on the calling thread and the walker's threads and returns when it is over. Sends the
    /// file items and then the summary to `out`. Returns false, without a summary, when the search was
    /// cancelled.
    pub fn run(self, out: &dyn Output) -> bool {
        let Search { config, walker } = self;
        let shared = Shared {
            dir: &config.dir,
            out,
            max_lines: config.max_lines,
            max_columns: config.max_columns,
            deadline: config.started.checked_add(config.sort_budget),
            lines: AtomicUsize::new(0),
            files_searched: AtomicUsize::new(0),
            files_matched: AtomicUsize::new(0),
            skipped: AtomicUsize::new(0),
            stop: AtomicBool::new(false),
            truncated: AtomicBool::new(false),
            cancelled: AtomicBool::new(false),
            streaming: AtomicBool::new(false),
            pending: Mutex::new(Some(Vec::new())),
        };
        walker.run(|| {
            let mut worker = Worker {
                shared: &shared,
                // Each thread has its own matchers: a shared regex makes the threads contend for its cache.
                filters: config.filters.clone(),
                // The terminator must be the line matchers' (`filter.rs`), or the searcher refuses the matcher.
                // Lines still end at `\n` only; a `\r` before it belongs to the terminator.
                searcher: SearcherBuilder::new()
                    .binary_detection(BinaryDetection::quit(0))
                    .line_terminator(LineTerminator::crlf())
                    .line_number(true)
                    .build(),
            };
            Box::new(move |entry| worker.visit(entry))
        });
        if out.is_cancelled() {
            shared.cancel();
        }
        // The walk ended within the budget, or nobody looked at the clock after it: everything goes out sorted.
        let sorted = shared.flush(&mut shared.pending());
        if shared.cancelled.load(Ordering::Relaxed) {
            #[cfg(test)]
            hook::record(&config.dir, hook::Ended::Cancelled(shared.files_searched.load(Ordering::Relaxed)));
            return false;
        }
        let summary = Summary {
            files_searched: shared.files_searched.load(Ordering::Relaxed),
            files_matched: shared.files_matched.load(Ordering::Relaxed),
            lines: shared.lines.load(Ordering::Relaxed),
            truncated: shared.truncated.load(Ordering::Relaxed),
            sorted,
            millis: config.started.elapsed().as_millis() as u64,
            skipped: shared.skipped.load(Ordering::Relaxed),
        };
        #[cfg(test)]
        hook::record(&config.dir, hook::Ended::Finished(summary.clone()));
        out.send(summary.into())
    }
}

/// What the threads of one search share.
struct Shared<'a> {
    dir: &'a Path,
    out: &'a dyn Output,
    max_lines: usize,
    max_columns: usize,
    /// Until then file items are collected in `pending`.
    /// `None`: never (the budget is beyond what the clock can express).
    deadline: Option<Instant>,
    /// Lines of the finished files; never more than `max_lines`.
    lines: AtomicUsize,
    files_searched: AtomicUsize,
    /// File items sent.
    files_matched: AtomicUsize,
    skipped: AtomicUsize,
    /// The walk is to end: the cap was reached, the search was cancelled, or a thread panicked.
    stop: AtomicBool,
    truncated: AtomicBool,
    cancelled: AtomicBool,
    /// `pending` is `None`; saves the lock at every walk entry.
    streaming: AtomicBool,
    /// The file items collected for sorting; `None` once they were sent. Every send happens under this lock.
    pending: Mutex<Option<Vec<FileItem>>>,
}

impl Shared<'_> {
    fn pending(&self) -> std::sync::MutexGuard<'_, Option<Vec<FileItem>>> {
        // A panic of another thread ends the search anyway; the buffer is still a list of whole items.
        self.pending.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
        self.stop.store(true, Ordering::Relaxed);
    }

    /// Whether a file that has `collected` lines may collect another one.
    fn has_room(&self, collected: usize) -> bool {
        self.lines.load(Ordering::Relaxed).saturating_add(collected) < self.max_lines
    }

    /// Counts up to `wanted` lines of a finished file under the cap and returns how many of them fit. Ends the
    /// search when the cap is reached.
    fn reserve(&self, wanted: usize) -> usize {
        let max = self.max_lines;
        let before = self
            .lines
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |lines| Some(lines.saturating_add(wanted).min(max)))
            .unwrap_or(max);
        let granted = wanted.min(max.saturating_sub(before));
        if before + granted >= max {
            self.truncated.store(true, Ordering::Relaxed);
            self.stop.store(true, Ordering::Relaxed);
        }
        granted
    }

    /// Sends one file item; the caller holds the lock of `pending`.
    fn send(&self, item: FileItem) -> bool {
        if self.cancelled.load(Ordering::Relaxed) {
            return false;
        }
        if !self.out.send(item.into()) {
            self.cancel();
            return false;
        }
        self.files_matched.fetch_add(1, Ordering::Relaxed);
        true
    }

    /// Sends the collected items sorted by path, if they were not sent before; returns whether it did.
    fn flush(&self, pending: &mut Option<Vec<FileItem>>) -> bool {
        let Some(mut items) = pending.take() else { return false };
        self.streaming.store(true, Ordering::Relaxed);
        items.sort_unstable_by(|a, b| a.path.cmp(&b.path));
        for item in items {
            if !self.send(item) {
                break;
            }
        }
        true
    }

    /// Whether the sort budget is used up.
    fn due(&self) -> bool {
        self.deadline.is_some_and(|deadline| self.out.now() >= deadline)
    }

    /// Called at every walk entry: sends the collected items once the sort budget is used up.
    fn flush_if_due(&self) {
        if !self.streaming.load(Ordering::Relaxed) && self.due() {
            self.flush(&mut self.pending());
        }
    }

    /// Takes a finished file item: collects it while the sort budget lasts, sends it afterwards.
    fn deliver(&self, item: FileItem) {
        let mut pending = self.pending();
        match pending.as_mut() {
            Some(items) => {
                items.push(item);
                if self.due() {
                    self.flush(&mut pending);
                }
            }
            None => {
                self.send(item);
            }
        }
    }
}

/// The state of one walker thread.
struct Worker<'a> {
    shared: &'a Shared<'a>,
    filters: Filters,
    searcher: Searcher,
}

impl Worker<'_> {
    fn visit(&mut self, entry: Result<ignore::DirEntry, ignore::Error>) -> WalkState {
        let shared = self.shared;
        if shared.stop.load(Ordering::Relaxed) {
            return WalkState::Quit;
        }
        if shared.out.is_cancelled() {
            shared.cancel();
            return WalkState::Quit;
        }
        shared.flush_if_due();
        match entry {
            Err(_) => {
                shared.skipped.fetch_add(1, Ordering::Relaxed);
            }
            // Regular files only: no directories, no symbolic links (not `walk::is_file_entry`, the index's rule).
            Ok(entry) if entry.depth() > 0 && entry.file_type().is_some_and(|t| t.is_file()) => {
                match walk::rel_string(shared.dir, entry.path()) {
                    Some(rel) => self.search(entry.path(), rel),
                    None => {
                        shared.skipped.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
            Ok(_) => {}
        }
        if shared.stop.load(Ordering::Relaxed) { WalkState::Quit } else { WalkState::Continue }
    }

    fn search(&mut self, path: &Path, rel: String) {
        let shared = self.shared;
        let Ok(file) = File::open(path) else {
            shared.skipped.fetch_add(1, Ordering::Relaxed);
            return;
        };
        // Before the content is read: a change during the search then shows as a newer time on disk.
        let mtime = file.metadata().and_then(|meta| meta.modified()).ok().map(unix_millis);
        let mut sink = LineSink { shared, filters: &self.filters, lines: Vec::new(), binary: false, full: false };
        if self.searcher.search_file(self.filters.primary(), &file, &mut sink).is_err() {
            shared.skipped.fetch_add(1, Ordering::Relaxed);
            return;
        }
        shared.files_searched.fetch_add(1, Ordering::Relaxed);
        let LineSink { mut lines, binary, full, .. } = sink;
        if binary || (lines.is_empty() && !full) {
            return;
        }
        lines.truncate(shared.reserve(lines.len()));
        if lines.is_empty() {
            return;
        }
        let path_spans = self.filters.path_spans(&rel);
        shared.deliver(FileItem { path: rel, path_spans, mtime, lines });
    }
}

impl Drop for Worker<'_> {
    fn drop(&mut self) {
        // A panic in one walker thread reaches the caller of `run` only after the others have ended.
        if std::thread::panicking() {
            self.shared.stop.store(true, Ordering::Relaxed);
        }
    }
}

/// Collects the kept lines of one file.
struct LineSink<'a> {
    shared: &'a Shared<'a>,
    filters: &'a Filters,
    lines: Vec<Line>,
    /// The searcher met a NUL byte.
    binary: bool,
    /// A kept line was left out because of the cap.
    full: bool,
}

impl Sink for LineSink<'_> {
    type Error = std::io::Error;

    fn matched(&mut self, _: &Searcher, found: &SinkMatch<'_>) -> Result<bool, std::io::Error> {
        let shared = self.shared;
        if shared.stop.load(Ordering::Relaxed) {
            return Ok(false);
        }
        let bytes = strip_terminator(found.bytes());
        if !self.filters.keep_line(bytes) {
            return Ok(true);
        }
        if !shared.has_room(self.lines.len()) {
            self.full = true;
            return Ok(false);
        }
        let (whole, shown, inexact) = line_text(bytes, shared.max_columns);
        let (mut spans, mut secondary) = (Vec::new(), Vec::new());
        // On the whole line, so that a pattern sees what follows the cut; reported for the part that is sent.
        for Span { start, end, secondary: other } in self.filters.line_spans(&whole, shown) {
            if other { &mut secondary } else { &mut spans }.push((start, end));
        }
        let text = whole[..shown].to_string();
        self.lines.push(Line { n: found.line_number().unwrap_or(0), text, spans, secondary, inexact });
        Ok(shared.has_room(self.lines.len()))
    }

    fn binary_data(&mut self, _: &Searcher, _: u64) -> Result<bool, std::io::Error> {
        self.binary = true;
        Ok(false)
    }

    fn finish(&mut self, _: &Searcher, finish: &SinkFinish) -> Result<(), std::io::Error> {
        self.binary |= finish.binary_byte_offset().is_some();
        Ok(())
    }
}

/// `line` without its terminator: a final `\n`, and a `\r` before that `\n`. A `\r` at the end of a file's last
/// line, with no `\n` after it, is part of the line.
fn strip_terminator(line: &[u8]) -> &[u8] {
    match line.strip_suffix(b"\n") {
        Some(line) => line.strip_suffix(b"\r").unwrap_or(line),
        None => line,
    }
}

/// The text of a line: the whole line as UTF-8 (invalid bytes replaced), how many bytes of it are sent (the
/// first `max_columns` characters), and whether what is sent differs from the file's line.
fn line_text(line: &[u8], max_columns: usize) -> (Cow<'_, str>, usize, bool) {
    let (whole, replaced) = match std::str::from_utf8(line) {
        Ok(text) => (Cow::Borrowed(text), false),
        Err(_) => (String::from_utf8_lossy(line), true),
    };
    // A text of at most `max_columns` bytes has at most that many characters.
    let cut = if whole.len() > max_columns { whole.char_indices().nth(max_columns).map(|(at, _)| at) } else { None };
    let shown = cut.unwrap_or(whole.len());
    (whole, shown, replaced || cut.is_some())
}

/// Milliseconds since the Unix epoch, rounded down (also for times before it).
fn unix_millis(time: SystemTime) -> i64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(since) => since.as_millis() as i64,
        Err(before) => {
            let before = before.duration();
            let millis = before.as_millis() as i64;
            if before.subsec_nanos() % 1_000_000 == 0 { -millis } else { -millis - 1 }
        }
    }
}

/// Lets tests see how the search of a directory ended, which a cancelled stream does not tell them.
#[cfg(test)]
pub(crate) mod hook {
    use super::Summary;
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};
    use std::sync::{Condvar, LazyLock, Mutex};
    use std::time::{Duration, Instant};

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum Ended {
        Finished(Summary),
        /// With the number of files searched until then.
        Cancelled(usize),
    }

    static ENDED: LazyLock<(Mutex<HashMap<PathBuf, Vec<Ended>>>, Condvar)> = LazyLock::new(Default::default);

    pub(super) fn record(dir: &Path, ended: Ended) {
        let (map, cv) = &*ENDED;
        map.lock().unwrap_or_else(|e| e.into_inner()).entry(dir.to_path_buf()).or_default().push(ended);
        cv.notify_all();
    }

    /// Waits until `count` searches of `dir` have ended and returns how, in the order they ended.
    pub(crate) fn wait(dir: &Path, count: usize, limit: Duration) -> Vec<Ended> {
        let (map, cv) = &*ENDED;
        let deadline = Instant::now() + limit;
        let mut map = map.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            let ended = map.get(dir).cloned().unwrap_or_default();
            let now = Instant::now();
            if ended.len() >= count || now >= deadline {
                return ended;
            }
            map = cv.wait_timeout(map, deadline - now).unwrap_or_else(|e| e.into_inner()).0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::grep::filter::{Case, FilterSpec};
    use crate::grep::service::testing::*;
    use tempfile::TempDir;

    #[test]
    fn terminators_are_stripped() {
        assert_eq!(strip_terminator(b"abc\n"), b"abc");
        assert_eq!(strip_terminator(b"abc\r\n"), b"abc");
        assert_eq!(strip_terminator(b"abc"), b"abc", "the last line of a file may have none");
        assert_eq!(strip_terminator(b"a\rb\r\r\n"), b"a\rb\r", "only one");
        assert_eq!(strip_terminator(b"\n"), b"");
        assert_eq!(strip_terminator(b"abc\r"), b"abc\r", "a carriage return alone ends no line");
        assert_eq!(strip_terminator(b"\r"), b"\r");
        assert_eq!(strip_terminator(b""), b"");
    }

    #[test]
    fn line_text_cuts_by_characters() {
        /// `(whole line, part that is sent, inexact)`.
        fn text(line: &[u8], max_columns: usize) -> (String, String, bool) {
            let (whole, shown, inexact) = line_text(line, max_columns);
            (whole.to_string(), whole[..shown].to_string(), inexact)
        }
        let s = String::from;
        assert_eq!(text(b"abc", 3), (s("abc"), s("abc"), false));
        assert_eq!(text(b"abcd", 3), (s("abcd"), s("abc"), true));
        assert_eq!(text("äöü".as_bytes(), 3), (s("äöü"), s("äöü"), false), "six bytes, three characters");
        assert_eq!(text("äöüß".as_bytes(), 3), (s("äöüß"), s("äöü"), true));
        assert_eq!(text(b"a\xffb", 10), (s("a\u{fffd}b"), s("a\u{fffd}b"), true));
        assert_eq!(text(b"a\xffb", 1), (s("a\u{fffd}b"), s("a"), true));
        assert_eq!(text(b"abc", 0), (s("abc"), s(""), true));
        assert_eq!(text(b"", 0), (s(""), s(""), false));
    }

    #[test]
    fn unix_millis_rounds_down() {
        assert_eq!(unix_millis(UNIX_EPOCH + Duration::from_micros(1_234_567)), 1234);
        assert_eq!(unix_millis(UNIX_EPOCH), 0);
        assert_eq!(unix_millis(UNIX_EPOCH - Duration::from_millis(2)), -2);
        assert_eq!(unix_millis(UNIX_EPOCH - Duration::from_micros(1_500)), -2);
    }

    #[test]
    fn matches_have_line_numbers_and_relative_paths() {
        let t = tree(&[
            ("top.txt", "one\nneedle here\nthree\nlast needle"),
            ("sub/deep/x.txt", "needle\n\nneedle needle\n"),
            ("sub/none.txt", "nothing\n"),
        ]);
        let found = find(t.path(), "needle");
        assert_eq!(found.paths(), ["sub/deep/x.txt", "top.txt"]);
        assert_eq!(found.texts("top.txt"), [(2, "needle here"), (4, "last needle")]);
        assert_eq!(found.texts("sub/deep/x.txt"), [(1, "needle"), (3, "needle needle")]);
        let lines = found.lines("sub/deep/x.txt");
        assert_eq!(lines[0].spans, [(0, 6)]);
        assert_eq!(lines[1].spans, [(0, 6), (7, 13)]);
        assert!(lines.iter().all(|l| l.secondary.is_empty() && !l.inexact));
        assert!(found.files.iter().all(|f| f.path_spans.is_empty()));
    }

    #[test]
    fn a_trailing_slash_on_the_directory_changes_nothing() {
        let t = tree(&[("sub/x.txt", "needle\n")]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.dir.push('/');
        assert_eq!(run(q).paths(), ["sub/x.txt"]);
    }

    #[test]
    fn the_summary_counts() {
        let t = tree(&[("a", "needle\nneedle\n"), ("b", "needle\n"), ("c", "nothing\n"), ("d/e", "")]);
        let summary = find(t.path(), "needle").summary;
        assert_eq!(
            Summary { millis: 0, ..summary },
            Summary {
                files_searched: 4,
                files_matched: 2,
                lines: 3,
                truncated: false,
                sorted: true,
                millis: 0,
                skipped: 0
            }
        );

        let none = find(t.path(), "absent");
        assert!(none.files.is_empty());
        assert_eq!((none.summary.files_searched, none.summary.files_matched, none.summary.lines), (4, 0, 0));

        let empty = TempDir::new().unwrap();
        let summary = find(empty.path(), "needle").summary;
        assert_eq!((summary.files_searched, summary.files_matched, summary.lines, summary.sorted), (0, 0, 0, true));
    }

    #[test]
    fn mtime_is_the_files_modification_time_in_milliseconds() {
        let t = tree(&[("a", "needle\n")]);
        let modified = std::fs::metadata(t.path().join("a")).unwrap().modified().unwrap();
        let expected = modified.duration_since(UNIX_EPOCH).unwrap().as_millis() as i64;
        assert!(expected > 1_600_000_000_000);
        assert_eq!(find(t.path(), "needle").file("a").mtime, Some(expected));
    }

    #[test]
    fn positions_are_character_offsets() {
        let t = tree(&[("a", "grüße — needle ≠ needle\nπ=needle\n")]);
        let found = find(t.path(), "needle");
        let lines = found.lines("a");
        // "grüße — " is 8 characters and 12 bytes.
        assert_eq!(lines[0].spans, [(8, 14), (17, 23)]);
        assert_eq!(lines[1].spans, [(2, 8)]);

        let found = find(t.path(), "ße — n");
        assert_eq!(found.lines("a")[0].spans, [(3, 9)]);
    }

    #[test]
    fn primary_and_secondary_matches_are_separate_lists() {
        let t = tree(&[("a", "foo bar baz\nfoo only\nbar foobar\nüfoobarbaz bar\n")]);
        let found = run(Query::new(t.path(), vec![line("foo"), line("bar")]));
        let lines = found.lines("a");
        assert_eq!(found.texts("a"), [(1, "foo bar baz"), (3, "bar foobar"), (4, "üfoobarbaz bar")]);
        assert_eq!((&lines[0].spans[..], &lines[0].secondary[..]), (&[(0, 3)][..], &[(4, 7)][..]));
        assert_eq!((&lines[1].spans[..], &lines[1].secondary[..]), (&[(4, 7)][..], &[(0, 3), (7, 10)][..]));
        assert_eq!(lines[2].spans, [(1, 4)]);
        assert_eq!(lines[2].secondary, [(4, 7), (11, 14)]);

        // The order of the filters decides which one is primary, not which lines are found.
        let swapped = run(Query::new(t.path(), vec![line("bar"), line("foo")]));
        assert_eq!(swapped.texts("a"), found.texts("a"));
        assert_eq!(swapped.lines("a")[0].spans, [(4, 7)]);
        assert_eq!(swapped.lines("a")[0].secondary, [(0, 3)]);
    }

    #[test]
    fn overlapping_secondary_matches_are_clipped_to_the_primary() {
        let t = tree(&[("a", "xx foobar yy\n")]);
        // `oba` overlaps `foo` (3..6) on one side and `bar` on the other.
        let found = run(Query::new(t.path(), vec![line("foo"), line("oba")]));
        let l = &found.lines("a")[0];
        assert_eq!(l.spans, [(3, 6)]);
        assert_eq!(l.secondary, [(6, 8)], "the part inside the primary match is the primary's");

        let found = run(Query::new(t.path(), vec![line("foobar"), line("oba")]));
        let l = &found.lines("a")[0];
        assert_eq!((l.spans.as_slice(), l.secondary.is_empty()), (&[(3, 9)][..], true));
    }

    #[test]
    fn path_spans_show_the_include_path_filters() {
        let t = tree(&[("src/walk.rs", "needle\n"), ("src/wälk/mod.rs", "needle\n"), ("doc/walk.md", "needle\n")]);
        let found = run(Query::new(t.path(), vec![line("needle"), path("/src/"), path(".rs")]));
        assert_eq!(found.paths(), ["src/walk.rs", "src/wälk/mod.rs"]);
        // `/src/` matches the added leading slash, which is not part of the path.
        assert_eq!(found.file("src/walk.rs").path_spans, [(0, 4), (8, 11)]);
        assert_eq!(found.file("src/wälk/mod.rs").path_spans, [(0, 4), (12, 15)], "character offsets");
    }

    #[test]
    fn literal_and_regexp() {
        let t = tree(&[("a", "a.c\nabc\nfn walk_dirs(\nfn walk(\n")]);
        assert_eq!(find(t.path(), "a.c").texts("a"), [(1, "a.c")]);
        assert_eq!(run(Query::new(t.path(), vec![line_re("a.c")])).texts("a"), [(1, "a.c"), (2, "abc")]);
        let found = run(Query::new(t.path(), vec![line_re(r"fn \w+_dirs\($")]));
        assert_eq!(found.texts("a"), [(3, "fn walk_dirs(")]);
        assert_eq!(found.lines("a")[0].spans, [(0, 13)]);
        assert!(find(t.path(), r"\w+").files.is_empty(), "a literal is not a regexp");
    }

    #[test]
    fn the_three_case_rules() {
        let t = tree(&[("a", "Foo\nfoo\nFOO\n")]);
        let search = |pattern: &str, case: Case| {
            let mut q = Query::new(t.path(), vec![line(pattern)]);
            q.case = case;
            let found = run(q);
            found.lines("a").iter().map(|l| l.n).collect::<Vec<_>>()
        };
        assert_eq!(search("foo", Case::Smart), [1, 2, 3]);
        assert_eq!(search("Foo", Case::Smart), [1]);
        assert_eq!(search("foo", Case::Sensitive), [2]);
        assert_eq!(search("FOO", Case::Sensitive), [3]);
        assert_eq!(search("Foo", Case::Insensitive), [1, 2, 3]);

        // The rule applies to every line filter, each with its own pattern under `smart`.
        let mut q = Query::new(t.path(), vec![line("foo"), not_line("FOO")]);
        assert_eq!(run(Query { case: Case::Smart, ..q }).texts("a"), [(1, "Foo"), (2, "foo")]);
        q = Query::new(t.path(), vec![line("foo"), not_line("FOO")]);
        assert!(run(Query { case: Case::Insensitive, ..q }).files.is_empty());
    }

    #[test]
    fn ignore_files_on_and_off() {
        let t = tree(&[
            (".gitignore", "ignored.txt\nbuild/\n"),
            (".ignore", "other.txt\n"),
            ("kept.txt", "needle\n"),
            ("ignored.txt", "needle\n"),
            ("other.txt", "needle\n"),
            ("build/out.txt", "needle\n"),
        ]);
        assert_eq!(find(t.path(), "needle").paths(), ["kept.txt"]);

        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.no_ignore = true;
        assert_eq!(run(q).paths(), ["build/out.txt", "ignored.txt", "kept.txt", "other.txt"]);
    }

    #[test]
    fn hidden_files_on_and_off() {
        let t = tree(&[("seen.txt", "needle\n"), (".hidden.txt", "needle\n"), (".config/x.txt", "needle\n")]);
        assert_eq!(find(t.path(), "needle").paths(), [".config/x.txt", ".hidden.txt", "seen.txt"]);

        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.hidden = false;
        let found = run(q);
        assert_eq!(found.paths(), ["seen.txt"]);
        assert_eq!(found.summary.files_searched, 1);
    }

    #[test]
    fn version_control_directories_are_never_searched() {
        let t = tree(&[
            ("a.txt", "needle\n"),
            (".git/config", "needle\n"),
            ("sub/.git/HEAD", "needle\n"),
            (".hg/store", "needle\n"),
            (".svn/entries", "needle\n"),
            (".jj/repo", "needle\n"),
            // A file of that name is a file like any other.
            ("worktree/.git", "needle\n"),
        ]);
        for no_ignore in [false, true] {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.no_ignore = no_ignore;
            let found = run(q);
            assert_eq!(found.paths(), ["a.txt", "worktree/.git"], "no-ignore {no_ignore}");
            assert_eq!(found.summary.files_searched, 2);
        }
    }

    #[test]
    fn binary_files_are_skipped() {
        let t = TempDir::new().unwrap();
        write(t.path(), "text.txt", "needle\n");
        write(t.path(), "early.bin", b"\0\x01\x02 needle\nneedle\n");
        // The NUL byte comes after matching lines; those are not reported either.
        write(t.path(), "late.bin", b"needle\nneedle\nmore\0 needle\n");
        let mut large = b"needle\n".repeat(40_000);
        large.extend_from_slice(b"\0\nneedle\n");
        write(t.path(), "large.bin", large);
        let found = find(t.path(), "needle");
        assert_eq!(found.paths(), ["text.txt"]);
        let s = found.summary;
        assert_eq!((s.files_searched, s.files_matched, s.lines, s.skipped, s.truncated), (4, 1, 1, 0, false));
    }

    #[test]
    fn each_filter_kind() {
        let t = tree(&[
            ("src/a.rs", "let needle = 1;\n// needle in a comment\nneedle(x);\n"),
            ("src/b.txt", "needle text\n"),
            ("tests/c.rs", "needle test\n"),
        ]);
        let search = |extra: Vec<FilterSpec>| {
            let mut filters = vec![line("needle")];
            filters.extend(extra);
            run(Query::new(t.path(), filters))
        };
        // include line
        assert_eq!(search(vec![line("let")]).texts("src/a.rs"), [(1, "let needle = 1;")]);
        assert_eq!(search(vec![line("let")]).paths(), ["src/a.rs"]);
        // exclude line
        let found = search(vec![not_line("//")]);
        assert_eq!(found.texts("src/a.rs"), [(1, "let needle = 1;"), (3, "needle(x);")]);
        assert_eq!(found.summary.lines, 4, "dropped lines do not count");
        // include path
        let found = search(vec![path(".rs")]);
        assert_eq!(found.paths(), ["src/a.rs", "tests/c.rs"]);
        assert_eq!(found.summary.files_searched, 2, "path filters apply before a file is opened");
        // exclude path
        assert_eq!(search(vec![not_path(".rs")]).paths(), ["src/b.txt"]);
        assert_eq!(search(vec![not_path("/tests/")]).paths(), ["src/a.rs", "src/b.txt"]);
        // all together
        let found = search(vec![path("/src/"), not_path(".txt"), not_line("//"), line("(")]);
        assert_eq!(found.paths(), ["src/a.rs"]);
        assert_eq!(found.texts("src/a.rs"), [(3, "needle(x);")]);
        // a file whose lines are all dropped gives no item
        assert_eq!(search(vec![not_line("text")]).paths(), ["src/a.rs", "tests/c.rs"]);
    }

    #[cfg(unix)]
    #[test]
    fn an_excluded_directory_is_not_entered() {
        use std::os::unix::fs::PermissionsExt;
        let t = tree(&[("src/a.txt", "needle\n"), ("vendor/b.txt", "needle\n"), ("vendor/locked/c.txt", "needle\n")]);
        let locked = t.path().join("vendor/locked");
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
        let readable = std::fs::read_dir(&locked).is_ok(); // running as root
        let entered = find(t.path(), "needle");
        let excluded = run(Query::new(t.path(), vec![line("needle"), not_path("/vendor/")]));
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(excluded.paths(), ["src/a.txt"]);
        assert_eq!(excluded.summary.files_searched, 1);
        if !readable {
            assert_eq!(entered.paths(), ["src/a.txt", "vendor/b.txt"]);
            assert_eq!(entered.summary.skipped, 1, "the unreadable directory is a walk error");
            assert_eq!(excluded.summary.skipped, 0, "it is not reached below an excluded directory");
        }
    }

    #[cfg(unix)]
    #[test]
    fn an_unreadable_file_is_counted_as_skipped() {
        use std::os::unix::fs::PermissionsExt;
        let t = tree(&[("ok.txt", "needle\n"), ("locked.txt", "needle\n")]);
        let locked = t.path().join("locked.txt");
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
        if File::open(&locked).is_ok() {
            return; // running as root
        }
        let found = find(t.path(), "needle");
        assert_eq!(found.paths(), ["ok.txt"]);
        let s = found.summary;
        assert_eq!((s.files_searched, s.files_matched, s.skipped), (1, 1, 1));
    }

    #[cfg(unix)]
    #[test]
    fn symbolic_links_are_not_searched() {
        let t = tree(&[("real/file.txt", "needle\n")]);
        let outside = tree(&[("other.txt", "needle\n")]);
        std::os::unix::fs::symlink("real/file.txt", t.path().join("link.txt")).unwrap();
        std::os::unix::fs::symlink("real", t.path().join("dirlink")).unwrap();
        std::os::unix::fs::symlink(outside.path(), t.path().join("outside")).unwrap();
        std::os::unix::fs::symlink(outside.path().join("other.txt"), t.path().join("outside.txt")).unwrap();
        std::os::unix::fs::symlink("missing", t.path().join("dangling")).unwrap();
        for no_ignore in [false, true] {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.no_ignore = no_ignore;
            let found = run(q);
            assert_eq!(found.paths(), ["real/file.txt"], "once, under its real path");
            let s = found.summary;
            assert_eq!((s.files_searched, s.files_matched, s.lines, s.skipped), (1, 1, 1, 0));
        }
    }

    #[test]
    fn long_lines_are_cut_and_inexact() {
        let long = format!("{}needle{}", "ä".repeat(10), "x".repeat(100));
        let t = tree(&[("a", &format!("{long}\nshort needle\n{}needle\n", "é".repeat(14)))]);
        let search = |max_columns: usize| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.max_columns = max_columns;
            run(q)
        };
        let found = search(20);
        let lines = found.lines("a");
        assert_eq!(lines[0].text, format!("{}needlexxxx", "ä".repeat(10)), "20 characters, not 20 bytes");
        assert_eq!((lines[0].spans.as_slice(), lines[0].inexact), (&[(10, 16)][..], true));
        assert_eq!((lines[1].text.as_str(), lines[1].inexact), ("short needle", false));
        // Exactly `max-columns` characters: not cut.
        assert_eq!((lines[2].text.chars().count(), lines[2].inexact), (20, false));
        assert_eq!(lines[2].spans, [(14, 20)]);

        // The cut goes through the match: the position ends at the cut.
        let found = search(12);
        let lines = found.lines("a");
        assert_eq!(lines[0].text, format!("{}ne", "ä".repeat(10)));
        assert_eq!((lines[0].spans.as_slice(), lines[0].inexact), (&[(10, 12)][..], true));
        // The match lies beyond the cut: the line is still a result, without a position.
        let found = search(10);
        assert_eq!(found.lines("a")[0].text, "ä".repeat(10));
        assert!(found.lines("a")[0].spans.is_empty() && found.lines("a")[0].inexact);
        assert_eq!((lines[1].text.as_str(), lines[1].inexact), ("short needle", false));

        assert!(search(500).lines("a").iter().all(|l| !l.inexact));
    }

    #[test]
    fn the_line_filters_see_the_whole_line_of_a_cut_line() {
        let t = tree(&[("a", "needle and far away a marker\nneedle and far away nothing\n")]);
        let mut q = Query::new(t.path(), vec![line("needle"), line("marker")]);
        q.max_columns = 6;
        let found = run(q);
        assert_eq!(found.texts("a"), [(1, "needle")]);
        assert!(found.lines("a")[0].secondary.is_empty());
    }

    #[test]
    fn invalid_utf8_is_replaced_and_inexact() {
        let t = TempDir::new().unwrap();
        write(t.path(), "a", b"caf\xff needle\nclean needle\n\xe4\xf6 needle \xfc\n");
        let found = find(t.path(), "needle");
        let lines = found.lines("a");
        assert_eq!((lines[0].text.as_str(), lines[0].inexact), ("caf\u{fffd} needle", true));
        assert_eq!(lines[0].spans, [(5, 11)]);
        assert_eq!((lines[1].text.as_str(), lines[1].inexact), ("clean needle", false));
        assert_eq!((lines[2].text.as_str(), lines[2].inexact), ("\u{fffd}\u{fffd} needle \u{fffd}", true));
        assert_eq!(lines[2].spans, [(3, 9)]);
    }

    #[test]
    fn crlf_lines_come_without_carriage_return() {
        let t = tree(&[("a", "first needle\r\nsecond\r\nneedle third\r\nlast needle")]);
        let found = find(t.path(), "needle");
        assert_eq!(found.texts("a"), [(1, "first needle"), (3, "needle third"), (4, "last needle")]);
        assert!(found.lines("a").iter().all(|l| !l.inexact));
    }

    #[test]
    fn line_ends_are_the_same_for_every_line_filter() {
        let t = tree(&[
            ("crlf", "a foo\r\nfoo b\r\nfoo\r\nc foo"),
            ("lf", "a foo\nfoo b\nfoo\nc foo"),
            ("mixed", "a foo\r\nfoo b\nfoo\n"),
        ]);
        let ends = [(1, "a foo"), (3, "foo"), (4, "c foo")];
        // As primary filter, which the searcher runs on the file's bytes...
        let found = run(Query::new(t.path(), vec![line_re("foo$")]));
        assert_eq!(found.paths(), ["crlf", "lf", "mixed"]);
        assert_eq!(found.texts("crlf"), ends);
        assert_eq!(found.texts("lf"), ends);
        assert_eq!(found.texts("mixed"), [(1, "a foo"), (3, "foo")]);
        assert_eq!(found.lines("crlf")[0].spans, [(2, 5)]);
        assert!(found.files.iter().flat_map(|f| &f.lines).all(|l| !l.text.contains('\r') && !l.inexact));
        // ...as another include filter...
        let found = run(Query::new(t.path(), vec![line("foo"), line_re("foo$")]));
        assert_eq!(found.texts("crlf"), ends);
        assert_eq!(found.texts("lf"), ends);
        assert_eq!(found.lines("crlf")[0].spans, [(2, 5)]);
        // ...and as exclude filter.
        let not_end = FilterSpec { exclude: true, ..line_re("foo$") };
        let found = run(Query::new(t.path(), vec![line("foo"), not_end]));
        assert_eq!(found.texts("crlf"), [(2, "foo b")]);
        assert_eq!(found.texts("lf"), [(2, "foo b")]);
        assert_eq!(found.texts("mixed"), [(2, "foo b")]);
        // `^` likewise, and what could match a `\r` does not see the one of the line end.
        let found = run(Query::new(t.path(), vec![line_re("^foo")]));
        assert_eq!(found.texts("crlf"), [(2, "foo b"), (3, "foo")]);
        assert_eq!(found.texts("lf"), [(2, "foo b"), (3, "foo")]);
        for pattern in [r"foo\s", "foo.", "foo[^x]"] {
            let found = run(Query::new(t.path(), vec![line_re(pattern)]));
            assert_eq!(found.paths(), ["crlf", "lf", "mixed"], "{pattern}");
            for file in ["crlf", "lf", "mixed"] {
                assert_eq!(found.texts(file), [(2, "foo b")], "{pattern} in {file}");
            }
        }
    }

    #[test]
    fn a_carriage_return_inside_a_line_stays_in_the_text() {
        let t = tree(&[("a", "one\rneedle two\nthree needle\rfour\n\rneedle\n")]);
        let found = find(t.path(), "needle");
        assert_eq!(found.texts("a"), [(1, "one\rneedle two"), (2, "three needle\rfour"), (3, "\rneedle")]);
        assert_eq!(found.lines("a")[0].spans, [(4, 10)]);
        assert!(found.lines("a").iter().all(|l| !l.inexact));
        // The other line filters still see the whole line.
        let found = run(Query::new(t.path(), vec![line("needle"), line("four")]));
        assert_eq!(found.texts("a"), [(2, "three needle\rfour")]);
        let found = run(Query::new(t.path(), vec![line("needle"), not_line("one")]));
        assert_eq!(found.lines("a").len(), 2);
    }

    #[test]
    fn utf16_with_a_byte_order_mark_is_found() {
        let text = "erste Zeile\r\nhällo needle\r\n";
        let mut le = vec![0xff, 0xfe];
        le.extend(text.encode_utf16().flat_map(u16::to_le_bytes));
        let mut be = vec![0xfe, 0xff];
        be.extend(text.encode_utf16().flat_map(u16::to_be_bytes));
        let mut utf8 = vec![0xef, 0xbb, 0xbf];
        utf8.extend_from_slice("needle first\n".as_bytes());
        let t = TempDir::new().unwrap();
        write(t.path(), "le.txt", le);
        write(t.path(), "be.txt", be);
        write(t.path(), "bom8.txt", utf8);
        let found = find(t.path(), "needle");
        assert_eq!(found.paths(), ["be.txt", "bom8.txt", "le.txt"]);
        for file in ["le.txt", "be.txt"] {
            assert_eq!(found.texts(file), [(2, "hällo needle")]);
            assert_eq!(found.lines(file)[0].spans, [(6, 12)]);
            assert!(!found.lines(file)[0].inexact);
        }
        // The UTF-8 mark is not part of the text.
        assert_eq!(found.texts("bom8.txt"), [(1, "needle first")]);
        assert_eq!(found.lines("bom8.txt")[0].spans, [(0, 6)]);
    }

    #[test]
    fn positions_of_a_cut_line_come_from_the_whole_line() {
        let t = tree(&[("a", "xxfoo yy foo\nab cd ef\nab cdef\näö foo ü foo\n")]);
        let search = |pattern: &str, max_columns: usize| {
            let mut q = Query::new(t.path(), vec![line_re(pattern)]);
            q.max_columns = max_columns;
            run(q)
        };
        // `$` is the end of the line, not of the text that is sent: the real match is at column 9.
        let found = search("foo$", 5);
        let l = &found.lines("a")[0];
        assert_eq!((l.n, l.text.as_str(), l.spans.is_empty(), l.inexact), (1, "xxfoo", true, true));
        // Non-ASCII text before the cut; the second match crosses it.
        let l = &found.lines("a")[1];
        assert_eq!((l.n, l.text.as_str(), l.inexact), (4, "äö fo", true));
        assert!(l.spans.is_empty(), "`foo$` is the second foo, beyond the cut");
        let found = search("foo", 9);
        let l = &found.lines("a")[1];
        assert_eq!((l.text.as_str(), l.spans.as_slice()), ("äö foo ü ", &[(3, 6)][..]));
        let found = search("foo", 11);
        let l = &found.lines("a")[1];
        assert_eq!((l.text.as_str(), l.spans.as_slice()), ("äö foo ü fo", &[(3, 6), (9, 11)][..]));
        // A greedy match up to the end of the line.
        let found = search(r"\w+$", 5);
        assert_eq!(found.texts("a"), [(1, "xxfoo"), (2, "ab cd"), (3, "ab cd"), (4, "äö fo")]);
        let spans: Vec<&[(u32, u32)]> = found.lines("a").iter().map(|l| l.spans.as_slice()).collect();
        assert_eq!(spans, [&[][..], &[][..], &[(3, 5)][..], &[][..]], "only the match that crosses the cut");
    }

    #[test]
    fn a_carriage_return_at_the_end_of_the_file_is_text() {
        let t = tree(&[("a", "first\r\none needle\r")]);
        let found = find(t.path(), "needle");
        assert_eq!(found.texts("a"), [(2, "one needle\r")]);
        assert!(!found.lines("a")[0].inexact);
        assert_eq!(found.lines("a")[0].spans, [(4, 10)]);
    }

    #[test]
    fn regexp_exclude_path_filters_do_not_prune_directories() {
        let t = tree(&[
            ("src/a.rs", "needle\n"),
            ("src/sub/b.rs", "needle\n"),
            ("top", "needle\n"),
            ("dir/x.y", "needle\n"),
        ]);
        let search = |pattern: &str| {
            let exclude = FilterSpec { regexp: true, ..not_path(pattern) };
            run(Query::new(t.path(), vec![line("needle"), exclude]))
        };
        // Files directly in `src`: the pattern matches `/src/`, but not the files further down.
        assert_eq!(search("^/src/[^/]*$").paths(), ["dir/x.y", "src/sub/b.rs", "top"]);
        // Paths without a dot: `/dir/` is one, `/dir/x.y` is not.
        assert_eq!(search("^[^.]*$").paths(), ["dir/x.y", "src/a.rs", "src/sub/b.rs"]);
        // No file path ends in a slash.
        assert_eq!(search("/$").paths(), ["dir/x.y", "src/a.rs", "src/sub/b.rs", "top"]);
        // What a regexp does exclude, it excludes file by file.
        let found = search("^/src/");
        assert_eq!(found.paths(), ["dir/x.y", "top"]);
        assert_eq!(found.summary.files_searched, 2, "not opened");
        // A literal still excludes, and prunes (`an_excluded_directory_is_not_entered`).
        let found = run(Query::new(t.path(), vec![line("needle"), not_path("/src/")]));
        assert_eq!(found.paths(), ["dir/x.y", "top"]);
    }

    /// An [`Output`] that records what it is sent, can refuse a send, and has a clock of its own: the time
    /// stands still at `started` until `late_after` walk entries have been visited, then it is an hour later.
    struct Mock {
        started: Instant,
        sent: Mutex<Vec<Item>>,
        /// Calls of `send`, refused ones included.
        sends: AtomicUsize,
        /// The first send to refuse, counted from 0; that one and all later ones fail.
        fail_at: usize,
        entries: AtomicUsize,
        late_after: usize,
        late: AtomicBool,
    }

    impl Mock {
        fn new(fail_at: usize, late_after: usize) -> Mock {
            Mock {
                started: Instant::now(),
                sent: Mutex::new(Vec::new()),
                sends: AtomicUsize::new(0),
                fail_at,
                entries: AtomicUsize::new(0),
                late_after,
                late: AtomicBool::new(false),
            }
        }

        /// Searches `dir` for `needle` with `sort_budget` on the mock's clock; the result of [`Search::run`].
        fn run(&self, dir: &Path, sort_budget: Duration) -> bool {
            let filters = Filters::compile(&[line("needle")], Case::Smart).unwrap();
            let config = Config {
                dir: dir.to_path_buf(),
                filters,
                types: None,
                use_ignore_files: true,
                include_hidden: true,
                ignores: Vec::new(),
                max_lines: usize::MAX,
                max_columns: 500,
                sort_budget,
                started: self.started,
            };
            Search::new(config).unwrap().run(self)
        }

        fn paths(&self) -> Vec<String> {
            let sent = self.sent.lock().unwrap();
            sent.iter()
                .filter_map(|item| if let Item::File { path, .. } = item { Some(path.clone()) } else { None })
                .collect()
        }

        fn summary(&self) -> Option<Item> {
            self.sent.lock().unwrap().iter().find(|item| matches!(item, Item::Summary { .. })).cloned()
        }
    }

    impl Output for Mock {
        fn send(&self, item: Item) -> bool {
            if self.sends.fetch_add(1, Ordering::SeqCst) >= self.fail_at {
                return false;
            }
            self.sent.lock().unwrap().push(item);
            true
        }

        fn is_cancelled(&self) -> bool {
            // Asked once per walk entry, before the entry is looked at.
            if self.entries.fetch_add(1, Ordering::SeqCst) + 1 >= self.late_after {
                self.late.store(true, Ordering::SeqCst);
            }
            false
        }

        fn now(&self) -> Instant {
            if self.late.load(Ordering::SeqCst) { self.started + Duration::from_secs(3600) } else { self.started }
        }
    }

    fn threads() -> usize {
        std::thread::available_parallelism().map_or(1, |n| n.get())
    }

    /// When the clock of [`Mock`] jumps for a tree of [`many`], so that at least `files` files were collected
    /// before: of the entries visited until then, at most one per other thread is unfinished, and 17 are
    /// directories.
    fn late_after(files: usize) -> usize {
        threads() + 17 + files
    }

    const SECOND: Duration = Duration::from_secs(1);

    #[test]
    fn the_sort_budget_runs_out_during_the_walk() {
        let t = many(400, 1);
        let mock = Mock::new(usize::MAX, late_after(50));
        assert!(mock.run(t.path(), SECOND));
        let paths = mock.paths();
        // Nothing lost, nothing twice.
        let mut all = paths.clone();
        all.sort_unstable();
        all.dedup();
        assert_eq!((paths.len(), all.len()), (400, 400));
        // What was collected until then came first, sorted.
        assert!(paths[..50].is_sorted(), "{:?}", &paths[..50]);
        let sent = mock.sent.lock().unwrap();
        assert_eq!(sent.len(), 401);
        let Some(Item::Summary { files_matched, lines, sorted, truncated, .. }) = sent.last() else {
            panic!("the last item is not a summary: {:?}", sent.last())
        };
        assert_eq!((*files_matched, *lines, *sorted, *truncated), (400, 400, false, false));
    }

    #[test]
    fn a_search_within_the_budget_sends_everything_sorted_at_the_end() {
        let t = many(400, 1);
        let mock = Mock::new(usize::MAX, usize::MAX);
        assert!(mock.run(t.path(), SECOND));
        let paths = mock.paths();
        assert_eq!(paths.len(), 400);
        assert!(paths.is_sorted());
        assert!(matches!(mock.summary(), Some(Item::Summary { sorted: true, files_matched: 400, .. })));
        // A budget beyond what the clock can add up never runs out.
        let mock = Mock::new(usize::MAX, 1);
        assert!(mock.run(t.path(), Duration::MAX));
        assert!(mock.paths().is_sorted());
        assert!(matches!(mock.summary(), Some(Item::Summary { sorted: true, files_matched: 400, .. })));
    }

    #[test]
    fn a_refused_send_ends_the_search_without_a_summary() {
        let t = many(400, 1);
        // While items are streamed as found (no budget)...
        let streaming = Mock::new(10, usize::MAX);
        assert!(!streaming.run(t.path(), Duration::ZERO));
        // ...while the collected items are sent during the walk...
        let mid_walk = Mock::new(10, late_after(50));
        assert!(!mid_walk.run(t.path(), SECOND));
        // ...and while they are sent after it.
        let at_the_end = Mock::new(10, usize::MAX);
        assert!(!at_the_end.run(t.path(), SECOND));
        for (what, mock) in [("streaming", &streaming), ("mid-walk", &mid_walk), ("at the end", &at_the_end)] {
            assert_eq!(mock.paths().len(), 10, "{what}");
            assert!(mock.summary().is_none(), "{what}");
            assert_eq!(mock.sends.load(Ordering::SeqCst), 11, "{what}: nothing is sent after the refusal");
        }
        assert!(mid_walk.paths().is_sorted() && at_the_end.paths().is_sorted());
        // The walk was left early.
        assert!(streaming.entries.load(Ordering::SeqCst) < 400);
    }

    /// `files` files in 16 directories, each with `lines` matching lines.
    fn many(files: usize, lines: usize) -> TempDir {
        let t = TempDir::new().unwrap();
        for d in 0..16 {
            std::fs::create_dir(t.path().join(format!("d{d:02}"))).unwrap();
        }
        let content: String = (1..=lines).map(|n| format!("needle {n}\n")).collect();
        for i in 0..files {
            std::fs::write(t.path().join(format!("d{:02}/f{i:04}", i % 16)), &content).unwrap();
        }
        t
    }

    #[test]
    fn the_line_cap_is_exact_with_many_files() {
        let t = many(2000, 3);
        for (max_lines, sort_budget_ms) in [(50, 0), (50, 60_000), (1, 0), (500, 0), (1000, 60_000)] {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.max_lines = max_lines;
            q.sort_budget_ms = sort_budget_ms;
            let found = run(q);
            let what = format!("max-lines {max_lines}, budget {sort_budget_ms}: {:?}", found.summary);
            assert_eq!(found.total_lines(), max_lines, "{what}");
            assert_eq!(found.summary.lines, max_lines, "{what}");
            assert!(found.summary.truncated, "{what}");
            assert_eq!(found.summary.files_matched, found.files.len(), "{what}");
            assert!(found.summary.files_searched < 2000, "the walk stops: {what}");
            assert!(found.files.iter().all(|f| !f.lines.is_empty()), "{what}");
            // A file that does not fit as a whole gives its first lines.
            for file in &found.files {
                let numbers: Vec<u64> = file.lines.iter().map(|l| l.n).collect();
                assert_eq!(numbers, (1..=numbers.len() as u64).collect::<Vec<_>>(), "{what}");
            }
        }
    }

    #[test]
    fn the_line_cap_within_one_file() {
        let t = many(1, 100);
        let search = |max_lines: usize| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.max_lines = max_lines;
            run(q)
        };
        let found = search(7);
        assert_eq!(found.lines("d00/f0000").iter().map(|l| l.n).collect::<Vec<_>>(), [1, 2, 3, 4, 5, 6, 7]);
        assert_eq!((found.summary.lines, found.summary.truncated), (7, true));

        let found = search(101);
        assert_eq!((found.summary.lines, found.summary.truncated), (100, false));
        // Reaching the cap exactly counts as reaching it.
        let found = search(100);
        assert_eq!((found.summary.lines, found.summary.truncated), (100, true));

        let found = search(0);
        assert!(found.files.is_empty());
        assert_eq!((found.summary.lines, found.summary.truncated), (0, true));
    }

    #[test]
    fn dropped_lines_do_not_count_for_the_cap() {
        let t = tree(&[("a", "needle x\nneedle x\nneedle x\nneedle y\nneedle x\nneedle y\nneedle y\n")]);
        let mut q = Query::new(t.path(), vec![line("needle"), not_line("x")]);
        q.max_lines = 2;
        let found = run(q);
        assert_eq!(found.texts("a"), [(4, "needle y"), (6, "needle y")]);
        assert!(found.summary.truncated);
    }

    #[test]
    fn a_quick_search_is_sorted_by_path() {
        // Byte order: uppercase before lowercase, `-` and `.` before `/`, non-ASCII last.
        let names = ["b/a", "a/z", "a/b/c", "a-b", "a.b", "B", "a", "ä", "z", "a/b0", "ab"];
        let t = TempDir::new().unwrap();
        for name in names {
            write(t.path(), &format!("{name}.txt"), "needle\n");
        }
        for i in 0..300 {
            write(t.path(), &format!("many/f{i:03}"), "needle\n");
        }
        let found = find(t.path(), "needle");
        assert!(found.summary.sorted);
        assert_eq!(found.paths().len(), names.len() + 300);
        assert_eq!(found.paths(), found.sorted_paths());
        let first: Vec<&str> = found.paths().into_iter().filter(|p| !p.starts_with("many/")).collect();
        assert_eq!(
            first,
            [
                "B.txt",
                "a-b.txt",
                "a.b.txt",
                "a.txt",
                "a/b/c.txt",
                "a/b0.txt",
                "a/z.txt",
                "ab.txt",
                "b/a.txt",
                "z.txt",
                "ä.txt"
            ]
        );
    }

    #[test]
    fn without_a_sort_budget_everything_is_streamed_as_found() {
        let t = many(400, 1);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.sort_budget_ms = 0;
        let found = run(q);
        assert!(!found.summary.sorted);
        assert_eq!(found.files.len(), 400);
        assert_eq!(found.sorted_paths().len(), 400);
        assert_eq!((found.summary.files_matched, found.summary.lines, found.summary.truncated), (400, 400, false));

        // Also when nothing is found.
        let mut q = Query::new(t.path(), vec![line("absent")]);
        q.sort_budget_ms = 0;
        assert!(!run(q).summary.sorted);
    }
}
