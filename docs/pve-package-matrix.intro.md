## What this document answers

Proxmox VE 9.2 shipped official arm64 support on 2026-08-05 with a five-item
caveat list. Those caveats are written for someone installing PVE on bare
metal. This repository ships PVE in a container, so the caveats have to be
re-evaluated against a target they were not written for, and separated from
the problems that are caused by containerisation rather than by architecture.

The matrix below is generated from the live APT indices, not from
documentation and not from memory. The four questions the brief poses are
answered from that data.

### 1. Which packages impose each of the five official arm64 caveats?

| # | Official caveat | Package that actually imposes it |
|---|---|---|
| 1 | VMs boot only through UEFI/AAVMF; SeaBIOS unavailable | `pve-qemu-kvm`, surfaced by `qemu-server` |
| 2 | AMD SEV and Intel GVT-g are x86-only | `pve-qemu-kvm` (SEV); GVT-g is imposed by no package in the closure |
| 3 | No OS-level CPU microcode package | No package in the closure |
| 4 | Guests run only on matching-arch nodes; same-arch live migration | `qemu-server`, `pve-container`, `pve-ha-manager`, `pve-cluster` |
| 5 | Individual packages may be released later on arm64 | `ifupdown2` (the only measured instance) |

Two of these five entries deserve emphasis because they contradict the
intuition that a documented caveat must correspond to a missing package.

**Caveat 1 is not a packaging limitation.** `pve-edk2-firmware-legacy`, which
carries the SeaBIOS blob, is `Architecture: all` and is published at
`4.2025.05-3` in *both* the amd64 and arm64 indices. It is a hard `Depends` of
`qemu-server` and therefore installs on arm64 whether or not anything can use
it. The caveat is a property of the emulator: `qemu-system-aarch64` exposes no
machine type that consumes a SeaBIOS image. The constraint is real, but it
lives at guest-configuration time, not at install time, and no package-level
check will ever detect it.

**Caveat 3 imposes nothing here.** `intel-microcode` and `amd64-microcode` are
not in the `proxmox-ve` closure on either architecture. There is no arm64
analogue to be missing, because there is no amd64 member to be missing it.

### 2. Which of those caveats are moot in a container, and why?

| # | Status in a container | Why |
|---|---|---|
| 1 | **Real, but confined to guests** | Only reachable once a VM is defined. Tier B territory; it does not affect whether the management plane works. |
| 2 | **Moot** | SEV and GVT-g are host-hardware passthrough features. A container that does not own the CPU's security engine or the iGPU cannot offer them on either architecture. |
| 3 | **Moot** | A container manages no CPU microcode. The relevant packages are absent from the closure, so this is moot twice over. |
| 4 | **Moot** | Single-node image. There is no second node to migrate to, and `corosync` is masked. |
| 5 | **Real, and the only one that costs work** | Measured, not hypothetical. See `ifupdown2` below. |

Caveat 4 is worth one further note: it is not merely out of scope, it is
*doubly* out of scope. Even were clustering in scope, mixed-architecture
clusters are not officially supported upstream, so a same-arch restriction
would bind before the container's own limitations did.

### 3. Which container problems are arch-independent?

All of them.

Twenty packages in the closure are classified container-hostile. Every single
one carries `affects both arches = yes`. Not one container-hostility finding
is specific to arm64, and not one is specific to amd64:

| Failure class | Packages |
|---|---|
| FUSE mounts | `pve-cluster` (pmxcfs at `/etc/pve`), `lxcfs` |
| Host network ownership | `ifupdown2` |
| Cluster membership over UDP | `corosync`, `libknet1t64` |
| Hardware watchdog | `pve-ha-manager` |
| Block device and udev access | `lvm2`, `dmsetup`, `smartmontools` |
| Kernel and firmware management | `proxmox-default-kernel`, `proxmox-kernel-helper`, `pve-firmware` |
| PID 1 and device management | `systemd`, `systemd-sysv`, `udev` |
| Guest execution | `pve-qemu-kvm`, `qemu-server` |
| Nested LXC | `pve-container`, `lxc-pve` |
| Mail spool and FQDN | `postfix` |

This is the finding the whole exercise was built to test, and the data
supports it without qualification. It has a direct scheduling consequence:
every one of these must be solved on amd64 first, because solving them is not
architecture work. Attempting them on arm64 concurrently would make "PVE does
not work in a container" and "our arm64 handling is broken" produce
indistinguishable failures.

### 4. Does any package reduce arm64 functionality below the baseline floor?

**No.**

The genuinely architecture-specific components — `pve-qemu-kvm`,
`pve-cluster`, `qemu-server`, `pve-container`, `pve-ha-manager`, `lxc-pve`,
`swtpm` — are all published for arm64 at *byte-identical versions* to amd64.
`pve-manager` and the whole Perl and JavaScript layer are `Architecture: all`
and identical by construction. There is no functional deficit to report.

Two qualifications, stated as findings rather than absorbed:

**`ifupdown2` is the one real gap, and it is subtler than "missing".** Proxmox
publishes `3.3.0-1+pmx12` as `Architecture: all` into the amd64 index only. On
arm64 the dependency still resolves — to Debian trixie's `3.0.0-1.3`, an older
version from a different repository. The build succeeds, nothing warns, and
the two architectures quietly ship different code. That is a cross-architecture
divergence wearing the costume of a satisfied dependency, and no check that
merely asks "does it install?" will ever see it. It is the sole
`build-and-publish` disposition in a 568-package closure.

**The ceph client stack diverges, upstream, in the opposite direction to the
one the brief anticipated.** Thirteen packages sit at `19.2.3-pve1` (squid) on
amd64 and `20.2.0-pve1` (tentacle) on arm64 — arm64 is *ahead*, by a major
version. The version sets are strictly disjoint, so no common pin exists; and
Debian's `ceph-fuse` is published amd64-only, so the tier-2 fallback cannot
satisfy `libpve-storage-perl` on arm64 either. This is recorded as an
allowlisted known divergence rather than a build failure. Skew detection is
therefore **symmetric** by design: assuming arm64 always lags would have missed
this entirely.

## Four traps worth recording

**`pve-edk2-firmware-aarch64` is only a `Suggests`.** It is not in the
dependency closure. Installing `proxmox-ve` — on either architecture — does not
install it. Since it supplies AAVMF, and caveat 1 means every arm64 guest must
boot UEFI, omitting it silently removes the ability to boot an aarch64 guest at
all. It must be installed explicitly. It is `Architecture: all`, so the same
explicit install serves both architectures and the Containerfile needs no
`$TARGETARCH` branch for firmware.

**Ceph splits into a mandatory half and an optional half.** `ceph-common` and
`ceph-fuse` are unconditional `Depends` of `libpve-storage-perl`, which is in
turn a hard dependency of `pve-manager`, `qemu-server` and `pve-container`;
`pve-qemu-kvm` depends on `ceph-common` independently. The ceph *client* cannot
be omitted without breaking dpkg. The ceph *server* packages — `ceph-base`,
`ceph-mon`, `ceph-osd`, `ceph-mds`, `ceph-mgr`, `radosgw` — are depended on by
nothing in the closure and are simply absent from it. That is the same
behaviour as a stock PVE install, where they arrive only via `pveceph install`.
No guard mechanism is required; the dependency graph already excludes them.

### 3. `e2fsprogs` is required at run time and is in no dependency

`pct create` on directory-backed storage formats a rootfs with `mkfs.ext4`. Nothing
in the closure pulls `e2fsprogs`, and `debian:trixie-slim` does not ship it, so the
call fails with `exec of mkfs.ext4 ... failed: No such file or directory` -- a
message naming neither the package nor the reason. It is the same class of finding
as the AAVMF trap above: a runtime dependency that the declared metadata does not
declare. The Containerfile installs it explicitly.

This one only surfaces when a container is actually created, so it survives every
check that stops at "the image starts and the API answers".

### 4. Sized `dir` rootfs volumes need a loop device

A sized rootfs (`--rootfs local:1`) creates a raw image file and attaches it through
`losetup`. Docker exposes no `/dev/loop*` or `/dev/loop-control` by default, so this
fails with `losetup: failed to set up loop device: No such file or directory`. An
unsized rootfs (`--rootfs local:0`) extracts straight into `/var/lib/vz/private/<vmid>`
and needs no loop device.

This is a runtime constraint rather than a packaging one -- it appears here because
it is discovered in the same place and by the same means as the other three, and
because reading the package graph would never reveal it.

## How to read the table

- **amd64 / arm64** — the newest version present in *that architecture's*
  `Packages` index. Availability is determined by index membership alone.
  `Architecture: all` is not evidence of availability: an `all` package still
  has to be listed in `binary-arm64/Packages` to be installable there, and
  Proxmox publishes several `all` packages into the amd64 index only.
- **arch-hostile** — unavailable on arm64, or diverging in version. Maps to one
  of the five official caveats.
- **container-hostile** — breaks because it is in a container, on any
  architecture.
- **both** — whether the container-hostility applies to both architectures.
  This is the column the exercise exists to fill in.
- **notes** — `mixed-origin` means the two architectures resolve from different
  repositories. `binNMU-only` means the versions differ solely by a Debian
  binary-rebuild suffix; those are per-architecture rebuilds of identical
  source and are not divergence.
- **disposition** — `install-from-proxmox`, `install-from-debian`,
  `install-with-known-skew` (allowlisted, documented in `DEVIATIONS.md`),
  `build-and-publish` (built from Proxmox sources and served through
  `the-wondersmith/apt`), `stub` (satisfied by `pve-container-shim`), or
  `not-installed-stubbed` (reachable only through a stubbed package, so never
  installed).
