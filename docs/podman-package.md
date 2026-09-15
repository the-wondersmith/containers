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

### `container-network-stack`

It also declares `Provides: container-network-stack (= 2)`, which is **not** redundant with the `netavark` entry above it. `Provides` is not
transitive: claiming the name `netavark` does not also claim what Debian's `netavark` package itself claims.
`golang-github-containers-common`
— a hard dependency of this package — depends on the virtual `container-network-stack`, and without the line above, nothing this package
ships
answers to that name even though the bundled netavark is exactly what it asks for.

The dependency is **unversioned**, and this package conflicts with only one of the two providers. That leaves these candidates:

| Provider                      | Declares                        | Conflicted here? | Installable on trixie?                           |
|-------------------------------|---------------------------------|------------------|--------------------------------------------------|
| `netavark`                    | `container-network-stack (= 2)` | **Yes**          | Never selected                                   |
| `containernetworking-plugins` | `container-network-stack (= 1)` | No               | **Yes** — 1.1.1+ds1-3 is a normal trixie package |

So there is no constraint making the generation-1 provider unsatisfying, and none is wanted: the `= N` is the stack generation (1 = CNI,
2 = netavark), not a version of anything bundled, which is why it is hardcoded rather than templated from the netavark version.

The generation-1 provider is a *wrong* answer rather than an impossible one, and that is the actual argument for the line:

- It is CNI, the stack podman removed support for in 5.0. Podman 6.0 cannot use a single binary in it.
- It declares `Depends: iptables`, which this package deliberately avoids — netavark 2.x deleted all iptables support, which is why
  `nftables` is a hard dependency here.

Resolving that way would install a dead network stack plus the firewall backend this package exists to not need, while the stack actually
shipped goes undeclared. Declaring the provide makes the dependency resolve to what is really installed.

In the reported failure apt 3.0 declined *both* candidates and the install failed outright rather than resolving wrongly:

```text
Unsatisfied dependencies:
  golang-github-containers-common : Depends: container-network-stack
  ...
  - containernetworking-plugins:amd64=1.1.1+ds1-3+b17 is not selected for install
  - netavark:amd64=1.14.0-2 is not selected for install because:
      podman:amd64=6.0.2-2 Conflicts netavark
```

Note that apt gave a reason for rejecting `netavark` and **none** for rejecting `containernetworking-plugins`. Do not read a hard constraint
into that silence — nothing in this package's control forbids it, and why it went unselected on that host was not established (apt policy on
a multi-suite system is the likely cause). The provide is correct either way; the failure is what surfaced it, not what justifies it.

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
