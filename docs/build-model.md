# Build model

Components are built by [melange](https://github.com/chainguard-dev/melange) against **Alpine 3.23** — not Wolfi, which is glibc-based. 3.23
rather than an older branch because podman 6 requires Go ≥ 1.25.9 and Alpine 3.21 ships only 1.23.9; 3.23 ships 1.25.10 along with Rust 1.91
and `libseccomp-static`.

## Why melange over abuild

melange was chosen over `abuild` because it is a consolidation rather than an addition: it replaces both the per-component build scripts and
the APKBUILD with one declarative definition, pins the build environment in the same file as the build, and emits a per-package SPDX SBOM
plus SLSA provenance. Each `.apk` carries an SBOM at `var/lib/db/sbom/`, and the bundle retains every component's — which matters for a
package whose entire premise is bundling upstream projects you cannot see from the metadata.

The bundle keeps those component documents at **`usr/share/doc/podman/sbom/`** rather than at the canonical path, leaving
`var/lib/db/sbom/` to melange for the bundle's own SBOM. That is not cosmetic: melange writes its SBOM host-side after the build guest
exits, as the user that invoked it, and the component files unpacked into the payload are root-owned. Leaving them in place makes that write
fail with `permission denied` on native Linux bind mounts — though not on Docker Desktop, which remaps ownership, so the failure appears only
in CI. The bundle definition asserts both halves afterwards: that the component SBOMs are present at the new path, and that the old one is
absent.

## Two Go toolchains, deliberately

The two halves of the build get Go from different places, deliberately. The musl components take Alpine 3.23's `go` from inside melange's
guest — that toolchain has to match the musl target, so mise cannot and should not supply it. The glibc podman build takes Go from **mise**,
pinned by `mise.lock`; trixie ships 1.24, below podman 6's requirement, so the distro toolchain is not an option there either. Both are
pinned, just by different pinning mechanisms, and a version skew between them is expected rather than a defect.

`SOURCE_DATE_EPOCH` is pinned on both halves of the build, since podman otherwise bakes a timestamp into the binary and a content-addressed
cache would be meaningless.

## The build tags are the toolchain

podman and buildah compute their build tags by *probing for headers* (`hack/systemd_tag.sh`, `hack/libsubid_tag.sh`,
`btrfs_installed_tag.sh`, …). The set of `-dev` packages installed in each build environment therefore **is** the build configuration. Tags
are never overridden wholesale — doing so silently drops upstream defaults such as `grpcnotrace`. Additions go through `EXTRA_BUILDTAGS`
(podman) or `EXTRA_BUILD_TAGS` (buildah), which both Makefiles append rather than replace.

The consequence is that the two podman builds differ in features, not just in linkage:

| Capability                    | Alpine (musl) | Debian (glibc) | Decided by                                  |
|-------------------------------|---------------|----------------|---------------------------------------------|
| journald + unit files         | no            | **yes**        | `libsystemd-dev`                            |
| btrfs graph driver            | no            | **yes**        | `libbtrfs-dev`                              |
| NSS/SSSD-backed subuid ranges | no            | **yes**        | `libsubid-dev`                              |
| SELinux labelling             | no            | **yes**        | `libselinux1-dev`                           |
| gpgme signature verification  | no            | no             | `libgpgme-dev`, deliberately absent on both |
| pure-Go OpenPGP               | yes           | yes            | `containers_image_openpgp`                  |
| pure-Go user/DNS resolution   | yes           | —              | `osusergo netgo`, static builds only        |

Where a capability is absent on musl it is because the library has no static form there, not because it was judged unnecessary: overlay
works fine on btrfs without the btrfs driver, and podman parses `/etc/subuid` directly without libsubid. The glibc build additionally
*asserts* that `hack/systemd_tag.sh` came back non-empty — if `libsystemd-dev` ever goes missing, the build fails rather than silently
shipping a package with no journald and no unit files.

## Related

- [Linkage policy](linkage.md) — what the build tags cost in linkage terms
- [Component cache](component-cache.md) — why `SOURCE_DATE_EPOCH` and the recipe hash matter together
- [Tooling](tooling.md) — mise as the pinning mechanism for the glibc half
