# Release process

Human interaction is minimized aggressively. Nothing is gated on approval; the acceptance suite is what stands between an upstream tag and a
published package.

| Classification                 | Outcome                                                                                                                                                                                       |
|--------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Minor / patch bump             | Build → acceptance → full release → APT dispatch. No human.                                                                                                                                   |
| **Major** bump (any component) | Build → acceptance → **prerelease**, no APT dispatch. Promoted automatically after a 7-day soak, provided acceptance still passes and no open issue names the tag. A tracking issue is filed. |
| Acceptance fails               | No release. Fails loudly.                                                                                                                                                                     |

Because the happy path for a major bump also has no human in it, the protection against a bad bump has to be the tests — see
the [acceptance suite](acceptance.md) for what that means in practice.

## The soak

`promote-prerelease.yaml` runs weekly, an hour after the upstream watcher so a prerelease published this morning is never evaluated in the
same hour it was created. A prerelease is promoted when it is at least **7 days** old, acceptance still passes against the published
artefacts, and **no open issue names its tag** — an open issue mentioning the tag in its title is an explicit hold, which is how a human
blocks a promotion without having to be in the loop for the ones that are fine.

Candidates are evaluated oldest-first, so two eligible prereleases promote in publication order and `pkgrel` stays monotonic. A
`workflow_dispatch` run can force a specific tag and skip the soak window.

## Related

- [Versioning](versioning.md) — how the version set and `pkgrel` for a release are derived
- [Acceptance suite](acceptance.md) — the only gate on a publish
- [CI security posture](ci-security.md) — the controls on the privileged release lane
- [Distribution](distribution.md) — what happens after a release is published
