# Rootless storage on Alpine

Alpine's `containers-common` ships **active** `graphroot` and `runroot` settings in `/etc/containers/storage.conf`. In podman 6 an explicit
value wins even for a rootless user — `rootless_storage_path` is deprecated and ignored when both are set — so out of the box a rootless
user tries to write under `/var/lib/containers` and `/run/containers` and is denied:

```
Error: configure storage: mkdir /run/containers: permission denied
```

## The fix

The Alpine package fixes this itself, shipping `/usr/share/containers/storage.conf.d/50-rootless-storage.conf`:

```toml
[storage]
graphroot = ""
runroot = ""
```

Setting a key to the empty string in a drop-in is treated as **unset** rather than as a literal empty path, restoring the per-user defaults.
Verified: with the fragment present, rootless `podman info` reports
`$HOME/.local/share/containers/storage` and rootless `podman run` succeeds, while rootful still reports
`/var/lib/containers/storage` — because the values Alpine forces are containers-storage's own built-in defaults for root and resolve
identically.

## Why `/usr/share`, and why Alpine only

It ships under `/usr/share` rather than `/etc` so it reads as a package default the admin can override, and only on Alpine: Debian's
`golang-github-containers-common` sets neither key, so the same fragment there would be a no-op that could silently override a future Debian
default.

The acceptance suite deliberately applies no workaround of its own, so a regression in this fragment fails the release rather than being
masked.

## Related

- [Service enablement](services.md) — the other Alpine-specific deviations from upstream packaging
- [Acceptance suite](acceptance.md) — the rootless test that guards this fragment
