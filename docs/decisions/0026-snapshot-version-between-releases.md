# 0026 — Between releases the version is `<next>-snapshot`, in Cargo.toml and quarry.el alike

Date: 2026-10-19
Status: accepted

## Context

Prebuilt modules are released with emrs's reusable workflow. A release is
tagged `v<version>` with the crate version, and an installer downloads
only the release of the exact version (emrs ADR 0004). Doom and straight
users follow `master`, so after a release the crate version must move on;
otherwise their newer Elisp would be paired with the previous release's
binary.

quarry has two version strings: `version` in `Cargo.toml`, which the
module reports as `:version`, and the `;; Version:` header of `quarry.el`,
which package.el and package-vc read. emrs suggests `<next>-dev` for the
crate, but `version-to-list` rejects `0.2.0-dev`, and an invalid header
breaks package-vc. It accepts `0.2.0-snapshot` (as `(0 2 0 -4)`, older
than `0.2.0`), which Cargo also accepts as a pre-release.

Options: `<next>-snapshot` in both files; `<next>-dev` in the crate with
the header left at the last release; bumping only at a release.

## Decision

- After a release `vX.Y.Z`, `Cargo.toml` and the header of `quarry.el`
  both become `X.Y+1.0-snapshot` (or another next version), the same
  string in both.
- A release sets both to the plain version, then the tag `vX.Y.Z` is
  pushed on that commit.

The user chose this on 2026-10-19.

## Consequences

- One version everywhere; the module's `:version` and the package version
  can be compared directly, which the coming emrs installer needs.
- No release ever has the version of a snapshot, so a snapshot build never
  downloads a binary; it builds locally, as the installer's fallback
  intends (emrs ADR 0006).
- quarry's string differs from emrs-dirdiff's `-dev`; emrs's tooling only
  needs a pre-release, so both work.
- The release workflow publishes a version with `-` as a prerelease;
  tagging a snapshot by mistake gives a prerelease, not a broken release.
