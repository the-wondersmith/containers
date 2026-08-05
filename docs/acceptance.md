# Acceptance suite

`.github/scripts/acceptance.sh` is the only thing standing between an upstream tag and a published package. Because
[releases are unattended](releases.md), it tests behavior, not file placement:

- `podman run` (crun + conmon) and `podman run --init` (bundled catatonit)
- `podman build` plus a content check on the resulting image
- **`podman network create` and container-to-container DNS** — the lockstep canary. If a `netavark` or `aardvark-dns`
  major bump is incompatible with the bundled podman, nothing else here would notice.
- rootless operation as an unprivileged user, exercising pasta and rootlessport
- Debian only: `--log-driver=journald` and the presence of the unit files
- linkage assertions against the static/dynamic model
- installed versions matched against the requested component set

## How it runs

The suite runs inside `docker run --privileged --cgroupns=host` from an ordinary runner step rather than a `container:`
job. The runner VM is already root, which yields the cgroup, netns, and nftables access netavark needs without nested virtualization — and
it is the only way to test the `.apk`, which cannot be installed on the Ubuntu host.

All four package/arch combinations run, with `fail-fast: false` so one distro's failure does not hide another's. arm64 runs on native
`ubuntu-24.04-arm` runners rather than under emulation.

Three paths need to be on a real filesystem, supplied as anonymous volumes (`-v /var/lib/containers -v /var/tmp -v /home`)
because overlayfs cannot be stacked on itself:

| Path                  | Why                                                                                          |
|-----------------------|----------------------------------------------------------------------------------------------|
| `/var/lib/containers` | graph driver root — `'overlay' is not supported over overlayfs, a mount_program is required` |
| `/var/tmp`            | where buildah stages the build-context overlay                                               |
| `/home`               | rootless storage lives under `$HOME`, so the same constraint applies again                   |

Forcing the `vfs` driver would also make the suite pass, and is deliberately *not* done: it would stop exercising the overlay driver users
actually get.

The suite is POSIX `sh` throughout, because on Alpine it runs under busybox `ash` and the point is to exercise the package on a stock base
image rather than one tailored to the tests. It also applies no workarounds of its own — see
[rootless storage](rootless-storage.md) — so a regression in a shipped config fragment fails the release rather than being masked.

## Fail closed, not open

Several of these assertions are the kind that pass vacuously when their tooling is missing, and each is guarded:

- `binutils` is installed explicitly on both distros, because `readelf … 2>/dev/null | grep -q NEEDED` against a *missing*
  `readelf` produces no output — which reads as "statically linked" for every binary in the payload.
- The linkage check counts what it inspected and fails if that count is zero.
- Mount points are detected via `/proc/mounts` rather than `stat -f -c %T`: busybox `stat` reports `UNKNOWN` for btrfs and friends, so a
  filesystem-type comparison silently matched nothing on Alpine and passed regardless.

## Related

- [Release process](releases.md) — what the suite gates
- [Linkage policy](linkage.md) — the model the linkage assertions check against
- [Service enablement](services.md) — the nftables reload assertions, in both directions
