#!/bin/sh
# Install consult (with compat) and wgrep from GNU ELPA and NonGNU ELPA into
# target/elpa and print the value for QUARRY_TEST_LOAD_PATH on stdout, e.g.
#   QUARRY_TEST_LOAD_PATH=$(tests/install-test-packages.sh) tests/run-ert.sh
# Emacs's own output goes to stderr.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
"${EMACS:-emacs}" --batch --eval '(progn
  (require (quote package))
  (setq package-user-dir (expand-file-name "target/elpa"))
  (package-initialize)
  (package-refresh-contents)
  (package-install (quote consult))
  (package-install (quote wgrep)))' >&2
for dir in "$root"/target/elpa/*/; do
    case $dir in
        */archives/) ;;
        *) printf '%s:' "${dir%/}" ;;
    esac
done
printf '\n'
