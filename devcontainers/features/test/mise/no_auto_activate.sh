#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016

set -euo pipefail

# Optional: Import test library
source dev-container-features-test-lib

# Definition specific tests
# `mise` must still be installed and usable -- opting out of activation is not
# opting out of the tool.
check "version" mise -v
check "installed to /usr/local/bin" test -x /usr/local/bin/mise

# Same interactive shells as the positive case, asserting the inverse.
check "bash: mise reports not activated" \
  bash -i -c 'mise doctor 2>&1 | grep -q "^activated: no"'
check "zsh: mise reports not activated" \
  zsh -i -c 'mise doctor 2>&1 | grep -q "^activated: no"'
check "fish: mise reports not activated" \
  fish -i -c 'mise doctor 2>&1 | grep -q "^activated: no"'

check "bash: shims not on PATH" \
  bash -i -c 'mise doctor 2>&1 | grep -q "^shims_on_path: no"'
check "zsh: shims not on PATH" \
  zsh -i -c 'mise doctor 2>&1 | grep -q "^shims_on_path: no"'
check "fish: shims not on PATH" \
  fish -i -c 'mise doctor 2>&1 | grep -q "^shims_on_path: no"'

check "bash: MISE_SHELL unset" bash -i -c '[ -z "${MISE_SHELL:-}" ]'
check "zsh: MISE_SHELL unset" zsh -i -c '[ -z "${MISE_SHELL:-}" ]'
check "fish: MISE_SHELL unset" fish -i -c 'test -z "$MISE_SHELL"'

# `mise` must resolve to the bare binary, not an activation wrapper.
check "bash: mise is not a function" bash -i -c '[ "$(type -t mise)" != function ]'
check "zsh: mise is not a function" zsh -i -c '[ "$(whence -w mise)" != "mise: function" ]'
check "fish: mise is not a function" fish -i -c 'test (type -t mise) != function'

# Report result
reportResults
