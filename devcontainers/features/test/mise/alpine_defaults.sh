#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

# Optional: Import test library
source dev-container-features-test-lib

# Definition specific tests
# Exercises the `apk` branch of `install()` and busybox `wget` as the fetcher.
check "version" mise -v
check "installed to /usr/local/bin" test -x /usr/local/bin/mise
check "bash was installed as a dependency" bash -c 'true'

# `detect` must resolve to musl here -- alpine has no `getconf GNU_LIBC_VERSION`,
# so the `ld-musl-*.so.1` probe is what decides. The musl asset is static.
check "musl build selected by detection" \
  sh -c "ldd /usr/local/bin/mise 2>&1 | grep -qiE 'not a (dynamic executable|valid dynamic program)'"

# Report result
reportResults
