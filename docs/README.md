# Documentation

Design notes, build and release mechanics, and contributor docs for this repository.

Every document here answers *why* as much as *what* — the constraints that forced a decision are recorded alongside the decision, so a
future change knows what it is about to break.

## Package design

- **[The podman package](podman-package.md)** — why the package is monolithic, how helper resolution works, and the metadata that lets it
  stand in for `netavark`, `aardvark-dns`, `catatonit`, and `buildah`.
- **[Declared dependencies](dependencies.md)** — both dependency sets, the no-`Recommends` policy, and the two dependencies that cannot be
  softened.
- **[Linkage policy](linkage.md)** — static unless genuinely impossible, the one deliberate glibc exception, and how the rule is enforced
  rather than trusted.
- **[Service enablement](services.md)** — what ships enabled and why, and the systemd → OpenRC port of the firewall reload watchers.
- **[Rootless storage on Alpine](rootless-storage.md)** — the `storage.conf` drop-in that makes rootless podman work out of the box.

## Build and release

- **[Build model](build-model.md)** — melange against Alpine 3.23, where each half of the build gets its Go toolchain, and why build tags
  are a property of the build environment.
- **[Component cache](component-cache.md)** — the GHCR OCI-artifact cache, its tag grammar, and why not `actions/cache`.
- **[Versioning](versioning.md)** — versions as inputs, `manifest.json` as the only persistent state, and how `pkgrel`
  is derived.
- **[Release process](releases.md)** — unattended releases, the major-bump soak, and what gates a publish.
- **[Acceptance suite](acceptance.md)** — what is tested, and why it tests behaviour rather than file placement.
- **[Distribution](distribution.md)** — releases, attestations, the APT control plane, and the trixie floor.
- **[Package signing](signing.md)** — why nothing here is signed, and what is relied on instead.
- **[CI security posture](ci-security.md)** — the trust list, token handling, and the auto-merge gates.

## Contributing

- **[Repository layout](repository-layout.md)** — directory map and what each workflow is for.
- **[Tooling](tooling.md)** — mise as the single source of truth, and its two deliberate exceptions.
- **[Local development](development.md)** — devcontainer, tasks, and what can and cannot be built locally.
