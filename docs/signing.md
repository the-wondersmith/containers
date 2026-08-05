# Package signing

**This repository does not sign packages.**

Signing belongs to the package repository. This repository **builds and attests**; `the-wondersmith/apt` owns the keys and signs what it
serves. That split is why the only secret any workflow here consumes is `APT_DISPATCH_TOKEN` — there is no key material to
manage, rotate, or leak. (The repository has other secrets configured for unrelated tooling; no workflow in this
repository references them.)

So the packages are unsigned, and that is a deliberate choice rather than an omission:

- The `.deb` was never going to be signed here. APT's trust model signs the repository *index*, not individual packages, and that index
  belongs to the APT repository.
- The `.apk` is built with no `--signing-key`, so it carries no `.SIGN.*` entry at all. Installing a local file therefore needs
  `--allow-untrusted`; if the APT repository ever serves an APK index, it re-signs with its own key at that point, and consumers trust
  *that* key.

An earlier revision of this repository signed the `.apk` with a per-run key. That is strictly worse than not signing: the public half died
with the runner, so the package carried a valid-looking signature nothing could verify and an operator had no way to tell it meant nothing.
Unsigned is honest; a signature no one can check is not.

## What is relied on instead

The control that actually matters is the **SLSA build-provenance attestation**, which binds the exact released bytes to this workflow's
signer identity. The APT control plane verifies it before ingesting, so an artefact that was not built here is rejected at the door — the
same mechanism `the-wondersmith/pve-modkit` relies on.

Because this repository is **public**, those attestations are verifiable by anyone, with no token and no special plan:

```sh
gh attestation verify ./podman_6.0.2-1_amd64.deb --repo the-wondersmith/containers
```

That is load-bearing for the argument above. An unsigned artefact is only honest rather than negligent if the thing that replaces the
signature is something a consumer can actually check — on a private repository, provenance attestation requires GitHub Advanced Security,
and the story would be considerably weaker.

## Related

- [Distribution](distribution.md) — where the attestation is produced and consumed
