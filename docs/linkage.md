# Linkage policy

The governing rule is: **static wherever possible, dynamic only where it is actually necessary, evaluated case by case.**

| Component         | Build          | Shared between packages? |
|-------------------|----------------|--------------------------|
| `netavark`        | static musl    | yes, byte-for-byte       |
| `aardvark-dns`    | static musl    | yes, byte-for-byte       |
| `catatonit`       | static musl    | yes, byte-for-byte       |
| `buildah`         | static musl    | yes, byte-for-byte       |
| `podman` (Alpine) | static musl    | Alpine only              |
| `podman` (Debian) | glibc, dynamic | Debian only              |

## The one exception

The Debian podman is the one deliberate exception. Keeping the **journald log driver** — the default on systemd hosts — requires podman's
`systemd` build tag, which requires linking against `libsystemd`, which exists neither on musl nor in Wolfi. That build also supplies the
systemd unit files: `make install.systemd` is an empty target without the tag.

The cost of that exception, stated plainly: podman on Debian is dynamically linked, so the `.deb` carries a real
`${shlibs:Depends}` and installs on trixie-or-newer rather than anywhere. Everything else in the payload is static and contributes no
runtime dependencies — `dh_shlibdeps` still runs, but finds nothing in the bundled helpers.

One dependency escapes `${shlibs:Depends}` entirely: podman `dlopen`s `libsystemd.so.0` rather than linking it, so it never appears as an
ELF `NEEDED` entry and `dh_shlibdeps` cannot see it. `libsystemd0` is therefore listed by hand in
`debian/control.in`; see [declared dependencies](dependencies.md).

## OpenPGP instead of gpgme

`containers_image_openpgp` is applied on **both** targets, replacing gpgme with a pure-Go OpenPGP implementation. That keeps signature
verification behaviour identical across the two packages and avoids libgpgme as a further runtime dependency. To restore stock-Debian gpgme
behaviour, drop the tag and add `libgpgme-dev` in
`.github/actions/build/podman-gnu/action.yaml`.

## Enforcement

Enforcement is not left to good intentions. Every melange definition asserts its own output has no ELF `NEEDED` entries, the glibc build
checks its linkage against an explicit allowlist, and the acceptance suite re-checks both after installation.

The glibc build's allowlist deliberately does *not* include `libsystemd` for the reason above — a `NEEDED` entry for it would mean podman
had started linking what it currently `dlopen`s.

## Related

- [Build model](build-model.md) — how build tags are computed, and what each podman build ends up with
- [Declared dependencies](dependencies.md) — the dependencies linkage alone does not produce
- [Acceptance suite](acceptance.md) — the post-install linkage assertions
- [Distribution](distribution.md) — why the dynamic Debian build lands on trixie and not bookworm
