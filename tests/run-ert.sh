#!/bin/sh
# Build the module, install it under the name Emacs expects, and run the
# ERT suite with module assertions enabled. emrs.el is taken from the emrs
# checkout that Cargo resolved, so it always matches the Rust crate.
#
# EMRS_MODULE_FILE: test this prebuilt module instead of building one.
#   Nothing is built; the file is installed as quarry-module.<ext>.
# EMRS_EL_DIR: the directory of emrs.el, instead of the Cargo lookup.
# QUARRY_TEST_REQUIRE_PACKAGES: when non-empty, missing consult or wgrep
#   is an error instead of skipped tests (CI and the release set it).
# The emrs release workflow sets both to test each released module.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [ -n "${EMRS_MODULE_FILE:-}" ]; then
    if [ ! -f "$EMRS_MODULE_FILE" ]; then
        echo "run-ert.sh: EMRS_MODULE_FILE not found: $EMRS_MODULE_FILE" >&2
        exit 1
    fi
else
    cargo build
fi
if [ -n "${EMRS_EL_DIR:-}" ]; then
    emrs_el=$EMRS_EL_DIR
    if [ ! -f "$emrs_el/emrs.el" ]; then
        echo "run-ert.sh: emrs.el not found in EMRS_EL_DIR: $emrs_el" >&2
        exit 1
    fi
else
    emrs_el=$(cargo metadata --format-version 1 |
        sed -n 's|.*"manifest_path":"\([^"]*\)/emrs/Cargo.toml".*|\1/elisp|p' | head -n 1)
    if [ ! -f "$emrs_el/emrs.el" ]; then
        echo "run-ert.sh: emrs.el not found next to the emrs crate" >&2
        exit 1
    fi
fi
out="$root/target/elisp"
mkdir -p "$out"
# quarry prefers a module built next to its own quarry.el (lisp/, by
# quarry-build-module).  Test copies of the Lisp files, so the debug
# module below is the one under test.  Remove old modules too, so none
# from an earlier run is left over.
rm -f "$out"/*.el "$out"/*.elc "$out"/quarry-module.*
cp lisp/*.el "$out/"
if [ -n "${EMRS_MODULE_FILE:-}" ]; then
    cp "$EMRS_MODULE_FILE" "$out/quarry-module.${EMRS_MODULE_FILE##*.}"
else
    for ext in so dylib dll; do
        for built in "target/debug/libquarry.$ext" "target/debug/quarry.$ext"; do
            if [ -f "$built" ]; then
                cp "$built" "$out/quarry-module.$ext"
            fi
        done
    done
fi
# Extra load-path directories, colon-separated, e.g. for consult,
# compat and wgrep.  They become the positional parameters, as -L arguments.
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
    missing=yes
fi
if ! "${EMACS:-emacs}" --batch "$@" --eval \
     "(kill-emacs (if (require 'wgrep nil t) 0 1))" \
     >/dev/null 2>&1; then
    echo "run-ert.sh: wgrep not found; the tests that need wgrep are skipped (see QUARRY_TEST_LOAD_PATH)"
    missing=yes
fi
if [ -n "${missing:-}" ] && [ -n "${QUARRY_TEST_REQUIRE_PACKAGES:-}" ]; then
    echo "run-ert.sh: QUARRY_TEST_REQUIRE_PACKAGES is set, so missing packages are an error" >&2
    exit 1
fi
exec "${EMACS:-emacs}" --batch --module-assertions \
    -L "$out" -L "$emrs_el" "$@" \
    -l "$root/tests/quarry-tests.el" \
    -l "$root/tests/quarry-consult-tests.el" \
    -l "$root/tests/quarry-consult-grep-tests.el" \
    -l "$root/tests/quarry-grep-tests.el" \
    -l "$root/tests/quarry-grep-wgrep-tests.el" \
    --eval "(ert-run-tests-batch-and-exit (or (getenv \"ERT_SELECTOR\") t))"
