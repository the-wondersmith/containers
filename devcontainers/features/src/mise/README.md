# Mise-En-Place ([`mise`](https://mise.jdx.dev/))

Installs `mise` to `/usr/local/bin/mise`, auto-detecting the correct libc
variant and optionally wiring up shell activation.

## Example Usage

```json
"features": {
  "ghcr.io/the-wondersmith/containers/mise:1": {}
}
```

Pinned, without touching shell rc files:

```json
"features": {
  "ghcr.io/the-wondersmith/containers/mise:1": {
    "mise-version": "2025.2.0",
    "mise-auto-activate": false
  }
}
```

## Options

| Option                     | Type      | Default  | Description                                                            |
|----------------------------|-----------|----------|------------------------------------------------------------------------|
| `mise-version`             | `string`  | `latest` | Version to install. `latest` resolves at build time.                   |
| `mise-install-musl`        | `string`  | `detect` | `true`, `false`, or `detect`. Which libc variant of the binary to use. |
| `mise-auto-activate`       | `boolean` | `true`   | Append activation directives to `bash`, `zsh` and `fish` rc files.     |
| `mise-install-from-github` | `boolean` | `false`  | Pull the release asset from GitHub rather than the `mise` CDN.         |

## Notes

### libc detection

`mise` ships both glibc and musl builds, and the musl one is statically linked.
The default `detect` picks between them by probing the container rather than
guessing from the distro:

1. If `getconf GNU_LIBC_VERSION` succeeds, glibc is present -> glibc build.
2. Otherwise, if `ld-musl-<arch>.so.1` exists under `/lib` or `/usr/lib` -> musl build.
3. If neither holds, `MISE_INSTALL_MUSL` is left unset and `mise`'s own installer decides.

Setting the option to `true` or `false` explicitly skips detection entirely.
Note that the musl build is static, so it runs on glibc systems too -- "it
executes" is not evidence that the right variant was selected.

### Shell activation

With `mise-auto-activate` enabled, both the container user's and the remote
user's home directories get:

| File                       | Directive                      |
|----------------------------|--------------------------------|
| `.bashrc`                  | `eval "$(mise activate bash)"` |
| `.zshrc`                   | `eval "$(mise activate zsh)"`  |
| `.config/fish/config.fish` | `mise activate fish \| source` |

`fish` gets its own idiom rather than an `eval` -- it has no `eval "$(...)"`
construct, so the `bash` form would be inert there.

Activation is what puts the `mise` shims on `PATH`. Without it `mise` is still
installed and usable, but managed tools won't resolve.

### Version pinning and GitHub

`mise`'s installer routes any *pinned* version through GitHub releases
regardless of `mise-install-from-github`; only `latest` is served from the CDN.
So a pinned version needs GitHub reachable at build time even with the option
off.

### `curl` and TLS

On images shipping neither `curl` nor `wget`, `curl` is installed together with
`ca-certificates`. The latter is only a *recommends* of `curl`, so
`--no-install-recommends` on its own leaves no CA bundle and every HTTPS fetch
fails with `curl: (77) error setting certificate verify locations`.

---

_Additional notes live in [`NOTES.md`](NOTES.md)._
