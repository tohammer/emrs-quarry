# Contributing

## Development setup

Work in a checkout, for example `~/src/emacs-quarry`.

### Doom Emacs

Keep the user recipe and add the checkout when it exists
(`my/quarry-dev` is any variable name):

```elisp
(defvar my/quarry-dev (file-directory-p "~/src/emacs-quarry"))
(package! quarry
  :recipe `(:host github :repo "tohammer/emrs-quarry" :files ("lisp/*.el")
            :pre-build ((load (expand-file-name "lisp/quarry-build.el") nil t)
                        (quarry-build-module-sync))
            ,@(when my/quarry-dev
                '(:local-repo "~/src/emacs-quarry" :build (:not compile)))))
```

With an absolute `:local-repo`, straight uses the checkout and never
clones or pulls it. `:build (:not compile)` leaves no `.elc` that would
shadow edits. The module is loaded from `lisp/quarry-module.so` in the
checkout.

| Change | Do | Takes effect |
|---|---|---|
| Elisp in `lisp/` | `eval-buffer`, or restart | at once, no `doom sync` |
| Rust in `src/` | `M-x quarry-build-module` | after restarting Emacs |
| New file in `lisp/` | remove `.local/straight/build-<version>/quarry` in the Doom directory, then `doom sync`, before restarting | after restarting Emacs |
| emrs too | the same recipe pattern for `emrs` (file `elisp/emrs.el`), and the cargo patch in the next section | after restarting Emacs |

Without removing the build directory, `doom sync` keeps the old
symlinks after a new file in `lisp/`, and Emacs fails at startup with
`Cannot open load file ... quarry-core` or similar.

### Build against a local emrs

Put this in `.cargo/config.toml` and do not commit it:

```toml
[patch."https://github.com/tohammer/emrs.git"]
emrs = { path = "../emrs/emrs" }
```

`Cargo.toml` pins emrs to a commit. Pin only commits on emrs's default
branch: users get `emrs.el` from that branch (ADR 0007).

## Tests

```sh
cargo test                          # Rust unit and service tests
tests/run-ert.sh                    # builds the debug module and runs the ERT suite
ERT_SELECTOR=cache tests/run-ert.sh # only tests whose name matches the regexp
EMACS=/path/to/emacs tests/run-ert.sh
```

`tests/run-ert.sh` tests copies of the Lisp files in `target/elisp` with
the debug module, so a module built in `lisp/` does not affect them.

With `EMRS_MODULE_FILE` the script tests that module and builds nothing.
Name the file `quarry-module.so`, `.dylib` or `.dll`. `EMRS_EL_DIR` names
the directory of `emrs.el`; without it the script finds `emrs.el` through
Cargo. The emrs release workflow uses both to test each released module:

```sh
EMRS_MODULE_FILE=/tmp/quarry-module.so EMRS_EL_DIR=/path/to/emrs/elisp tests/run-ert.sh
```

Some tests need packages, found through `QUARRY_TEST_LOAD_PATH`, a
colon-separated list of directories added to `load-path`:

```sh
QUARRY_TEST_LOAD_PATH=~/.emacs.d/straight/build/consult:~/.emacs.d/straight/build/compat:~/.emacs.d/straight/build/wgrep tests/run-ert.sh
```

- `tests/quarry-consult-tests.el` and `tests/quarry-consult-grep-tests.el`
  need consult (2.0 or later for the file finder; the live grep is
  tested with 3.7) and compat. Without them the script says so and skips
  the tests that call consult; the tests of the async steps, of the
  input syntax, of the directory logic and of loading without consult
  still run.
- `tests/quarry-grep-wgrep-tests.el` needs wgrep. Without it those tests
  are skipped, except the one for the refusals of `e`.

With `QUARRY_TEST_REQUIRE_PACKAGES` set to any non-empty value, a missing
consult or wgrep is an error instead of skipped tests. CI and the release
workflow set it.

Rerun the suite with these packages after upgrading consult, wgrep or
transient: quarry uses internals of each (ADRs 0008, 0013, 0016, 0018).

## Benchmarks

```sh
bench/run-bench.sh                  # file finder
bench/run-bench.sh --size 1m        # 100k, 1m or both; also --skip-baseline, --keep
bench/run-bench.sh replace          # grep replace; checks every written file
```

The file finder benchmark generates AOSP-like trees (nested
directories, empty files, committed to a temporary git repository) and
types about 100 query prefixes through `completion-all-completions` with
the `quarry` style and a limit of 100, timing each call. The baseline is
`project-files` of the vc backend followed by `flex`. Trees need up to
about 800 MB and 1.2 million inodes for `1m`, more with the git
repository for the baseline, and go to `target/bench-trees` or
`$QUARRY_BENCH_DIR`. The script exits non-zero when quarry's p99 exceeds
50 ms (100k) or 150 ms (1m).

The replace benchmark builds the release module, generates trees of
1,000 and 10,000 files with 5 matched lines each and one of 1,000 files
with 100 matched lines each, and times the preview and the writing,
twice each. It compares every file with the expected content and exits
non-zero when one differs. Trees go to a temporary directory under
`$QUARRY_BENCH_TMP`, `$TMPDIR` or `/tmp` and are removed. Results are in
`docs/architecture/grep.md`, "Cost of large change sets".

## Releasing

`.github/workflows/release.yml` calls emrs's reusable
`module-release.yml`. A tag `v<version>` builds the module for
linux-x86_64, linux-aarch64 and macos-aarch64, runs the smoke test and
the ERT suite against each file on Emacs 30.1 and 31.1, and publishes the
files and `SHA256SUMS` to the release. Started by hand (`gh workflow run
release.yml`), it builds and tests without publishing.

Versions follow ADR 0026: between releases `Cargo.toml` and the
`;; Version:` header of `lisp/quarry.el` carry the same
`<next>-snapshot`.

1. On a branch, set both to the release version, for example `0.2.0`,
   run `cargo build` to update `Cargo.lock`, and merge the pull request.
2. Tag the merge commit and push the tag:

   ```sh
   git switch master && git pull --ff-only
   git tag v0.2.0
   git push origin v0.2.0
   ```

   Use a lightweight tag: the README tells Doom users to pin the commit
   that `git ls-remote` shows for it.
3. Check the release: three module files and `SHA256SUMS`.
4. On a branch, set both versions to the next snapshot, for example
   `0.3.0-snapshot`, and merge it.

If a platform's tests fail, nothing is published. Fix the cause, delete
the tag (`git push origin :v0.2.0`, `git tag -d v0.2.0`) and tag again.

## CI

`.github/workflows/ci.yml` runs on every pull request and on `master`:
`cargo fmt --all -- --check`, `cargo clippy --all-targets -- -D
warnings` and `cargo test` on Linux, `cargo check` with the minimum
supported Rust, and `tests/run-ert.sh` on Linux and macOS with Emacs
30.1 and 31.1, with consult and wgrep from GNU ELPA and NonGNU ELPA.

`master` takes changes only through pull requests, merged with a merge
commit.

## Documentation

- `README.md`, `docs/user/`: user documentation.
- `docs/architecture.md`, `docs/architecture/`: how the system is built.
- `docs/specs/`: specifications; `docs/decisions/`: decision records.
- `docs/backlog.md`, `docs/backlog/`, `docs/next-steps.md`: open points
  and what comes next.
