# Deviations

Every stub, neutralised unit, dropped package, disabled test, and workaround applied to the Proxmox VE container image.
Each entry states the constraint that forced the deviation alongside its functional consequence, so a future change knows what it is about to break.

## 1. Kernel metapackage stubbed

`pve-container-shim` declares `Provides: proxmox-default-kernel (= 1.0.0-1)` and `Conflicts: proxmox-default-kernel`.
`Replaces` is deliberately absent: this package ships none of the real package's files.

Consequence: `proxmox-ve` installs without a kernel image. `pveversion -v` reports no kernel line, which is honest — there is no PVE kernel in the container; the host's is already running.

Sunset: `proxmox-ve` 9.2.0 declares a bare unversioned `Depends: proxmox-default-kernel`. If a future release adds a version constraint the shim must bump deliberately or be removed.

## 2. `--no-install-recommends` is load-bearing, not tidiness

Measured: `apt-get install -s proxmox-ve` schedules 603 packages without `--no-install-recommends`, including a full `proxmox-kernel-6.17` image, `pve-firmware`, and `initramfs-tools`. With the flag: 371 packages and no kernel image at all.

Consequence: removing the flag silently reintroduces hundreds of megabytes of inert kernel payload.

## 3. dpkg `path-include` workaround for `pve-manager`

`debian:trixie-slim` ships `/etc/dpkg/dpkg.cfg.d/docker` declaring `path-exclude /usr/share/doc/*` with only `*/copyright` re-included.
`pve-manager` ships `aplinfo.dat` — the appliance-template index `pveam` consumes — under `/usr/share/doc/pve-manager/`, and its postinst does a plain `cp` of that path.
Without intervention the build fails:

```
cp: cannot stat '/usr/share/doc/pve-manager/aplinfo.dat': No such file or directory
dpkg: error processing package pve-manager (--configure)
```

That `pve-manager` failure blocks `proxmox-ve`. The error message names neither dpkg configuration nor the base image, so the cause is not discoverable from the error alone.

Fix: write `/etc/dpkg/dpkg.cfg.d/zz-pve-manager-aplinfo` containing `path-include /usr/share/doc/pve-manager/*` before `apt-get install`.
The `zz-` prefix matters because dpkg reads that directory in lexical order and the exclusion lives in a file named `docker`.

Consequence: none in the final image. The slimming layer deletes `/usr/share/doc/*` afterwards, and the postinst has by then copied the file to `/var/lib/pve-manager/apl-info/`, which slimming does not touch.

## 4. `/usr/bin/unshare` deliberately NOT diverted

The plan called for diverting three binaries; only `/usr/sbin/ifreload` and `/usr/sbin/update-initramfs` are diverted.
Diverting a core util-linux binary is high-risk and no specific failure mode for `unshare` has been demonstrated in this image.

Consequence: if a future failure traces to `unshare`, this is the first place to look.

## 5. Eight systemd units neutralised

Five units are masked (symlinks to `/dev/null` under `/etc/systemd/system/`). Three receive drop-ins.

**`watchdog-mux.service`** — masked. Opens `/dev/watchdog`; a container does not own the watchdog device.

**`systemd-networkd-wait-online.service`** — masked. Never completes without a managed interface; blocks anything that depends on `network-online.target`.

**`kbrequest.target`** — masked. No keyboard is attached in a container context.

**`lxc-net.service`** — masked. Guarded `ConditionVirtualization=!lxc`, which matches only `lxc`/`lxc-libvirt`. Docker and Podman report `docker`/`podman`, so the condition evaluates TRUE and the unit runs, bringing up `lxcbr0` plus dnsmasq and requiring iptables NAT the container does not own.

**`corosync.service`** — masked. This image is single-node and ships no cluster configuration, so corosync has nothing to join: started anyway it either fails outright or sits retrying, and its hard `Requires=network-online.target` drags an ordering dependency into the boot for a service that cannot do anything useful here. Its `ConditionKernelCommandLine=!nocluster` reads the host's `/proc/cmdline`, so it is not a lever the image controls either. An earlier revision of this entry justified the mask by claiming that masking `systemd-networkd-wait-online.service` leaves `network-online.target` permanently unreachable; that was wrong — masking a unit whose only job is to *delay* the target makes it reachable sooner, not never. The mask is still correct, for the reason above.

**`networking.service`** — drop-in resetting `ExecStart` to `/usr/libexec/pve-container-shim/ifup-guest-bridges`. `WantedBy=basic.target network.target shutdown.target` with no virtualisation guard, and its shipped `ifup -a` would reconfigure the runtime-owned uplink from an `/etc/network/interfaces` the runtime never wrote. The helper brings up only bridges declared with a `bridge-ports` line inside an `auto` stanza, which is the subset of that file this image can honour. An earlier revision reset `ExecStart` to `/bin/true`; that was correct while the image declared no bridge of its own, and stopped being correct when it did.

**`lxcfs.service`** — drop-in clearing `ConditionVirtualization=` and adding `ExecStartPre=-/bin/fusermount3 -u /var/lib/lxcfs`. The shipped condition prevents lxcfs from starting inside a container at all; clearing it lets the image control startup explicitly. The `ExecStartPre` ensures the FUSE mount point is clean before each start attempt.

**`ifupdown2-pre.service`** — drop-in resetting `ExecStart` to `/bin/true`. Its shipped `ExecStart=/bin/udevadm settle` waits for a udev event queue nothing in a container services, so it blocks until its own `TimeoutSec=180` expires; it is ordered `Before=network.target` with `DefaultDependencies=no`, so every network-dependent unit waits three minutes behind it on every start.

An earlier revision of this document stated that `ifupdown2-pre.service` does not exist and that a drop-in for it would be inert. That was true of Debian's `ifupdown2 3.0.0-1.3`, which ships only `ifup@.service` and `networking.service`. It stopped being true once this image began building Proxmox's `3.3.0-1+pmx12` from source and installing it on both architectures, because that package ships the unit as well. The claim was right about the package we used to ship and wrong about the one we ship now — the failure mode of recording a conclusion without recording what it depended on.

Consequence: clustering and host network management are out of scope for this image.

## 6. FUSE probe teardown must not require server cooperation

The entrypoint's FUSE probe performs a real `mount -i -t fuse -o fd=9,…` because a character-device check on `/dev/fuse` passes in cases where pmxcfs still fails. The mount has no server behind it.

A plain `umount` issues a FUSE request into fd 9 and blocks forever in uninterruptible sleep (`D` state, wchan `__fuse_simple_request`), wedging PID 1 with zero log output while Docker reports the container `running`.

Teardown must close fd 9 first — the kernel then aborts the connection, so any in-flight request fails with `ENOTCONN` — and then `umount -l` (`MNT_DETACH`, which issues no FUSE request). Both halves are load-bearing.

## 7. Ceph client version skew accepted per-package

amd64 installs `19.2.3-pve1` (squid) and arm64 installs `20.2.0-pve1` (tentacle) across 13 client packages.
Proxmox's published sets are strictly disjoint per arch, so no common version exists. `pve-test` carries the same skew.
Debian is not an option: `ceph-fuse` is amd64-only there while being an unconditional `Depends` of `libpve-storage-perl`.

Consequence: divergence in installed bytes, not exercised behaviour, because the first image configures no ceph storage.
Ceph server packages are excluded automatically — nothing in the closure depends on them, exactly as stock PVE behaves via `pveceph install`.

## 8. `ifupdown2` built from upstream source

Proxmox publishes `ifupdown2 3.3.0-1+pmx12` (`Architecture: all`) into the amd64 index only.
On arm64 the dependency still resolves but silently falls back to Debian trixie's `3.0.0-1.3` — a different repository at an older version.
This is a cross-architecture divergence wearing the costume of a satisfied dependency.

Confirmed in a built arm64 image: `apt-cache policy ifupdown2` reports `Installed: 3.0.0-1.3`.

Remedy: build `3.3.0-1+pmx12` from `https://git.proxmox.com/git/ifupdown2.git` and publish the single `Architecture: all` package through `the-wondersmith/apt`.

Sunset condition, stated as a literal check: when

```
curl -fsSL \
  http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-arm64/Packages.gz \
  | gunzip | grep -q '^Package: ifupdown2$'
```

succeeds, delete the build action and its publishing path.

## 9. arm64 LXC template catalogue is two entries deep

`download.proxmox.com/images/aplinfo-pve-9.dat` publishes only `alpine-3.24-default` and `debian-13-standard` for arm64, against a full catalogue for amd64.

Consequence: the acceptance suite uses `alpine-3.24-default` because it is the only template present on both arches under the same name. Any other choice would be architecture-asymmetric.

## 10. First image verified natively on arm64; amd64 verification deferred to CI

The plan called for amd64 first as the control, on the reasoning that "PVE doesn't work in a container" and "our arm64 handling is broken" produce similar-looking failures. That assumed an amd64 build host.

The development host is arm64. A local `--platform linux/amd64` build would run the entire install and the systemd/pmxcfs runtime test under QEMU emulation, adding a third confound to the exact two the ordering exists to separate.

Consequence: amd64 functional verification happens on a native `ubuntu-latest` runner in CI, not locally.

## 11. Files the shim ships, by name

The argument for packaging the container adaptations rather than writing loose
`RUN` lines was that every deviation would then be enumerable with
`dpkg -L pve-container-shim`.  The acceptance suite asserts that, matching each
shipped path's basename against this document, so the names have to appear here
or the claim is untested.

- `10-container.conf` — the drop-in filename, used under
  `lxcfs.service.d/`, `networking.service.d/` and `ifupdown2-pre.service.d/`.
  It clears `lxcfs.service`'s `ConditionVirtualization=!container`, points
  `networking.service` at the guest-bridge helper below, and stops
  `ifupdown2-pre.service` waiting three minutes on a udev queue nothing
  services.
- `ensure-hostname` — the `/etc/hosts` repair run before `pve-cluster.service`.
  Without it the node hostname resolves to loopback and pmxcfs clients fail with
  `ipcc_send_rec[1] failed: Connection refused`, a message naming neither the
  hostname nor `/etc/hosts`.
- `kvm-probe` — the ioctl helper that issues `KVM_GET_API_VERSION` and
  `KVM_CREATE_VM`.  Opening `/dev/kvm` proves presence and permissions but not
  that the device is functional; a stale or hand-`mknod`'d node opens cleanly and
  fails on first use.  The helper is what makes the KVM verdict trustworthy.
- `pve-container-shim.conf` — the `tmpfiles.d` entry that creates
  `/run/network`.  Without it `ifup` fails with `error: Another instance of
  this program is already running.` while no other instance exists: ifupdown2
  reports that when it cannot *create* its lock file, not only when one is
  held, so a missing parent directory surfaces as a concurrency conflict
  naming neither the directory nor the path.  Debian's ifupdown2 normally
  gets the directory from `networking.service`'s own start-up, which this
  image replaces.
- `ifup-guest-bridges` — the helper `networking.service` runs in place of
  `ifup -a`.  It brings up only bridges declared with a `bridge-ports` line
  inside an `auto` stanza, selected by that marker rather than by a `vmbr*`
  name so a differently-named bridge is not skipped and a non-bridge called
  `vmbr0` is not wrongly matched.  It exits 0 when no bridge is declared,
  which is what keeps `networking.service` active rather than failed at the
  reduced privilege tier, where no guest bridge exists.

- `pve-guest-dnsmasq.service` — DHCP and DNS for the guest bridge. Proxmox VE runs no DHCP server of its own: on real
  hardware the bridge is enslaved to a physical port and guests are addressed by whatever serves that network. Here the
  bridge has no member port and reaches the outside through NAT, so a guest's DHCP request is never seen by anything but
  this host, and without a server on the bridge a guest boots, brings up its NIC, waits out its timeout and looks hung.
  The unit carries `ConditionPathExists=/run/pve-container/guest-dnsmasq.conf`, which the entrypoint writes only when the
  `guest_network` capability resolves enabled — so at a privilege tier that cannot create a bridge the unit is skipped
  rather than failed, and nothing has to be masked to keep it out of the way.

## 12. `/usr/share/doc/pve-manager` is exempt from slimming

`slim-paths.txt` deletes `/usr/share/doc/*`, which is normally inert.  It is not
inert here: Proxmox stores two runtime files under that path.

- `trustedkeys.gpg` is read at runtime by `/usr/bin/sqv`, which `pveam` invokes
  to verify the signature on every appliance index it downloads.  Deleting it
  makes `pveam update` fail signature verification for every source; it then
  prints `update failed` and **exits 0**, and `pveam download` reports
  `template: no such template` — a message naming neither the keyring nor the
  slimming layer.
- `aplinfo.dat` is unpacked only because of the `zz-pve-manager-aplinfo` dpkg
  `path-include`, and survives deletion only because `pve-manager`'s postinst
  copies it into `/var/lib/pve-manager/apl-info/` at install time.

The manifest therefore carries `!/usr/share/doc/pve-manager` as a keep-line.
`-delete` implies `-depth`, and `-depth` silently disables `-prune`, so the
exclusion is implemented with negated `-path` tests, which are the only form
that survives.

**Consequence:** the image keeps roughly 74 KiB it would otherwise drop.  Every
other `/usr/share/doc` path is still removed.

**How this was found:** by the acceptance suite's LXC lifecycle item, not by
inspection.  The slimming layer's own `dpkg -V` delta assertion did not catch it
and could not have — it proves every deletion is declared by a glob in the
manifest, not that deleting it is safe.

## 13. `e2fsprogs` is installed explicitly

`pct create` on directory-backed storage formats a raw file and shells out to
`mkfs.ext4`.  Nothing in the `proxmox-ve` dependency closure depends on
`e2fsprogs` and `debian:trixie-slim` does not ship it, so the call fails with
`exec of mkfs.ext4 ... failed: No such file or directory`.

This is the same class of finding as `pve-edk2-firmware-aarch64`, which
`qemu-server` lists only under `Suggests`: a package PVE genuinely needs at
runtime that its own dependency metadata does not declare.  Both are installed
explicitly in the Containerfile.

**Consequence:** none, beyond the package's own size.  Omitting it makes LXC
container creation fail with a message that names neither the package nor the
reason, and only when a container is actually created.

## 14. Nested LXC guests require `--privileged`

`docs/pve-image.md` documents three runtime tiers. The management-plane tier and the
firewall-logging tier both reach a working API, and under both `pct create` succeeds — but
`pct start` fails at:

```
lxc_setup: 3811 Failed to setup first automatic mounts
do_start: 1466 Failed to setup container "902"
__lxc_start: 2288 Failed to spawn container "902"
```

`--cap-add NET_ADMIN`, `--security-opt seccomp=unconfined` and `--security-opt
systempaths=unconfined` were each tried; none is sufficient. The full
create/start/exec/stop/destroy chain passes only under `--privileged`.

Functional consequence: an operator who wants LXC guests cannot have the reduced capability
surface. The management plane still does not require `--privileged`, so the two goals are
separable — but they cannot both be had at once in this runtime.

This was found by the acceptance suite, and an earlier revision of `docs/pve-image.md` claimed
the firewall-logging tier was sufficient for LXC. That claim was wrong and has been corrected
rather than softened.

## 15. Sized directory-backed rootfs volumes need loop devices

`pct create --rootfs local:1` on `dir` storage creates a raw image file and attaches it through
a loop device. Docker exposes no `/dev/loop*` or `/dev/loop-control` by default, so this fails:

```
losetup: /var/lib/vz/images/900/vm-900-disk-0.raw: failed to set up loop device: No such file or directory
losetup: device node /dev/loop0 (7:0) is lost. You may use mknod(1) to recover it.
```

The acceptance suite therefore uses an **unsized** rootfs (`--rootfs local:0`), which extracts
the template straight into `/var/lib/vz/private/<vmid>` and never invokes `losetup`.

Functional consequence: no per-container disk quota on `dir` storage. An operator who needs one
must pass `--device /dev/loop-control` together with the loop device nodes themselves. This is a
runtime limitation of the container, not of the image, and no workaround is applied in the image.

## 16. LXC guests need `lxc.apparmor.profile: unconfined` on AppArmor-enabled hosts

`lxc-start` decides for itself whether to apply an AppArmor profile: if the host kernel has AppArmor, it
generates one and loads it. Inside a container it cannot reach `apparmor_parser`'s interface file, so the
load fails and the guest refuses to start:

```
run_apparmor_parser: 954 Failed to run apparmor_parser on "/var/lib/lxc/900/apparmor/lxc-900_<-var-lib-lxc>":
  Cache read/write disabled: interface file missing. (Kernel needs AppArmor 2.4 compatibility patch.)
apparmor_prepare: 1126 Failed to load generated AppArmor profile
lxc_init: 1069 Failed to initialize LSM
__lxc_start: 2208 Failed to initialize container "900"
```

The determining variable is **whether the host kernel has AppArmor**, not the architecture. A host with no
AppArmor at all skips the LSM entirely and starts guests cleanly, which is why this appears on some hosts
and not others and why it is not an architecture finding. It was discovered on an amd64 host only because
that happened to be the first AppArmor-enabled kernel the suite ran against; an AppArmor-enabled arm64
host fails identically.

The accommodation is to set `lxc.apparmor.profile: unconfined` on the guest. That is preferred over
passing `--security-opt apparmor=unconfined` to the outer container, which would achieve the same effect
by weakening the container's own confinement instead of the guest's -- a larger blast radius for the same
outcome, and the opposite of making confinement available to guests.

Functional consequence: **the guest runs unconfined.** That is a real cost and is stated rather than
buried. It is, however, already what this image reports about itself -- `probe/apparmor` returns
`indeterminate` or `absent` in every container runtime tested, and `probe/nested-lxc` consequently reports
`present`/`unconfined` with a detail line saying guests will run without confinement. Setting the profile
explicitly makes an existing limitation visible rather than introducing a new one.

Nothing in the image applies this automatically. The acceptance suite sets it on its own test guest so
that item 7 exercises the lifecycle rather than the host's LSM configuration; an operator creating real
guests must decide for themselves.

## 17. Applying network changes from the PVE GUI affects guest bridges only

The web UI's *Apply Configuration* button, and the `PUT /nodes/{node}/network` API call behind it,
work in this image: the staged configuration in `/etc/network/interfaces.new` is committed over
`/etc/network/interfaces` and guest bridges declared in it are brought up. What is deliberately not
applied is anything touching the uplink the container runtime created.

`pve-container-shim` diverts `/usr/sbin/ifreload` and replaces it with a wrapper. The wrapper handles
the two invocations PVE actually makes, both in `PVE/API2/Network.pm`:

- `ifreload -V`, from `assert_ifupdown2_installed()`, is delegated to the real ifupdown2. That
  assertion requires the first line of stdout to match `/^\s*ifupdown2:(\S+)\s*$/`, the version to
  parse to at least 1.2.8, and the fourth dot-or-dash separated field to contain `pve`, `pmx` or
  `proxmox`. Because the image installs Proxmox's own `ifupdown2 3.3.0-1+pmx12` on both
  architectures, built from `git.proxmox.com`, delegating tells the truth and the assertion passes.
- `ifreload -a`, from `reload_network_config`, runs `/usr/libexec/pve-container-shim/ifup-guest-bridges`
  rather than the real implementation, and prints `ifreload: applying guest bridges only; the uplink
  belongs to the container runtime` to stderr.

The narrowing is the deviation. The real `ifreload -a` diffs the whole of `/etc/network/interfaces`
against live state and applies the difference, which inside a container includes the uplink the
runtime created, addressed from a pool this file knows nothing about. Applying a file the runtime
never wrote to an interface the runtime manages ranges from a no-op to disconnecting the container.
Bringing up a bridge with no member port is entirely internal, so that is the subset the wrapper
honours -- the same subset `networking.service` applies at boot, through the same helper, so the
button and the boot path cannot disagree.

**Functional consequence.** An operator who edits a guest bridge in the web UI and clicks Apply gets
the change. An operator who edits the uplink gets a successful task with a stderr line explaining
that nothing moved -- visible in the task log, not silent, but it is a success report for an
operation that was declined rather than performed. Container networking belongs to the runtime, and
the way to change it is `--network`, published ports or a user-defined network, not this file.

**Two earlier revisions of this section were wrong, in opposite directions.** The first said applying
network changes "does nothing", which described a no-op stub that absorbed every argument. The second
said the apply failed with a misleading error: that was accurate at the time, because the stub
answered `-V` on stderr and emitted nothing on stdout, so the version parse produced an empty string
and `assert_ifupdown2_installed()` died *before the worker forked* -- the operator was told
`incompatible 'ifupdown2' package version ''! Did you install from Proxmox repositories?`, which
accused the package when the cause was the stub. Both descriptions are obsolete. The path now
completes, and this section describes what it actually does.

For contrast, `dockurr/proxmox` diverts `ifreload` as well, and its stub answers `-V` with a
hard-coded `ifupdown2:3.3.0-1+pmx12`. That satisfies every gate, so its worker forks, the rename
executes, its no-op `-a` returns 0, and the pending marker clears having applied nothing at all --
including for guest bridges. The hard-coded string also keeps parsing after an upgrade changes the
version it claims.


## 18. ISO storage content must be enabled before a guest can be installed

`/etc/pve/storage.cfg` does not exist in a fresh image. pmxcfs synthesises a default `local` entry when the file is
absent, and that synthesised default accepts `vztmpl` but **not** `iso` -- which is why container templates download
and install cleanly while an ISO cannot be placed at all. Running `pvesm set local --content iso,vztmpl,backup,images,rootdir`
creates the file with the full content list.

The image does not do this automatically. Enabling content types is an operator decision about what a storage is for,
and writing a storage configuration on the operator's behalf would make the first thing they see in the web UI a
configuration they did not choose. The acceptance suite performs it explicitly as a step of the guest-boot item, which
is the honest place for it: the harness needs ISO content, so the harness asks for it.

Functional consequence: an operator who wants to install a guest from an ISO must enable that content type on the
target storage first, exactly as on real hardware where the installer sets it up.

## 19. `qm status` reports a cgroup accounting error that does not affect the guest

Every `qm status` on a running VM emits, to stderr:

```
unable to get memory stat for <vmid> - can't open '/sys/fs/cgroup/qemu.slice/<vmid>.scope//memory.current'
Use of uninitialized value in multiplication (*) at /usr/share/perl5/QemuServer.pm line 2642
```

followed by five more `uninitialized value` warnings from the same block. PVE reads per-VM cgroup memory accounting
from a path that does not exist in this container's cgroup layout, then does arithmetic on the undefined result.

This is cosmetic. The VM starts, runs, reports `status: running`, and boots to userspace -- acceptance item 13 proves
that end to end. No workaround is applied, because the only ones available would be to suppress PVE's own diagnostics
or to fabricate a cgroup hierarchy it expects, and both would hide a real difference between this image and a bare
metal node rather than record it.

Functional consequence: memory statistics for running guests are unavailable, so the web UI's per-VM memory gauge has
nothing to display. Guest operation is unaffected.

## 20. Booting an aarch64 guest needs an arm64 host whose OS runs at EL2

Acceptance item 14 boots an aarch64 guest under KVM. Its harness is implemented and proven, but
it reports `not-attempted` on most arm64 hosts, because `/dev/kvm` does not exist on them.

On aarch64 there is no CPU feature flag to consult -- nothing corresponding to `vmx` or `svm` on
x86. The kernel registers the `/dev/kvm` misc device only after `kvm_init()` succeeds, and
`kvm_init()` requires the OS to be running at EL2. A hypervisor that does not hand EL2 to its
guests therefore produces a kernel with KVM compiled in, a populated `/sys/module/kvm`, and no
device node at all.

Three hosts were measured:

| host | silicon | hypervisor | `/sys/module/kvm` | `/dev/kvm` | kernel says |
|---|---|---|---|---|---|
| OrbStack VM | Apple, implementer `0x61` | Apple Virtualization.framework | present | absent | (nothing logged) |
| Azure `Standard_D4ps_v6` | Neoverse N2, `0x41`/`0xd49` | Hyper-V | present | absent | `kvm [1]: HYP mode not available` |
| AWS `a1.metal` | Cortex-A72, `0x41`/`0xd08` | none, bare metal | present | **present** | `kvm [1]: Hyp nVHE mode initialized successfully` |

All three have KVM in the kernel; only bare metal produces the device. Azure publishes no arm64
bare-metal SKU at all -- 98 arm64 sizes in `eastus`, none of them `.metal` -- and its nested
virtualisation is an x86-only feature that works by exposing VT-x or AMD-V to the guest, a
mechanism with no aarch64 counterpart.

**Functional consequence.** Running aarch64 guests requires arm64 bare metal, or a host that
grants EL2 by some other means. This is a property of the host, not of the image: on `a1.metal`
the image booted an aarch64 guest to a login prompt with no changes at all.

**Why this validates the capability probe's design.** A check reading `/sys/module/kvm`, or CPU
features, would have reported KVM available on all three hosts and been wrong on two. The probe
opens the device and issues `KVM_GET_API_VERSION` and `KVM_CREATE_VM`, which is the only signal
that distinguishes them, and is why it is written as a functional test rather than a declarative
one. See `docs/pve-image.md` for the capability contract.


## 21. Guest networking refuses to run in a shared network namespace, and may move its own subnet

Guest networking creates a bridge and installs a MASQUERADE rule. Both are namespace-scoped, and both are
created by the entrypoint rather than by the container runtime — so neither is torn down when the container
exits. In the container's own network namespace that is harmless: the namespace goes away and takes them with
it. In the *host's* namespace it is not, because the bridge and the rule outlive the container that made them.

The entrypoint therefore refuses to configure guest networking when the uplink lives in a namespace it does
not own, comparing `/sys/class/net/<uplink>/ifindex` against `iflink`: those differ for a veth, whose peer is
in another namespace, and match for an interface the current namespace owns. Refusal is not fatal — the
management plane comes up, guest networking is reported off, and the message names the interface and offers
`PVE_GUEST_NETWORK=disable` to suppress the check deliberately.

One case is knowingly allowed through. Docker Desktop's `--network host` puts the container in the LinuxKit
VM's namespace by way of a veth, so the test permits it. That VM is the runtime's disposable machine rather
than the operator's host, which bounds what a leftover bridge can affect.

Separately, when `PVE_GUEST_SUBNET` is unset the entrypoint may choose a range other than the `10.10.10.0/24`
default. It tests candidates against the host's routing table and takes the first that is not already routed,
announcing the substitution on start-up. A subnet the operator named explicitly is never moved. The functional
consequence is that a caller who reads the default out of this document rather than out of the start-up output
may find guests on a different range than expected; the alternative — configuring a subnet the host already
routes — sends guest traffic into whatever owns that range and fails silently.

## 22. An existing guest bridge stanza is adopted rather than re-derived

The entrypoint picks a guest subnet by checking whether the default is already
routed and stepping to an alternative if it is. That search runs on every start,
but its result is only used the first time: once `/etc/network/interfaces`
carries a bridge stanza, the address in that file is authoritative and the
search result is discarded.

The constraint that forced it: an earlier revision used the file for the bridge
and the freshly-computed answer for NAT and DHCP. The bridge came up on one
range while guests were handed leases on a second and masqueraded through a
third, and every start-up line reported success. Adopting the file for all three
is what keeps them in agreement.

The consequence is that a subnet which only became routed *after* the first
start is not moved off. That is deliberate: renumbering a bridge underneath
running guests breaks their connectivity immediately and silently, which is
worse than a collision the operator can see and correct by removing the stanza.
Acceptance item 17b covers the adoption path by seeding a non-default address
and asserting the bridge, NAT and DHCP all follow it.

## Related

- [Proxmox VE package matrix](docs/pve-package-matrix.md) — the package dispositions these deviations produce, classified by architecture and container hostility
- [Provenance](PROVENANCE.md) — the package sources that the tier-3 entries here justify
- [Package signing](docs/signing.md) — why attestation is the trust anchor rather than package signatures
