# Proxmox acceptance suite

`.github/scripts/pve-acceptance.sh` is the gate between a built Proxmox VE image and a published one. It reports every item as
`pass`, `fail` or `not-attempted`, never as a narrative summary, and every failure carries a cause class so that an
architecture problem, a container problem and a pipeline problem are not confused for one another.

It runs **on the host, driving containers**, unlike [podman's suite](acceptance.md) which runs inside one. That difference is
forced rather than stylistic: several items are about how the image behaves under *different runtime flags* — the capability
contract, the reduced-privilege invocation, recovery from an unclean stop — and none of those can be observed from inside a
container that has already started.

## How it runs

```bash
IMAGE=ghcr.io/the-wondersmith/containers/proxmox:9.2.0-1 \
KVM_AVAILABLE=false \
  .github/scripts/pve-acceptance.sh
```

Both variables are mandatory and neither has a default. `IMAGE` is obvious. `KVM_AVAILABLE` is deliberately not defaulted: a
default would let the suite decide the KVM question for itself instead of consuming an observation, and the one thing this
suite must never do is report a skipped KVM test as a pass. `.github/workflows/test-proxmox-image.yaml` probes `/dev/kvm` on
the runner it is actually running on and passes the result in.

The workflow builds the image natively on each architecture rather than pulling one. Emulation is not an option here: the
suite exercises systemd as PID 1, a real FUSE mount, cgroup delegation and nested LXC, all of which behave differently under
QEMU user-mode emulation, so an emulated failure would be uninterpretable. Pulling is not an option either, because gating a
push on acceptance that requires the push is circular.

## Two tiers, and why the split is not a convenience

**Tier A** runs on hosted runners and gates every build. It covers everything that does not require hardware virtualisation.

**Tier B** is KVM guest boot. It runs only where `/dev/kvm` is genuinely present and is otherwise reported `not-attempted`.

Both Tier B items share one harness. The only architecture-dependent parts are the release-index
URL, the entry delimiter in that index, and four `qm create` flags; everything else -- including
the part that took longest to get right -- is common code. Three details are what make the
assertion mean anything. The boot image is **discovered**, by parsing Alpine's release index for
the `alpine-virt` flavour and verifying the published sha256, because the filename carries a
version upstream re-rolls; note the two indices are not formatted alike, x86_64 using inline
`- key: value` entries where aarch64 puts a bare `-` on its own line, so a parser handling only
the first reports the ISO missing when it is present. The serial reader **attaches before the
guest starts**, because PVE configures the chardev with `server=on,wait=off` and QEMU discards
anything written before a client connects -- a reader attached afterwards captures an empty
buffer having missed the entire boot. And the assertion is a **login prompt in real console
output** within a bounded poll, not `qm start` returning zero, which proves only that QEMU
launched.

On aarch64 the guest boots through UEFI via AAVMF with an EFI variables disk at
`efitype=4m,pre-enrolled-keys=0`. That is not a preference: SeaBIOS has no aarch64 machine type,
which is why the Containerfile installs `pve-edk2-firmware-aarch64` explicitly even though
`qemu-server` lists it only under `Suggests`. The ISO attaches over virtio-scsi rather than with
`--cdrom`, because `--cdrom` attaches as `ide2` and the aarch64 `virt` machine has no IDE
controller -- QEMU exits with `Bus 'ide.1' not found` before any guest code runs.

**Item 14's harness is implemented and proven end to end**, on an AWS `a1.metal` instance -- arm64
bare metal, where the OS runs at EL2 -- booting Alpine to `Kernel 6.18.35-0-virt on aarch64
(/dev/ttyAMA0)` with `efivarfs` mounted, confirming a genuine UEFI boot. When it reports
`not-attempted` on the hosts used day to day, the reason is that no arm64 host with working KVM
is available, not that the test does not exist. See `DEVIATIONS.md` section 20.

Tier B is never inferred from Tier A passing. Reports of `/dev/kvm` on GitHub-hosted runners are contradictory — GitHub's own
answer on `actions/runner-images` says KVM is not exposed on virtualised servers — so the only trustworthy answer is to look
at the runner in front of you.

## Items run under three different privilege tiers, deliberately

The image supports three documented invocations, described in full in [the image guide](pve-image.md). The suite exercises
more than one of them because a single tier cannot demonstrate everything:

| items | tier | why |
|-------|------|-----|
| 1–6, 8–12 | management plane (`--cap-add SYS_ADMIN --device /dev/fuse`) | this is the tier the documentation recommends, so it is the tier most items must hold under |
| 15 (guest networking) | `--privileged` | creating a bridge and installing NAT need `CAP_NET_ADMIN`, which the management-plane tier does not carry; guest networking is a privileged-tier feature by design, exactly as LXC is |
| 7 (LXC lifecycle) | `--privileged` | `pct start` fails under both lesser tiers at `lxc_setup: 3811 Failed to setup first automatic mounts`; running the item under a tier the evidence says cannot support it would be testing the wrong configuration |

Item 9 asserts the stronger claim behind the first row: that the documented reduced set contains no `--privileged`, and that
the management plane comes up under exactly it.

## What each item actually proves

Assertions are decomposed so no single line covers more than one claim. Several are written specifically to avoid a shape
that would pass vacuously:

- **Item 1** polls `systemctl is-system-running` on a bounded 120-second deadline rather than sleeping a fixed interval. A
  fixed sleep either wastes time or races startup, and a race samples `starting` and then reports an empty failed-unit list
  because nothing has tried to start yet — a pass that proves nothing. `degraded` passes only when every failed unit is
  pre-declared; today that is `lxcfs.service` and `pvefw-logger.service` in the management-plane tier.
- **Item 3** asserts `/etc/pve` from `/proc/mounts` as source `/dev/fuse` with fstype `fuse`, then separately asserts it is
  writable. A write test alone would pass on a tmpfs fallback, which is exactly the broken state worth catching. The fstype
  really is `fuse`; pmxcfs registers no `fuse.pmxcfs` subtype, and asserting one would fail against a working image.
- **Item 4** calls the authenticated API (`pvesh get /nodes`) as well as checking units. `systemctl is-active` proves a unit
  did not exit, which is not the same as the API answering.
- **Item 7a** asserts on the appliance index *file*, not on `pveam update`'s exit status. That command prints `update failed`
  and still exits 0 — a defect that let a genuinely broken image through earlier in this project's history.
- **Item 7b** resolves the template filename at run time by prefix and host architecture. `pveam available` lists every
  architecture regardless of host, so matching on the name alone would cheerfully download an amd64 template onto arm64.
- **Item 8** is eight discrete assertions with its own declared count, because "every capability variable behaves per
  contract" compressed into one line would let a partial implementation report a pass.
- **Item 11** measures `/dev/shm` with `df` as the primary metric and treats `qb-*` as attribution only. The libqb segments
  are the management plane's, but QEMU `memory-backend-file`, spice and virtio-fs all consume `/dev/shm` without that prefix,
  so the number derived here is a management-plane floor, not a VM-workload sizing.

## The suite checks itself

Three assertions exist to stop the suite lying about its own coverage:

- The observed `KNOWN-FAIL` set must **equal** a pre-declared set, not merely be contained by it. `KNOWN-FAIL` emits a warning
  without setting the exit code, which makes it an escape hatch: left open, any inconvenient item could be reclassified and
  the suite would still report green. Equality also means an exemption that stops firing is a failure, because carrying a dead
  exemption forward is how an escape hatch widens. The declared set is currently empty.
- The reported result count is checked against a **declared floor** (`EXPECTED_ITEMS`, currently 20). The constant is written
  down rather than derived from the run: a derived count would be a tautology, agreeing with itself no matter how many
  assertions had been deleted. The check is `>=`, so adding assertions never trips it while dropping below the declared floor
  does. The count is of individual `PASS`/`FAIL` results, not of the numbered item groups, so the observed total (around forty)
  sits well above the floor.
- Every functional path in `dpkg -L pve-container-shim` must be named in [`DEVIATIONS.md`](../DEVIATIONS.md). The argument for
  packaging the container adaptations rather than writing loose `RUN` lines was that every deviation would then be enumerable;
  this is the assertion that keeps that claim honest rather than aspirational.

## Results

Both architectures, natively built and natively run. Management-plane tier except item 7, which runs privileged.

| outcome | arm64 | amd64 |
|---------|-------|-------|
| pass | 38 | 39 |
| fail | 0 | 0 |
| not-attempted | 2 | 1 |

arm64 ran under Docker on an Apple Silicon host; amd64 ran under rootful podman 6.0.0 on a remote Linux host reached
through a docker context. Neither was emulated. The amd64 build required `--platform linux/amd64` against a builder
bound to that host, because BuildKit defaults its target platform to the *client's* architecture rather than the
builder's -- three earlier builds produced arm64 images on the remote amd64 daemon before that was understood.

Tier B accounts for the difference. On arm64 the host provided no `/dev/kvm`, so items 13 and 14 both report
`not-attempted` for that reason. On amd64 `/dev/kvm` was present and functional, and **item 13 passes**: an x86 guest
boots to a login prompt. Item 14 remains `not-attempted` there because an aarch64 guest on an amd64 host would fall
back to TCG emulation, which exercises QEMU rather than the virtualisation path the item exists to prove. The reason
is the host, not a missing harness, and the two are reported differently on purpose.

## What running it found

Four real defects, none of which reading the code would have surfaced:

1. **`e2fsprogs` was missing.** `pct create` failed at `exec of mkfs.ext4 … No such file or directory`. Nothing in the
    568-package dependency closure pulls it and `debian:trixie-slim` does not ship it.
2. **The slimming layer deleted `/usr/share/doc/pve-manager/trustedkeys.gpg`.** `sqv` reads it at run time to verify every
    appliance-index signature. Losing it broke `pveam update` for every source — while `pveam update` still exited 0.
3. **Sized directory-backed rootfs volumes need loop devices** the container does not have.
4. **Nested LXC guest start requires `--privileged`.** This falsified a claim that had already been written into
    [the image guide](pve-image.md), which was corrected rather than softened.

## Related

- [Image guide](pve-image.md) — the three invocations these items are run under, and what each one costs
- [Deviations](../DEVIATIONS.md) — the file set item 7's cross-check asserts against
- [Package matrix](pve-package-matrix.md) — the closure that two of the four defects above were absent from
- [Acceptance suite](acceptance.md) — the podman equivalent, which runs inside the container rather than driving it
