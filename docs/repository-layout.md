# Repository layout

```
.
├── packaging/
│   ├── melange/                       # component build definitions (Alpine 3.23 / musl)
│   │   ├── catatonit.yaml  netavark.yaml  aardvark-dns.yaml
│   │   ├── buildah.yaml    podman.yaml
│   │   └── podman-bundle.yaml         # the shipped .apk; assembles, compiles nothing
│   └── podman/
│       ├── 50-bundled-helpers.conf    # shared by both packages
│       ├── alpine/openrc/             # OpenRC services (no systemd on Alpine)
│       └── debian/                    # control.in, rules, changelog, source/format
├── docs/
└── .github/
    ├── actions/
    │   ├── build/podman-gnu/          # the one component melange cannot produce
    │   ├── components/{restore,save}/ # GHCR component cache
    │   ├── package/podman/debian/     # assemble the .deb from components
    │   ├── apt-dispatch/              # shared control-plane notify
    │   ├── authorize-actor/           # gate workflows on the triggering actor
    │   └── prepare-ci-env/            # mise, from mise.lock
    ├── scripts/acceptance.sh
    └── workflows/
```

Component builds live under `actions/build/` and `packaging/melange/` rather than under a `podman/` subtree, because they are
package-agnostic; only packaging is per-package. A second package slots in alongside podman without reworking the surrounding machinery.

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
| `dependabot-automerge.yaml`  | `workflow_run` (CI done) | Auto-merge passing pinned-SHA bumps.                                                    |

`promote-prerelease.yaml` is scheduled an hour after `upstream-watch.yaml` so a freshly published prerelease is never evaluated in the same
hour it was created. `dependabot-automerge.yaml` keys off CI completion rather than the pull request itself, because the merge gate is "CI
passed *and* the diff is nothing but pinned-SHA bumps".

Every workflow declares least-privilege `permissions` at the top level. The seven entry-point workflows also gate on
`authorize-actor`; the two reusable ones inherit that gate from their caller. See
[CI security posture](ci-security.md).

## Related

- [Release process](releases.md) — how `upstream-watch`, `release`, and `promote-prerelease` fit together
- [CI security posture](ci-security.md) — the trust list and the auto-merge gates
- [Local development](development.md) — running the same definitions locally
