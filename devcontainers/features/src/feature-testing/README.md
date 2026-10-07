# Wondersmith Feature Testing Helper

Scaffolding for testing *other* features in this collection. Not intended for
real dev containers -- it exists so that scenarios in `test/<feature>/` can set
up conditions a feature's own options can't reach.

## Example Usage

```yaml
"features": {
  "ghcr.io/the-wondersmith/containers/feature-testing:1": {
    "command": "echo 'look ma! no hands!'",
    "command-shell": "bash"
  }
}
```

## Options

| Option          | Type     | Default | Description                                                              |
|-----------------|----------|---------|--------------------------------------------------------------------------|
| `command`       | `string` | `""`    | Command forwarded as-is to `<command-shell> -c <command>`. Empty = skip. |
| `command-shell` | `string` | `"sh"`  | Shell `command` runs in. Must already be installed.                      |

## Notes

### `DEVCONTAINERS_FEATURE_TESTING` Environment Variable

Adding this feature to a scenario exports `DEVCONTAINERS_FEATURE_TESTING=true`
into the install environment of every feature that installs *after* it, letting
a feature detect that it's under test and accommodate accordingly.

It works by appending to `../devcontainer-features.builtin.env`, which the CLI's
per-feature wrapper sources with `set -a` before handing off to `install.sh`,
and which persists across feature `RUN` layers. Note that this is a *build-time*
mechanism -- the variable is not in the environment of the running container, so
a test script has to read the file rather than `$DEVCONTAINERS_FEATURE_TESTING`.

The motivating case is `mise`'s `mise-install-from-github`, which can't be
exercised honestly in-harness: GitHub can't be made unreachable mid-build (`/etc/hosts` is a read-only mount under BuildKit), and a feature
install that
fails aborts the entire run rather than being recorded as an expected failure.
So `mise` skips the install when it sees the marker plus that option, and the
scenario asserts the binary never landed in the image.

Because the marker only reaches features installed *after* this one, and install
order is not something a scenario controls (see below), a feature relying on it
should treat its absence as "not under test" and behave normally.

### Install order is not declaration order

Each feature gets its own `RUN` layer, but the CLI decides the order -- it is *not* the order features appear in the scenario's `features`
object. For example, in the `mise` scenarios this feature installs **first** despite being declared second.

**Do not** assume this feature runs after the feature under test. In particular,
`command-shell` must already exist at the point this feature runs -- there is no
bootstrapping -- which is why the default is `sh` rather than `bash`. Anything
richer needs a base image that already provides it.

---

_Note: This file was auto-generated from
the [devcontainer-feature.json](https://github.com/devcontainers/features/blob/main/src/github-cli/devcontainer-feature.json). Add
additional notes to a `NOTES.md`._
