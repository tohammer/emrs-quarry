//! The path set of one project: every indexed file as a path relative to the root.
//!
//! Paths are `/`-separated, without a leading `./`, valid UTF-8. Each path is kept ready for matching as a
//! [`Utf32String`], so a query does not convert strings.
//!
//! Memory: an ASCII path (the common case) is stored once, inside its `Utf32String::Ascii`. A non-ASCII path
//! (or an ASCII path containing `\r\n`, which nucleo treats as one grapheme) is stored twice: the original text and nucleo's codepoint form (which keeps only the first codepoint of each
//! grapheme, so the text cannot be recovered from it). The lookup table holds a 64-bit hash per path and the
//! slot number, not a copy of the path; hash collisions are resolved by comparing with the stored path.
//!
//! Removal is O(1) amortised: the last slot is moved into the freed one (`swap_remove`) and its table entry is
//! updated. Slot numbers are therefore stable only while the set does not change, which [`Index::version`]
//! tells.

#![allow(dead_code)]

use nucleo_matcher::{Utf32Str, Utf32String};
use std::collections::HashMap;
use std::collections::hash_map::{Entry as MapEntry, RandomState};
use std::hash::BuildHasher;
use std::sync::atomic::{AtomicU64, Ordering};

/// Source of index versions. Versions are unique across all `Index` instances of the process, so a version
/// identifies one state of one index (the matcher's narrowing cache relies on that when the service swaps in a
/// fresh index after a walk).
static NEXT_VERSION: AtomicU64 = AtomicU64::new(1);

fn next_version() -> u64 {
    NEXT_VERSION.fetch_add(1, Ordering::Relaxed)
}

/// One indexed path.
struct Entry {
    /// The path in nucleo's form. For an ASCII path this is `Utf32String::Ascii` holding the path itself.
    hay: Utf32String,
    /// The original text of a non-ASCII path; `None` for ASCII paths (the text is in `hay`).
    text: Option<Box<str>>,
}

impl Entry {
    fn new(path: &str) -> Self {
        let hay = Utf32String::from(path);
        let text = match hay {
            Utf32String::Ascii(_) => None,
            Utf32String::Unicode(_) => Some(Box::from(path)),
        };
        Entry { hay, text }
    }

    fn path(&self) -> &str {
        match (&self.text, &self.hay) {
            (Some(text), _) => text,
            (None, Utf32String::Ascii(text)) => text,
            (None, Utf32String::Unicode(_)) => unreachable!("non-ASCII entries keep their text"),
        }
    }
}

/// Slots of the paths sharing one hash value (almost always exactly one).
enum Bucket {
    One(u32),
    Many(Vec<u32>),
}

pub struct Index {
    entries: Vec<Entry>,
    table: HashMap<u64, Bucket>,
    hasher: RandomState,
    version: u64,
}

impl Default for Index {
    fn default() -> Self {
        Self::new()
    }
}

impl Index {
    pub fn new() -> Self {
        Index { entries: Vec::new(), table: HashMap::new(), hasher: RandomState::new(), version: next_version() }
    }

    fn hash(&self, path: &str) -> u64 {
        self.hasher.hash_one(path)
    }

    /// The slot holding `path`, if present.
    fn find(&self, hash: u64, path: &str) -> Option<u32> {
        match self.table.get(&hash)? {
            Bucket::One(slot) => (self.entries[*slot as usize].path() == path).then_some(*slot),
            Bucket::Many(slots) => slots.iter().copied().find(|&slot| self.entries[slot as usize].path() == path),
        }
    }

    /// Adds `path`; returns false if it was already present.
    pub fn add(&mut self, path: &str) -> bool {
        let hash = self.hash(path);
        if self.find(hash, path).is_some() {
            return false;
        }
        let slot = u32::try_from(self.entries.len()).expect("index holds at most u32::MAX paths");
        self.entries.push(Entry::new(path));
        match self.table.entry(hash) {
            MapEntry::Vacant(vacant) => {
                vacant.insert(Bucket::One(slot));
            }
            MapEntry::Occupied(mut occupied) => {
                let bucket = occupied.get_mut();
                match bucket {
                    Bucket::One(other) => *bucket = Bucket::Many(vec![*other, slot]),
                    Bucket::Many(slots) => slots.push(slot),
                }
            }
        }
        self.version = next_version();
        true
    }

    /// Removes `path`; returns false if it was absent.
    pub fn remove(&mut self, path: &str) -> bool {
        let hash = self.hash(path);
        let Some(slot) = self.find(hash, path) else {
            return false;
        };
        self.unlink(hash, slot);
        self.remove_slot(slot);
        self.version = next_version();
        true
    }

    /// Removes every path below the directory `dir` (paths starting with `dir/`; `dirx/...` is not below `dir`).
    /// A trailing `/` on `dir` is ignored. Returns the number of paths removed. This scans the whole index.
    pub fn remove_dir(&mut self, dir: &str) -> usize {
        let dir = dir.trim_end_matches('/');
        let below = |path: &str| {
            if dir.is_empty() {
                return true;
            }
            path.len() > dir.len() && path.starts_with(dir) && path.as_bytes()[dir.len()] == b'/'
        };
        let mut removed = 0;
        let mut slot = 0;
        while slot < self.entries.len() {
            if below(self.entries[slot].path()) {
                let hash = self.hash(self.entries[slot].path());
                self.unlink(hash, slot as u32);
                self.remove_slot(slot as u32);
                removed += 1;
                // The last entry moved into `slot`; look at it next.
            } else {
                slot += 1;
            }
        }
        if removed > 0 {
            self.version = next_version();
        }
        removed
    }

    /// Drops the table entry pointing at `slot`.
    fn unlink(&mut self, hash: u64, slot: u32) {
        let MapEntry::Occupied(mut occupied) = self.table.entry(hash) else {
            unreachable!("present path has a table entry");
        };
        match occupied.get_mut() {
            Bucket::One(_) => {
                occupied.remove();
            }
            Bucket::Many(slots) => {
                slots.retain(|&s| s != slot);
                if let [only] = slots[..] {
                    *occupied.get_mut() = Bucket::One(only);
                }
            }
        }
    }

    /// Removes the entry at `slot` (already unlinked) by moving the last entry into it.
    fn remove_slot(&mut self, slot: u32) {
        let last = (self.entries.len() - 1) as u32;
        self.entries.swap_remove(slot as usize);
        if slot != last {
            let hash = self.hash(self.entries[slot as usize].path());
            match self.table.get_mut(&hash).expect("moved path has a table entry") {
                Bucket::One(s) => *s = slot,
                Bucket::Many(slots) => {
                    for s in slots.iter_mut().filter(|s| **s == last) {
                        *s = slot;
                    }
                }
            }
        }
    }

    pub fn contains(&self, path: &str) -> bool {
        self.find(self.hash(path), path).is_some()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// All paths, in unspecified order.
    pub fn iter(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().map(Entry::path)
    }

    /// Changes whenever the set changes (every successful add or remove). Versions are unique across all
    /// indexes of the process, so equal versions mean the same index in the same state.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The path in slot `slot` (`0..len()`). Slots are valid until the next change.
    pub(crate) fn path(&self, slot: u32) -> &str {
        self.entries[slot as usize].path()
    }

    /// The path in slot `slot` in nucleo's form.
    pub(crate) fn haystack(&self, slot: u32) -> Utf32Str<'_> {
        self.entries[slot as usize].hay.slice(..)
    }

    /// Whether nucleo has one character per Unicode scalar value of the path in slot `slot`, i.e. nucleo's
    /// indices are character indices. False only for paths with multi-codepoint graphemes (e.g. decomposed
    /// accents), because nucleo keeps only the first codepoint of each grapheme.
    pub(crate) fn chars_are_graphemes(&self, slot: u32) -> bool {
        let entry = &self.entries[slot as usize];
        match &entry.text {
            None => true,
            Some(text) => text.chars().count() == entry.hay.len(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted(index: &Index) -> Vec<&str> {
        let mut paths: Vec<&str> = index.iter().collect();
        paths.sort();
        paths
    }

    /// Every path is found through the table at the slot it occupies, and the table holds nothing else.
    fn check_consistent(index: &Index) {
        for slot in 0..index.len() as u32 {
            let path = index.path(slot);
            assert_eq!(index.find(index.hash(path), path), Some(slot), "{path}");
        }
        let in_table: usize = index
            .table
            .values()
            .map(|b| match b {
                Bucket::One(_) => 1,
                Bucket::Many(s) => s.len(),
            })
            .sum();
        assert_eq!(in_table, index.len());
    }

    #[test]
    fn add_contains_len() {
        let mut index = Index::new();
        assert!(index.is_empty());
        assert!(index.add("a.rs"));
        assert!(index.add("src/b.rs"));
        assert!(index.add("dö/ñame.rs"));
        assert_eq!(index.len(), 3);
        assert!(!index.is_empty());
        assert!(index.contains("a.rs"));
        assert!(index.contains("dö/ñame.rs"));
        assert!(!index.contains("b.rs"));
        assert_eq!(sorted(&index), ["a.rs", "dö/ñame.rs", "src/b.rs"]);
        check_consistent(&index);
    }

    #[test]
    fn no_duplicates() {
        let mut index = Index::new();
        assert!(index.add("a.rs"));
        assert!(!index.add("a.rs"));
        assert!(index.add("dö.rs"));
        assert!(!index.add("dö.rs"));
        assert_eq!(index.len(), 2);
        assert_eq!(sorted(&index), ["a.rs", "dö.rs"]);
    }

    #[test]
    fn remove() {
        let mut index = Index::new();
        for p in ["a", "b", "c", "d"] {
            index.add(p);
        }
        assert!(index.remove("a"));
        assert!(!index.remove("a"));
        assert!(!index.remove("zzz"));
        assert_eq!(sorted(&index), ["b", "c", "d"]);
        check_consistent(&index);
        assert!(index.remove("d"));
        assert!(index.remove("b"));
        assert!(index.remove("c"));
        assert!(index.is_empty());
        assert!(index.add("a"));
        assert!(index.contains("a"));
        check_consistent(&index);
    }

    #[test]
    fn remove_dir_matches_whole_components() {
        let mut index = Index::new();
        for p in ["dir/a", "dir/sub/b", "dirx/c", "dir", "dirx", "other/dir/d", "dir.rs", "x"] {
            index.add(p);
        }
        assert_eq!(index.remove_dir("dir"), 2);
        assert_eq!(sorted(&index), ["dir", "dir.rs", "dirx", "dirx/c", "other/dir/d", "x"]);
        check_consistent(&index);
        assert_eq!(index.remove_dir("dir"), 0);
        assert_eq!(index.remove_dir("other/"), 1);
        assert_eq!(sorted(&index), ["dir", "dir.rs", "dirx", "dirx/c", "x"]);
        check_consistent(&index);
    }

    #[test]
    fn remove_dir_many() {
        let mut index = Index::new();
        for i in 0..1000 {
            index.add(&format!("{}/f{i}", if i % 3 == 0 { "a" } else { "b" }));
        }
        assert_eq!(index.remove_dir("a"), 334);
        assert_eq!(index.len(), 666);
        assert!(index.iter().all(|p| p.starts_with("b/")));
        check_consistent(&index);
    }

    #[test]
    fn version_bumps_only_on_change() {
        let mut index = Index::new();
        let v0 = index.version();
        assert!(index.add("a"));
        let v1 = index.version();
        assert_ne!(v1, v0);
        assert!(!index.add("a"));
        assert_eq!(index.version(), v1);
        assert!(!index.remove("b"));
        assert_eq!(index.version(), v1);
        assert_eq!(index.remove_dir("x"), 0);
        assert_eq!(index.version(), v1);
        assert!(index.add("x/y"));
        let v2 = index.version();
        assert_ne!(v2, v1);
        assert_eq!(index.remove_dir("x"), 1);
        let v3 = index.version();
        assert_ne!(v3, v2);
        assert!(index.remove("a"));
        assert_ne!(index.version(), v3);
        // Two indexes never share a version.
        assert_ne!(Index::new().version(), Index::new().version());
    }

    #[test]
    fn hash_collisions_are_resolved() {
        // Simulate three paths with the same hash by putting them into one bucket under a's hash.
        let mut index = Index::new();
        index.add("a");
        index.add("b");
        index.add("c");
        let (ha, hb, hc) = (index.hash("a"), index.hash("b"), index.hash("c"));
        index.table.remove(&hb);
        index.table.remove(&hc);
        index.table.insert(ha, Bucket::Many(vec![0, 1, 2]));
        assert_eq!(index.find(ha, "a"), Some(0));
        assert_eq!(index.find(ha, "b"), Some(1));
        assert_eq!(index.find(ha, "c"), Some(2));
        assert_eq!(index.find(ha, "d"), None);
        // Removing slot 0 moves "c" from slot 2 into slot 0; its bucket entry must follow.
        index.unlink(ha, 0);
        index.entries.swap_remove(0);
        if let Some(Bucket::Many(slots)) = index.table.get_mut(&ha) {
            for s in slots.iter_mut().filter(|s| **s == 2) {
                *s = 0;
            }
        }
        assert_eq!(index.find(ha, "c"), Some(0));
        assert_eq!(index.find(ha, "b"), Some(1));
        index.unlink(ha, 1);
        assert!(matches!(index.table.get(&ha), Some(Bucket::One(0))));
    }

    #[test]
    fn haystack_and_graphemes() {
        let mut index = Index::new();
        index.add("ab");
        index.add("dö/ñame.rs");
        index.add("e\u{301}.rs");
        assert!(index.chars_are_graphemes(0));
        assert!(index.chars_are_graphemes(1));
        assert!(!index.chars_are_graphemes(2));
        assert!(matches!(index.haystack(0), Utf32Str::Ascii(b"ab")));
        assert_eq!(index.haystack(1).len(), 10);
        assert_eq!(index.path(2), "e\u{301}.rs");
        // "\r\n" is one grapheme for nucleo, so this ASCII path gets the Unicode form and keeps its text.
        index.add("a\r\nb");
        assert!(!index.chars_are_graphemes(3));
        assert_eq!(index.haystack(3).len(), 3);
        assert_eq!(index.path(3), "a\r\nb");
        assert!(index.contains("a\r\nb"));
    }
}
