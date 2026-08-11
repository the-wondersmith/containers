# Proxmox VE image

A single-node Proxmox VE 9.2 management plane in an OCI image, built from the same Containerfile for
`linux/amd64` and `linux/arm64`.

Published as `ghcr.io/the-wondersmith/containers/proxmox`.

## What this image is for

It runs the Proxmox VE management plane — `pmxcfs`, `pvedaemon`, `pveproxy`, `pvestatd`, and the web UI on
8006 — inside a container, with LXC guests where the host permits it and KVM guests where hardware
virtualisation is exposed. It is a single node. Clustering is out of scope: `corosync.service` is masked
because the image is single-node and ships no cluster configuration, so it has nothing to join; its hard
`Requires=network-online.target` only adds boot ordering for a service that cannot be useful here, and a
container has no stable node identity to cluster with in any case.

## Environment variable contract

Five capability variables, each accepting exactly `auto`, `require`, or `disable`. The default is `auto`.

| variable | governs |
|----------|---------|
| `PVE_FUSE` | the FUSE mount `pmxcfs` uses for `/etc/pve` |
| `PVE_KVM` | hardware-assisted virtualisation via `/dev/kvm` |
| `PVE_CGROUP_DELEGATION` | cgroup v2 delegation, which `pct start` requires |
| `PVE_NESTED_LXC` | the composite of cgroup delegation and AppArmor that LXC guests need |
| `PVE_GUEST_NETWORK` | the bridge and NAT that give guests a network |

### Semantics

- **`auto`** — probe; enable if present, degrade visibly if not. A degraded capability prints a summary
  line naming the outcome, the reason, and the exact runtime flag that would provide it, then start-up
  continues with the dependent units masked.
- **`require`** — probe; if the capability is absent *or* the probe could not determine an answer, fail
  fast with exit 79. The message names the capability, the outcome, the reason, the remedy, and the hint
  that `auto` would degrade instead.
- **`disable`** — do not probe at all. The state file records `probe_ran: false` and `outcome: null`, and
  the dependent units are masked exactly as they would be for a probed absence.

An unrecognised value exits 78 and names the variable together with the three legal values. A typo must
not silently become `auto`.

There is deliberately **no global override**. Each capability's fail-fast behaviour is independent,
because an operator who accepts running without KVM has said nothing at all about whether they accept
running without a working `/etc/pve`.

### Why three states rather than a boolean

A probe can fail to reach a verdict — securityfs not mounted, a cgroup control file unreadable, a helper
missing. `require` treats "could not determine" as unsatisfied, which is the same *decision* as absent but
a different *fact*, and the operator needs to know which one they are looking at. A boolean cannot carry
that, so the contract does not have one.

### Other variables

| variable | default | behaviour |
|----------|---------|-----------|
| `PVE_ROOT_PASSWORD` | `root` | set via `chpasswd`; the default is announced on stderr, not applied silently |
| `PVE_ROOT_PASSWORD_HASH` | unset | set via `chpasswd -e`; wins over `PVE_ROOT_PASSWORD` with a warning if both are set |
| `PVE_SHM_SIZE` | unset | attempts `mount -o remount,size=<value> /dev/shm`; on refusal prints a warning naming `--shm-size` and continues |
| `PVE_GUEST_BRIDGE` | `vmbr0` | name of the guest bridge declared in `/etc/network/interfaces` |
| `PVE_GUEST_SUBNET` | `10.10.10.1/24` | the bridge's own address; the guest subnet, DHCP range and NAT rule are all derived from it |
| `TZ` | UTC | when set to a zone under `/usr/share/zoneinfo`, symlinks `/etc/localtime` and writes `/etc/timezone`; an unrecognised zone is fatal (exit 80) |
| `PVE_DEBUG` | unset | `1` enables shell tracing on stderr; it cannot change any policy outcome |

`TZ` is fatal rather than advisory when the zone is not recognised, for the same reason an unrecognised
capability policy is: the operator asked for something specific and it was not understood, so continuing on
the default produces a system that looks deliberate and is not. Every timestamp written afterwards would be
plausible and wrong, and by the time anyone noticed, the name that was rejected would be long gone from the
output. Leave `TZ` unset to run on UTC on purpose.

`PVE_DEBUG` deliberately only turns on tracing. It softens no probe verdict, downgrades no required
capability, and converts no failure into a warning. A debug switch that changes what the program decides
yields a system that only works while it is being observed, and leaves the operator debugging a configuration
they will never actually run.

`--shm-size` is the documented path for `/dev/shm` sizing because it is in place before any process
starts. The remount is an opportunistic fallback that happens after the kernel has already created the
tmpfs and can legitimately be refused; failing start-up over a tuning knob would be the worse outcome.

## Resolved state

Every start writes `/run/pve-container/capabilities.json`, one entry per capability:

```json
{
  "kvm": {
    "policy": "auto",
    "probe_ran": true,
    "outcome": "absent",
    "resolved": "disabled",
    "reason": "device_absent",
    "remedy": "--device /dev/kvm"
  }
}
```

`outcome` is `null` if and only if `probe_ran` is false. `resolved` is `enabled`, `disabled`, or
`aborted`; `aborted` appears only on a `require` failure, and the file is written *before* the abort so
the state that caused it is recoverable. When `probe_ran` is false the `remedy` comes from a static
per-capability map and is never empty — a `disable` row has no probe object to source one from, and an
empty remedy there would be a silent contract violation.

The same information is printed as one line per capability at start-up, so the resolved state is visible
without reading systemd journals or parsing JSON.

## Probes

Each probe is independently invocable at `/usr/local/lib/pve/probe/<name>` and emits one JSON object —
`{capability, outcome, reason, detail, remedy}` — with exit `0`, `1`, or `2` mirroring
`present`, `absent`, `indeterminate`. An operator debugging a degraded start can run one by hand.

- **`fuse`** performs a **real mount**: it opens `/dev/fuse`, issues `mount -i -t fuse -o fd=N,...`, then
  tears the mount down. This proves three things at once — the device opens, `CAP_SYS_ADMIN` is held, and
  seccomp is not blocking `mount(2)`. Checking that `/dev/fuse` is a readable character device passes in
  cases where `pmxcfs` still fails.
- **`kvm`** does presence and permission checks in shell, then hands off to a helper that opens the device
  itself and issues `KVM_GET_API_VERSION` followed by `KVM_CREATE_VM`. Opening alone cannot distinguish a
  live device from a stale or hand-created node; the ioctls can.
  On `x86_64` the `vmx`/`svm` CPU flag is read as a **diagnostic only** — it distinguishes "virtualisation
  disabled in firmware" from "device not exposed to the container" and never gates the outcome. There is
  deliberately no `aarch64` equivalent: EL2 availability is not a CPU feature flag. The kernel either
  initialises KVM at boot or logs `HYP mode not available` and creates no device node, so the functional
  probe *is* the EL2 check.
- **`cgroup-delegation`** distinguishes no cgroupfs, cgroup v1 only, and a v2 hierarchy whose
  `cgroup.subtree_control` is not writable. The last case is `indeterminate` rather than `absent` because
  delegation may still exist at a level the container cannot observe from inside.
- **`apparmor`** checks the module parameter before securityfs, because the parameter is readable even
  when securityfs is not mounted, so an explicitly disabled module is a definite answer while a missing
  securityfs is only an unobservable one.
- **`nested-lxc`** composes the previous two asymmetrically: missing cgroup delegation is `absent`, but
  prerequisites rather than the capability itself: it reports `present` with reason `prerequisites_met`, because
  starting a guest additionally requires privileges the probe does not test — the acceptance suite runs its LXC
  lifecycle under `--privileged` for that reason. A
  missing AppArmor is `present` with reason `unconfined`. Guests still run without AppArmor, so reporting
  `absent` would disable LXC support entirely over a security-policy question the operator may already
  have answered.
- **`guest-network`** creates a throwaway bridge with `ip link` and deletes it again, rather than reading
  `CapBnd`: the bounding set says what the kernel believes is held, not what a seccomp profile will
  actually permit. See [Guest networking](#guest-networking) for what the entrypoint does when it resolves
  `enabled`.

## Runtime requirements

`--privileged` is **not** required to reach a working management plane. That was established by controlled
removal rather than assertion: each flag was dropped in turn and the resulting failures were observed and
named.

### What the host has to provide

- **Memory.** Around 2 GiB for the management plane alone; add whatever the guests need on top. pmxcfs, `pvedaemon`,
  `pveproxy`, `pvestatd` and `rrdcached` all run regardless of whether any guest exists.
- **Disk.** The image itself is roughly 400 MiB. `/var/lib/vz` holds container templates, ISOs and guest disks, so size
  it for the guests rather than for the image; an Alpine template is ~15 MiB and a small ISO ~70 MiB.
- **cgroup v2.** `--cgroupns=host` with `/sys/fs/cgroup` bind-mounted read-write. A cgroup v1 host is not supported.
- **Shared memory.** The runtime default is 64 MiB, which is the whole of `/dev/shm`. pmxcfs and the PVE daemons use
  it for their IPC segments, and QEMU uses it for guest memory backing when a guest is configured that way, so the
  default is tight rather than wrong. The invocations below pass `--shm-size 256m`. `PVE_SHM_SIZE` exists as a
  fallback that remounts `/dev/shm` after start, but `--shm-size` is the better lever because it is in place before
  any process opens the mount.
- **A shutdown grace period.** `docker stop` allows 10 seconds by default. Unmounting the pmxcfs FUSE filesystem and
  stopping `pveproxy`, `pvedaemon`, `pvestatd`, `pve-firewall` and `rrdcached` routinely takes longer, so the default
  turns every ordinary stop into a SIGKILL — that is, into precisely the unclean stop the image is built to recover
  from, on every single stop rather than only on a crash. The image sets `STOPSIGNAL SIGRTMIN+3` so systemd is asked
  to shut down properly, but that only helps if it is given time to finish, which is why the invocations below pass
  `--stop-timeout 120`.
- **KVM, if guests are wanted.** `/dev/kvm` must exist on the host *and* be passed in with `--device /dev/kvm`.
  **Docker Desktop does not provide it** — on macOS and Windows the engine runs inside a VM that is not given nested
  virtualisation, so `/dev/kvm` does not exist to be passed. The management plane, LXC guests and everything else in
  Tier A work there; KVM guests do not, and the capability probe will say so rather than failing obscurely later. On
  arm64 the requirement is stricter still: see [DEVIATIONS.md](../DEVIATIONS.md) §20.

### Management plane

```sh
docker run -d --name pve \
  --stop-timeout 120 --shm-size 256m \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  -p 8006:8006 \
  ghcr.io/the-wondersmith/containers/proxmox:9
```

`/etc/pve` mounts, the API answers, the web UI renders. The system reaches `degraded` with exactly two
failed units, both expected and both harmless to the management plane:

- `lxcfs.service` — its FUSE mount is blocked by Docker's default seccomp profile. Only LXC guests need it.
- `pvefw-logger.service` — exits 255 at `nflog_bind_pf AF_INET failed`; it needs `CAP_NET_ADMIN`, which
  Docker's default set omits. Firewall *logging* is lost; `pve-firewall.service` itself is unaffected.

### With firewall logging and a clean unit state

```sh
docker run -d --name pve \
  --stop-timeout 120 --shm-size 256m \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  --cap-add SYS_ADMIN --cap-add NET_ADMIN \
  --device /dev/fuse \
  --security-opt seccomp=unconfined \
  -p 8006:8006 \
  ghcr.io/the-wondersmith/containers/proxmox:9
```

`NET_ADMIN` clears `pvefw-logger.service` and `seccomp=unconfined` clears `lxcfs.service`, so the system
reaches `running` with no failed units at all.

This tier does **not** get you working LXC guests. `pct create` succeeds here, but `pct start` fails at
`lxc_setup: 3811 Failed to setup first automatic mounts` — the same failure as under the management-plane
tier. An earlier revision of this document claimed otherwise; that claim was disproven by the acceptance
suite and is corrected here rather than softened.

### With LXC guests

```sh
docker run -d --name pve \
  --stop-timeout 120 --shm-size 256m \
  --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  -p 8006:8006 \
  ghcr.io/the-wondersmith/containers/proxmox:9
```

Nested LXC guests require `--privileged`. This was established by trying the alternatives rather than by
assumption: the create/start/exec/stop/destroy chain fails under both tiers above and passes under this
one. `--security-opt systempaths=unconfined` and `seccomp=unconfined` were both tried and neither is
sufficient on its own.

Three constraints apply to guests:

- Use an **unsized** rootfs (`--rootfs local:0`). A sized volume creates a raw image and attaches it
  through a loop device, and Docker exposes no `/dev/loop*` by default, so `pct create` fails at
  `losetup: failed to set up loop device: No such file or directory`. The consequence of the unsized form
  is that there is no per-container disk quota; supply `--device /dev/loop-control` and the loop devices
  themselves if you need one.
- On a host whose kernel has AppArmor, set `lxc.apparmor.profile: unconfined` on the guest or it will not
  start. `lxc-start` generates a profile and cannot load it from inside a container, failing at
  `apparmor_prepare: 1126 Failed to load generated AppArmor profile` / `lxc_init: 1069 Failed to
  initialize LSM`. The consequence is that the guest runs unconfined, which is already what
  `probe/nested-lxc` reports for this runtime. A host with no AppArmor skips the LSM and needs nothing.
- Only `alpine-3.24-default` and `debian-13-standard` are published for arm64, so any other template
  choice makes a guest configuration architecture-specific.

### With KVM guests

Add `--device /dev/kvm`. The host must expose hardware virtualisation, and if the host is itself a VM,
nested virtualisation must be enabled. GitHub-hosted runners do not provide `/dev/kvm`, so guest boot is
never exercised in hosted CI and is never reported as passing there.

### On the shape of these sets

Each list is **irredundant** — no flag in it can be removed without breaking the tier it belongs to. It is
not "the minimum set": the result is order-dependent, and a different drop order could yield a different
irredundant set of the same size. The order used was `--privileged` → `seccomp=unconfined` →
`NET_ADMIN` → `SYS_ADMIN`, and it is recorded so the result is reproducible rather than merely asserted.

`CAP_SYS_ADMIN` is the one flag whose removal is catastrophic rather than partial: without it `/etc/pve`
never mounts and nine units fail.

## Guest networking

`PVE_GUEST_NETWORK` is a capability like the others, and it needs `CAP_NET_ADMIN` — which the management-plane tier does
not carry. The probe answers by creating a throwaway bridge and deleting it again, rather than by reading `CapBnd`: the
bounding set says what the kernel believes is held, not what a seccomp profile will actually permit.

When it resolves `enabled` the entrypoint writes a bridge stanza into `/etc/network/interfaces` and brings it up with
the real `ifupdown2`, rather than creating the bridge imperatively with `ip link`. That is deliberate. A bridge built
imperatively leaves the file describing a network nobody built, so the web UI's Network page becomes decoration and
`ifreload -a` has nothing real to apply. Writing the file makes it the source of truth, which is what allows PVE's own
Apply Configuration button to work.

It then derives the subnet from `PVE_GUEST_SUBNET`, enables IP forwarding and reads the value back, resolves the uplink
from the default route, and installs a MASQUERADE rule — verifying it afterwards through the same iptables binary that
installed it, because Debian ships `iptables` as an alternatives symlink over two back ends with separate rule sets and
a rule added to one is invisible to the other. The rule carries `-m comment --comment "pve-container-shim guest NAT"`,
so an operator inspecting a host that has run this image can tell which rule it owns and remove exactly that one. If the
`FORWARD` chain has a `DROP` or `REJECT` policy the entrypoint warns, because guest traffic is then dropped before NAT
ever applies and the symptom is a guest that gets an address and reaches nothing.

Three things happen before any of that, and each exists because getting it wrong is silent rather than loud.

**The uplink is checked for a shared network namespace first.** If the container runs with the host's networking —
`--network host`, or any runtime that hands over the host's namespace — then creating `vmbr0` and installing a NAT rule
would mutate the *host's* network, and nothing tears either of them down when the container exits. The test compares
`/sys/class/net/<uplink>/ifindex` against `iflink`: they differ for a veth, whose peer lives in another namespace, and
are equal for an interface the current namespace owns outright. An earlier revision tested for a `device` symlink
instead, which was wrong on any host whose default route leaves through a bridge — every Proxmox host, and most
container hosts. On refusal the entrypoint names the interface, says why, and points at `PVE_GUEST_NETWORK=disable` to
suppress the check; guest networking is skipped and start-up continues. One case is knowingly allowed through: Docker
Desktop's `--network host` places the container in the LinuxKit VM's namespace by way of a veth, so the test permits it.
That VM is the runtime's disposable machine rather than the operator's host, which bounds the consequence.

**The default subnet is checked for a collision.** `10.10.10.0/24` is a default, not a promise, and a host that already
routes it would have guest traffic disappear into whatever owns the range. When `PVE_GUEST_SUBNET` is unset the
entrypoint tests candidates in turn — `10.10.10`, `10.20.30`, `172.30.40`, `172.31.40`, `192.168.230`, `192.168.231` —
and takes the first that is not already routed, announcing the substitution. A subnet the operator named explicitly is
never moved. Detecting the collision needs both an `ip route show table all root` query for routes inside the prefix and
a `match` query filtered to real destination prefixes: the default route matches every candidate, so a naive `match`
alone rejects all of them on any host that has one.

**The bridge MTU is inherited from the uplink**, clamped to 1500 if the uplink is jumbo, and advertised to guests through
`dhcp-option=option:mtu`. Guest traffic leaves through NAT over that uplink, so a guest configured larger than the path
it will actually take fragments or blackholes at the first hop; the clamp exists because every hop must agree on a jumbo
frame and a NAT'd destination on the far side of the internet made no such promise.

Guest addressing is served by `pve-guest-dnsmasq.service`, which the shim ships. It is gated on
`ConditionPathExists=/run/pve-container/guest-dnsmasq.conf`, and the entrypoint writes that file only when the
capability resolves `enabled`. At a lower tier the file is absent and systemd records the unit as *skipped* rather than
*failed*, so nothing has to be masked to keep it out of the way and `systemctl status` still reports why it did not run.
Proxmox VE ships no DHCP server of its own: on real hardware the bridge is enslaved to a physical port and guests are
addressed by whatever serves that network. Here the bridge has no member port and reaches the outside through NAT, so
without a server on the bridge a guest boots, brings up its NIC, waits out its timeout and appears hung. The generated
configuration sets `filter-AAAA`: the bridge has no IPv6 path, so an AAAA record would make every guest lookup wait out
a connect timeout before falling back to IPv4.

Applying network changes from the web UI works for guest bridges and deliberately does not touch the uplink. See
`DEVIATIONS.md` §17 for the mechanism and its functional consequence.

## Known limitations

### Both architectures

- Single node only. `corosync.service`, `watchdog-mux.service`, `systemd-networkd-wait-online.service`,
  `kbrequest.target` and `lxc-net.service` are masked, and `networking.service` is neutralised. Each is
  recorded with its failure mode in [DEVIATIONS.md](../DEVIATIONS.md).
- No Proxmox kernel. `proxmox-default-kernel` is satisfied by a shim package that provides and conflicts
  with it. `pveversion -v` therefore reports no kernel line, which is honest: there is no PVE kernel, the
  host's is already running.
- ZFS is not installed. Directory-backed storage is the supported path.
- Ceph *client* libraries are present because `libpve-storage-perl` and `pve-qemu-kvm` depend on them
  unconditionally. Ceph *server* packages are not, exactly as on a stock PVE node.
- `postfix` is installed and its unit runs. It arrives as a hard dependency of `pve-manager`, so removing it
  would break dpkg, and the package matrix classifies it container-hostile because it expects to own a mail
  spool and a resolvable FQDN. In practice it starts cleanly and delivers nothing, because nothing in this
  image is configured to send mail. It is inert rather than absent, and left that way deliberately.

### arm64 specifically

- **Guests must boot UEFI.** SeaBIOS has no `aarch64` machine type, so every arm64 guest needs AAVMF from
  `pve-edk2-firmware-aarch64`. That package is installed explicitly because `qemu-server` lists it only
  under `Suggests`, which means it is in neither architecture's dependency closure and would otherwise be
  silently absent.
- Only two LXC templates exist upstream for arm64 — `alpine-3.24-default` and `debian-13-standard`. The
  amd64 catalogue is far larger.
- AMD SEV and Intel GVT-g are x86-only. Neither is used here.
- The ceph client stack is a major version ahead on arm64 (tentacle) versus amd64 (squid). Proxmox
  publishes disjoint sets, so no common version exists. The divergence is in installed bytes rather than
  exercised behaviour, since no ceph storage is configured, and it is tracked per-package rather than
  waved through.

## Verifying the image

Use `gh attestation verify`:

```sh
gh attestation verify oci://ghcr.io/the-wondersmith/containers/proxmox@sha256:... \
  --repo the-wondersmith/containers
```

**Do not reach for `cosign verify-attestation`.** GHCR has no native OCI referrers API and falls back to a
tag-based scheme; cosign's referrers request is redirected to a URL that 404s and it does not fall back,
so verification fails against a perfectly valid attestation. `gh attestation verify` queries GitHub's
first-party attestation API and is unaffected. This is a registry limitation, not a signing defect, and
switching tools would trade a working check for a broken one.

Always pin by digest rather than tag when verifying. A tag can be repointed between resolution and
verification.

## Related

- [Package matrix](pve-package-matrix.md) — which packages are available on which architecture, and why
- [Deviations](../DEVIATIONS.md) — every stub, mask and workaround, with its functional consequence
- [Provenance](../PROVENANCE.md) — where each package comes from, mapped to the permitted tiers
- [Proxmox acceptance](pve-acceptance.md) — the behavioural gate this image must clear
- [Acceptance](acceptance.md) — the behavioural gate the podman package uses, and the model this one follows
