//! The `grep` service: searches a directory for lines and streams the matches. One instance serves every result
//! buffer; it is started from Elisp with `(emrs-start 'quarry "grep" nil)`, has no start arguments, emits no
//! events and keeps no state between requests. Several searches can run at the same time.
//!
//! Lisp shapes (spec `2026-10-10-grep.md`, "The service"):
//!
//! | Request | Reply |
//! |---|---|
//! | `(:types)` | list of `(:name "rust" :globs ("*.rs"))`, sorted by name |
//! | `(:search :dir D :filters (F ...) ...)` | stream of file items and one summary item, capacity 256 |
//!
//! **`(:types)`** lists the file types the `ignore` crate defines (what `rg --type-list` prints), the globs of
//! each sorted.
//!
//! **`(:search …)`** fields; only `:dir` and `:filters` are required:
//!
//! | Field | Value | Default |
//! |---|---|---|
//! | `:dir` | string: absolute path of an existing directory | |
//! | `:filters` | list of `(:target :line :exclude nil :pattern "foo" :regexp t)`: the enabled filters in the buffer's order; `:target` is `:line` or `:path`, `:exclude` and `:regexp` may be left out. At least one must be an include line filter | |
//! | `:case` | `:smart`, `:sensitive` or `:insensitive`: the case rule of the line filters | `:smart` |
//! | `:file-type` | string: a name from `(:types)` | nil: all files |
//! | `:globs` | list of strings: globs for file names (not paths: no `/`), e.g. `("*.el" "*.org")`, instead of `:file-type` | nil: all files |
//! | `:no-ignore` | non-nil: `.gitignore`, `.ignore` and the git exclude files are not applied | nil |
//! | `:hidden` | search hidden files; say `:hidden nil` to leave out every file and directory whose name starts with a dot, whatever the file type or globs | t |
//! | `:ignores` | list of strings: extra gitignore lines relative to `:dir` | nil |
//! | `:max-lines` | integer: the search stops when this many lines are collected | 50000 |
//! | `:max-columns` | integer: longer lines are cut after this many characters | 500 |
//! | `:sort-budget-ms` | integer: how long results are collected to be sent sorted | 150 |
//!
//! The request is checked before anything is searched, and a request that fails a check fails the call (an
//! `emrs-error` of kind `service`; for `emrs-call-stream`, `on-end` with status `failed`). The messages:
//!
//! | Situation | Message | `:data` |
//! |---|---|---|
//! | `:dir` is not absolute | `grep directory is not an absolute path: D` | |
//! | `:dir` is missing or cannot be read | `grep directory D cannot be used: OS MESSAGE` | |
//! | `:dir` is not a directory | `grep directory is not a directory: D` | |
//! | A filter has an empty or invalid pattern | ``invalid filter `PATTERN`: ENGINE MESSAGE`` (may span lines) | `(:filter INDEX)`, the 0-based position in `:filters` |
//! | No include line filter | `a search needs an include line filter` | `(:filter nil)` |
//! | `:file-type` and `:globs` both given | `give a file type or globs, not both` | |
//! | `:file-type` is not a name from `(:types)` | `unknown file type: NAME` | |
//! | A glob is empty or invalid | `invalid glob "GLOB": MESSAGE` | |
//! | A glob contains `/` | `glob "GLOB" names a directory; globs match file names, use a path filter for directories` | |
//! | An `:ignores` line is invalid | `invalid ignore pattern "LINE": MESSAGE` | |
//!
//! **Stream items** are of two kinds, told apart by their first element.
//!
//! A file item, one per file with kept lines:
//!
//! ```elisp
//! (:file :path "src/walk.rs" :path-spans ((4 8)) :mtime 1760103296123
//!        :lines ((:n 169 :text "pub fn walk(" :spans ((4 11)) :secondary ((0 3)) :inexact nil)
//!                ...))
//! ```
//!
//! - `:path` is relative to `:dir`, `/`-separated. `:path-spans` are the parts of it matched by include path
//!   filters, sorted and merged; nil without such filters.
//! - `:mtime` is the file's modification time in milliseconds since the Unix epoch, rounded down, as an integer
//!   (nil if the file system did not tell). It is read when the file is opened, before its content.
//! - `:lines` are in ascending line number. `:n` counts from 1. `:text` is the line without `\n` or `\r\n`.
//! - `:spans` are the matches of the primary filter (the first include line filter), `:secondary` those of the
//!   other include line filters where they lie outside the primary matches. Both are lists of `(START END)`,
//!   character offsets into `:text` counted from 0, `END` exclusive, ascending and not overlapping; nil when
//!   empty.
//! - `:inexact` is t when `:text` is not exactly the file's line: it was cut after `:max-columns` characters, or
//!   the line held bytes that are not valid UTF-8 (each shown as U+FFFD). The matches are found on the whole
//!   line and listed as positions in `:text` as sent: a match that crosses the cut ends at the cut, a match
//!   beyond it is not listed.
//!
//! The summary item, exactly one, the last item of a search that was not cancelled:
//!
//! ```elisp
//! (:summary :files-searched 19 :files-matched 2 :lines 7 :truncated nil :sorted t :millis 61 :skipped 0)
//! ```
//!
//! - `:files-searched`: files opened and read (binary files included, they give no lines). `:files-matched`:
//!   the number of file items. `:lines`: the lines in them, never more than `:max-lines`.
//! - `:truncated`: `:lines` reached `:max-lines` and the search stopped there.
//! - `:sorted`: every file item came in order of its path (byte order). That is so when the search ended within
//!   `:sort-budget-ms`. Otherwise the items found until then are sent sorted and the rest as they are found.
//! - `:millis`: from the arrival of the request to the summary. `:skipped`: files that could not be opened or
//!   read, walk errors such as unreadable directories, and paths that are not valid UTF-8.
//!
//! A cancelled search (`emrs-cancel`, or the instance stops) sends nothing more, also no summary.
//!
//! `handle` only checks the request, opens the stream and spawns the search (`ctx.spawn`); how the search works
//! is described in `src/grep/search.rs`.

use crate::grep::filter::{Case, FilterSpec, Filters};
use crate::grep::search::{Config, Item, Output, Search};
use emrs::{CancelToken, Context, Error, Reply, Service, StreamSender};
use ignore::types::{Types, TypesBuilder};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// Capacity of the `(:search)` stream, in items (files).
const STREAM_CAPACITY: usize = 256;

/// The name of the type built from `:globs`.
const GLOB_TYPE: &str = "globs";

fn default_true() -> bool {
    true
}

fn default_max_lines() -> usize {
    50_000
}

fn default_max_columns() -> usize {
    500
}

fn default_sort_budget_ms() -> u64 {
    150
}

#[derive(Debug, Deserialize)]
pub enum Request {
    /// `(:types)`; replies with a list of [`TypeDef`].
    Types,
    /// `(:search :dir D :filters (F ...) ...)`; replies with a stream of [`Item`]. See the module docs.
    Search {
        dir: String,
        filters: Vec<FilterSpec>,
        #[serde(default)]
        case: Case,
        #[serde(default)]
        file_type: Option<String>,
        #[serde(default)]
        globs: Vec<String>,
        #[serde(default)]
        no_ignore: bool,
        #[serde(default = "default_true")]
        hidden: bool,
        #[serde(default)]
        ignores: Vec<String>,
        #[serde(default = "default_max_lines")]
        max_lines: usize,
        #[serde(default = "default_max_columns")]
        max_columns: usize,
        #[serde(default = "default_sort_budget_ms")]
        sort_budget_ms: u64,
    },
}

/// A file type of `(:types)`: `(:name "rust" :globs ("*.rs"))`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TypeDef {
    pub name: String,
    pub globs: Vec<String>,
}

/// The `:data` of a filter error: `(:filter INDEX)`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FilterErrorData {
    /// 0-based position of the filter in `:filters`; nil when the list as a whole is at fault.
    pub filter: Option<usize>,
}

/// The file types of the `ignore` crate, sorted by name.
fn type_list() -> Vec<TypeDef> {
    let mut builder = TypesBuilder::new();
    builder.add_defaults();
    let mut types: Vec<TypeDef> = builder
        .definitions()
        .into_iter()
        .map(|def| TypeDef { name: def.name().to_string(), globs: def.globs().to_vec() })
        .collect();
    types.sort_by(|a, b| a.name.cmp(&b.name));
    types
}

/// The file restriction of a search: a named type, a type made of `globs`, or none.
fn file_types(file_type: Option<&str>, globs: &[String]) -> Result<Option<Types>, String> {
    let mut builder = TypesBuilder::new();
    let selected = match (file_type, globs) {
        (None, []) => return Ok(None),
        (Some(_), [_, ..]) => return Err("give a file type or globs, not both".to_string()),
        (Some(name), []) => {
            builder.add_defaults();
            // Not left to `build`: it would take `all` for a name.
            if !builder.definitions().iter().any(|def| def.name() == name) {
                return Err(format!("unknown file type: {name}"));
            }
            name
        }
        (None, globs) => {
            for glob in globs {
                if glob.is_empty() {
                    return Err(format!("invalid glob {glob:?}: it is empty"));
                }
                // A type's globs are matched against the file name alone; this one would match nothing.
                if glob.contains('/') {
                    return Err(format!(
                        "glob {glob:?} names a directory; globs match file names, use a path filter for directories"
                    ));
                }
                builder.add(GLOB_TYPE, glob).map_err(|e| format!("invalid glob {glob:?}: {e}"))?;
            }
            GLOB_TYPE
        }
    };
    builder.select(selected);
    match builder.build() {
        Ok(types) => Ok(Some(types)),
        Err(ignore::Error::Glob { glob: Some(glob), err }) => Err(format!("invalid glob {glob:?}: {err}")),
        Err(e) => Err(e.to_string()),
    }
}

/// The search directory as a path, if it is an absolute path of an existing directory.
fn search_dir(dir: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(dir);
    if !path.is_absolute() {
        return Err(format!("grep directory is not an absolute path: {dir}"));
    }
    match std::fs::metadata(&path) {
        Err(e) => Err(format!("grep directory {dir} cannot be used: {e}")),
        Ok(meta) if !meta.is_dir() => Err(format!("grep directory is not a directory: {dir}")),
        Ok(_) => Ok(path),
    }
}

/// The stream of one search as the search's output.
struct StreamOutput {
    out: StreamSender<Item>,
    token: CancelToken,
}

impl Output for StreamOutput {
    fn send(&self, item: Item) -> bool {
        self.out.send(item).is_ok()
    }

    fn is_cancelled(&self) -> bool {
        self.token.is_cancelled()
    }
}

pub struct GrepService;

impl Service for GrepService {
    const NAME: &'static str = "grep";
    type Args = ();
    type Request = Request;
    type Event = ();

    fn start(_: (), _: &Context<Self>) -> Result<Self, Error> {
        Ok(GrepService)
    }

    fn handle(&mut self, request: Request, reply: Reply, ctx: &Context<Self>) {
        let started = Instant::now();
        match request {
            Request::Types => reply.ok(type_list()),
            Request::Search {
                dir,
                filters,
                case,
                file_type,
                globs,
                no_ignore,
                hidden,
                ignores,
                max_lines,
                max_columns,
                sort_budget_ms,
            } => {
                let dir = match search_dir(&dir) {
                    Ok(dir) => dir,
                    Err(message) => return reply.err(Error::new(message)),
                };
                let filters = match Filters::compile(&filters, case) {
                    Ok(filters) => filters,
                    Err(e) => return reply.err(Error::with_data(e.message, FilterErrorData { filter: e.index })),
                };
                let types = match file_types(file_type.as_deref(), &globs) {
                    Ok(types) => types,
                    Err(message) => return reply.err(Error::new(message)),
                };
                let config = Config {
                    dir,
                    filters,
                    types,
                    use_ignore_files: !no_ignore,
                    include_hidden: hidden,
                    ignores,
                    max_lines,
                    max_columns,
                    sort_budget: Duration::from_millis(sort_budget_ms),
                    started,
                };
                let search = match Search::new(config) {
                    Ok(search) => search,
                    Err(message) => return reply.err(Error::new(message)),
                };
                let out = reply.stream::<Item>(STREAM_CAPACITY);
                // The stream's token is cancelled by `emrs-cancel` and when the instance stops.
                let output = StreamOutput { token: out.token(), out };
                ctx.spawn(move |_| {
                    // After a cancellation the stream is already closed; dropping the sender is all there is to do.
                    if search.run(&output) {
                        output.out.finish();
                    }
                });
            }
        }
    }
}

/// What the tests of this file and of `search.rs` share: trees, requests, and a search run to its end.
#[cfg(test)]
pub(crate) mod testing {
    use super::*;
    use crate::grep::filter::Target;
    use crate::grep::search::{FileItem, Line, Summary};
    use emrs::StreamEnd;
    use emrs::testing::Host;
    use std::path::Path;
    use tempfile::TempDir;

    pub(crate) fn write(root: &Path, rel: &str, content: impl AsRef<[u8]>) {
        let path = root.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, content).unwrap();
    }

    pub(crate) fn tree(files: &[(&str, &str)]) -> TempDir {
        let t = TempDir::new().unwrap();
        for (rel, content) in files {
            write(t.path(), rel, content);
        }
        t
    }

    fn spec(target: Target, exclude: bool, pattern: &str, regexp: bool) -> FilterSpec {
        FilterSpec { target, exclude, pattern: pattern.to_string(), regexp }
    }
    /// An include line filter, literal.
    pub(crate) fn line(pattern: &str) -> FilterSpec {
        spec(Target::Line, false, pattern, false)
    }
    /// An include line filter, regexp.
    pub(crate) fn line_re(pattern: &str) -> FilterSpec {
        spec(Target::Line, false, pattern, true)
    }
    pub(crate) fn not_line(pattern: &str) -> FilterSpec {
        spec(Target::Line, true, pattern, false)
    }
    pub(crate) fn path(pattern: &str) -> FilterSpec {
        spec(Target::Path, false, pattern, false)
    }
    pub(crate) fn not_path(pattern: &str) -> FilterSpec {
        spec(Target::Path, true, pattern, false)
    }

    /// The fields of a `(:search)` request, with the defaults of the service except for a sort budget that no
    /// test search exceeds.
    pub(crate) struct Query {
        pub dir: String,
        pub filters: Vec<FilterSpec>,
        pub case: Case,
        pub file_type: Option<String>,
        pub globs: Vec<String>,
        pub no_ignore: bool,
        pub hidden: bool,
        pub ignores: Vec<String>,
        pub max_lines: usize,
        pub max_columns: usize,
        pub sort_budget_ms: u64,
    }

    impl Query {
        pub(crate) fn new(dir: &Path, filters: Vec<FilterSpec>) -> Query {
            Query {
                dir: dir.to_str().unwrap().to_string(),
                filters,
                case: Case::Smart,
                file_type: None,
                globs: Vec::new(),
                no_ignore: false,
                hidden: true,
                ignores: Vec::new(),
                max_lines: default_max_lines(),
                max_columns: default_max_columns(),
                sort_budget_ms: 60_000,
            }
        }

        pub(crate) fn request(self) -> Request {
            Request::Search {
                dir: self.dir,
                filters: self.filters,
                case: self.case,
                file_type: self.file_type,
                globs: self.globs,
                no_ignore: self.no_ignore,
                hidden: self.hidden,
                ignores: self.ignores,
                max_lines: self.max_lines,
                max_columns: self.max_columns,
                sort_budget_ms: self.sort_budget_ms,
            }
        }
    }

    /// A finished search: its file items in the order they arrived, and its summary.
    #[derive(Debug)]
    pub(crate) struct Found {
        pub files: Vec<FileItem>,
        pub summary: Summary,
    }

    impl Found {
        /// Checks the stream's rules: it ended as done, file items only, then exactly one summary.
        pub(crate) fn from_stream(result: emrs::testing::StreamResult<Item>) -> Found {
            assert_eq!(result.status, StreamEnd::Done, "{:?}", result.error.map(|e| e.to_string()));
            let mut items = result.items;
            let summary = match items.pop() {
                Some(Item::Summary { files_searched, files_matched, lines, truncated, sorted, millis, skipped }) => {
                    Summary { files_searched, files_matched, lines, truncated, sorted, millis, skipped }
                }
                other => panic!("the last item is not a summary: {other:?}"),
            };
            let files = items
                .into_iter()
                .map(|item| match item {
                    Item::File { path, path_spans, mtime, lines } => FileItem { path, path_spans, mtime, lines },
                    Item::Summary { .. } => panic!("a second summary"),
                })
                .collect();
            Found { files, summary }
        }

        pub(crate) fn paths(&self) -> Vec<&str> {
            self.files.iter().map(|f| f.path.as_str()).collect()
        }

        /// The paths in sorted order, whatever order they arrived in.
        pub(crate) fn sorted_paths(&self) -> Vec<&str> {
            let mut paths = self.paths();
            paths.sort_unstable();
            paths
        }

        pub(crate) fn file(&self, path: &str) -> &FileItem {
            self.files.iter().find(|f| f.path == path).unwrap_or_else(|| panic!("no item for {path}"))
        }

        pub(crate) fn lines(&self, path: &str) -> &[Line] {
            &self.file(path).lines
        }

        /// `(line number, text)` of the lines of `path`.
        pub(crate) fn texts(&self, path: &str) -> Vec<(u64, &str)> {
            self.lines(path).iter().map(|l| (l.n, l.text.as_str())).collect()
        }

        pub(crate) fn total_lines(&self) -> usize {
            self.files.iter().map(|f| f.lines.len()).sum()
        }
    }

    pub(crate) fn host() -> Host<GrepService> {
        Host::<GrepService>::start(()).with_timeout(Duration::from_secs(30))
    }

    /// Runs one search on a fresh instance to its end.
    pub(crate) fn run(query: Query) -> Found {
        Found::from_stream(host().call_stream::<Item>(query.request()).unwrap())
    }

    /// Searches `dir` for the literal `pattern` with the defaults.
    pub(crate) fn find(dir: &Path, pattern: &str) -> Found {
        run(Query::new(dir, vec![line(pattern)]))
    }

    /// The error a search request is refused with.
    pub(crate) fn refused(query: Query) -> Error {
        let result = host().call_stream::<Item>(query.request()).unwrap();
        assert_eq!(result.status, StreamEnd::Failed);
        assert!(result.items.is_empty());
        result.error.expect("an error")
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;
    use crate::grep::search::hook::{self, Ended};
    use emrs::{ErrorKind, State};
    use tempfile::TempDir;

    #[test]
    fn type_list_has_rust_and_is_sorted() {
        let types = host().call::<Vec<TypeDef>>(Request::Types).unwrap();
        assert!(types.len() > 100, "{}", types.len());
        assert!(types.contains(&TypeDef { name: "rust".into(), globs: vec!["*.rs".into()] }));
        assert!(types.windows(2).all(|pair| pair[0].name < pair[1].name), "sorted by name, no duplicates");
        assert!(types.iter().all(|t| !t.globs.is_empty()));
        // `all` selects every type in the `ignore` crate; it is not a type.
        assert!(types.iter().all(|t| t.name != "all"));
    }

    #[test]
    fn file_type_restricts_the_files() {
        let t =
            tree(&[("a.rs", "needle\n"), ("b.txt", "needle\n"), ("sub/c.rs", "needle\n"), ("sub/d.el", "needle\n")]);
        assert_eq!(find(t.path(), "needle").paths(), ["a.rs", "b.txt", "sub/c.rs", "sub/d.el"]);

        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.file_type = Some("rust".into());
        let found = run(q);
        assert_eq!(found.paths(), ["a.rs", "sub/c.rs"]);
        assert_eq!(found.summary.files_searched, 2, "other files are not opened");
    }

    #[test]
    fn globs_restrict_the_files() {
        let t =
            tree(&[("a.rs", "needle\n"), ("b.txt", "needle\n"), ("sub/c.rs", "needle\n"), ("sub/d.el", "needle\n")]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.globs = vec!["*.el".into(), "b.*".into()];
        let found = run(q);
        assert_eq!(found.paths(), ["b.txt", "sub/d.el"]);
        assert_eq!(found.summary.files_searched, 2);
    }

    #[test]
    fn hidden_files_stay_out_with_a_file_type_or_globs() {
        let files = [".hidden.txt", "seen.txt", ".hd/x.txt", "sub/y.txt", "sub/.z.txt", "other.rs"];
        let t = TempDir::new().unwrap();
        for file in files {
            write(t.path(), file, "needle\n");
        }
        let search = |hidden: bool, file_type: Option<&str>, globs: &[&str]| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.hidden = hidden;
            q.file_type = file_type.map(String::from);
            q.globs = globs.iter().map(|g| g.to_string()).collect();
            run(q)
        };
        let found = search(false, None, &["*.txt"]);
        assert_eq!(found.paths(), ["seen.txt", "sub/y.txt"]);
        assert_eq!(found.summary.files_searched, 2);
        assert_eq!(search(false, Some("txt"), &[]).paths(), ["seen.txt", "sub/y.txt"]);
        assert_eq!(search(false, None, &[]).paths(), ["other.rs", "seen.txt", "sub/y.txt"]);
        let all_txt = [".hd/x.txt", ".hidden.txt", "seen.txt", "sub/.z.txt", "sub/y.txt"];
        assert_eq!(search(true, None, &["*.txt"]).paths(), all_txt);
        assert_eq!(search(true, Some("txt"), &[]).paths(), all_txt);
    }

    #[test]
    fn a_sort_budget_beyond_the_clock_is_no_budget_limit() {
        let t = tree(&[("b", "needle\n"), ("a", "needle\n")]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.sort_budget_ms = u64::MAX;
        let found = run(q);
        assert_eq!(found.paths(), ["a", "b"]);
        assert!(found.summary.sorted);
    }

    #[test]
    fn bad_type_requests_are_refused() {
        let t = tree(&[("a.rs", "needle\n")]);
        let query = || Query::new(t.path(), vec![line("needle")]);

        let mut unknown = query();
        unknown.file_type = Some("nosuchtype".into());
        let error = refused(unknown);
        assert_eq!(error.kind(), ErrorKind::Service);
        assert_eq!(error.message(), "unknown file type: nosuchtype");

        let mut all = query();
        all.file_type = Some("all".into());
        assert_eq!(refused(all).message(), "unknown file type: all");

        let mut both = query();
        both.file_type = Some("rust".into());
        both.globs = vec!["*.rs".into()];
        assert_eq!(refused(both).message(), "give a file type or globs, not both");

        let mut bad_glob = query();
        bad_glob.globs = vec!["*.rs".into(), "a[".into()];
        let message = refused(bad_glob).message().to_string();
        assert!(message.starts_with("invalid glob \"a[\": "), "{message}");

        let mut empty_glob = query();
        empty_glob.globs = vec![String::new()];
        assert!(refused(empty_glob).message().starts_with("invalid glob \"\""));

        let mut dir_glob = query();
        dir_glob.globs = vec!["*.rs".into(), "sub/*.txt".into()];
        assert_eq!(
            refused(dir_glob).message(),
            "glob \"sub/*.txt\" names a directory; globs match file names, use a path filter for directories"
        );
    }

    #[test]
    fn invalid_filters_are_refused_with_their_index() {
        let t = tree(&[("a", "needle\n")]);
        let mut error = refused(Query::new(t.path(), vec![line("needle"), not_path("x"), line_re("a(b")]));
        assert_eq!(error.kind(), ErrorKind::Service);
        let message = error.message().to_string();
        assert!(message.starts_with("invalid filter `a(b`: "), "{message}");
        assert!(message.contains("unclosed group"), "{message}");
        assert_eq!(error.take_data::<FilterErrorData>(), Some(FilterErrorData { filter: Some(2) }));

        let mut error = refused(Query::new(t.path(), vec![line("")]));
        assert!(error.message().contains("empty"), "{}", error.message());
        assert_eq!(error.take_data::<FilterErrorData>(), Some(FilterErrorData { filter: Some(0) }));
    }

    #[test]
    fn a_search_without_include_line_filter_is_refused() {
        let t = tree(&[("a", "needle\n")]);
        for filters in [vec![], vec![not_line("x"), path("a")]] {
            let mut error = refused(Query::new(t.path(), filters));
            assert_eq!(error.message(), "a search needs an include line filter");
            assert_eq!(error.take_data::<FilterErrorData>(), Some(FilterErrorData { filter: None }));
        }
    }

    #[test]
    fn bad_directories_are_refused() {
        let t = tree(&[("file", "needle\n")]);
        let query = |dir: &str| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.dir = dir.to_string();
            q
        };
        let error = refused(query("relative/dir"));
        assert_eq!(error.message(), "grep directory is not an absolute path: relative/dir");

        let missing = t.path().join("missing");
        let message = refused(query(missing.to_str().unwrap())).message().to_string();
        assert!(message.starts_with(&format!("grep directory {} cannot be used: ", missing.display())), "{message}");

        let file = t.path().join("file");
        let message = refused(query(file.to_str().unwrap())).message().to_string();
        assert_eq!(message, format!("grep directory is not a directory: {}", file.display()));
    }

    #[test]
    fn extra_ignores_apply_and_invalid_ones_are_refused() {
        let t = tree(&[("a.txt", "needle\n"), ("gen/b.txt", "needle\n"), ("c.min.js", "needle\n")]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.ignores = vec!["/gen/".into(), "*.min.js".into()];
        // Extra lines are not ignore files: they apply with `no-ignore` too.
        q.no_ignore = true;
        assert_eq!(run(q).paths(), ["a.txt"]);

        let mut bad = Query::new(t.path(), vec![line("needle")]);
        bad.ignores = vec!["ok.txt".into(), "[z-a]".into()];
        let message = refused(bad).message().to_string();
        assert!(message.starts_with("invalid ignore pattern \"[z-a]\": "), "{message}");
    }

    #[test]
    fn a_search_called_without_a_stream_is_a_protocol_error() {
        let t = tree(&[("a", "needle\n")]);
        let error = host().call::<Item>(Query::new(t.path(), vec![line("needle")]).request()).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::Protocol);
    }

    /// A tree of `count` files in 20 directories, each with one line `needle N`.
    fn big_tree(count: usize) -> TempDir {
        let t = TempDir::new().unwrap();
        for d in 0..20 {
            std::fs::create_dir(t.path().join(format!("d{d:02}"))).unwrap();
        }
        for i in 0..count {
            std::fs::write(t.path().join(format!("d{:02}/f{i:05}", i % 20)), format!("needle {i}\n")).unwrap();
        }
        t
    }

    fn threads() -> usize {
        std::thread::available_parallelism().map_or(1, |n| n.get())
    }

    /// The host has no "cancelled" end of a stream (Elisp reports it itself in `emrs-cancel`); what can be seen
    /// is that nothing more arrives and that the search task ends early.
    #[test]
    fn a_cancelled_search_stops() {
        let count = 3000;
        let t = big_tree(count);
        let mut host = host();
        let mut q = Query::new(t.path(), vec![line("needle")]);
        // Everything is streamed as found, and nothing is drained: the threads block at the stream's capacity.
        q.sort_budget_ms = 0;
        let call = host.begin_stream(q.request()).unwrap();
        std::thread::sleep(Duration::from_millis(100));
        let cancelled = Instant::now();
        host.cancel(call);
        let ended = hook::wait(t.path(), 1, Duration::from_secs(10));
        assert!(cancelled.elapsed() < Duration::from_secs(2), "{:?}", cancelled.elapsed());
        let [Ended::Cancelled(searched)] = ended[..] else { panic!("{ended:?}") };
        // Every file matches, so a thread cannot get past a file while the stream is full.
        assert!(searched <= STREAM_CAPACITY + threads(), "searched {searched} of {count} files");
        assert_eq!(host.items_received(call), 0, "the items of a cancelled call are discarded");

        // The instance keeps working.
        let found = Found::from_stream(host.call_stream::<Item>(q_all(t.path())).unwrap());
        assert_eq!(found.summary.files_matched, count);
    }

    fn q_all(dir: &std::path::Path) -> Request {
        Query::new(dir, vec![line("needle")]).request()
    }

    #[test]
    fn a_search_cancelled_while_it_collects_stops() {
        let t = big_tree(3000);
        let mut host = host();
        // The default budget: the search is cancelled while it still collects for sorting, or just after.
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.sort_budget_ms = default_sort_budget_ms();
        let call = host.begin_stream(q.request()).unwrap();
        host.cancel(call);
        let ended = hook::wait(t.path(), 1, Duration::from_secs(10));
        assert!(matches!(ended[..], [Ended::Cancelled(_)]), "{ended:?}");
    }

    #[test]
    fn stopping_the_instance_ends_a_running_search() {
        let t = big_tree(3000);
        let mut host = host();
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.sort_budget_ms = 0;
        host.begin_stream(q.request()).unwrap();
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(host.stop(), State::Stopped);
        let ended = hook::wait(t.path(), 1, Duration::from_secs(10));
        assert!(matches!(ended[..], [Ended::Cancelled(_)]), "{ended:?}");
    }

    #[test]
    fn two_searches_at_the_same_time_both_complete() {
        let a = big_tree(600);
        let b = big_tree(400);
        let mut host = host();
        let mut qa = Query::new(a.path(), vec![line("needle")]);
        qa.sort_budget_ms = 0;
        let call_a = host.begin_stream(qa.request()).unwrap();
        let call_b = host.begin_stream(Query::new(b.path(), vec![line_re("needle [0-9]*7$")]).request()).unwrap();
        let types = host.call::<Vec<TypeDef>>(Request::Types).unwrap();
        assert!(!types.is_empty(), "the instance answers while searches run");
        let found_b = Found::from_stream(host.finish_stream::<Item>(call_b));
        let found_a = Found::from_stream(host.finish_stream::<Item>(call_a));
        assert_eq!((found_a.summary.files_matched, found_a.summary.lines, found_a.summary.sorted), (600, 600, false));
        assert_eq!((found_b.summary.files_matched, found_b.summary.files_searched), (40, 400));
        assert!(found_b.summary.sorted);
        assert!(found_b.files.iter().all(|f| f.lines[0].text.ends_with('7')));
    }

    #[test]
    fn a_slow_consumer_gets_everything() {
        // More file items than the stream holds: the search blocks until the host drains, and nothing is lost.
        let count = STREAM_CAPACITY * 4;
        let t = big_tree(count);
        let mut host = host();
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.sort_budget_ms = 0;
        let call = host.begin_stream(q.request()).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        assert!(hook::wait(t.path(), 1, Duration::ZERO).is_empty(), "the search waits for the consumer");
        let found = Found::from_stream(host.finish_stream::<Item>(call));
        assert_eq!(found.files.len(), count);
        assert_eq!(found.summary.lines, count);
    }
}
