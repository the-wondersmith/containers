#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016

set -euo pipefail

# Optional: Import test library
source dev-container-features-test-lib

# Definition specific tests
# An explicit `mise-install-musl` must win over autodetection: this is a glibc
# base, so `detect` would have chosen the dynamically linked asset.
check "version" mise -v
check "musl build overrides glibc detection" \
  sh -c "ldd /usr/local/bin/mise 2>&1 | grep -qiE 'not a (dynamic executable|valid dynamic program)'"
check "static binary is not glibc-linked" \
  sh -c "! ldd /usr/local/bin/mise 2>&1 | grep -q 'libgcc_s'"

# Report result
reportResults
