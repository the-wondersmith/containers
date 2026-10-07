#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016

set -euo pipefail

# Optional: Import test library
source dev-container-features-test-lib

marker='/usr/local/share/mise-install-from-github.status'

# Definition specific tests
# A failed install would abort the whole run rather than be reported, so the
# feature records the outcome of the GitHub install and lets the build proceed.
# That marker is the actual assertion -- its absence means the from-GitHub
# branch never ran at all.
check "install outcome was recorded" test -f "${marker}"
check "install from GitHub succeeded" grep -qx 'status=0' "${marker}"

# ... and the recorded success has to agree with reality
check "version" mise -v
check "installed to /usr/local/bin" test -x /usr/local/bin/mise

# Report result
reportResults
