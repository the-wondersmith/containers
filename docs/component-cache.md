# Component cache

Components are cached as OCI artifacts in GHCR:

```
ghcr.io/<owner>/containers/components/<component>:<version>-<target>-r<recipe-hash>
ghcr.io/the-wondersmith/containers/components/netavark:2.0.0-aarch64-linux-musl-r7c1f9a2
```

## The tag grammar

`components/` rather than `artifacts/`, because the released `.deb`/`.apk` are already the artifacts. Flat rather than nested under
`podman/`, because netavark is an upstream project the podman package happens to bundle — if a future package bundles it too, it should hit
the same entry. Full target triple, because `musl` alone names a libc rather than a linkage mode.

The `-r<recipe-hash>` suffix is load-bearing: it is a short hash of the build definition itself. Version alone is not a sufficient key —
changing a build flag or the Alpine base would otherwise keep serving pre-change binaries forever.

## Why GHCR

GHCR was chosen over the alternatives deliberately. `actions/cache` evicts entries unread for 7 days, so a quiet component would be rebuilt
every time. Artifacts survive 90 days but are keyed by `(run_id, name)`, so answering *"does a netavark 2.0.0/aarch64-linux-musl build
exist?"* would need an index of past runs — exactly the persistent state this repository avoids. A registry tag answers it in one stateless
call.

## Pruning

Never expiring cuts both ways: without pruning, every component version ever built accumulates forever, along with an entry for every recipe
change. `prune-components.yaml` runs monthly, keeps the most recent 10 versions per component, and deletes untagged manifests. It is
deliberately conservative — a wrongly pruned entry costs exactly one rebuild, and the retention floor is high enough that rollbacks stay
cheap. Manual runs default to `dry-run: true`.

The `reference` a build is *stored* under is the one `components/restore` emitted when it looked the component up, rather than being
recomputed at save time, so the lookup key and the storage key cannot drift apart.

## Related

- [Build model](build-model.md) — reproducibility, without which a content-addressed cache is meaningless
- [Versioning](versioning.md) — the other place this repository refuses to keep committed state
