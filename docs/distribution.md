# Distribution

Packages are published as GitHub Releases with SLSA build-provenance attestations bound to the exact bytes released — both
`.deb`s and both `.apk`s, alongside the `manifest.json` that records the component set. On release a `repository_dispatch`
notifies a separate APT repository control plane, which owns publishing for the Debian packages. Prereleases are never dispatched.

## Why there are two dispatch paths

A release created with the default `GITHUB_TOKEN` does **not** fire the `release: published` event — GitHub suppresses it to prevent
workflow recursion. So dispatch has three callers rather than one:

| Caller                      | Covers                                                      |
|-----------------------------|-------------------------------------------------------------|
| `release.yaml`              | CI-created releases, which never fire the event             |
| `promote-prerelease.yaml`   | prereleases promoted after their soak, for the same reason  |
| `publish-apt-packages.yaml` | releases a human creates in the GitHub UI, which do fire it |

Ingest is idempotent on `(repo, tag)`, so a rare double-dispatch is harmless. All three funnel through the shared
`.github/actions/apt-dispatch` composite, and `publish-apt-packages.yaml` additionally refuses to run for a prerelease.

## Why trixie, not bookworm

The Debian package targets **trixie**, not bookworm. That is not a preference — bookworm cannot satisfy the runtime dependencies at all: it
ships crun 1.8.1 against a `>= 1.14` requirement, conmon 2.1.6 against `>= 2.1.7`, and has no
`golang-github-containers-common` at any version. Its debhelper (13.11) is also too old to discover systemd units installed under
`usr/lib/systemd/system`, so unit enablement silently does nothing. trixie supplies crun 1.21, conmon 2.1.12, containers-common 0.62, and
debhelper 13.24.

Note the dependency is `golang-github-containers-common`, which is what Debian actually calls it. `containers-common` is the Alpine and
Fedora name and does not exist in Debian, not even as a virtual package.

Because the payload is self-contained, installation needs nothing else:

```sh
apt install ./podman_6.0.2-1_amd64.deb
```

## Related

- [Package signing](signing.md) — why the released artefacts carry no signature
- [Release process](releases.md) — what triggers a dispatch
- [The podman package](podman-package.md) — why "self-contained" is literal
