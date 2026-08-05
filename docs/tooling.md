# Tooling

`mise.toml` plus `mise.lock` are **the** single source of truth for tooling, in CI as much as locally. Nothing under
`.github/` downloads or installs a tool that mise can provide — no `actions/setup-*`, no `curl`-a-tarball, no `apt-get` for anything mise
carries. `prepare-ci-env` does nothing but invoke `jdx/mise-action` and then assert `mise install --locked`, which fails if any enabled tool
lacks a pre-resolved URL and checksum for the platform, so a lockfile miss cannot quietly become an unpinned download.

## The lockfile

The lockfile pins exact versions and per-platform checksums for `linux-x64`, `linux-arm64`, and `macos-arm64`. Refresh it with:

```sh
mise lock -p 'linux-x64,linux-arm64,macos-arm64'
```

`mise.ci.toml` narrows the set to what CI actually invokes — notably excluding both Rust toolchains and `cargo-binstall`, since the Rust
components compile inside melange's Alpine guest from *its* toolchain, not from mise's. `uv` is present because `yamllint` has no binary
release and resolves to `pipx:yamllint`; without a Python package manager, `mise install`
fails outright in a bare distro container.

## Two deliberate exceptions

Both because they are not our build environment:

- `.github/scripts/acceptance.sh` installs `jq`, `binutils`, and `iproute2` with apt/apk *inside the container under test*. That is the
  package's target environment; putting mise there would test something no user will ever run.
- Distro build and runtime dependencies — `libsystemd-dev`, `debhelper`, `dpkg-dev`, `libsubid5`, `go-md2man` — stay on apt. They are
  target-platform ABI and packaging tools, not tooling mise carries. `curl`, `git`, and `tar` stay too:
  mise-action needs them to bootstrap itself.

## Related

- [Local development](development.md) — the tasks mise exposes
- [Build model](build-model.md) — why only one half of the build takes its Go from mise
