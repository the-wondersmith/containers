#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016

set -euo pipefail

# Optional: Import test library
source dev-container-features-test-lib

# Definition specific tests
check "version" mise -v

# Start each shell the way a user would -- interactively, so it reads its own rc
# file -- and ask `mise` itself whether it ended up activated. `mise doctor`
# exits non-zero when it has anything to report, so the grep is what decides.
check "bash: mise reports activated" \
  bash -i -c 'mise doctor 2>&1 | grep -q "^activated: yes"'
check "zsh: mise reports activated" \
  zsh -i -c 'mise doctor 2>&1 | grep -q "^activated: yes"'
check "fish: mise reports activated" \
  fish -i -c 'mise doctor 2>&1 | grep -q "^activated: yes"'

# Activation is what puts the shims on PATH; without it tools are unreachable.
check "bash: shims on PATH" \
  bash -i -c 'mise doctor 2>&1 | grep -q "^shims_on_path: yes"'
check "zsh: shims on PATH" \
  zsh -i -c 'mise doctor 2>&1 | grep -q "^shims_on_path: yes"'
check "fish: shims on PATH" \
  fish -i -c 'mise doctor 2>&1 | grep -q "^shims_on_path: yes"'

# Each shell must activate as *itself* -- this is what catches an rc file being
# handed the directive for the wrong shell.
check "bash: MISE_SHELL is bash" bash -i -c '[ "$MISE_SHELL" = bash ]'
check "zsh: MISE_SHELL is zsh" zsh -i -c '[ "$MISE_SHELL" = zsh ]'
check "fish: MISE_SHELL is fish" fish -i -c 'test "$MISE_SHELL" = fish'

# Activation replaces the bare binary with a shell function wrapper.
check "bash: mise is a shell function" bash -i -c '[ "$(type -t mise)" = function ]'
check "zsh: mise is a shell function" zsh -i -c '[ "$(whence -w mise)" = "mise: function" ]'
check "fish: mise is a shell function" fish -i -c 'test (type -t mise) = function'

# Report result
reportResults
