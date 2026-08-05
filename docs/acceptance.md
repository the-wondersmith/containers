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

## Rootless is split by who owns the failure

The rootless assertions are deliberately in two parts.

**What this package owns** — the uid/gid mapping, the shipped
[rootless-storage fragment](rootless-storage.md), and running a container as an unprivileged user — is asserted with
`--network host`, which involves no pasta at all. That is a hard failure on both distros.

**What the environment owns** is pasta. Alpine 3.23 ships pasta `2025_09_19` and rootless pasta does not work inside this
harness; Debian's `2025_05_03` does. Everything else measured is identical between the two: `newuidmap` privileges
(capabilities on Alpine, setuid-root on Debian, both effective), the full subuid range mapped, `/dev/net/tun`, the runtime
directory mode, and the userns limits. pasta fails within a millisecond of starting, with `EACCES` on
`/proc/sys/net/ipv4/ip_local_port_range` and on the netns path.

This was confirmed not to be a packaging problem by installing **Alpine's own podman 5.7.0** into the same privileged
container, where it fails the same way. Nothing in this package is involved in the difference.

So a pasta failure matching that exact signature is recorded as `KNOWN-FAIL` with a workflow warning rather than blocking
the release. **Any other failure still fails**, and host networking cannot produce that signature, so the tolerance cannot
mask a regression in the part the package is responsible for. Skipping the assertion outright would have hidden real
regressions too, which is the opposite of what this suite exists for.

Once Alpine's pasta works in a nested container — or the suite gains a non-containerised Alpine target — the tolerance
should be deleted and the assertion made hard again.

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
