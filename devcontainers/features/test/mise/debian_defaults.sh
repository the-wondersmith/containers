#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016

set -euo pipefail

# Optional: Import test library
source dev-container-features-test-lib

# Definition specific tests
# Exercises the `apt` branch of `install()` -- bookworm-slim ships neither
# `curl` nor `wget`, so the fetcher has to be installed from scratch.
check "version" mise -v
check "installed to /usr/local/bin" test -x /usr/local/bin/mise

# Regression guard: `--no-install-recommends` silently omits `ca-certificates`,
# which leaves `curl` unable to verify TLS and the download empty.
check "ca-certificates bundle present" test -s /etc/ssl/certs/ca-certificates.crt

# `detect` must resolve to glibc here -- `getconf GNU_LIBC_VERSION` succeeds,
# so the dynamically linked asset is selected.
check "glibc build selected by detection" \
  sh -c "ldd /usr/local/bin/mise 2>&1 | grep -q 'libgcc_s'"

# Report result
reportResults
