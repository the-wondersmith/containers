### Install order is not declaration order

Each feature gets its own `RUN` layer, but the CLI decides the order -- it is *not* the order features appear in the scenario's `features`
object. For example, in the `mise` scenarios this feature installs **first** despite being declared second.

**Do not** assume this feature runs after the feature under test. In particular,
`command-shell` must already exist at the point this feature runs -- there is no
bootstrapping -- which is why the default is `sh` rather than `bash`. Anything
richer needs a base image that already provides it.
