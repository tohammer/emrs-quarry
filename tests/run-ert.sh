#!/bin/sh
# Build the module, install it under the name Emacs expects, and run the
# ERT suite with module assertions enabled. emrs.el is taken from the emrs
# checkout that Cargo resolved, so it always matches the Rust crate.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
cargo build
emrs_el=$(cargo metadata --format-version 1 |
    sed -n 's|.*"manifest_path":"\([^"]*\)/emrs/Cargo.toml".*|\1/elisp|p' | head -n 1)
if [ ! -f "$emrs_el/emrs.el" ]; then
    echo "run-ert.sh: emrs.el not found next to the emrs crate" >&2
    exit 1
fi
out="$root/target/elisp"
mkdir -p "$out"
# quarry prefers a module built next to its own quarry.el (lisp/, by
# quarry-build-module).  Test copies of the Lisp files, so the debug
# module below is the one under test.
rm -f "$out"/*.el "$out"/*.elc
cp lisp/*.el "$out/"
for ext in so dylib dll; do
    for built in "target/debug/libquarry.$ext" "target/debug/quarry.$ext"; do
        if [ -f "$built" ]; then
            cp "$built" "$out/quarry-module.$ext"
        fi
    done
done
# Extra load-path directories, colon-separated, e.g. for consult and
# compat.  They become the positional parameters, as -L arguments.
set --
if [ -n "${QUARRY_TEST_LOAD_PATH:-}" ]; then
    set -f
    old_ifs=$IFS
    IFS=:
    for dir in $QUARRY_TEST_LOAD_PATH; do
        if [ -n "$dir" ]; then
            set -- "$@" -L "$dir"
        fi
    done
    IFS=$old_ifs
    set +f
fi
if ! "${EMACS:-emacs}" --batch "$@" --eval \
     "(kill-emacs (if (and (require 'consult nil t) (fboundp 'consult--async-pipeline)) 0 1))" \
     >/dev/null 2>&1; then
    echo "run-ert.sh: consult 2.0 or later not found; the tests that need consult are skipped (see QUARRY_TEST_LOAD_PATH)"
fi
exec "${EMACS:-emacs}" --batch --module-assertions \
    -L "$out" -L "$emrs_el" "$@" \
    -l "$root/tests/quarry-tests.el" \
    -l "$root/tests/quarry-consult-tests.el" \
    --eval "(ert-run-tests-batch-and-exit (or (getenv \"ERT_SELECTOR\") t))"
