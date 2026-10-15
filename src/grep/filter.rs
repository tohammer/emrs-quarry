//! Filters of the grep service: pure logic, no I/O (spec `2026-10-10-grep.md`, section "Filters").
//!
//! A filter has a target (line or path), a direction (include or exclude), a pattern and a syntax (literal or
//! regexp). [`Filters::compile`] turns the enabled filters, in the buffer's order, into matchers. All of them are
//! `grep_regex::RegexMatcher`s, so the first include line filter (the *primary* filter) can be handed to the
//! searcher as it is ([`Filters::primary`]).
//!
//! Line filters:
//! - They are matched against the text of one line without its terminator, which is `\n` or `\r\n`. The
//!   matchers are built with `crlf(true)`, as ripgrep does with `--crlf` for the pattern it scans with: a
//!   pattern that names `\n` or `\r` is rejected as an invalid filter, and classes such as `\s`, `.` or `[^a]`
//!   never match either of them, so a match cannot run across lines or into a terminator. The primary filter,
//!   which the searcher runs on the file's bytes with the terminators in place, therefore decides as the other
//!   line filters do on the line without its terminator.
//! - `^` and `$` mean the start and the end of the line (the matchers are in multi-line mode, as in ripgrep);
//!   `$` matches before `\n` and before `\r\n`, never between the two.
//! - The price is a carriage return that is not part of a line end: no line filter can match it, and `^` and
//!   `$` also match after and before it. The search needs `grep_matcher::LineTerminator::crlf()` on its
//!   searcher, which refuses a matcher whose terminator differs from its own.
//! - The search's [`Case`] applies to each of them. `Smart` is decided per filter by the matcher builder: the
//!   filter is case-insensitive unless its own pattern has an uppercase letter (for a regexp, escapes such as
//!   `\W` or `\S` do not count).
//! - Not supported: the text anchors `\A` and `\z`, and switching multi-line mode off (`(?-m)`). Use `^` and
//!   `$`. They are not rejected, but they mean different things in the primary filter, which runs on a buffer
//!   holding many lines of the file, and in the other line filters, which run on one line at a time: `a\z` as
//!   primary filter finds at most the last line of a buffer, as another include filter it keeps every line
//!   that ends in `a`.
//!
//! Path filters:
//! - They are matched against `/` followed by the path relative to the search directory, `/`-separated. So
//!   `/test/` matches `test/a.c` and `src/test/a.c` but not `contest/a.c`, and `.rs` matches by extension.
//! - `^` is the start of that text, i.e. the added `/`; `$` is its end.
//! - They always use smart case, whatever the search's case rule.
//!
//! A file is kept when its path matches every include path filter and no exclude path filter; a line when it
//! matches every include line filter and no exclude line filter.
//!
//! A *literal* exclude path filter also decides whether a directory is entered ([`Filters::skip_dir`]): when it
//! occurs in `/` + the relative directory + `/`, it occurs in the path of every file below, so none of them
//! would be kept. No other filter does: files below a directory may match an include path filter when the
//! directory does not, and a regexp exclude filter that matches the directory's text need not match the files
//! below it (`^/src/[^/]*$` matches `/src/` and `/src/a.rs`, not `/src/sub/b.rs`). Regexp exclude path filters
//! are tested on each file.
//!
//! Highlight positions are character offsets (Unicode scalar values), not bytes; ends are exclusive. They are
//! found on the whole line and reported for the part of it that is sent ([`Filters::line_spans`]).

use grep_matcher::{Captures, Match, Matcher};
use grep_regex::{RegexMatcher, RegexMatcherBuilder};
use serde::Deserialize;
use std::fmt;

/// What a filter is matched against.
///
/// Decoded from the bare keywords `:line` and `:path`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub enum Target {
    Line,
    Path,
}

/// The case rule for line filters.
///
/// Decoded from the bare keywords `:smart`, `:sensitive` and `:insensitive`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
pub enum Case {
    /// Case-insensitive unless the filter's pattern contains an uppercase letter.
    #[default]
    Smart,
    Sensitive,
    Insensitive,
}

/// One enabled filter as Emacs sends it: `(:target :line :exclude nil :pattern "foo" :regexp t)`.
///
/// `:exclude` and `:regexp` may be left out (nil). `:target` and `:pattern` are required.
#[derive(Debug, Clone, Deserialize)]
pub struct FilterSpec {
    pub target: Target,
    #[serde(default)]
    pub exclude: bool,
    pub pattern: String,
    /// True for a regexp, false for a literal string.
    #[serde(default)]
    pub regexp: bool,
}

/// A filter list that cannot be used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilterError {
    /// 0-based index in the list given to [`Filters::compile`]; `None` for the list as a whole (no include
    /// line filter).
    pub index: Option<usize>,
    /// For a filter: ``invalid filter `PATTERN`: ENGINE MESSAGE`` (the engine's message may span lines). For the
    /// list: a sentence.
    pub message: String,
}

impl fmt::Display for FilterError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.index {
            Some(index) => write!(f, "filter {index}: {}", self.message),
            None => f.write_str(&self.message),
        }
    }
}

/// A highlighted range of a line: character offsets, `end` exclusive. The result of [`Filters::line_spans`];
/// it is not sent to Emacs in this form (the search splits the ranges into two lists).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: u32,
    pub end: u32,
    /// True when the match comes from an include line filter other than the primary one.
    pub secondary: bool,
}

/// The compiled filters of one search. Cheap to clone, shared by the search threads.
#[derive(Debug, Clone)]
pub struct Filters {
    primary: RegexMatcher,
    /// Include line filters other than the primary one, in list order.
    other_includes: Vec<RegexMatcher>,
    exclude_lines: Vec<RegexMatcher>,
    include_paths: Vec<RegexMatcher>,
    exclude_paths: Vec<RegexMatcher>,
    /// The literal ones among `exclude_paths`: those that also keep the walk out of a directory.
    prune_dirs: Vec<RegexMatcher>,
}

/// How far beyond the part of a line that is sent [`Filters::line_spans`] looks for matches, in bytes. A line
/// can be many megabytes long (minified code); its highlights are not worth a scan of all of it per filter.
const SPAN_LOOKAHEAD: usize = 64 * 1024;

fn build(spec: &FilterSpec, line: bool, case: Case) -> Result<RegexMatcher, String> {
    let mut builder = RegexMatcherBuilder::new();
    builder.fixed_strings(!spec.regexp);
    if line && !spec.regexp && spec.pattern.contains(['\n', '\r']) {
        // The engine's message for this talks about a regex.
        return Err(format!("invalid filter `{}`: a pattern cannot contain a line break", spec.pattern));
    }
    if line {
        match case {
            Case::Smart => builder.case_smart(true),
            Case::Insensitive => builder.case_insensitive(true),
            Case::Sensitive => &mut builder,
        };
        // Sets the line terminator to `\r\n` and makes `^`, `$` and `.` treat `\r` like `\n`.
        builder.multi_line(true).crlf(true);
    } else {
        builder.case_smart(true);
    }
    builder.build(&spec.pattern).map_err(|e| format!("invalid filter `{}`: {e}", spec.pattern))
}

/// Byte ranges of the non-empty matches of `matcher` in `haystack`.
fn find_all(matcher: &RegexMatcher, haystack: &[u8]) -> Vec<(usize, usize)> {
    find_before(matcher, haystack, haystack.len())
}

/// Byte ranges of the non-empty matches of `matcher` in `haystack` that start before `limit`. The search ends
/// at the first match that starts at or beyond it.
fn find_before(matcher: &RegexMatcher, haystack: &[u8], limit: usize) -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    // The error type is `NoError`: the regex matcher cannot fail while searching.
    let _ = matcher.find_iter(haystack, |m| {
        if m.start() >= limit {
            return false;
        }
        if m.start() < m.end() {
            found.push((m.start(), m.end()));
        }
        true
    });
    found
}

fn is_match(matcher: &RegexMatcher, haystack: &[u8]) -> bool {
    matcher.is_match(haystack).unwrap_or(false)
}

/// Sorts and merges overlapping ranges (touching ranges stay separate).
fn merge(mut ranges: Vec<(usize, usize)>) -> Vec<(usize, usize)> {
    ranges.sort_unstable();
    let mut merged: Vec<(usize, usize)> = Vec::with_capacity(ranges.len());
    for (start, end) in ranges {
        match merged.last_mut() {
            Some(last) if start < last.1 => last.1 = last.1.max(end),
            _ => merged.push((start, end)),
        }
    }
    merged
}

/// Maps byte offsets of `text` to character offsets. An offset inside a character maps to the next character
/// boundary (matchers on UTF-8 text do not produce such offsets).
struct CharOffsets {
    /// `None` for ASCII text, where the two are the same.
    table: Option<Vec<u32>>,
}

impl CharOffsets {
    fn new(text: &str) -> CharOffsets {
        if text.is_ascii() {
            return CharOffsets { table: None };
        }
        let mut table = Vec::with_capacity(text.len() + 1);
        let mut chars = 0u32;
        for c in text.chars() {
            // The first byte of a character is its offset; the following bytes round up to the next one.
            table.push(chars);
            chars += 1;
            for _ in 1..c.len_utf8() {
                table.push(chars);
            }
        }
        table.push(chars);
        CharOffsets { table: Some(table) }
    }

    fn at(&self, byte: usize) -> u32 {
        match &self.table {
            None => byte as u32,
            Some(table) => table[byte],
        }
    }
}

impl Filters {
    /// Compiles the enabled filters, in the buffer's order, for the case rule of the search.
    ///
    /// Errors: an empty pattern or an invalid pattern (`index` is its position in `specs`; the first one in the
    /// list is reported); no include line filter (`index` is `None`).
    pub fn compile(specs: &[FilterSpec], case: Case) -> Result<Filters, FilterError> {
        let mut primary = None;
        let mut other_includes = Vec::new();
        let mut exclude_lines = Vec::new();
        let mut include_paths = Vec::new();
        let mut exclude_paths = Vec::new();
        let mut prune_dirs = Vec::new();
        for (index, spec) in specs.iter().enumerate() {
            let error = |message: String| FilterError { index: Some(index), message };
            if spec.pattern.is_empty() {
                return Err(error("invalid filter: the pattern is empty".to_string()));
            }
            let matcher = build(spec, spec.target == Target::Line, case).map_err(error)?;
            match (spec.target, spec.exclude) {
                (Target::Line, false) if primary.is_none() => primary = Some(matcher),
                (Target::Line, false) => other_includes.push(matcher),
                (Target::Line, true) => exclude_lines.push(matcher),
                (Target::Path, false) => include_paths.push(matcher),
                (Target::Path, true) => {
                    if !spec.regexp {
                        prune_dirs.push(matcher.clone());
                    }
                    exclude_paths.push(matcher);
                }
            }
        }
        let Some(primary) = primary else {
            return Err(FilterError { index: None, message: "a search needs an include line filter".to_string() });
        };
        Ok(Filters { primary, other_includes, exclude_lines, include_paths, exclude_paths, prune_dirs })
    }

    /// The matcher the searcher scans files with: the first include line filter.
    pub fn primary(&self) -> &RegexMatcher {
        &self.primary
    }

    /// Whether a file is kept: its path matches every include path filter and no exclude path filter.
    /// `rel` is relative to the search directory, `/`-separated, without a leading slash.
    pub fn keep_file(&self, rel: &str) -> bool {
        let haystack = format!("/{rel}");
        let haystack = haystack.as_bytes();
        self.include_paths.iter().all(|m| is_match(m, haystack))
            && !self.exclude_paths.iter().any(|m| is_match(m, haystack))
    }

    /// Whether a directory is not entered: a literal exclude path filter occurs in `/` + `rel_dir` + `/`, and
    /// so in the path of every file below. No other filter skips a directory (see the module docs). `rel_dir`
    /// is relative, `/`-separated, without slashes at either end.
    pub fn skip_dir(&self, rel_dir: &str) -> bool {
        if self.prune_dirs.is_empty() {
            return false;
        }
        let haystack = format!("/{rel_dir}/");
        self.prune_dirs.iter().any(|m| is_match(m, haystack.as_bytes()))
    }

    /// Character ranges of `rel` (without the added leading `/`) matched by include path filters: sorted,
    /// non-overlapping, overlapping matches merged. A match that starts on the added `/` is clipped to start at
    /// 0; one that covers only that `/` yields nothing.
    pub fn path_spans(&self, rel: &str) -> Vec<(u32, u32)> {
        if self.include_paths.is_empty() {
            return Vec::new();
        }
        let haystack = format!("/{rel}");
        let mut ranges = Vec::new();
        for matcher in &self.include_paths {
            for (start, end) in find_all(matcher, haystack.as_bytes()) {
                if end > 1 {
                    ranges.push((start.saturating_sub(1), end - 1));
                }
            }
        }
        let offsets = CharOffsets::new(rel);
        merge(ranges).into_iter().map(|(s, e)| (offsets.at(s), offsets.at(e))).collect()
    }

    /// For a line the primary filter matched: whether the other include line filters match it and no exclude
    /// line filter does. `line` is the line without its terminator; it need not be valid UTF-8.
    pub fn keep_line(&self, line: &[u8]) -> bool {
        self.other_includes.iter().all(|m| is_match(m, line)) && !self.exclude_lines.iter().any(|m| is_match(m, line))
    }

    /// Highlight positions for a line of which the first `shown` bytes are sent. `text` is the whole line
    /// (without terminator) and `shown` a character boundary in it, `text.len()` when the line is not cut.
    ///
    /// The matches are found on the whole line, so that `$`, `\b` and greedy patterns see what really follows
    /// the cut: all non-empty matches of the primary filter and of the other include line filters that start
    /// before `shown`. A match that crosses `shown` is clipped to it. The result is character ranges into the
    /// shown part, sorted by start and not overlapping. Primary matches are reported as they are. Secondary
    /// matches are merged where they overlap each other, then clipped to the parts outside primary matches;
    /// empty remainders are dropped.
    ///
    /// Cost: a filter is not searched for beyond its first match that starts at or after `shown`, and never
    /// further than [`SPAN_LOOKAHEAD`] bytes beyond `shown`. In a line longer than that, a pattern is matched
    /// as if the line ended there.
    pub fn line_spans(&self, text: &str, shown: usize) -> Vec<Span> {
        let mut end = text.len().min(shown.saturating_add(SPAN_LOOKAHEAD));
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let bytes = &text.as_bytes()[..end];
        let primary = find_before(&self.primary, bytes, shown);
        let mut secondary = Vec::new();
        for matcher in &self.other_includes {
            secondary.extend(find_before(matcher, bytes, shown));
        }
        let mut pieces: Vec<(usize, usize, bool)> = primary.iter().map(|&(s, e)| (s, e, false)).collect();
        for (start, end) in merge(secondary) {
            let mut from = start;
            // `primary` is sorted and non-overlapping.
            for &(ps, pe) in primary.iter().filter(|&&(ps, pe)| ps < end && pe > start) {
                if ps > from {
                    pieces.push((from, ps, true));
                }
                from = from.max(pe);
            }
            if from < end {
                pieces.push((from, end, true));
            }
        }
        pieces.sort_unstable();
        let offsets = CharOffsets::new(&text[..shown]);
        pieces
            .into_iter()
            .filter(|&(s, _, _)| s < shown)
            .map(|(s, e, secondary)| Span { start: offsets.at(s), end: offsets.at(e.min(shown)), secondary })
            .filter(|span| span.start < span.end)
            .collect()
    }

    /// The new text of each primary match of a line that is sent whole: `template` interpolated with the match's
    /// capture groups, in the syntax of `rg -r` (`$0`, `$1`, `${1}`, `$name`, `${name}`, `$$`; a group that does
    /// not exist or did not take part gives the empty string). `text` is the whole line without terminator.
    ///
    /// One entry per primary span of [`Filters::line_spans`]`(text, text.len())`, in the same order: the
    /// matches of the primary filter on the whole line that are not empty as character ranges. (A byte-level
    /// pattern such as `(?-u:\xA4)` can match inside a character; that span is dropped there, so it is here.)
    /// Each match is found by the same iteration as there, and its groups by a search that starts at it, which
    /// sees the line before it as the first did.
    pub fn replacements(&self, text: &str, template: &[u8]) -> Vec<String> {
        let haystack = text.as_bytes();
        // The error type is `NoError`, as in `find_before`.
        let Ok(mut caps) = self.primary.new_captures() else { return Vec::new() };
        let offsets = CharOffsets::new(text);
        let mut found = Vec::new();
        for (start, end) in find_all(&self.primary, haystack) {
            if offsets.at(start) == offsets.at(end) {
                continue;
            }
            let matched = self.primary.captures_at(haystack, start, &mut caps).unwrap_or(false);
            debug_assert!(matched && caps.get(0) == Some(Match::new(start, end)));
            let mut new = Vec::new();
            caps.interpolate(|name| self.primary.capture_index(name), haystack, template, &mut new);
            // A group can end inside a character only with a byte-level pattern such as `(?-u:\xC3)`.
            found.push(String::from_utf8(new).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned()));
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(target: Target, exclude: bool, pattern: &str, regexp: bool) -> FilterSpec {
        FilterSpec { target, exclude, pattern: pattern.to_string(), regexp }
    }
    fn line(pattern: &str, regexp: bool) -> FilterSpec {
        spec(Target::Line, false, pattern, regexp)
    }
    fn not_line(pattern: &str, regexp: bool) -> FilterSpec {
        spec(Target::Line, true, pattern, regexp)
    }
    fn path(pattern: &str, regexp: bool) -> FilterSpec {
        spec(Target::Path, false, pattern, regexp)
    }
    fn not_path(pattern: &str, regexp: bool) -> FilterSpec {
        spec(Target::Path, true, pattern, regexp)
    }
    fn compile(specs: &[FilterSpec]) -> Filters {
        Filters::compile(specs, Case::Smart).unwrap()
    }
    fn primary_matches(f: &Filters, text: &str) -> bool {
        is_match(f.primary(), text.as_bytes())
    }
    /// The spans of a line that is sent whole.
    fn spans(f: &Filters, text: &str) -> Vec<Span> {
        f.line_spans(text, text.len())
    }
    fn sp(start: u32, end: u32, secondary: bool) -> Span {
        Span { start, end, secondary }
    }

    #[test]
    fn filters_are_send_sync_clone() {
        fn assert_traits<T: Send + Sync + Clone>() {}
        assert_traits::<Filters>();
    }

    #[test]
    fn literal_matches_metacharacters_literally() {
        for pattern in [".", "(", "a*", "\\d", "[x]", "a.c"] {
            let f = compile(&[line(pattern, false)]);
            assert!(primary_matches(&f, &format!("x {pattern} y")), "{pattern}");
        }
        let f = compile(&[line("a.c", false)]);
        assert!(!primary_matches(&f, "abc"));
        let f = compile(&[line("a.c", true)]);
        assert!(primary_matches(&f, "abc"));
        let f = compile(&[line("fn \\w+\\(", true)]);
        assert!(primary_matches(&f, "fn foo(x)"));
        assert!(!primary_matches(&f, "fn (x)"));
    }

    #[test]
    fn case_rules_for_line_filters() {
        let check = |case, pattern: &str, regexp, text: &str| {
            let f = Filters::compile(&[line(pattern, regexp)], case).unwrap();
            primary_matches(&f, text)
        };
        for regexp in [false, true] {
            assert!(check(Case::Smart, "foo", regexp, "a FOO b"));
            assert!(!check(Case::Smart, "Foo", regexp, "a foo b"));
            assert!(check(Case::Smart, "Foo", regexp, "a Foo b"));
            assert!(!check(Case::Sensitive, "foo", regexp, "FOO"));
            assert!(check(Case::Sensitive, "foo", regexp, "foo"));
            assert!(check(Case::Insensitive, "Foo", regexp, "fOO"));
        }
        // `\W` and `\S` are not uppercase letters.
        assert!(check(Case::Smart, "\\Wfoo", true, "-FOO"));
        assert!(check(Case::Smart, "a\\Sb", true, "A-B"));
        assert!(!check(Case::Smart, "A\\Sb", true, "a-b"));
    }

    #[test]
    fn smart_case_is_decided_per_filter() {
        let f = compile(&[line("foo", false), line("Bar", false), line("baz", true)]);
        // `foo` is insensitive, `Bar` sensitive, `baz` insensitive.
        assert!(primary_matches(&f, "FOO"));
        assert!(f.keep_line(b"Bar BAZ"));
        assert!(!f.keep_line(b"bar BAZ"));
    }

    #[test]
    fn path_filters_are_always_smart() {
        for case in [Case::Smart, Case::Sensitive, Case::Insensitive] {
            let f = Filters::compile(&[line("x", false), path("readme", false)], case).unwrap();
            assert!(f.keep_file("README.md"), "{case:?}");
            let f = Filters::compile(&[line("x", false), path("README", false)], case).unwrap();
            assert!(f.keep_file("README.md"), "{case:?}");
            assert!(!f.keep_file("readme.md"), "{case:?}");
        }
    }

    #[test]
    fn leading_slash_rule() {
        let f = compile(&[line("x", false), path("/test/", false)]);
        assert!(f.keep_file("test/a.c"));
        assert!(f.keep_file("src/test/a.c"));
        assert!(!f.keep_file("contest/a.c"));
        assert!(!f.keep_file("a.c"));
        let f = compile(&[line("x", false), path("^/src/", true)]);
        assert!(f.keep_file("src/a.c"));
        assert!(!f.keep_file("lib/src/a.c"));
    }

    #[test]
    fn extension_patterns() {
        let f = compile(&[line("x", false), path(".rs", false)]);
        assert!(f.keep_file("src/a.rs"));
        assert!(!f.keep_file("src/a.c"));
        // A literal `.rs` also matches inside a name; the regexp form with an anchor does not.
        assert!(f.keep_file("src/a.rsx"));
        let f = compile(&[line("x", false), path("\\.rs$", true)]);
        assert!(f.keep_file("src/a.rs"));
        assert!(!f.keep_file("src/a.rsx"));
        assert!(!f.keep_file("src/ars"));
    }

    #[test]
    fn include_and_exclude_paths() {
        let f = compile(&[line("x", false), path("src/", false), path(".rs", false), not_path("/gen/", false)]);
        assert!(f.keep_file("src/a.rs"));
        assert!(!f.keep_file("src/a.c"));
        assert!(!f.keep_file("lib/a.rs"));
        assert!(!f.keep_file("src/gen/a.rs"));
        // Only excludes keep everything else.
        let f = compile(&[line("x", false), not_path("/test/", false)]);
        assert!(f.keep_file("src/a.c"));
        assert!(!f.keep_file("test/a.c"));
        // No path filters keep every file.
        assert!(compile(&[line("x", false)]).keep_file("anything"));
    }

    #[test]
    fn include_and_exclude_lines() {
        let f = compile(&[line("foo", false), line("bar", false), not_line("baz", false)]);
        assert!(f.keep_line(b"foo bar"));
        assert!(!f.keep_line(b"foo"));
        assert!(!f.keep_line(b"foo bar baz"));
        // Only an exclude besides the primary.
        let f = compile(&[line("foo", false), not_line("^\\s*//", true)]);
        assert!(f.keep_line(b"foo()"));
        assert!(!f.keep_line(b"   // foo"));
        // Mixed with path filters, which do not affect lines.
        let f = compile(&[path("a", false), not_path("b", false), line("foo", false)]);
        assert!(f.keep_line(b"foo"));
    }

    #[test]
    fn anchors_are_line_anchors() {
        let f = compile(&[line("^foo$", true)]);
        assert!(primary_matches(&f, "foo"));
        assert!(!primary_matches(&f, "foo bar"));
        assert!(!primary_matches(&f, " foo"));
        let f = compile(&[line("x", false), line("^bar", true)]);
        assert!(f.keep_line(b"bar x"));
        assert!(!f.keep_line(b"x bar"));
    }

    #[test]
    fn line_matchers_do_not_cross_a_line_terminator() {
        // A pattern that names the terminator is refused...
        let err = Filters::compile(&[line("a\\nb", true)], Case::Smart).unwrap_err();
        assert_eq!(err.index, Some(0));
        // ...and `\s` does not match it.
        let f = compile(&[line("a\\s+b", true)]);
        assert!(!is_match(f.primary(), b"a\nb"));
        assert!(primary_matches(&f, "a  b"));
    }

    #[test]
    fn line_matchers_treat_crlf_as_one_terminator() {
        // The primary filter sees the file's bytes, the other line filters the line without its terminator.
        let f = compile(&[line("foo$", true), line("o$", true), not_line("x$", true)]);
        for haystack in ["foo\r\n", "foo\n", "foo"] {
            assert!(primary_matches(&f, haystack), "{haystack:?}");
        }
        assert!(!primary_matches(&f, "foo \r\n"));
        assert!(f.keep_line(b"foo"));
        assert!(!f.keep_line(b"foox"));
        let f = compile(&[line("^bar", true)]);
        assert!(primary_matches(&f, "foo\r\nbar\r\n"));
        // Nothing matches a carriage return: not a class, not `.`, and a pattern that names it is refused.
        for pattern in ["foo\\s", "foo.", "foo[^x]", "foo\\s*$x"] {
            let f = compile(&[line(pattern, true)]);
            assert!(!primary_matches(&f, "foo\r\n"), "{pattern}");
            assert!(!primary_matches(&f, "foo\rbar\n"), "{pattern}");
        }
        assert_eq!(Filters::compile(&[line("a\\rb", true)], Case::Smart).unwrap_err().index, Some(0));
        assert_eq!(Filters::compile(&[line("a\rb", false)], Case::Smart).unwrap_err().index, Some(0));
        // A carriage return inside a line is a line end for the anchors.
        let f = compile(&[line("foo$", true)]);
        assert!(primary_matches(&f, "foo\rbar\n"));
        // Path filters are not line matchers.
        let f = compile(&[line("x", false), path("a\rb", false)]);
        assert!(f.keep_file("a\rb"));
    }

    #[test]
    fn primary_is_the_first_include_line_filter() {
        let f = compile(&[path("src", false), not_line("zzz", false), line("beta", false), line("alpha", false)]);
        assert!(primary_matches(&f, "beta"));
        assert!(!primary_matches(&f, "alpha"));
        assert!(f.keep_line(b"alpha"));
        assert!(!f.keep_line(b"beta"));
        assert_eq!(spans(&f, "alpha beta"), vec![sp(0, 5, true), sp(6, 10, false)]);
    }

    #[test]
    fn skip_dir_follows_literal_exclude_path_filters_only() {
        let f = compile(&[line("x", false), not_path("/test/", false), not_path("Vendor", false)]);
        assert!(f.skip_dir("test"));
        assert!(f.skip_dir("src/test"));
        assert!(!f.skip_dir("contest"));
        assert!(!f.skip_dir("src"));
        assert!(f.skip_dir("a/Vendor.d"));
        assert!(!f.skip_dir("a/vendor.d"), "smart case, as for the files");
        // Include path filters never skip a directory.
        let f = compile(&[line("x", false), path(".rs", false), path("/test/", false)]);
        assert!(!f.skip_dir("src"));
        assert!(!f.skip_dir("other"));
        // Nor do regexp exclude filters: what matches the directory's text need not match the files below.
        for pattern in ["^/src/[^/]*$", "^[^.]*$", "/$", "^/vendor/", "/old/", "src"] {
            let f = compile(&[line("x", false), not_path(pattern, true)]);
            for dir in ["src", "src/sub", "dir", "vendor", "a/old"] {
                assert!(!f.skip_dir(dir), "{pattern} {dir}");
            }
        }
        // They are tested on each file.
        let f = compile(&[line("x", false), not_path("^/src/[^/]*$", true)]);
        assert!(!f.keep_file("src/a.rs"));
        assert!(f.keep_file("src/sub/b.rs"));
        let f = compile(&[line("x", false), not_path("^[^.]*$", true)]);
        assert!(!f.keep_file("top"));
        assert!(f.keep_file("dir/x.y"));
        let f = compile(&[line("x", false), not_path("/$", true)]);
        assert!(f.keep_file("dir/x.y"));
    }

    #[test]
    fn a_literal_line_filter_with_a_line_break_is_refused_in_plain_words() {
        for pattern in ["a\nb", "a\r\nb", "a\rb"] {
            let err = Filters::compile(&[line("x", false), not_line(pattern, false)], Case::Smart).unwrap_err();
            assert_eq!(err.index, Some(1));
            assert_eq!(err.message, format!("invalid filter `{pattern}`: a pattern cannot contain a line break"));
        }
        // A file name may contain one.
        assert!(Filters::compile(&[line("x", false), path("a\nb", false)], Case::Smart).is_ok());
        // A regexp that names one keeps the engine's message.
        let err = Filters::compile(&[line("a\\nb", true)], Case::Smart).unwrap_err();
        assert!(err.message.starts_with("invalid filter `a\\nb`: ") && !err.message.contains("line break"));
    }

    #[test]
    fn line_spans_of_a_cut_line_come_from_the_whole_line() {
        // `$` is the end of the line, not of the part that is shown.
        let f = compile(&[line("foo$", true)]);
        assert!(f.line_spans("xxfoo yy foo", 5).is_empty());
        assert_eq!(f.line_spans("xxfoo yy foo", 12), vec![sp(9, 12, false)]);
        assert_eq!(f.line_spans("xxfoo", 5), vec![sp(2, 5, false)]);
        // A greedy match that reaches the end of the line is not one of the shown part's last word.
        let f = compile(&[line("\\w+$", true)]);
        assert!(f.line_spans("ab cd ef", 5).is_empty());
        assert_eq!(f.line_spans("ab cdef", 5), vec![sp(3, 5, false)], "clipped to the cut");
        // `\b` sees the character after the cut.
        let f = compile(&[line("foo\\b", true)]);
        assert!(f.line_spans("a foobar", 5).is_empty());
        assert_eq!(f.line_spans("a foo bar", 5), vec![sp(2, 5, false)]);
        // A match that crosses the cut is clipped, one that starts at or beyond it is dropped.
        let f = compile(&[line("needle", false), line("hay", false)]);
        assert_eq!(f.line_spans("hay needle hay", 7), vec![sp(0, 3, true), sp(4, 7, false)]);
        assert_eq!(f.line_spans("hay needle hay", 4), vec![sp(0, 3, true)]);
        assert_eq!(f.line_spans("hay needle hay", 13), vec![sp(0, 3, true), sp(4, 10, false), sp(11, 13, true)]);
        assert!(f.line_spans("hay needle hay", 0).is_empty());
        // A secondary match is clipped to the outside of a primary match that itself crosses the cut.
        let f = compile(&[line("cdef", false), line("bcd", false)]);
        assert_eq!(f.line_spans("abcdefg", 3), vec![sp(1, 2, true), sp(2, 3, false)]);
        // Character offsets, with non-ASCII text before the cut; `shown` is in bytes.
        let f = compile(&[line("needle", false)]);
        assert_eq!(f.line_spans("äö needle ü needle", 9), vec![sp(3, 7, false)]);
        assert_eq!(
            f.line_spans("äö needle ü needle", "äö needle ü ne".len()),
            vec![sp(3, 9, false), sp(12, 14, false)]
        );
    }

    #[test]
    fn line_spans_look_a_bounded_distance_beyond_the_cut() {
        let f = compile(&[line("foo$", true), line("zz", false)]);
        let long = format!("xxfoo{}", " y".repeat(SPAN_LOOKAHEAD));
        // The line goes on for longer than is looked at: `$` is taken at the end of that window, far from the cut.
        assert!(f.line_spans(&long, 5).is_empty());
        let long = format!("xxfoo zz{} zz foo", "ä".repeat(SPAN_LOOKAHEAD));
        assert_eq!(f.line_spans(&long, 8), vec![sp(6, 8, true)]);
        assert_eq!(f.line_spans(&long, long.len()).len(), 3);
    }

    #[test]
    fn errors() {
        let err = Filters::compile(&[path("a", false), not_line("b", false)], Case::Smart).unwrap_err();
        assert_eq!(err.index, None);
        let err = Filters::compile(&[], Case::Smart).unwrap_err();
        assert_eq!(err.index, None);

        let err = Filters::compile(&[line("a", false), line("", false)], Case::Smart).unwrap_err();
        assert_eq!(err.index, Some(1));
        let err = Filters::compile(&[path("", true), line("a", false)], Case::Smart).unwrap_err();
        assert_eq!(err.index, Some(0));

        let err = Filters::compile(&[line("ok", false), line("foo(", true)], Case::Smart).unwrap_err();
        assert_eq!(err.index, Some(1));
        assert!(err.message.contains("`foo(`"), "{}", err.message);
        assert!(err.message.contains("unclosed group"), "{}", err.message);
        assert!(err.to_string().starts_with("filter 1: "));

        let err = Filters::compile(&[line("ok", false), not_path("a)", true)], Case::Smart).unwrap_err();
        assert_eq!(err.index, Some(1));
        assert!(err.message.contains("`a)`"), "{}", err.message);

        // The same text as a literal is fine.
        assert!(Filters::compile(&[line("foo(", false)], Case::Smart).is_ok());
    }

    #[test]
    fn line_spans_primary_and_secondary() {
        let f = compile(&[line("foo", false), line("bar", false)]);
        assert_eq!(spans(&f, "bar foo"), vec![sp(0, 3, true), sp(4, 7, false)]);
        // Several matches of each.
        assert_eq!(
            spans(&f, "foo bar foo bar"),
            vec![sp(0, 3, false), sp(4, 7, true), sp(8, 11, false), sp(12, 15, true)]
        );
        // Exclude filters and path filters add nothing.
        let f = compile(&[line("foo", false), not_line("bar", false), path("foo", false)]);
        assert_eq!(spans(&f, "foo bar"), vec![sp(0, 3, false)]);
        assert!(spans(&f, "nothing").is_empty());
    }

    #[test]
    fn line_spans_clip_secondary_to_outside_the_primary() {
        // Secondary `abcdef` overlapped by primary `cd` in the middle: two remainders.
        let f = compile(&[line("cd", false), line("abcdef", false)]);
        assert_eq!(spans(&f, "abcdef"), vec![sp(0, 2, true), sp(2, 4, false), sp(4, 6, true)]);
        // Secondary inside the primary vanishes.
        let f = compile(&[line("abcdef", false), line("cd", false)]);
        assert_eq!(spans(&f, "abcdef"), vec![sp(0, 6, false)]);
        // Partial overlap on one side.
        let f = compile(&[line("cdef", false), line("abcd", false)]);
        assert_eq!(spans(&f, "abcdef"), vec![sp(0, 2, true), sp(2, 6, false)]);
        // Identical matches: only the primary one.
        let f = compile(&[line("foo", false), line("foo", true)]);
        assert_eq!(spans(&f, "foo"), vec![sp(0, 3, false)]);
    }

    #[test]
    fn line_spans_merge_overlapping_secondary() {
        let f = compile(&[line("zz", false), line("abc", false), line("bcd", false)]);
        assert_eq!(spans(&f, "abcd zz"), vec![sp(0, 4, true), sp(5, 7, false)]);
        // A merged secondary range is clipped around a primary match inside it.
        let f = compile(&[line("c", false), line("abc", false), line("bcd", false)]);
        assert_eq!(spans(&f, "abcd"), vec![sp(0, 2, true), sp(2, 3, false), sp(3, 4, true)]);
    }

    #[test]
    fn line_spans_empty_matches_are_dropped() {
        let f = compile(&[line("a", false), line("x*", true)]);
        assert_eq!(spans(&f, "bab"), vec![sp(1, 2, false)]);
    }

    #[test]
    fn line_spans_use_character_offsets() {
        let f = compile(&[line("foo", false)]);
        assert_eq!(spans(&f, "ä foo"), vec![sp(2, 5, false)]);
        assert_eq!(spans(&f, "→ä foo → foo"), vec![sp(3, 6, false), sp(9, 12, false)]);
        let f = compile(&[line("ö", false), line("→", false)]);
        assert_eq!(spans(&f, "ä→ö"), vec![sp(1, 2, true), sp(2, 3, false)]);
        // A four-byte character.
        let f = compile(&[line("x", false)]);
        assert_eq!(spans(&f, "😀x"), vec![sp(1, 2, false)]);
        // Case-insensitive match of a non-ASCII letter.
        let f = compile(&[line("ÄB", false)]);
        assert!(spans(&f, "xäb").is_empty());
        let f = compile(&[line("äb", false)]);
        assert_eq!(spans(&f, "xÄB"), vec![sp(1, 3, false)]);
    }

    /// The replacements of a line that is sent whole.
    fn replaced(f: &Filters, text: &str, template: &str) -> Vec<String> {
        f.replacements(text, template.as_bytes())
    }

    #[test]
    fn replacements_interpolate_the_template_per_match() {
        let f = compile(&[line("(?P<word>[a-z]+)=(\\d+)", true)]);
        let text = "a=1, bc=23";
        assert_eq!(replaced(&f, text, "$0"), ["a=1", "bc=23"]);
        assert_eq!(replaced(&f, text, "$2"), ["1", "23"]);
        assert_eq!(replaced(&f, text, "${2}x"), ["1x", "23x"]);
        assert_eq!(replaced(&f, text, "${word}:$word"), ["a:a", "bc:bc"]);
        assert_eq!(replaced(&f, text, "$$1"), ["$1", "$1"]);
        assert_eq!(replaced(&f, text, "plain"), ["plain", "plain"]);
        assert_eq!(replaced(&f, text, ""), ["", ""]);
        // `$2x` is the group named `2x`, which does not exist; so are group 7 and an unknown name.
        assert_eq!(replaced(&f, text, "<$2x|$7|$nope|${nope}>"), ["<|||>", "<|||>"]);
        // A group that did not take part.
        let f = compile(&[line("(a)|(b)", true)]);
        assert_eq!(replaced(&f, "ab", "[$1$2]"), ["[a]", "[b]"]);
        assert_eq!(replaced(&f, "ab", "[$1]"), ["[a]", "[]"]);
    }

    #[test]
    fn replacements_of_a_literal_filter_have_the_whole_match_only() {
        let f = compile(&[line("a.(b)", false)]);
        assert_eq!(replaced(&f, "xa.(b) a.(b)", "<$0|$1>"), ["<a.(b)|>", "<a.(b)|>"]);
    }

    #[test]
    fn replacements_follow_the_spans_one_to_one() {
        let check = |f: &Filters, text: &str| {
            let primary: Vec<Span> = spans(f, text).into_iter().filter(|s| !s.secondary).collect();
            let found = replaced(f, text, "$0");
            assert_eq!(found.len(), primary.len(), "{text:?}");
            // Each replacement is the text of its span.
            let chars: Vec<char> = text.chars().collect();
            for (span, new) in primary.iter().zip(&found) {
                let old: String = chars[span.start as usize..span.end as usize].iter().collect();
                assert_eq!(&old, new, "{text:?}");
            }
            found
        };
        // Touching matches.
        let f = compile(&[line("ab", false)]);
        assert_eq!(check(&f, "ababab"), ["ab", "ab", "ab"]);
        // Empty matches are left out on both sides.
        let f = compile(&[line("a*", true)]);
        assert_eq!(check(&f, "baab"), ["aa"]);
        assert_eq!(check(&f, "aabaa"), ["aa", "aa"]);
        assert!(check(&f, "bbb").is_empty());
        let f = compile(&[line("\\b|x", true)]);
        assert!(check(&f, "ab xb").is_empty());
        // Multibyte text before and inside the matches.
        let f = compile(&[line("ä(.)ö", true)]);
        assert_eq!(check(&f, "→ äüö äßö 😀ä😀ö"), ["äüö", "äßö", "ä😀ö"]);
        assert_eq!(replaced(&f, "→ äüö äßö 😀ä😀ö", "<$1>"), ["<ü>", "<ß>", "<😀>"]);
        // With secondary filters on the line.
        let f = compile(&[line("o+", true), line("fo", false), line("b", false)]);
        assert_eq!(check(&f, "foo boo fob"), ["oo", "oo", "o"]);
        // The interpolation sees the whole line: `$` and `\b` as in the matching.
        let f = compile(&[line("(\\w+)$", true)]);
        assert_eq!(replaced(&f, "ab cd", "[$1]"), ["[cd]"]);
        // A byte-level match inside a character is no span, so it has no replacement either.
        let f = compile(&[line("(?-u:\\xA4)|x", true)]);
        assert_eq!(check(&f, "äx"), ["x"]);
        assert_eq!(replaced(&f, "äx", "<$0>"), ["<x>"]);
    }

    #[test]
    fn path_spans_are_relative_to_the_path() {
        let f = compile(&[line("x", false), path(".rs", false)]);
        assert_eq!(f.path_spans("src/a.rs"), vec![(5, 8)]);
        let f = compile(&[line("x", false), path("src", false)]);
        assert_eq!(f.path_spans("src/src.rs"), vec![(0, 3), (4, 7)]);
        // Exclude path filters and an absent match give nothing.
        let f = compile(&[line("x", false), not_path("src", false)]);
        assert!(f.path_spans("src/a.rs").is_empty());
        assert!(compile(&[line("x", false), path("zzz", false)]).path_spans("a.rs").is_empty());
        assert!(compile(&[line("x", false)]).path_spans("a.rs").is_empty());
    }

    #[test]
    fn path_spans_clip_the_added_slash() {
        let f = compile(&[line("x", false), path("/src", false)]);
        assert_eq!(f.path_spans("src/a.rs"), vec![(0, 3)]);
        // A match that covers only the added slash yields nothing.
        let f = compile(&[line("x", false), path("^/", true)]);
        assert!(f.path_spans("src/a.rs").is_empty());
        let f = compile(&[line("x", false), path("/", false)]);
        assert_eq!(f.path_spans("a/b"), vec![(1, 2)]);
    }

    #[test]
    fn path_spans_merge_and_count_characters() {
        let f = compile(&[line("x", false), path("src/a", false), path("a.r", false)]);
        assert_eq!(f.path_spans("src/a.rs"), vec![(0, 7)]);
        let f = compile(&[line("x", false), path("ü", false), path("é/", false)]);
        assert_eq!(f.path_spans("aü/é/b"), vec![(1, 2), (3, 5)]);
        assert_eq!(f.path_spans("日本/ü.rs"), vec![(3, 4)]);
    }

    #[test]
    fn keep_line_accepts_invalid_utf8() {
        let f = compile(&[line("foo", false), line("bar", false), not_line("baz", false)]);
        assert!(f.keep_line(b"foo \xff\xfe bar"));
        assert!(!f.keep_line(b"foo \xff baz bar"));
        assert!(!f.keep_line(b"\xff"));
    }

    #[test]
    fn spec_and_span_shapes() {
        // Decoding is covered by emrs; here only the derive defaults.
        let s = spec(Target::Line, false, "a", false);
        assert_eq!(s.target, Target::Line);
        assert_eq!(Case::default(), Case::Smart);
        assert_eq!(sp(1, 2, true), Span { start: 1, end: 2, secondary: true });
    }
}
