#!/bin/sh
# Benchmark quarry against project-files + flex on generated AOSP-like
# trees of 100,000 and 1,000,000 empty files (spec "Testing", "Benchmark").
#
# Usage: bench/run-bench.sh [--size 100k|1m|both] [--skip-baseline] [--keep]
#
#   --size           trees to measure (default: both)
#   --skip-baseline  do not measure project-files + flex (it needs a git
#                    commit of the tree, which takes a while on 1m)
#   --keep           keep the generated trees for the next run; a kept tree
#                    is reused when its generator version matches
#
# Trees go to $QUARRY_BENCH_DIR (default: target/bench-trees). They need
# about 1.1 inodes per file plus one 4 KiB block per directory: roughly
# 80 MB and 120,000 inodes for 100k, 800 MB and 1.2 million inodes for 1m,
# more with the git repository the baseline needs (the 1m index file alone
# is about 100 MB).
#
# Exits non-zero when quarry's p99 latency exceeds 50 ms (100k) or 150 ms
# (1m), or on any error.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

sizes="100k 1m"
baseline=1
keep=0
while [ $# -gt 0 ]; do
    case $1 in
        --size)
            [ $# -ge 2 ] || { echo "run-bench.sh: --size needs a value" >&2; exit 2; }
            case $2 in
                100k|1m) sizes=$2 ;;
                both) sizes="100k 1m" ;;
                *) echo "run-bench.sh: --size must be 100k, 1m or both" >&2; exit 2 ;;
            esac
            shift 2 ;;
        --skip-baseline) baseline=0; shift ;;
        --keep) keep=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "run-bench.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

emacs=${EMACS:-emacs}
cargo build --release
emrs_el=$(cargo metadata --format-version 1 |
    sed -n 's|.*"manifest_path":"\([^"]*\)/emrs/Cargo.toml".*|\1/elisp|p' | head -n 1)
if [ ! -f "$emrs_el/emrs.el" ]; then
    echo "run-bench.sh: emrs.el not found next to the emrs crate" >&2
    exit 1
fi
out="$root/target/bench-elisp"
mkdir -p "$out"
for ext in so dylib dll; do
    for built in "target/release/libquarry.$ext" "target/release/quarry.$ext"; do
        if [ -f "$built" ]; then
            cp "$built" "$out/quarry-module.$ext"
        fi
    done
done
cp "$root/bench/quarry-bench.el" "$out/"
"$emacs" --batch -L "$root/lisp" -L "$emrs_el" -L "$out" \
    --eval '(setq byte-compile-error-on-warn t)' \
    -f batch-byte-compile "$out/quarry-bench.el"

trees=${QUARRY_BENCH_DIR:-$root/target/bench-trees}
mkdir -p "$trees"
trees=$(cd "$trees" && pwd)
version=$("$emacs" --batch -L "$root/lisp" -L "$emrs_el" -L "$out" -l "$out/quarry-bench.elc" \
    --eval '(princ quarry-bench-generator-version)')

echo "Trees in $trees:"
df -h "$trees" | tail -n 1
df -i "$trees" | tail -n 1

now_s() {
    # date +%s%N is not POSIX; seconds suffice for the slow steps here.
    date +%s
}

status=0
for size in $sizes; do
    case $size in
        100k) n=100000 threshold=50 ;;
        1m) n=1000000 threshold=150 ;;
    esac
    tree="$trees/tree-$size"
    stamp="$trees/tree-$size.stamp"
    if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "generator=$version" ]; then
        echo
        echo "Generating the $size tree in $tree"
        rm -rf "$tree" "$stamp" "$trees/tree-$size.git"
        start=$(now_s)
        "$emacs" --batch -L "$root/lisp" -L "$emrs_el" -L "$out" -l "$out/quarry-bench.elc" \
            --eval "(quarry-bench-generate $n \"$trees/tree-$size\")"
        mkdir -p "$tree"
        (cd "$tree" && xargs mkdir -p < "$trees/tree-$size.dirs" &&
             xargs touch < "$trees/tree-$size.files")
        rm -f "$trees/tree-$size.dirs" "$trees/tree-$size.files"
        echo "generator=$version" > "$stamp"
        echo "Generated in $(($(now_s) - start)) s, $(du -sh "$tree" | cut -f 1) on disk"
    else
        echo
        echo "Reusing the $size tree in $tree"
    fi
    if [ "$baseline" = 1 ] && [ ! -f "$trees/tree-$size.git" ]; then
        echo "Committing the $size tree to git (needed by the baseline)"
        start=$(now_s)
        rm -rf "$tree/.git"
        (cd "$tree" && git init -q &&
             git add -A &&
             git -c user.name=bench -c user.email=bench@example.invalid \
                 -c commit.gpgsign=false commit -q -m "bench tree")
        touch "$trees/tree-$size.git"
        echo "Committed in $(($(now_s) - start)) s, $(du -sh "$tree/.git" | cut -f 1) in .git"
    fi
    "$emacs" --batch -L "$root/lisp" -L "$emrs_el" -L "$out" \
        -l "$out/quarry-bench.elc" -f quarry-bench-run \
        "$size" "$tree" "$threshold" "$baseline" || status=1
    if [ "$keep" = 0 ]; then
        rm -rf "$tree" "$stamp" "$trees/tree-$size.git"
    fi
done
exit $status
