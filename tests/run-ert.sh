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
# projdex prefers a module built next to its own projdex.el (lisp/, by
# projdex-build-module).  Test copies of the Lisp files, so the debug
# module below is the one under test.
cp lisp/*.el "$out/"
for ext in so dylib dll; do
    for built in "target/debug/libprojdex.$ext" "target/debug/projdex.$ext"; do
        if [ -f "$built" ]; then
            cp "$built" "$out/projdex-module.$ext"
        fi
    done
done
exec "${EMACS:-emacs}" --batch --module-assertions \
    -L "$out" -L "$emrs_el" \
    -l "$root/tests/projdex-tests.el" \
    --eval "(ert-run-tests-batch-and-exit (or (getenv \"ERT_SELECTOR\") t))"
