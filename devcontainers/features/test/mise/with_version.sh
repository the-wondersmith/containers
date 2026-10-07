#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016

set -euo pipefail

# Optional: Import test library
source dev-container-features-test-lib

# Definition specific tests
check "mise version is equal to 2025.2.0" sh -c "mise -v | grep '2025.2.0'"

# Report result
reportResults
