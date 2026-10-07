#!/usr/bin/env sh
# shellcheck shell=sh disable=SC2016

set -eu

# The `devcontainer` CLI's per-feature wrapper sources this with `set -a` before
# handing off to `install.sh`, and it persists across feature `RUN` layers
printf 'DEVCONTAINERS_FEATURE_TESTING=true\n' >> ../devcontainer-features.builtin.env

# run the user-specified command
if [ -z "${COMMAND:-}" ]; then
  (:) # no-op
elif ! command -v "${COMMAND_SHELL:-}" > /dev/null 2>&1; then
  printf '❗️ `COMMAND_SHELL` %s not installed/available' "${COMMAND_SHELL:-}" >&2
  exit 1
else
  "${COMMAND_SHELL}" -c "${COMMAND}"
fi
