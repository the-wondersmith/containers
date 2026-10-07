### `DEVCONTAINERS_FEATURE_TESTING`

`install.sh` has one branch that exists solely for the test suite. It is inert
unless the `feature-testing` helper is also present in the scenario, and it is
scoped to the conjunction of *under test* **and** `mise-install-from-github`:

```sh
if [ "${DEVCONTAINERS_FEATURE_TESTING:-false}" != 'true' ] ||
  [ "${MISE_INSTALL_FROM_GITHUB:-false}" != 'true' ]; then
```

Why it's needed: `devcontainer features test` has no way to record a feature
install that is *expected* to fail -- a non-zero `install.sh` fails the image
build, which aborts the entire run before any scenario reports. So under test
the outcome of the GitHub install is captured to
`/usr/local/share/mise-install-from-github.status` as `status=<n>` and the build
is allowed to continue either way; `test/mise/install_from_github.sh` asserts on
that marker.

Outside the test suite nothing writes the marker and a failed install fails the
build exactly as it did before. Both halves are verified in
`test/mise/install_from_github.sh` and by the `auto_activate` /
`no_auto_activate` scenarios, which carry the marker with
`mise-install-from-github` left off and must still install normally.

This is a workaround for a harness limitation, not a permanent design. If
`devcontainers/cli` grows an expected-failure verdict for scenarios, or build
option passthrough so `--add-host` becomes reachable, this branch should go.

### Why `/etc/hosts` isn't used to test unreachable-GitHub

BuildKit mounts `/etc/hosts` read-only for the duration of a build, so no
feature's `install.sh` can add entries to it -- neither appending nor replacing
is permitted. That rules out blackholing a host mid-build, which is why the
marker approach above exists.
