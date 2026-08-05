# The podman package

The package is monolithic and self-contained. Rather than depending on separately packaged helpers, it bundles
`netavark`, `aardvark-dns`, `catatonit`, and the `buildah` CLI directly into the payload.

## How helper resolution works

This works because podman resolves its helper binaries from a hardcoded search path that includes `/usr/libexec/podman`. Shipping the
helpers there means podman finds them with no external packages involved. As belt-and-braces the package installs a config fragment at
`/usr/share/containers/containers.conf.d/50-bundled-helpers.conf` pinning
`helper_binaries_dir`, and the helper path is also baked into the binary at compile time via `HELPER_BINARIES_DIR`.

## Why bundle at all

The payoff is **zero declared dependencies** on `netavark` or `aardvark-dns`. No official Debian or Alpine repository ships those at the
required 2.x, so bundling sidesteps the availability problem entirely.

## Standing in for the packages it replaces

Because the package writes those binaries into system paths, it has to claim the names as well as the paths.

On **Debian** it declares `Conflicts`, `Replaces`, and versioned `Provides` for `netavark`, `aardvark-dns`, `catatonit`, and `buildah`,
templated to the versions actually bundled — so another package's *versioned* dependency on any of them is satisfied by installing this one.

On **Alpine** the same intent needs three mechanisms instead of two:

- `provides` carries the same versioned entries, rewritten at build time from the resolved component set.
- `replaces` covers the four components, plus **`podman-openrc`**: Alpine splits its podman init script into that subpackage, and this
  bundle ships `/etc/init.d/podman` itself, so the two would otherwise collide on the same path.
- `provider-priority: "100"` makes this bundle win over any separately packaged netavark, aardvark-dns, catatonit, or buildah rather than
  leaving the choice to apk's resolution order.

## Related

- [Declared dependencies](dependencies.md) — what the package does depend on, and why none of it is soft
- [Linkage policy](linkage.md) — how the bundled binaries are built, and which one is the exception
- [Component cache](component-cache.md) — where the bundled binaries come from
