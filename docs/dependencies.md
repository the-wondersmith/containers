# Declared dependencies

This is the **podman package's** dependency policy. The dependency sets are deliberately opinionated: **no `Recommends`, no `Suggests`**. A
package either needs something at runtime, in which case it is a hard dependency, or it does not ship as a dependency at all. (The Proxmox VE
image reasons about upstream `Recommends`/`Suggests` differently — it installs a `Suggests`-only firmware package explicitly, because a
closure that stops at `Depends` would omit something the image genuinely needs; see [the package matrix](pve-package-matrix.md).)

|                           | Debian `Depends`                  | Alpine `runtime`         |
|---------------------------|-----------------------------------|--------------------------|
| OCI runtime               | `crun (>= 1.14) \| runc`          | `crun`                   |
| Monitor                   | `conmon (>= 2.1.7)`               | `conmon`                 |
| Rootless networking       | `passt`                           | `passt`                  |
| Firewall                  | `nftables`                        | `nftables`               |
| Shared config/policy      | `golang-github-containers-common` | `containers-common`      |
| subuid/subgid tools       | `uidmap`                          | `shadow-uidmap`          |
| Trust store               | `ca-certificates`                 | `ca-certificates-bundle` |
| Maintainer-script helpers | `init-system-helpers (>= 1.54)`   | —                        |
| journald                  | `libsystemd0`                     | —                        |

`netavark`, `aardvark-dns`, `catatonit`, and `buildah` are conspicuously absent from both: they are
[bundled](podman-package.md), not depended upon.

## The two that look like they could be softer, and cannot

**`libsystemd0` is listed explicitly and must stay that way.** podman reaches journald through go-systemd's `sdjournal`, which **`dlopen`s**
`libsystemd.so.0` rather than linking it — verified: the binary carries the `sd_journal_*` symbols and the `libsystemd.so.0` string, but no
ELF `NEEDED` entry. `dh_shlibdeps` cannot see a `dlopen`, so `${shlibs:Depends}` does not pick it up. Keeping the journald log driver is the
entire reason the Debian podman is a separate dynamically linked build, so its dependency should not be left to chance — systemd hosts
happen to always have `libsystemd0`, which is exactly how a missing dependency stays invisible until someone hits it.

**`ca-certificates` is a hard dependency, not a `Recommends`.** Debian's own podman only recommends it. Without a trust store podman cannot
pull from any HTTPS registry:

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

A podman that cannot fetch an image is not usefully installed. Alpine's `ca-certificates-bundle` is listed for the same reason even though
it currently arrives transitively — that should not depend on another package's dependency graph staying the way it is today.

## Hard runtime facts

- **`nftables` is mandatory.** netavark 2.x deleted all iptables and CNI support upstream. This is also what makes the
  [firewall reload watchers](services.md) load-bearing rather than nice-to-have.
- **`passt`/pasta is the only rootless networking stack.** slirp4netns was removed in podman 6.0 and is not a dependency.
- **cgroups v2 is required.** cgroups v1 is not supported.

## Related

- [The podman package](podman-package.md) — why the helpers are absent from these lists
- [Linkage policy](linkage.md) — why only one binary in the payload contributes to `${shlibs:Depends}`
- [Distribution](distribution.md) — why these versions force trixie
