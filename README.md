# containers

A centralized toolkit for building distributable Linux packages for container tooling.

[![CI](https://github.com/the-wondersmith/containers/actions/workflows/ci.yaml/badge.svg)](https://github.com/the-wondersmith/containers/actions/workflows/ci.yaml)
[![Release](https://img.shields.io/github/v/release/the-wondersmith/containers?sort=semver)](https://github.com/the-wondersmith/containers/releases/latest)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

The current deliverable is a self-contained **podman** package for Debian (`.deb`) and Alpine (`.apk`), for `amd64` and
`arm64`. It bundles `netavark`, `aardvark-dns`, `catatonit`, and the `buildah` CLI into the payload, so it installs with **zero
container-tooling dependencies** — no repository ships those helpers at the 2.x versions podman 6 needs.

## Install

Download the artifacts for your platform from the [latest release](https://github.com/the-wondersmith/containers/releases/latest).

**Debian** (trixie or newer):

```sh
apt install ./podman_6.0.2-1_amd64.deb
```

**Alpine**:

```sh
apk add --allow-untrusted ./podman-6.0.2-r1.apk
```

Debian packages are also served from the [`the-wondersmith/apt`](https://github.com/the-wondersmith/apt) repository, which signs its own
index. Local files carry no signature of their own — see [package signing](docs/signing.md).

## What you get

- **Nothing else to install.** The helpers ship inside the package, at the path podman already searches, and no dependency is soft — a
  `Recommends` you skipped cannot leave you with a broken podman.
- **Statically linked**, everywhere it is possible to be. The one exception is podman itself on Debian, which links against `libsystemd` to
  keep the journald log driver.
- **Services enabled on install** — the API endpoint, the netavark DHCP proxy, and watchers that re-apply container firewall rules after an
  nftables or firewalld reload, on both systemd and OpenRC.
- **Rootless works out of the box**, including on Alpine, whose stock `storage.conf` otherwise breaks it.
- **Built, tested, and attested in CI.** Every release carries a SLSA build-provenance attestation bound to the exact bytes published, and
  no release happens without a privileged behavioural acceptance suite passing first.

## Documentation

Design rationale, build and release mechanics, and contributor docs live in **[`docs/`](docs/README.md)**.

Start with [the podman package](docs/podman-package.md) for the bundling model, [declared dependencies](docs/dependencies.md) for what it
needs at runtime, [build model](docs/build-model.md) for how it is built, or [local development](docs/development.md) to build it yourself.

## License

[AGPL-3.0](LICENSE).
