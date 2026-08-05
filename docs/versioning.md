# Versioning

There is no `versions.yaml`. Versions are **inputs**, resolved at run time and recorded as **output**.

`upstream-watch.yaml` runs weekly, resolves the newest `x.y.z` tag for every component, peels it to a commit SHA, and diffs the result
against the `manifest.json` asset attached to the most recent release. That manifest is the repository's entire persistent state — no bump
commits, no bump pull requests, no auto-merge machinery.

## The committed versions are a snapshot, not the source of truth

Each melange definition does carry a `version` and a `git-checkout` `expected-commit`. CI never reads either as an input:
the component jobs copy the definition to `.melange-build/` and rewrite both from the resolved component set before building, and the bundle
job rewrites its own `version` and `epoch` in place. What those committed values mean is "the versions this repository was last verified
against".

They still matter locally, because `mise run build` and every `act` run *do* read them — and the act event fixtures are derived from them.
Left alone they drift, and a local build quietly produces something older than what CI releases.
`mise run versions:refresh` resolves upstream the same way `upstream-watch.yaml` does and rewrites the definitions in place, without
committing.

## pkgrel

`pkgrel` is likewise derived rather than stored: it resets to `1` when podman's own version changes and increments otherwise, so a release
driven purely by a `buildah` bump still produces a distinguishable package. One number drives all three identities — git tag `v6.0.2-1`,
Debian `6.0.2-1`, Alpine `6.0.2-r1`.

## Related

- [Release process](releases.md) — how a resolved version set becomes a release
- [Component cache](component-cache.md) — why the cache key needs more than a version
