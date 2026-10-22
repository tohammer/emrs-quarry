#!/bin/sh
# Benchmark quarry against project-files + flex on generated AOSP-like
# trees of 100,000 and 1,000,000 empty files (spec "Testing", "Benchmark").
#
# Usage: bench/run-bench.sh [--size 100k|1m|both] [--skip-baseline] [--keep]
#        bench/run-bench.sh replace
#
# "replace" measures grep replace instead (see bench/replace-bench.el):
# 1,000 and 10,000 files with 5 matched lines each, and 1,000 files with
# 100 matched lines each (100,000 matches), each twice; the trees are
# generated in a temporary directory ($QUARRY_BENCH_TMP or $TMPDIR) and
# removed afterwards.
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

mode=files
if [ "${1:-}" = replace ]; then
    mode=replace
    shift
fi
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
# Keep the user's install directory and the network out of the runs.
install_eval="(setq emrs-install-directory (file-name-as-directory (make-temp-file \"emrs-install\" t)) emrs-install-download 'never)"
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
    --eval "$install_eval" \
    --eval '(setq byte-compile-error-on-warn t)' \
    -f batch-byte-compile "$out/quarry-bench.el"

if [ "$mode" = replace ]; then
    # Copies of the Lisp files next to the release module, which the
    # installer finds through `load-path'.
    out="$root/target/bench-replace-elisp"
    mkdir -p "$out"
    rm -f "$out"/*.el "$out"/*.elc
    cp lisp/*.el "$out/"
    for ext in so dylib dll; do
        for built in "target/release/libquarry.$ext" "target/release/quarry.$ext"; do
            if [ -f "$built" ]; then
                cp "$built" "$out/quarry-module.$ext"
            fi
        done
    done
    cp "$root/bench/replace-bench.el" "$out/"
    "$emacs" --batch -L "$emrs_el" -L "$out" \
        --eval "$install_eval" \
        --eval '(setq byte-compile-error-on-warn t)' \
        -f batch-byte-compile "$out/replace-bench.el"
    tmp=$(mktemp -d "${QUARRY_BENCH_TMP:-${TMPDIR:-/tmp}}/quarry-replace-bench.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT INT TERM
    status=0
    for run in 1 2; do
        for label in 1k-5 10k-5 1k-100k; do
            # Not through a pipe: sh has no pipefail, and the exit status
            # of Emacs says whether every file was as expected.
            rc=0
            "$emacs" --batch -L "$emrs_el" -L "$out" \
                --eval "$install_eval" \
                -l "$out/replace-bench.elc" \
                --eval "(quarry-replace-bench-run)" "$label" "$tmp" \
                >"$tmp/run.log" 2>&1 || rc=$?
            cat "$tmp/run.log"
            cat "$tmp/run.log" >>"$tmp/log"
            [ "$rc" -eq 0 ] || status=1
        done
    done
    echo
    echo "Run  case      files  matches  preview(s)  work(s)  apply(s)  verified"
    grep '^RESULT' "$tmp/log" | awk '{ split($3,f,"="); split($4,m,"="); split($5,p,"="); split($6,w,"="); split($7,a,"=");
        split($8,v,"="); printf "%-4d %-9s %-6s %-8s %-11s %-8s %-9s %s\n", ++n, $2, f[2], m[2], p[2], w[2], a[2], v[2] }'
    if [ "$(grep -c '^RESULT' "$tmp/log")" -ne 6 ]; then
        echo "run-bench.sh: not every case printed a result" >&2
        status=1
    fi
    exit $status
fi

trees=${QUARRY_BENCH_DIR:-$root/target/bench-trees}
mkdir -p "$trees"
trees=$(cd "$trees" && pwd)
version=$("$emacs" --batch -L "$root/lisp" -L "$emrs_el" -L "$out" --eval "$install_eval" -l "$out/quarry-bench.elc" \
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
        "$emacs" --batch -L "$root/lisp" -L "$emrs_el" -L "$out" --eval "$install_eval" -l "$out/quarry-bench.elc" \
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
        --eval "$install_eval" -l "$out/quarry-bench.elc" -f quarry-bench-run \
        "$size" "$tree" "$threshold" "$baseline" || status=1
    if [ "$keep" = 0 ]; then
        rm -rf "$tree" "$stamp" "$trees/tree-$size.git"
    fi
done
exit $status
