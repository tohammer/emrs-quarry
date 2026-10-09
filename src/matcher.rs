//! Fuzzy queries against an [`Index`]: nucleo scoring, ranking, match positions, parallel scoring and
//! incremental narrowing (spec "Matching").
//!
//! Order of results: score descending, then path length in bytes (UTF-8) ascending, then path ascending (byte
//! order, which is code point order). Paths in an index are unique, so the order is total and deterministic.
//! An empty or whitespace-only query matches every path with score 0, so it lists the index in tie-break order.
//!
//! Match positions are character (Unicode scalar value) indices into the path, sorted and deduplicated. nucleo
//! works on graphemes (it keeps the first code point of each); for paths with multi-codepoint graphemes the
//! grapheme indices are converted to the character index of the grapheme's first code point.

#![allow(dead_code)]

use crate::index::Index;
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Utf32String};
use std::cmp::Ordering;
use std::ops::Range;

/// Largest accepted `limit`; smaller limits are raised to 1.
pub const MAX_LIMIT: usize = 10_000;

/// Above this many candidates, scoring is split over threads.
pub const PARALLEL_THRESHOLD: usize = 50_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueryResult {
    /// Best first, at most `limit`.
    pub paths: Vec<String>,
    /// Parallel to `paths`; character indices, sorted, deduplicated. `Some` only if requested.
    pub positions: Option<Vec<Vec<u32>>>,
    /// Number of matching paths before the limit.
    pub total: usize,
}

/// The previous query, for incremental narrowing.
struct Cache {
    text: String,
    version: u64,
    /// Slots of every path that matched `text` (not only the returned ones).
    matches: Vec<u32>,
}

/// A matching path: its score and its slot in the index.
#[derive(Clone, Copy)]
struct Hit {
    score: u32,
    slot: u32,
}

/// The result of scoring one chunk of candidates.
struct Chunk {
    /// Slots of all matches in the chunk.
    matches: Vec<u32>,
    /// The chunk's best `limit` hits, best first.
    top: Vec<Hit>,
}

/// The paths a query scores: the whole index, or the matches of the previous query.
#[derive(Clone, Copy)]
enum Candidates<'a> {
    All(usize),
    Slots(&'a [u32]),
}

impl Candidates<'_> {
    fn len(self) -> usize {
        match self {
            Candidates::All(n) => n,
            Candidates::Slots(slots) => slots.len(),
        }
    }

    fn get(self, i: usize) -> u32 {
        match self {
            Candidates::All(_) => i as u32,
            Candidates::Slots(slots) => slots[i],
        }
    }
}

/// Query engine of one service instance: reusable nucleo matchers (one per scoring thread) and the narrowing
/// cache.
pub struct Matcher {
    /// One per scoring thread; `nucleos[0]` is also used for single-threaded scoring and positions.
    nucleos: Vec<nucleo_matcher::Matcher>,
    parallel_threshold: usize,
    cache: Option<Cache>,
    /// Number of candidates the last query scored (for tests).
    last_scored: usize,
}

impl Default for Matcher {
    fn default() -> Self {
        Self::new()
    }
}

impl Matcher {
    pub fn new() -> Self {
        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
        Self::with_parallelism(PARALLEL_THRESHOLD, threads)
    }

    /// A matcher that scores in parallel above `threshold` candidates (instead of [`PARALLEL_THRESHOLD`]).
    pub(crate) fn with_parallel_threshold(threshold: usize) -> Self {
        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
        Self::with_parallelism(threshold, threads)
    }

    /// A matcher that scores in parallel above `threshold` candidates, with `threads` threads.
    pub(crate) fn with_parallelism(threshold: usize, threads: usize) -> Self {
        let config = Config::DEFAULT.match_paths();
        let nucleos = (0..threads.max(1)).map(|_| nucleo_matcher::Matcher::new(config.clone())).collect();
        Matcher { nucleos, parallel_threshold: threshold, cache: None, last_scored: 0 }
    }

    pub fn query(&mut self, index: &Index, text: &str, limit: usize, positions: bool) -> QueryResult {
        let limit = limit.clamp(1, MAX_LIMIT);
        let pattern = Pattern::parse(text, CaseMatching::Smart, Normalization::Smart);

        let cache = self.cache.take().filter(|c| c.version == index.version() && narrows(&c.text, text));
        let candidates = match &cache {
            Some(cache) => Candidates::Slots(&cache.matches),
            None => Candidates::All(index.len()),
        };
        self.last_scored = candidates.len();

        let chunks = if candidates.len() > self.parallel_threshold && self.nucleos.len() > 1 {
            let n = self.nucleos.len();
            let size = candidates.len().div_ceil(n);
            let pattern = &pattern;
            std::thread::scope(|scope| {
                let handles: Vec<_> = self
                    .nucleos
                    .iter_mut()
                    .enumerate()
                    .map(|(i, nucleo)| {
                        let range = (i * size).min(candidates.len())..((i + 1) * size).min(candidates.len());
                        scope.spawn(move || score_chunk(index, pattern, candidates, range, nucleo, limit))
                    })
                    .collect();
                handles.into_iter().map(|h| h.join().expect("scoring thread panicked")).collect()
            })
        } else {
            vec![score_chunk(index, &pattern, candidates, 0..candidates.len(), &mut self.nucleos[0], limit)]
        };

        let (matches, top) = if chunks.len() == 1 {
            let chunk = chunks.into_iter().next().expect("one chunk");
            (chunk.matches, chunk.top)
        } else {
            let mut matches = Vec::with_capacity(chunks.iter().map(|c| c.matches.len()).sum());
            let mut top = Vec::new();
            for chunk in chunks {
                matches.extend_from_slice(&chunk.matches);
                top.extend_from_slice(&chunk.top);
            }
            (matches, best(index, top, limit))
        };
        drop(cache);

        let positions = positions.then(|| {
            let nucleo = &mut self.nucleos[0];
            let mut buf = Vec::new();
            top.iter().map(|hit| match_positions(index, &pattern, hit.slot, nucleo, &mut buf)).collect()
        });
        let result = QueryResult {
            paths: top.iter().map(|hit| index.path(hit.slot).to_owned()).collect(),
            positions,
            total: matches.len(),
        };
        self.cache = Some(Cache { text: text.to_owned(), version: index.version(), matches });
        result
    }
}

/// Whether the matches of query `new` are a subset of the matches of query `old` (on the same index), so that
/// `new` only needs to score `old`'s matches. Conservative: false does not mean "not a subset".
///
/// nucleo splits a query into atoms at whitespace characters (`char::is_whitespace`, e.g. space, tab, U+3000)
/// not preceded by `\`. When `new` extends `old`, the atoms of `old` before its last one are unchanged, the
/// last one may grow, and new atoms may follow. A further atom only adds a condition (all atoms must match). A
/// grown last atom matches a subset of what it matched before, provided its kind and polarity cannot change.
/// The spec's conditions:
/// - `old` must not end with `\`: the next character could escape whitespace (joining atoms) or a `$`.
/// - `old` must not end with `$`: an atom ending in `$` is anchored at the end (postfix or exact) and loses
///   the anchor when it grows. (The spec also excludes any `$` in the last atom or the appended text; that is
///   more than needed, since a newly typed `$` only adds an anchor, but harmless.)
/// - no `!` in the last atom or the appended text: a negated atom excludes less when its needle grows.
///
/// Prefixes `^` and `'` are fixed once typed, and prefix, substring and fuzzy matches of a longer needle imply
/// matches of its prefix. Smart case is decided per atom and only switches from insensitive to exact as the
/// atom grows; a character matched exactly also matches insensitively, because the shorter atom has no upper
/// case characters.
///
/// The last atom is determined with nucleo's own splitting rule, escapes included. Splitting on whitespace
/// while ignoring escapes would be wrong: for `old = "!a\ b"` it would see the last atom `b` (no `!`), yet
/// nucleo's atom is the negated `a b`, and `"!a\ bc"` (excluding only `a bc`) matches paths that `"!a\ b"`
/// excluded.
///
/// One further condition, beyond the spec, because nucleo breaks the subset property: smart normalization
/// switches off when a non-normalized character (e.g. `é`) joins the atom, and with normalization off a
/// character is case-folded without being normalized first. For a non-ASCII needle character this can match
/// more: `ⱥ` does not match `Ⱥ` (normalized to `A`, then folded to `a`), but `ⱥé` matches `Ⱥé` (`Ⱥ` folded to
/// `ⱥ`); `ƅ`/`Ƅ` behave the same. So a last atom with a non-ASCII character does not narrow when the appended
/// text has one. (For ASCII needle characters normalization does not matter: checked by extending one-character
/// atoms, over all Unicode scalar values and their folded and normalized forms, against the pinned nucleo.)
pub(crate) fn narrows(old: &str, new: &str) -> bool {
    let Some(appended) = new.strip_prefix(old) else {
        return false;
    };
    if old.ends_with('\\') || old.ends_with('$') {
        return false;
    }
    let last = last_atom(old);
    let special = |s: &str| s.contains(['!', '$']);
    if special(last) || special(appended) {
        return false;
    }
    last.is_ascii() || appended.is_ascii()
}

/// The text of the last atom of `query` as nucleo splits it: everything after the last whitespace character
/// that is not preceded by a backslash.
fn last_atom(query: &str) -> &str {
    let mut start = 0;
    let mut prev = None;
    for (i, c) in query.char_indices() {
        if c.is_whitespace() && prev != Some('\\') {
            start = i + c.len_utf8();
        }
        prev = Some(c);
    }
    &query[start..]
}

/// Scores candidates `range` with one nucleo matcher and keeps the best `limit`.
fn score_chunk(
    index: &Index,
    pattern: &Pattern,
    candidates: Candidates<'_>,
    range: Range<usize>,
    nucleo: &mut nucleo_matcher::Matcher,
    limit: usize,
) -> Chunk {
    let mut hits = Vec::new();
    for i in range {
        let slot = candidates.get(i);
        if let Some(score) = pattern.score(index.haystack(slot), nucleo) {
            hits.push(Hit { score, slot });
        }
    }
    let matches = hits.iter().map(|hit| hit.slot).collect();
    Chunk { matches, top: best(index, hits, limit) }
}

/// The ranking order: score descending, path length (bytes) ascending, path ascending.
fn rank(index: &Index, a: &Hit, b: &Hit) -> Ordering {
    b.score.cmp(&a.score).then_with(|| {
        let (pa, pb) = (index.path(a.slot), index.path(b.slot));
        pa.len().cmp(&pb.len()).then_with(|| pa.cmp(pb))
    })
}

/// The best `limit` of `hits`, best first.
fn best(index: &Index, mut hits: Vec<Hit>, limit: usize) -> Vec<Hit> {
    if hits.len() > limit {
        hits.select_nth_unstable_by(limit - 1, |a, b| rank(index, a, b));
        hits.truncate(limit);
    }
    hits.sort_unstable_by(|a, b| rank(index, a, b));
    hits
}

/// Character indices of the match of `pattern` in the path at `slot`, sorted and deduplicated.
fn match_positions(
    index: &Index,
    pattern: &Pattern,
    slot: u32,
    nucleo: &mut nucleo_matcher::Matcher,
    buf: &mut Vec<u32>,
) -> Vec<u32> {
    buf.clear();
    pattern.indices(index.haystack(slot), nucleo, buf);
    buf.sort_unstable();
    buf.dedup();
    if index.chars_are_graphemes(slot) {
        return buf.clone();
    }
    let starts = grapheme_starts(index.path(slot));
    buf.iter().map(|&g| starts[g as usize]).collect()
}

/// For each nucleo character (grapheme) of `text`, the character index of its first code point.
///
/// Uses nucleo's own segmentation: a code point starts a grapheme iff the prefix ending with it has one more
/// grapheme than the prefix before it (grapheme boundaries before a position do not depend on what follows
/// it). Quadratic in the path length, but only used for returned paths with multi-codepoint graphemes.
fn grapheme_starts(text: &str) -> Vec<u32> {
    let mut starts = Vec::new();
    let mut count = 0;
    for (ci, (b, c)) in text.char_indices().enumerate() {
        let n = Utf32String::from(&text[..b + c.len_utf8()]).len();
        if n > count {
            starts.push(ci as u32);
            count = n;
        }
    }
    starts
}

#[cfg(test)]
mod tests {
    use super::*;
    use nucleo_matcher::Utf32Str;

    fn index_of(paths: &[&str]) -> Index {
        let mut index = Index::new();
        for p in paths {
            assert!(index.add(p));
        }
        index
    }

    fn paths(index: &Index, text: &str) -> Vec<String> {
        Matcher::new().query(index, text, 100, false).paths
    }

    fn score(path: &str, text: &str) -> Option<u32> {
        let mut nucleo = nucleo_matcher::Matcher::new(Config::DEFAULT.match_paths());
        let pattern = Pattern::parse(text, CaseMatching::Smart, Normalization::Smart);
        let mut buf = Vec::new();
        pattern.score(Utf32Str::new(path, &mut buf), &mut nucleo)
    }

    /// Single-threaded full scoring, written independently of `Matcher`: the reference for equivalence tests.
    fn reference(index: &Index, text: &str, limit: usize, positions: bool) -> QueryResult {
        let limit = limit.clamp(1, MAX_LIMIT);
        let mut nucleo = nucleo_matcher::Matcher::new(Config::DEFAULT.match_paths());
        let pattern = Pattern::parse(text, CaseMatching::Smart, Normalization::Smart);
        let mut hits: Vec<(u32, &str)> = index
            .iter()
            .filter_map(|p| {
                let hay = Utf32String::from(p);
                pattern.score(hay.slice(..), &mut nucleo).map(|s| (s, p))
            })
            .collect();
        hits.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.len().cmp(&b.1.len())).then(a.1.cmp(b.1)));
        let total = hits.len();
        hits.truncate(limit);
        let positions = positions.then(|| {
            hits.iter()
                .map(|(_, p)| {
                    let hay = Utf32String::from(*p);
                    let mut idx = Vec::new();
                    pattern.indices(hay.slice(..), &mut nucleo, &mut idx);
                    idx.sort_unstable();
                    idx.dedup();
                    // Map grapheme index -> char index by walking graphemes with a simple re-segmentation.
                    let starts = grapheme_starts(p);
                    idx.into_iter().map(|g| starts[g as usize]).collect()
                })
                .collect()
        });
        QueryResult { paths: hits.iter().map(|(_, p)| p.to_string()).collect(), positions, total }
    }

    #[test]
    fn ranking_by_score() {
        let index = index_of(&["a/x_b_y_c", "abc", "a/b/c"]);
        let got = paths(&index, "abc");
        assert_eq!(got[0], "abc");
        assert!(score("abc", "abc") > score("a/b/c", "abc"));
        assert!(score("a/b/c", "abc") > score("a/x_b_y_c", "abc"));
        assert_eq!(got, ["abc", "a/b/c", "a/x_b_y_c"]);
    }

    #[test]
    fn ranking_tie_breaks_length_then_path() {
        let index = index_of(&["y/abc.rs", "x/abc.rs", "x/abc.rsxx", "x/abc.r"]);
        // All four match "abc" with the same score.
        let scores: Vec<_> = index.iter().map(|p| score(p, "abc")).collect();
        assert!(scores.iter().all(|s| *s == scores[0] && s.is_some()), "{scores:?}");
        assert_eq!(paths(&index, "abc"), ["x/abc.r", "x/abc.rs", "y/abc.rs", "x/abc.rsxx"]);
    }

    #[test]
    fn length_is_counted_in_bytes() {
        // "é/ab" is 4 characters but 5 bytes: by bytes it ties with "zz/ab" and sorts after it by path.
        let index = index_of(&["zz/ab", "é/ab", "q/ab"]);
        assert_eq!(paths(&index, ""), ["q/ab", "zz/ab", "é/ab"]);
    }

    #[test]
    fn empty_query_lists_everything_in_tie_break_order() {
        let index = index_of(&["b/c", "a", "bb", "ab", "c/d/e"]);
        let expected = ["a", "ab", "bb", "b/c", "c/d/e"];
        for text in ["", " ", "   "] {
            let result = Matcher::new().query(&index, text, 100, true);
            assert_eq!(result.paths, expected);
            assert_eq!(result.total, 5);
            assert_eq!(result.positions, Some(vec![vec![]; 5]));
        }
    }

    #[test]
    fn smart_case() {
        let index = index_of(&["Foo.rs", "foo.rs", "FOO.rs"]);
        let mut lower = paths(&index, "foo");
        lower.sort();
        assert_eq!(lower, ["FOO.rs", "Foo.rs", "foo.rs"]);
        assert_eq!(paths(&index, "Foo"), ["Foo.rs"]);
        assert_eq!(paths(&index, "FOO"), ["FOO.rs"]);
    }

    #[test]
    fn negation_and_anchors() {
        let index = index_of(&["src/main.rs", "src/test.rs", "lib/src/a.rs", "src/a.rsx", "tests/x.rs"]);
        let mut got = paths(&index, "rs !test");
        got.sort();
        assert_eq!(got, ["lib/src/a.rs", "src/a.rsx", "src/main.rs"]);
        let mut got = paths(&index, "^src");
        got.sort();
        assert_eq!(got, ["src/a.rsx", "src/main.rs", "src/test.rs"]);
        let mut got = paths(&index, "a.rs$");
        got.sort();
        assert_eq!(got, ["lib/src/a.rs"]);
        let mut got = paths(&index, "^src rs$ !main");
        got.sort();
        assert_eq!(got, ["src/test.rs"]);
    }

    #[test]
    fn positions_are_char_indices() {
        let index = index_of(&["dö/ñame.rs"]);
        let result = Matcher::new().query(&index, "ñame", 10, true);
        assert_eq!(result.paths, ["dö/ñame.rs"]);
        assert_eq!(result.positions, Some(vec![vec![3, 4, 5, 6]]));
        // Normalization: "n" matches "ñ"; "ö" is at char 1, the "r" of ".rs" at char 8.
        let result = Matcher::new().query(&index, "drs", 10, true);
        assert_eq!(result.positions, Some(vec![vec![0, 8, 9]]));
        // "ñ" in the query turns normalization off for its atom: it matches "ñ" exactly.
        let result = Matcher::new().query(&index, "dñame", 10, true);
        assert_eq!(result.positions, Some(vec![vec![0, 3, 4, 5, 6]]));
    }

    #[test]
    fn positions_with_multi_codepoint_graphemes() {
        // Decomposed "é" (e + U+0301) is one nucleo character but two Emacs characters.
        let index = index_of(&["e\u{301}e\u{301}/x.rs"]);
        let result = Matcher::new().query(&index, "x", 10, true);
        assert_eq!(result.positions, Some(vec![vec![5]]));
        let result = Matcher::new().query(&index, "x.r", 10, true);
        assert_eq!(result.positions, Some(vec![vec![5, 6, 7]]));
        let result = Matcher::new().query(&index, "ee", 10, true);
        assert_eq!(result.positions, Some(vec![vec![0, 2]]));
        assert_eq!(grapheme_starts("e\u{301}e\u{301}/x"), [0, 2, 4, 5]);
        assert_eq!(grapheme_starts("abc"), [0, 1, 2]);
    }

    #[test]
    fn positions_only_when_requested_and_for_returned_paths() {
        let index = index_of(&["abc", "xabc", "zzz"]);
        let result = Matcher::new().query(&index, "abc", 1, false);
        assert_eq!(result.positions, None);
        let result = Matcher::new().query(&index, "abc", 2, true);
        assert_eq!(result.paths, ["abc", "xabc"]);
        assert_eq!(result.positions, Some(vec![vec![0, 1, 2], vec![1, 2, 3]]));
        // Two atoms that overlap: positions deduplicated.
        let result = Matcher::new().query(&index, "abc bc", 1, true);
        assert_eq!(result.positions, Some(vec![vec![0, 1, 2]]));
    }

    #[test]
    fn limit_clamp_and_total() {
        let mut index = Index::new();
        for i in 0..MAX_LIMIT + 5 {
            index.add(&format!("f{i}"));
        }
        let mut matcher = Matcher::new();
        let result = matcher.query(&index, "", 0, false);
        assert_eq!(result.paths, ["f0"]);
        assert_eq!(result.total, MAX_LIMIT + 5);
        let result = matcher.query(&index, "", usize::MAX, false);
        assert_eq!(result.paths.len(), MAX_LIMIT);
        assert_eq!(result.total, MAX_LIMIT + 5);
        let result = matcher.query(&index, "f1", 3, false);
        assert_eq!(result.paths, ["f1", "f10", "f11"]);
        assert_eq!(result.total, index.iter().filter(|p| p.contains('1')).count());
        let result = matcher.query(&index, "zzz", 3, false);
        assert_eq!(result, QueryResult { paths: vec![], positions: None, total: 0 });
    }

    #[test]
    fn empty_index() {
        let index = Index::new();
        let result = Matcher::new().query(&index, "a", 10, true);
        assert_eq!(result, QueryResult { paths: vec![], positions: Some(vec![]), total: 0 });
    }

    #[test]
    fn narrowing_conditions() {
        for (old, new, expected) in [
            ("", "a", true),
            ("a", "ab", true),
            ("ab", "ab", true),
            ("ab", "ab c", true),
            ("ab ", "ab c", true),
            ("^sr", "^src", true),
            ("'co", "'cor", true),
            ("!te", "!tes", false),                // negation grows: excludes less
            ("te", "te !x", false),                // appended `!`
            ("te", "te!", false),                  // appended `!`
            ("!x te", "!x tes", true),             // `!` only in an earlier atom
            ("rs", "rs$", false),                  // appended `$`
            ("rs$", "rs$x", false),                // old ends with `$`
            ("r$s", "r$sx", false),                // `$` in the last atom
            ("a$ b", "a$ bc", true),               // `$` only in an earlier atom
            ("a\\", "a\\ b", false),               // old ends with `\`
            ("!a\\ b", "!a\\ bc", false),          // escaped space: the last atom is `!a\ b`
            ("!a\tb", "!a\tbc", true),             // a tab splits atoms: the last atom is `b`
            ("!a\\\tb", "!a\\\tbc", false),        // escaped tab: the last atom is `!a\<tab>b`
            ("!a\u{3000}b", "!a\u{3000}bc", true), // ideographic space splits atoms
            ("abc", "ab", false),                  // deletion
            ("abc", "abd", false),                 // edit
            ("foo", "fooB", true),                 // smart case turns exact: narrower
            ("ma", "mañ", true),                   // normalization turns exact: narrower
            ("mañ", "mañá", false),                // non-ASCII atom loses normalization (nucleo quirk)
            ("ⱥ", "ⱥé", false),                    // the case that breaks
            ("ⱥ", "ⱥx", true),                     // ASCII appended: normalization unchanged
            ("^A", "^AB", true),                   // case-sensitive prefix
            ("^A x", "^A xy", true),               // only the last atom matters
            ("^a", "^aB", true),                   // insensitive prefix to sensitive one: narrower
            ("^aB", "^aBc", true),
            ("A", "AB", true),
            ("'A", "'AB", true),
        ] {
            assert_eq!(narrows(old, new), expected, "{old:?} -> {new:?}");
        }
        assert_eq!(last_atom("a b\\ c"), "b\\ c");
        assert_eq!(last_atom("a b "), "");
        assert_eq!(last_atom(" x"), "x");
        assert_eq!(last_atom("a\tb"), "b");
        assert_eq!(last_atom("a\\\tb"), "a\\\tb");
        assert_eq!(last_atom("ほげ\u{3000}ふが"), "ふが");
        assert_eq!(last_atom("x"), "x");
    }

    #[test]
    fn narrowing_is_used_and_invalidated() {
        let mut index = index_of(&["src/a.rs", "src/b.rs", "lib/c.rs", "doc/d.md"]);
        let mut matcher = Matcher::new();
        matcher.query(&index, "rs", 10, false);
        assert_eq!(matcher.last_scored, 4);
        matcher.query(&index, "rs s", 10, false);
        assert_eq!(matcher.last_scored, 3);
        index.add("src/e.rs");
        let result = matcher.query(&index, "rs sr", 10, false);
        assert_eq!(matcher.last_scored, 5, "index changed: full scoring");
        assert_eq!(result.total, 3);
        matcher.query(&index, "rs src", 10, false);
        assert_eq!(matcher.last_scored, 3);
        matcher.query(&index, "rs sr", 10, false);
        assert_eq!(matcher.last_scored, 5, "deletion: full scoring");
        // A fresh index with possibly the same number of changes never reuses the cache.
        let other = index_of(&["src/a.rs", "src/b.rs", "lib/c.rs", "doc/d.md", "src/e.rs"]);
        matcher.query(&other, "rs src", 10, false);
        assert_eq!(matcher.last_scored, 5);
    }

    #[test]
    fn escaped_space_negation_does_not_narrow_wrongly() {
        let index = index_of(&["my folder/x", "my file/x", "other/x"]);
        let mut matcher = Matcher::new();
        let r = matcher.query(&index, "!my\\ f", 10, false);
        assert_eq!(r.paths, ["other/x"]);
        let r = matcher.query(&index, "!my\\ fi", 10, false);
        assert_eq!(r.paths, ["other/x", "my folder/x"]);
    }

    /// Case-sensitive prefixes narrow correctly (nucleo-matcher 0.3.1 got them wrong, fixed upstream), and the
    /// normalization quirk that `narrows` works around.
    #[test]
    fn narrowing_and_nucleo_quirks() {
        let index = index_of(&["A", "AB", "ABC", "Ⱥé", "Ⱥx", "Ƅé", "x/Fo", "Fo", "Foo", "Foo/bar"]);
        let sequences = [&["^A", "^AB", "^ABC"][..], &["ⱥ", "ⱥé"], &["ⱥ", "ⱥx"], &["ƅ", "ƅé"], &["^F", "^Fo", "^Foo"]];
        for sequence in sequences {
            let mut matcher = Matcher::new();
            for text in sequence {
                assert_eq!(matcher.query(&index, text, 10, true), reference(&index, text, 10, true), "{text:?}");
            }
        }
        let mut got = paths(&index, "^Fo");
        got.sort();
        assert_eq!(got, ["Fo", "Foo", "Foo/bar"]);
        // Fixed upstream (nucleo commit dc305406): case-sensitive prefix of a longer ASCII path.
        assert!(score("AB", "^A").is_some());
        assert!(score("Foo", "^Fo").is_some());
        assert_eq!(score("foo", "^Fo"), None);
        // Still present: the longer atom matches where the shorter one does not.
        assert_eq!(score("Ⱥé", "ⱥ"), None);
        assert!(score("Ⱥé", "ⱥé").is_some());
    }

    #[test]
    fn parallel_scoring_merges_chunks() {
        let mut index = Index::new();
        for i in 0..1000 {
            index.add(&format!("d{}/f{i}.rs", i % 7));
        }
        for (threshold, threads) in [(0, 2), (0, 3), (10, 4), (999, 8), (0, 33)] {
            let mut matcher = Matcher::with_parallelism(threshold, threads);
            for (text, limit) in [("", 5), ("f1", 20), ("d3 rs", 1000), ("zz", 3), ("f", 1)] {
                assert_eq!(
                    matcher.query(&index, text, limit, true),
                    reference(&index, text, limit, true),
                    "threshold {threshold} threads {threads} {text:?}"
                );
            }
        }
        // More threads than candidates: some chunks are empty.
        let small = index_of(&["a/b", "b/c", "c/d"]);
        let mut matcher = Matcher::with_parallelism(0, 8);
        assert_eq!(matcher.query(&small, "b", 2, true), reference(&small, "b", 2, true));
        // The public constructor with a forced threshold works too.
        let mut matcher = Matcher::with_parallel_threshold(0);
        assert_eq!(matcher.query(&index, "f9", 50, true), reference(&index, "f9", 50, true));
    }

    /// Deterministic pseudo-random numbers (64-bit LCG, Knuth's MMIX constants).
    struct Lcg(u64);

    impl Lcg {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            self.0 >> 33
        }

        fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
            items[self.next() as usize % items.len()]
        }
    }

    fn generated_index(n: usize) -> Index {
        const DIRS: &[&str] = &[
            "src",
            "lib",
            "test",
            "tests",
            "Foo",
            "bar",
            "dö",
            "ñame",
            "util",
            "core",
            "e\u{301}t",
            "my folder",
            "my file",
            "Core",
            "src_util",
            "a b",
            "x$y",
            "!bang",
            "Ünï",
        ];
        const STEMS: &[&str] = &[
            "main",
            "mod",
            "util",
            "FooBar",
            "foo_bar",
            "test_core",
            "readme",
            "ñ",
            "café",
            "cafe\u{301}",
            "a",
            "index",
            "matcher",
            "walk",
            "Ab",
        ];
        const EXTS: &[&str] = &["rs", "md", "txt", "rsx", "c", "h", "el", ""];
        let mut lcg = Lcg(42);
        let mut index = Index::new();
        while index.len() < n {
            let depth = 1 + lcg.next() as usize % 4;
            let mut path = String::new();
            for _ in 0..depth {
                path.push_str(lcg.pick(DIRS));
                path.push('/');
            }
            path.push_str(lcg.pick(STEMS));
            if lcg.next().is_multiple_of(3) {
                path.push_str(&(lcg.next() % 100).to_string());
            }
            let ext = lcg.pick(EXTS);
            if !ext.is_empty() {
                path.push('.');
                path.push_str(ext);
            }
            index.add(&path);
        }
        index
    }

    /// Every prefix of `text`, in typing order.
    fn typed(text: &str) -> Vec<String> {
        text.char_indices().map(|(i, c)| text[..i + c.len_utf8()].to_owned()).collect()
    }

    /// One step of a query sequence.
    enum Step {
        Query(String),
        Add(&'static str),
        Remove(&'static str),
    }

    fn queries(texts: &[&str]) -> Vec<Step> {
        texts.iter().map(|t| Step::Query(t.to_string())).collect()
    }

    fn typing(text: &str) -> Vec<Step> {
        typed(text).into_iter().map(Step::Query).collect()
    }

    #[test]
    fn parallel_and_narrowing_equal_full_scoring() {
        let mut index = generated_index(4000);
        for p in ["tab\there/x.rs", "ほげ ふが/x.rs", "cr\r\nlf/x.rs", "Foo"] {
            index.add(p);
        }
        let mut sequences: Vec<Vec<Step>> = [
            "srcutil",
            "src/util",
            "foo bar",
            "fooB",
            "FooBar",
            "test !core",
            "lib rs$",
            "lib rs$ main",
            "^src ut",
            "^dö ñ",
            "'core f",
            "café",
            "cafe\u{301}",
            "e\u{301}t m",
            "ma mañ",
            "ünï",
            "Ünï",
            "!my\\ fi",
            "my\\ fo",
            "a\\ b",
            "x$y",
            "x\\$",
            "\\!bang",
            "!bang m",
            "^lib$",
            "s r c u t i l m a i n r s",
            "zzz",
            "^Foo/ba",
            "^Core m",
            "!test\tmain",
            "!tab\\\there",
            "ほげ\u{3000}ふ",
            "!ほげ\u{3000}x",
            "cr\r\nl",
            "ƅ ⱥé",
        ]
        .iter()
        .map(|t| typing(t))
        .collect();
        // Deleting characters, editing, and retyping.
        sequences.push(queries(&["utilx", "util", "utila", "uti", "ut", "", "u", "ut"]));
        sequences.push(queries(&["test", "tes", "test", "test!", "test!c", "test", "test c"]));
        sequences.push(queries(&["rs", "rs$", "rs$ ", "rs$ m", "rs", "rs m"]));
        // Index changes between queries.
        sequences.push(vec![
            Step::Query("ut".into()),
            Step::Add("zz/util_new.rs"),
            Step::Query("uti".into()),
            Step::Query("util".into()),
            Step::Remove("zz/util_new.rs"),
            Step::Query("util_".into()),
            Step::Add("util_x"),
            Step::Query("util_x".into()),
            Step::Remove("util_x"),
            Step::Query("util_x".into()),
        ]);

        // One matcher per thread count, all fed the same steps; 1 thread scores sequentially even above the
        // threshold, so it checks narrowing alone.
        let mut narrowed = 0;
        for (seq_no, sequence) in sequences.iter().enumerate() {
            let mut matchers: Vec<(usize, Matcher)> =
                [1, 3, 8].into_iter().map(|t| (t, Matcher::with_parallelism(100, t))).collect();
            for (step_no, step) in sequence.iter().enumerate() {
                match step {
                    Step::Add(p) => assert!(index.add(p)),
                    Step::Remove(p) => assert!(index.remove(p)),
                    Step::Query(text) => {
                        let (limit, positions) = [(50, true), (1, true), (10_000, false), (7, true)][step_no % 4];
                        let want = reference(&index, text, limit, positions);
                        for (threads, matcher) in &mut matchers {
                            let got = matcher.query(&index, text, limit, positions);
                            assert_eq!(got, want, "sequence {seq_no} step {step_no} {text:?} threads {threads}");
                            narrowed += usize::from(matcher.last_scored < index.len());
                        }
                    }
                }
            }
        }
        assert!(narrowed > 300, "narrowing was used {narrowed} times");
    }
}
