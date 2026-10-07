#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016

set -euo pipefail

# Optional: Import test library
source dev-container-features-test-lib

# Definition specific tests
check "version" mise -v

# Report result
reportResults
