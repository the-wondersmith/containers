# Repository layout

```
.
├── packaging/
│   ├── melange/                       # component build definitions (Alpine 3.23 / musl)
│   │   ├── catatonit.yaml  netavark.yaml  aardvark-dns.yaml
│   │   ├── buildah.yaml    podman.yaml
│   │   └── podman-bundle.yaml         # the shipped .apk; assembles, compiles nothing
│   ├── podman/
│   │   ├── 50-bundled-helpers.conf    # shared by both packages
│   │   ├── alpine/openrc/             # OpenRC services (no systemd on Alpine)
│   │   └── debian/                    # control.in, rules, changelog, source/format
│   ├── pve-container-shim/            # container-adaptation .deb for the Proxmox image
│   │   ├── debian/                    # control.in, rules, changelog, links, post/prerm
│   │   ├── systemd/                   # unit masks, drop-ins, the two shipped units
│   │   ├── libexec/                   # ensure-hostname, ifup-guest-bridges, kvm-probe
│   │   ├── sbin/                      # ifreload wrapper, update-initramfs no-op
│   │   └── tmpfiles/                  # /run/network fragment
│   └── proxmox/                       # the Proxmox VE OCI image
│       ├── Containerfile
│       ├── apt/proxmox.sources        # deb822 source + pinned keyring
│       ├── slim-paths.txt             # image slimming manifest
│       └── image/                     # entrypoint.sh, lib/, probe/
├── docs/
└── .github/
    ├── actions/
    │   ├── build/podman-gnu/          # the one component melange cannot produce
    │   ├── build/ifupdown2/           # tier-3 ifupdown2 built from git.proxmox.com
    │   ├── components/{restore,save}/ # GHCR component cache
    │   ├── package/podman/debian/     # assemble the .deb from components
    │   ├── package/pve-container-shim/debian/  # build the shim .deb
    │   ├── apt-dispatch/              # shared control-plane notify
    │   ├── authorize-actor/           # gate workflows on the triggering actor
    │   └── prepare-ci-env/            # mise, from mise.lock
    ├── scripts/
    │   ├── acceptance.sh              # podman behavioural suite
    │   ├── pve-acceptance.sh          # Proxmox image behavioural suite
    │   ├── pve-package-matrix.sh      # resolves the proxmox-ve closure; generates docs/
    │   ├── pve-version-skew.sh        # per-arch version drift detector
    │   ├── release-identity.sh        # classify a release by tag prefix
    │   └── release-identity-test.sh
    └── workflows/
```

`dist/` (build output) and `dockurr/` (third-party reference kept only for comparison) are gitignored and omitted here; this tree documents committed source.

Component builds live under `actions/build/` and `packaging/melange/` rather than under a `podman/` subtree, because they are
package-agnostic; only packaging is per-package. That design has since paid off: the `pve-container-shim` package and the Proxmox VE image
slotted in alongside podman without reworking the surrounding machinery.

## Workflows

| Workflow                     | Trigger                  | Purpose                                                                                 |
|------------------------------|--------------------------|-----------------------------------------------------------------------------------------|
| `ci.yaml`                    | PRs, pushes to `main`    | `mise run lint` and `mise run tests`; compile every melange definition for both arches. |
| `upstream-watch.yaml`        | weekly (Mon 08:00 UTC)   | Resolve upstream, classify, dispatch a release.                                         |
| `build-podman-packages.yaml` | reusable, dispatchable   | Components (cache-aware) → `.deb` + `.apk`, both arches.                                |
| `test-podman-packages.yaml`  | reusable                 | Privileged behavioural acceptance suite.                                                |
| `release.yaml`               | reusable                 | Derive identity, orchestrate, attest, publish, dispatch.                                |
| `promote-prerelease.yaml`    | weekly (Mon 09:00 UTC)   | Re-verify and promote soaked prereleases.                                               |
| `prune-components.yaml`      | monthly (1st 04:00 UTC)  | Trim the GHCR component cache.                                                          |
| `publish-apt-packages.yaml`  | release published        | Dispatch human-created UI releases.                                                     |
| `build-proxmox-packages.yaml`| reusable, dispatchable   | Build the `pve-container-shim` and `ifupdown2` `.deb`s (both `Architecture: all`).      |
| `build-proxmox-image.yaml`   | reusable, dispatchable   | Per-arch image build → digest merge → provenance; both arches.                          |
| `release-proxmox.yaml`       | `workflow_dispatch`      | Build, attest, publish the Proxmox image and its `.deb`s; `prerelease: true` default.   |
| `test-proxmox-image.yaml`    | reusable, dispatchable   | Build then run the Proxmox behavioural suite; probes `/dev/kvm`, emits `KVM_AVAILABLE`. |
| `dependabot-automerge.yaml`  | `workflow_run` (CI done) | Auto-merge passing pinned-SHA bumps.                                                    |

`promote-prerelease.yaml` is scheduled an hour after `upstream-watch.yaml` so a freshly published prerelease is never evaluated in the same
hour it was created. `dependabot-automerge.yaml` keys off CI completion rather than the pull request itself, because the merge gate is "CI
passed *and* the diff is nothing but pinned-SHA bumps".

Every workflow declares least-privilege `permissions` at the top level. The lanes that publish gate on `authorize-actor`: `release.yaml` and
`release-proxmox.yaml` each run it before any privileged job. The Proxmox build, image, and test workflows carry no `authorize-actor` — they
hold `contents: read` only and publish nothing, and GitHub already requires write access to dispatch a workflow, so the gate sits on the
publishing lane rather than on the lanes that only build and discard. See [CI security posture](ci-security.md).

## Related

- [Release process](releases.md) — how `upstream-watch`, `release`, and `promote-prerelease` fit together
- [CI security posture](ci-security.md) — the trust list and the auto-merge gates
- [Local development](development.md) — running the same definitions locally
