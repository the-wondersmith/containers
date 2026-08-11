# Provenance

This document maps every package source in the `proxmox-ve` container image to a permitted tier and justifies anything not from tier 1 or tier 2.

## Tier 1 — official Proxmox

Repository: `http://download.proxmox.com/debian/pve`, suite `trixie`, component `pve-no-subscription`.

Keyring: `https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg`,
sha256 `136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45`, asserted at build time.
A silently changed keyring is a supply-chain event, not a transient fetch failure.

The repository publishes `binary-amd64` and `binary-arm64` under the same suite and component, so nothing in the Containerfile branches on target architecture for source selection.
`pve-no-subscription` rather than `pve-enterprise` because the enterprise component requires a subscription key a published image cannot carry.

## Tier 2 — official Debian

Repository: `http://deb.debian.org/debian`, suite `trixie`, component `main`.

456 of the 568 packages in the resolved closure.

Note: the six systemd packages resolve from the Proxmox mirror on amd64 and from Debian on arm64 at the byte-identical version `257.13-1~deb13u1`.
Proxmox mirrors stock Debian systemd for its own installer with no PVE patches; the two architectures are therefore byte-identical despite resolving from different hosts.

## Tier 3 — built by this project

Two packages are neither Proxmox-published nor Debian-published.

**`ifupdown2` from upstream source.** Built from `https://git.proxmox.com/git/ifupdown2.git` and published through `the-wondersmith/apt`.
The justification and sunset condition are in `DEVIATIONS.md` §8.

**`pve-container-shim`.** First-party, built in-pipeline and published through the same path.
It derives from no upstream source and exists solely to reconcile PVE's kernel-metapackage assumptions with a container environment.
Complete source is under `packaging/pve-container-shim/`.

## Ubuntu: not used

No Ubuntu package appears anywhere in the closure. Stated explicitly so nobody has to re-derive it.

## Licensing

Proxmox VE is AGPLv3. This repository is AGPL-3.0. Source-availability obligations attach to a published image.

Every Proxmox component is installed unmodified from the official repository.
`ifupdown2` is built unmodified from official upstream sources; the build recipe is in this repository.
`pve-container-shim`'s complete source is in this repository under `packaging/pve-container-shim/`.

## Verification

Attestation rather than package signatures is the trust anchor — see `docs/signing.md`.

GHCR has no native OCI 1.1 referrers API and falls back to a `sha256-<digest>` tag scheme.
As a result `cosign verify-attestation` fails against GHCR, while `gh attestation verify` works because it queries GitHub's first-party attestation API.
Recorded here so nobody later "improves" verification by switching to cosign.

## Related

- [Deviations](DEVIATIONS.md) — the workarounds that justify the tier-3 entries above
- [Proxmox VE package matrix](docs/pve-package-matrix.md) — the full 568-package closure these sources supply
- [Package signing](docs/signing.md) — why attestation is the trust anchor rather than package signatures
