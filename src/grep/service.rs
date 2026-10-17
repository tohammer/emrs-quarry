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
//! | `:file-types` | list of strings: names from `(:types)`; a file must be of one of them; may be combined with `:globs`, a file must pass both | nil: all files |
//! | `:globs` | list of strings: gitignore-style path globs relative to `:dir`, like `rg -g`: `("*.el" "src/**" "!*.min.js")`. A glob without `/` matches a name at any depth, one with a `/` at its start or inside a path below `:dir` (a `/` at the end only says "a directory": `!vendor/` is every directory `vendor`), `**` crosses directories, a leading `!` excludes, the last glob that matches decides; with a glob that has no `!`, a file must match one, so name files, not their directory (`src/**`, not `src/`). An excluding glob that matches a directory keeps the walk out of it (`!gen/`; `!gen/**` drops the files one by one). Case-sensitive. A file must also be of one of the `:file-types` if any are given. Globs only restrict: they never bring back a file that an ignore file names or that is hidden (ADR 0017) | nil: all files |
//! | `:no-ignore` | non-nil: `.gitignore`, `.ignore` and the git exclude files are not applied | nil |
//! | `:hidden` | search hidden files; say `:hidden nil` to leave out every file and directory whose name starts with a dot, whatever the file types or globs (a glob cannot bring a hidden file back) | t |
//! | `:ignores` | list of strings: extra gitignore lines relative to `:dir` | nil |
//! | `:max-lines` | integer: the search stops when this many kept lines are collected (with `:count-up-to`, see that key) | 50000 |
//! | `:count-up-to` | integer: when `:max-lines` is reached, the search sends nothing more but goes on counting kept lines until there are this many in all or the walk ends, for `:total` (ADR 0025). A value at or below `:max-lines` counts nothing beyond it | nil: no counting, no `:total` |
//! | `:max-columns` | integer: longer lines are cut after this many characters | 500 |
//! | `:before` | integer ≥ 0: lines sent before each kept line as context lines, at most 1000 | 0 |
//! | `:after` | integer ≥ 0: lines sent after each kept line as context lines, at most 1000 | 0 |
//! | `:sort-budget-ms` | integer: how long results are collected to be sent sorted | 150 |
//! | `:replace` | string: a replacement template for the primary filter's matches, in the syntax of `rg -r`: `$0` is the whole match, `$1` or `${1}` a group by number, `$name` or `${name}` a group by name, `$$` a literal `$`. A name runs as far as ASCII letters, digits and `_` go, so `$1a` is the group named `1a` (write `${1}a`). A group that does not exist or did not take part gives the empty string; a literal primary filter has only `$0`. Not checked: every string is a template | nil: no `:replacements` |
//!
//! A *kept line* is a line that the primary filter (the first include line filter) matched and the other line
//! filters kept. A *context line* is a line of the same file that is not kept and lies at most `:before` lines
//! before or at most `:after` lines after a kept line (ADR 0014). Line filters are not applied to context lines,
//! so a line that an exclude line filter dropped can be one. Larger values of `:before` and `:after` are taken
//! as 1000, without an error.
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
//! | A `:file-types` entry is not a name from `(:types)` (the first one is named) | `unknown file type: NAME` | |
//! | A glob names nothing: empty or blank, `!`, `/` | `invalid glob "GLOB": it is empty` | |
//! | A glob is invalid | `invalid glob "GLOB": MESSAGE` | |
//! | An `:ignores` line is invalid | `invalid ignore pattern "LINE": MESSAGE` | |
//!
//! **Stream items** are of two kinds, told apart by their first element.
//!
//! A file item, one per file with kept lines:
//!
//! ```elisp
//! (:file :path "src/walk.rs" :path-spans ((4 8)) :mtime 1760103296123
//!        :lines ((:n 168 :text "#[inline]" :spans nil :secondary nil :inexact nil :context t)
//!                (:n 169 :text "pub fn walk(" :spans ((4 11)) :secondary ((0 3)) :inexact nil)
//!                ...))
//! ```
//!
//! - `:path` is relative to `:dir`, `/`-separated. `:path-spans` are the parts of it matched by include path
//!   filters, sorted and merged; nil without such filters.
//! - `:mtime` is the file's modification time in milliseconds since the Unix epoch, rounded down, as an integer
//!   (nil if the file system did not tell). It is read when the file is opened, before its content.
//! - `:lines` are the kept lines and their context lines, in ascending line number, each line once. `:n` counts
//!   from 1. `:text` is the line without `\n` or `\r\n`. Gaps are not marked: two neighbours whose `:n` differ
//!   by more than 1 have lines between them that were not sent.
//! - `:context` is t on a context line; a kept line has no `:context`. A context line has `:n`, `:text` and
//!   `:inexact` with the meaning they have for a kept line, and `:spans` and `:secondary` nil. Without `:before`
//!   and `:after` there are no context lines.
//! - `:spans` are the matches of the primary filter (the first include line filter), `:secondary` those of the
//!   other include line filters where they lie outside the primary matches. Both are lists of `(START END)`,
//!   character offsets into `:text` counted from 0, `END` exclusive, ascending and not overlapping; nil when
//!   empty.
//! - `:inexact` is t when `:text` is not exactly the file's line: it was cut after `:max-columns` characters, or
//!   the line held bytes that are not valid UTF-8 (each shown as U+FFFD). The matches are found on the whole
//!   line and listed as positions in `:text` as sent: a match that crosses the cut ends at the cut, a match
//!   beyond it is not listed.
//! - `:replacements` only with `:replace`, and only on a kept line whose `:inexact` is nil: a list of strings,
//!   one per entry of `:spans` and in the same order, each the template interpolated for that match, on the
//!   whole line as the matching is done (`:replacements ("new_a" "new_b")`). A kept line with `:inexact` t and
//!   a context line have no `:replacements`; without `:replace` no line has it. Empty matches are in neither
//!   list, nor is a match of a byte-level pattern that lies inside one character (empty as characters).
//!
//! The summary item, exactly one, the last item of a search that was not cancelled:
//!
//! ```elisp
//! (:summary :files-searched 19 :files-matched 2 :lines 7 :truncated nil :sorted t :millis 61 :skipped 0)
//! ```
//!
//! - `:files-searched`: files opened and read (binary files included, they give no lines). `:files-matched`:
//!   the number of file items. `:lines`: the kept lines in them, never more than `:max-lines`; context lines
//!   are not counted, here or for `:max-lines`.
//! - `:truncated`: `:lines` reached `:max-lines`. Without `:count-up-to` the search stopped there; with it,
//!   nothing more was sent and the walk went on counting (see `:total`). The kept line that filled the cap
//!   has its context lines before it; those after it may be missing.
//! - `:total`: only with `:count-up-to` and `:truncated` t, after `:skipped`: the kept lines of the whole tree,
//!   delivered or not, counted as for `:max-lines` but at most `:count-up-to` (`:total 73412`). `:total` below
//!   `:count-up-to` is exact; equal to it means at least that many. A file found binary counts nothing beyond
//!   `:max-lines`. With `:count-up-to` at or below `:max-lines` it is `:count-up-to`.
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
use ignore::overrides::{Override, OverrideBuilder};
use ignore::types::{Types, TypesBuilder};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Capacity of the `(:search)` stream, in items (files).
const STREAM_CAPACITY: usize = 256;

/// The most context lines per side that a search uses. The searcher keeps the last `before` lines of every file
/// in its buffer, with or without a match, so a huge `:before` would buffer whole files, per thread. Larger
/// `:before` and `:after` are clamped to this, not refused.
const MAX_CONTEXT: usize = 1000;

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

// One request is made per call and moved into `handle` at once; a box would only cost an allocation.
#[allow(clippy::large_enum_variant)]
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
        file_types: Vec<String>,
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
        #[serde(default)]
        before: usize,
        #[serde(default)]
        after: usize,
        #[serde(default = "default_sort_budget_ms")]
        sort_budget_ms: u64,
        #[serde(default)]
        replace: Option<String>,
        #[serde(default)]
        count_up_to: Option<usize>,
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

/// The file types of a search, if any are asked for (`:file-types`; the walker applies them). A file must be of
/// one of them: selecting several types gives their union.
fn file_types(names: &[String]) -> Result<Option<Types>, String> {
    if names.is_empty() {
        return Ok(None);
    }
    let mut builder = TypesBuilder::new();
    builder.add_defaults();
    for name in names {
        // Not left to `build`: it would take `all` for a name.
        if !builder.definitions().iter().any(|def| def.name() == name) {
            return Err(format!("unknown file type: {name}"));
        }
        builder.select(name);
    }
    builder.build().map(Some).map_err(|e| e.to_string())
}

/// The path globs of a search, compiled relative to `dir`; `None` for no globs. The search asks the matcher
/// after the walker's own rules (ADR 0017), so a glob only takes files away.
///
/// The matcher reads a glob as a line of a gitignore file and would drop some lines without a word, leaving the
/// search unrestricted: a line that starts with `#` is a comment there, so that `#` is escaped here (`#*#` are
/// Emacs's auto-save files); a glob that names nothing (`""`, `"!"`, `"/"`, blanks) is refused.
fn path_globs(dir: &Path, globs: &[String]) -> Result<Option<Override>, String> {
    if globs.is_empty() {
        return Ok(None);
    }
    let mut builder = OverrideBuilder::new(dir);
    for glob in globs {
        let name = glob.trim_end();
        let name = name.strip_prefix('!').unwrap_or(name);
        if name.is_empty() || name == "/" {
            return Err(format!("invalid glob {glob:?}: it is empty"));
        }
        let escaped;
        let line = if glob.starts_with('#') {
            escaped = format!("\\{glob}");
            &escaped
        } else {
            glob
        };
        builder.add(line).map_err(|e| match e {
            ignore::Error::Glob { err, .. } => format!("invalid glob {glob:?}: {err}"),
            e => format!("invalid glob {glob:?}: {e}"),
        })?;
    }
    match builder.build() {
        Ok(globs) => Ok(Some(globs)),
        Err(e) => Err(format!("invalid glob: {e}")),
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
                file_types: type_names,
                globs,
                no_ignore,
                hidden,
                ignores,
                max_lines,
                max_columns,
                before,
                after,
                sort_budget_ms,
                replace,
                count_up_to,
            } => {
                let dir = match search_dir(&dir) {
                    Ok(dir) => dir,
                    Err(message) => return reply.err(Error::new(message)),
                };
                let filters = match Filters::compile(&filters, case) {
                    Ok(filters) => filters,
                    Err(e) => return reply.err(Error::with_data(e.message, FilterErrorData { filter: e.index })),
                };
                let types = match file_types(&type_names) {
                    Ok(types) => types,
                    Err(message) => return reply.err(Error::new(message)),
                };
                let globs = match path_globs(&dir, &globs) {
                    Ok(globs) => globs,
                    Err(message) => return reply.err(Error::new(message)),
                };
                let config = Config {
                    dir,
                    filters,
                    types,
                    globs,
                    use_ignore_files: !no_ignore,
                    include_hidden: hidden,
                    ignores,
                    max_lines,
                    max_columns,
                    before: before.min(MAX_CONTEXT),
                    after: after.min(MAX_CONTEXT),
                    sort_budget: Duration::from_millis(sort_budget_ms),
                    started,
                    replace,
                    count_up_to,
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
        pub file_types: Vec<String>,
        pub globs: Vec<String>,
        pub no_ignore: bool,
        pub hidden: bool,
        pub ignores: Vec<String>,
        pub max_lines: usize,
        pub max_columns: usize,
        pub before: usize,
        pub after: usize,
        pub sort_budget_ms: u64,
        pub replace: Option<String>,
        pub count_up_to: Option<usize>,
    }

    impl Query {
        pub(crate) fn new(dir: &Path, filters: Vec<FilterSpec>) -> Query {
            Query {
                dir: dir.to_str().unwrap().to_string(),
                filters,
                case: Case::Smart,
                file_types: Vec::new(),
                globs: Vec::new(),
                no_ignore: false,
                hidden: true,
                ignores: Vec::new(),
                max_lines: default_max_lines(),
                max_columns: default_max_columns(),
                before: 0,
                after: 0,
                sort_budget_ms: 60_000,
                replace: None,
                count_up_to: None,
            }
        }

        pub(crate) fn request(self) -> Request {
            Request::Search {
                dir: self.dir,
                filters: self.filters,
                case: self.case,
                file_types: self.file_types,
                globs: self.globs,
                no_ignore: self.no_ignore,
                hidden: self.hidden,
                ignores: self.ignores,
                max_lines: self.max_lines,
                max_columns: self.max_columns,
                before: self.before,
                after: self.after,
                sort_budget_ms: self.sort_budget_ms,
                replace: self.replace,
                count_up_to: self.count_up_to,
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
                Some(Item::Summary {
                    files_searched,
                    files_matched,
                    lines,
                    truncated,
                    sorted,
                    millis,
                    skipped,
                    total,
                }) => Summary { files_searched, files_matched, lines, truncated, sorted, millis, skipped, total },
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

        /// The lines of `path` as `grep` marks them: `"2- 3: 4-"` is the kept line 3 between two context lines.
        pub(crate) fn marks(&self, path: &str) -> String {
            let marks: Vec<String> =
                self.lines(path).iter().map(|l| format!("{}{}", l.n, if l.context { '-' } else { ':' })).collect();
            marks.join(" ")
        }

        pub(crate) fn total_lines(&self) -> usize {
            self.files.iter().map(|f| f.lines.len()).sum()
        }

        /// The kept lines of all files.
        pub(crate) fn total_kept(&self) -> usize {
            self.files.iter().flat_map(|f| &f.lines).filter(|l| !l.context).count()
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
    fn file_types_restrict_the_files() {
        let t =
            tree(&[("a.rs", "needle\n"), ("b.txt", "needle\n"), ("sub/c.rs", "needle\n"), ("sub/d.el", "needle\n")]);
        assert_eq!(find(t.path(), "needle").paths(), ["a.rs", "b.txt", "sub/c.rs", "sub/d.el"]);

        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.file_types = vec!["rust".into()];
        let found = run(q);
        assert_eq!(found.paths(), ["a.rs", "sub/c.rs"]);
        assert_eq!(found.summary.files_searched, 2, "other files are not opened");
    }

    #[test]
    fn several_file_types_give_the_union_of_their_files() {
        let t = tree(&[("a.rs", "needle\n"), ("b.txt", "needle\n"), ("sub/c.el", "needle\n"), ("d.md", "needle\n")]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.file_types = vec!["rust".into(), "elisp".into()];
        let found = run(q);
        assert_eq!(found.paths(), ["a.rs", "sub/c.el"]);
        assert_eq!(found.summary.files_searched, 2, "other files are not opened");

        // A name given twice counts once.
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.file_types = vec!["rust".into(), "rust".into()];
        assert_eq!(run(q).paths(), ["a.rs"]);
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
    fn globs_with_a_slash_and_double_star_match_paths() {
        let t = tree(&[
            ("a.rs", "needle\n"),
            ("src/b.rs", "needle\n"),
            ("src/deep/c.rs", "needle\n"),
            ("other/src/d.rs", "needle\n"),
            ("src/e.txt", "needle\n"),
        ]);
        let search = |globs: &[&str]| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.globs = globs.iter().map(|g| g.to_string()).collect();
            run(q)
        };
        assert_eq!(search(&["src/*.rs"]).paths(), ["src/b.rs"]);
        assert_eq!(search(&["src/**"]).paths(), ["src/b.rs", "src/deep/c.rs", "src/e.txt"]);
        assert_eq!(search(&["src/**/*.rs"]).paths(), ["src/b.rs", "src/deep/c.rs"]);
        assert_eq!(search(&["**/src/*.rs"]).paths(), ["other/src/d.rs", "src/b.rs"]);
        assert_eq!(search(&["*.rs"]).paths(), ["a.rs", "other/src/d.rs", "src/b.rs", "src/deep/c.rs"]);
        assert_eq!(search(&["*.RS"]).paths(), Vec::<&str>::new(), "case-sensitive");
    }

    #[test]
    fn excluding_globs_take_files_away_and_the_last_match_decides() {
        let t = tree(&[
            ("a.js", "needle\n"),
            ("a.min.js", "needle\n"),
            ("sub/b.js", "needle\n"),
            ("sub/b.min.js", "needle\n"),
            ("c.txt", "needle\n"),
        ]);
        let search = |globs: &[&str]| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.globs = globs.iter().map(|g| g.to_string()).collect();
            run(q)
        };
        // Only excluding globs: everything else stays.
        assert_eq!(search(&["!*.min.js"]).paths(), ["a.js", "c.txt", "sub/b.js"]);
        assert_eq!(search(&["*.js", "!*.min.js"]).paths(), ["a.js", "sub/b.js"]);
        // The later glob wins, in both directions.
        assert_eq!(search(&["!*.min.js", "*.js"]).paths(), ["a.js", "a.min.js", "sub/b.js", "sub/b.min.js"]);
        assert_eq!(search(&["*.js", "!*.min.js", "sub/*.min.js"]).paths(), ["a.js", "sub/b.js", "sub/b.min.js"]);
    }

    #[test]
    fn an_excluding_glob_that_matches_a_directory_keeps_the_walk_out_of_it() {
        let t = tree(&[("a.txt", "needle\n"), ("vendor/x.txt", "needle\n"), ("vendor/deep/y.txt", "needle\n")]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.globs = vec!["!vendor".into()];
        let found = run(q);
        assert_eq!(found.paths(), ["a.txt"]);
        assert_eq!(found.summary.files_searched, 1, "the files below vendor are not opened");

        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.globs = vec!["!vendor/".into()];
        assert_eq!(run(q).paths(), ["a.txt"]);

        // As in a gitignore file, a later glob does not bring back a file below an excluded directory.
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.globs = vec!["!vendor".into(), "vendor/x.txt".into()];
        assert_eq!(run(q).paths(), Vec::<&str>::new());
    }

    #[test]
    fn file_types_and_globs_together_must_both_match() {
        let t =
            tree(&[("a.rs", "needle\n"), ("b.txt", "needle\n"), ("sub/c.rs", "needle\n"), ("sub/d.rs", "needle\n")]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.file_types = vec!["rust".into()];
        q.globs = vec!["sub/*".into(), "b.txt".into()];
        let found = run(q);
        assert_eq!(found.paths(), ["sub/c.rs", "sub/d.rs"]);

        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.file_types = vec!["rust".into()];
        q.globs = vec!["!sub/d.rs".into()];
        assert_eq!(run(q).paths(), ["a.rs", "sub/c.rs"]);

        // Several types are alternatives; the globs narrow them all.
        let t = tree(&[
            ("a.rs", "needle\n"),
            ("a_test.el", "needle\n"),
            ("b.el", "needle\n"),
            ("b_test.txt", "needle\n"),
            ("sub/c_test.rs", "needle\n"),
        ]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.file_types = vec!["rust".into(), "elisp".into()];
        q.globs = vec!["*test*".into()];
        assert_eq!(run(q).paths(), ["a_test.el", "sub/c_test.rs"]);

        // No file passes both: no hits, no error.
        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.file_types = vec!["elisp".into()];
        q.globs = vec!["*.rs".into()];
        assert_eq!(run(q).paths(), Vec::<&str>::new());

        let mut q = Query::new(t.path(), vec![line("needle")]);
        q.file_types = vec!["rust".into(), "elisp".into()];
        q.globs = vec!["!*test*".into()];
        assert_eq!(run(q).paths(), ["a.rs", "b.el"]);
    }

    #[test]
    fn globs_never_bring_back_ignored_or_hidden_files() {
        let t = tree(&[
            (".gitignore", "ignored.txt\n"),
            ("ignored.txt", "needle\n"),
            ("seen.txt", "needle\n"),
            (".hidden.txt", "needle\n"),
            (".hd/x.txt", "needle\n"),
        ]);
        let search = |hidden: bool, no_ignore: bool, globs: &[&str]| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.hidden = hidden;
            q.no_ignore = no_ignore;
            q.globs = globs.iter().map(|g| g.to_string()).collect();
            run(q).paths().into_iter().map(String::from).collect::<Vec<_>>()
        };
        assert_eq!(search(false, false, &["*.txt", "ignored.txt", ".hidden.txt", ".hd/**"]), ["seen.txt"]);
        assert_eq!(search(true, false, &["*.txt", "ignored.txt"]), [".hd/x.txt", ".hidden.txt", "seen.txt"]);
        assert_eq!(search(true, true, &["*.txt"]), [".hd/x.txt", ".hidden.txt", "ignored.txt", "seen.txt"]);
    }

    #[test]
    fn hidden_files_stay_out_with_file_types_or_globs() {
        let files = [".hidden.txt", "seen.txt", ".hd/x.txt", "sub/y.txt", "sub/.z.txt", "other.rs"];
        let t = TempDir::new().unwrap();
        for file in files {
            write(t.path(), file, "needle\n");
        }
        let search = |hidden: bool, file_types: &[&str], globs: &[&str]| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.hidden = hidden;
            q.file_types = file_types.iter().map(|t| t.to_string()).collect();
            q.globs = globs.iter().map(|g| g.to_string()).collect();
            run(q)
        };
        let found = search(false, &[], &["*.txt"]);
        assert_eq!(found.paths(), ["seen.txt", "sub/y.txt"]);
        assert_eq!(found.summary.files_searched, 2);
        assert_eq!(search(false, &["txt"], &[]).paths(), ["seen.txt", "sub/y.txt"]);
        assert_eq!(search(false, &[], &[]).paths(), ["other.rs", "seen.txt", "sub/y.txt"]);
        let all_txt = [".hd/x.txt", ".hidden.txt", "seen.txt", "sub/.z.txt", "sub/y.txt"];
        assert_eq!(search(true, &[], &["*.txt"]).paths(), all_txt);
        assert_eq!(search(true, &["txt"], &[]).paths(), all_txt);
        assert_eq!(search(false, &["txt", "rust"], &[]).paths(), ["other.rs", "seen.txt", "sub/y.txt"]);
        assert_eq!(search(false, &["txt", "rust"], &["*.rs"]).paths(), ["other.rs"]);
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
        unknown.file_types = vec!["nosuchtype".into()];
        let error = refused(unknown);
        assert_eq!(error.kind(), ErrorKind::Service);
        assert_eq!(error.message(), "unknown file type: nosuchtype");

        let mut all = query();
        all.file_types = vec!["all".into()];
        assert_eq!(refused(all).message(), "unknown file type: all");

        let mut among = query();
        among.file_types = vec!["rust".into(), "nope".into(), "alsonot".into(), "txt".into()];
        assert_eq!(refused(among).message(), "unknown file type: nope");

        let mut empty = query();
        empty.file_types = vec!["rust".into(), String::new()];
        assert_eq!(refused(empty).message(), "unknown file type: ");

        let mut bad_glob = query();
        bad_glob.globs = vec!["*.rs".into(), "a[".into()];
        let message = refused(bad_glob).message().to_string();
        assert!(message.starts_with("invalid glob \"a[\": "), "{message}");

        let mut empty_glob = query();
        empty_glob.globs = vec![String::new()];
        assert_eq!(refused(empty_glob).message(), "invalid glob \"\": it is empty");

        let mut lone_bang = query();
        lone_bang.globs = vec!["!".into()];
        assert_eq!(refused(lone_bang).message(), "invalid glob \"!\": it is empty");

        // The matcher would drop these lines without a word and search everything.
        for nothing in [" ", "/", "!/", "! "] {
            let mut q = query();
            q.globs = vec![nothing.into()];
            assert_eq!(refused(q).message(), format!("invalid glob {nothing:?}: it is empty"));
        }
    }

    #[test]
    fn a_glob_that_starts_with_a_hash_is_a_glob_not_a_comment() {
        // Not `#a#`: a global git exclude file often names Emacs's auto-save files.
        let t = tree(&[("#a.c", "needle\n"), ("b.c", "needle\n"), ("sub/#d.c", "needle\n")]);
        let search = |globs: &[&str]| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.globs = globs.iter().map(|g| g.to_string()).collect();
            run(q)
        };
        assert_eq!(search(&["#*.c"]).paths(), ["#a.c", "sub/#d.c"]);
        assert_eq!(search(&["!#*.c"]).paths(), ["b.c"]);
        assert_eq!(search(&["b.*", "#d.c"]).paths(), ["b.c", "sub/#d.c"]);
    }

    #[test]
    fn a_slash_at_the_end_of_a_glob_does_not_anchor_it() {
        let t = tree(&[("vendor/a", "needle\n"), ("sub/vendor/b", "needle\n"), ("src/c", "needle\n")]);
        let search = |globs: &[&str]| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            q.globs = globs.iter().map(|g| g.to_string()).collect();
            run(q)
        };
        assert_eq!(search(&["!vendor/"]).paths(), ["src/c"]);
        assert_eq!(search(&["!/vendor/"]).paths(), ["src/c", "sub/vendor/b"]);
        // An including glob must name files: the directory alone selects nothing.
        assert_eq!(search(&["src/"]).paths(), Vec::<&str>::new());
        assert_eq!(search(&["src/**"]).paths(), ["src/c"]);
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

    #[test]
    fn context_lines_come_with_the_context_flag() {
        let t = tree(&[("a", "one\ntwo\nneedle\nfour\nfive\n")]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        (q.before, q.after) = (1, 2);
        let result = host().call_stream::<Item>(q.request()).unwrap();
        let [Item::File { path, lines, .. }, Item::Summary { lines: counted, truncated: false, .. }] =
            &result.items[..]
        else {
            panic!("{:?}", result.items)
        };
        assert_eq!(path, "a");
        let shape: Vec<(u64, &str, bool)> = lines.iter().map(|l| (l.n, l.text.as_str(), l.context)).collect();
        assert_eq!(shape, [(2, "two", true), (3, "needle", false), (4, "four", true), (5, "five", true)]);
        assert_eq!(lines[1].spans, [(0, 6)]);
        assert!(lines.iter().filter(|l| l.context).all(|l| l.spans.is_empty() && l.secondary.is_empty()));
        assert_eq!(*counted, 1, "the summary counts kept lines");
    }

    #[test]
    fn a_request_without_context_returns_no_context_lines() {
        let t = tree(&[("a", "one\ntwo\nneedle\nfour\nfive\n")]);
        // `Query::new` sends 0 for both fields. The Host bypasses decoding, so the serde default for a request
        // that leaves them out is covered by the Elisp tests.
        let found = run(Query::new(t.path(), vec![line("needle")]));
        assert_eq!(found.texts("a"), [(3, "needle")]);
        assert!(found.files.iter().flat_map(|f| &f.lines).all(|l| !l.context));
    }

    #[test]
    fn context_counts_above_the_limit_are_reduced_to_it() {
        let numbered: String =
            (1..=2500).map(|i| if i == 1250 { "needle\n".to_string() } else { format!("l{i}\n") }).collect();
        let t = tree(&[("a", numbered.as_str())]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        (q.before, q.after) = (usize::MAX, usize::MAX);
        let found = run(q);
        let lines = found.lines("a");
        assert_eq!(lines.len(), 2 * MAX_CONTEXT + 1);
        assert_eq!(lines.iter().filter(|l| l.context && l.n < 1250).count(), MAX_CONTEXT);
        assert_eq!(lines.iter().filter(|l| l.context && l.n > 1250).count(), MAX_CONTEXT);
        assert_eq!((lines[0].n, lines[lines.len() - 1].n), (250, 2250));
    }

    #[test]
    fn a_context_count_of_exactly_the_limit_is_not_reduced() {
        let numbered: String =
            (1..=2500).map(|i| if i == 1250 { "needle\n".to_string() } else { format!("l{i}\n") }).collect();
        let t = tree(&[("a", numbered.as_str())]);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        (q.before, q.after) = (MAX_CONTEXT, MAX_CONTEXT);
        let found = run(q);
        assert_eq!(found.lines("a").len(), 2 * MAX_CONTEXT + 1);
        let mut q = Query::new(t.path(), vec![line("needle")]);
        (q.before, q.after) = (999, 3);
        let found = run(q);
        assert_eq!(found.lines("a").len(), 999 + 3 + 1);
    }

    /// The field names a value serializes, in order: the keywords of its Lisp plist. The `Host` hands the
    /// items over as Rust values and emrs keeps its Lisp conversion private, so the tests see what serde gives
    /// it through this serializer, which accepts a struct or a struct variant only and does not look at the field
    /// values.
    fn field_names<T: serde::Serialize>(value: &T) -> Vec<&'static str> {
        use serde::ser::{Impossible, SerializeStruct, SerializeStructVariant, Serializer};
        use std::fmt::Error as Refused;

        struct Names;
        struct Fields(Vec<&'static str>);
        type Never = Impossible<Vec<&'static str>, Refused>;

        macro_rules! refuse {
            ($($method:ident($($arg:ty),*);)*) => {
                $(fn $method(self, $(_: $arg),*) -> Result<Vec<&'static str>, Refused> { Err(Refused) })*
            };
        }

        impl SerializeStruct for Fields {
            type Ok = Vec<&'static str>;
            type Error = Refused;
            fn serialize_field<V: ?Sized + serde::Serialize>(
                &mut self,
                key: &'static str,
                _: &V,
            ) -> Result<(), Refused> {
                self.0.push(key);
                Ok(())
            }
            fn end(self) -> Result<Vec<&'static str>, Refused> {
                Ok(self.0)
            }
        }

        impl SerializeStructVariant for Fields {
            type Ok = Vec<&'static str>;
            type Error = Refused;
            fn serialize_field<V: ?Sized + serde::Serialize>(
                &mut self,
                key: &'static str,
                value: &V,
            ) -> Result<(), Refused> {
                SerializeStruct::serialize_field(self, key, value)
            }
            fn end(self) -> Result<Vec<&'static str>, Refused> {
                Ok(self.0)
            }
        }

        impl Serializer for Names {
            type Ok = Vec<&'static str>;
            type Error = Refused;
            type SerializeSeq = Never;
            type SerializeTuple = Never;
            type SerializeTupleStruct = Never;
            type SerializeTupleVariant = Never;
            type SerializeMap = Never;
            type SerializeStruct = Fields;
            type SerializeStructVariant = Fields;
            refuse! {
                serialize_bool(bool); serialize_i8(i8); serialize_i16(i16); serialize_i32(i32); serialize_i64(i64);
                serialize_u8(u8); serialize_u16(u16); serialize_u32(u32); serialize_u64(u64); serialize_f32(f32);
                serialize_f64(f64); serialize_char(char); serialize_str(&str); serialize_bytes(&[u8]);
                serialize_none(); serialize_unit(); serialize_unit_struct(&'static str);
                serialize_unit_variant(&'static str, u32, &'static str);
            }
            fn serialize_some<V: ?Sized + serde::Serialize>(self, _: &V) -> Result<Self::Ok, Refused> {
                Err(Refused)
            }
            fn serialize_newtype_struct<V: ?Sized + serde::Serialize>(
                self,
                _: &'static str,
                _: &V,
            ) -> Result<Self::Ok, Refused> {
                Err(Refused)
            }
            fn serialize_newtype_variant<V: ?Sized + serde::Serialize>(
                self,
                _: &'static str,
                _: u32,
                _: &'static str,
                _: &V,
            ) -> Result<Self::Ok, Refused> {
                Err(Refused)
            }
            fn serialize_seq(self, _: Option<usize>) -> Result<Never, Refused> {
                Err(Refused)
            }
            fn serialize_tuple(self, _: usize) -> Result<Never, Refused> {
                Err(Refused)
            }
            fn serialize_tuple_struct(self, _: &'static str, _: usize) -> Result<Never, Refused> {
                Err(Refused)
            }
            fn serialize_tuple_variant(
                self,
                _: &'static str,
                _: u32,
                _: &'static str,
                _: usize,
            ) -> Result<Never, Refused> {
                Err(Refused)
            }
            fn serialize_map(self, _: Option<usize>) -> Result<Never, Refused> {
                Err(Refused)
            }
            fn serialize_struct(self, _: &'static str, _: usize) -> Result<Fields, Refused> {
                Ok(Fields(Vec::new()))
            }
            fn serialize_struct_variant(
                self,
                _: &'static str,
                _: u32,
                _: &'static str,
                _: usize,
            ) -> Result<Fields, Refused> {
                Ok(Fields(Vec::new()))
            }
        }

        value.serialize(Names).expect("a struct or a struct variant")
    }

    #[test]
    fn replacements_are_in_the_lisp_form_only_with_a_template() {
        // Line 2 is kept by empty matches only: an exact kept line without spans.
        let t = tree(&[("a", "xax\nbbb\n")]);
        let fields = |l: &crate::grep::search::Line| field_names(l);
        let found = run(Query::new(t.path(), vec![line_re("a*")]));
        for l in found.lines("a") {
            assert_eq!(fields(l), ["n", "text", "spans", "secondary", "inexact"], "{l:?}");
        }
        let mut q = Query::new(t.path(), vec![line_re("a*")]);
        q.replace = Some("<$0>".to_string());
        let found = run(q);
        let lines = found.lines("a");
        assert_eq!(found.marks("a"), "1: 2:");
        let with = ["n", "text", "spans", "secondary", "inexact", "replacements"];
        // `:replacements ("<a>")`.
        assert_eq!(fields(&lines[0]), with);
        assert_eq!(lines[0].replacements, Some(vec!["<a>".to_string()]));
        // `:replacements nil`, present: the line can be replaced, it has nothing to change.
        assert_eq!(fields(&lines[1]), with);
        assert!(lines[1].spans.is_empty());
        assert_eq!(lines[1].replacements, Some(Vec::new()));
    }

    #[test]
    fn the_total_is_in_the_lisp_form_only_with_a_count_and_truncation() {
        let t = tree(&[("a", "needle\nneedle\nneedle\n"), ("b", "needle\n")]);
        let summary = |max_lines: usize, count_up_to: Option<usize>| {
            let mut q = Query::new(t.path(), vec![line("needle")]);
            (q.max_lines, q.count_up_to) = (max_lines, count_up_to);
            let found = run(q);
            let item: Item = found.summary.clone().into();
            (field_names(&item), found.summary.total)
        };
        let without = ["files_searched", "files_matched", "lines", "truncated", "sorted", "millis", "skipped"];
        let mut with = without.to_vec();
        with.push("total");
        // Truncated without a count, a count without truncation, and neither.
        assert_eq!(summary(2, None), (without.to_vec(), None));
        assert_eq!(summary(10, Some(100)), (without.to_vec(), None));
        assert_eq!(summary(10, None), (without.to_vec(), None));
        assert_eq!(summary(2, Some(100)), (with, Some(4)));
    }
}
