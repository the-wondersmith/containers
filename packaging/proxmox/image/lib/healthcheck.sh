#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

mkdir -p /run/pve
touch /run/pve/healthcheck.token

RUNNER='oci-runtime'

if [[ "${container:-}" == 'podman' ]]; then
  RUNNER='podman'
elif [[ -f /.dockerenv ]]; then
  RUNNER='docker'
fi

TOKEN="$(cat /run/pve/healthcheck.token)"

if [[ -z "${TOKEN}" ]]; then

  pveum user add "${RUNNER}@pve" --comment "managed-by: ${RUNNER}" || true
  pveum user token delete "${RUNNER}@pve" healthcheck || true

  pveum user token add "${RUNNER}@pve" healthcheck \
    --comment "managed-by: ${RUNNER}" --output-format yaml \
    | yq '.value' > /run/pve/healthcheck.token

  TOKEN="$(cat /run/pve/healthcheck.token)"
fi

exec curl -fsSL \
  -H "Authorization: PVEAPIToken=${RUNNER}@pve"'!healthcheck='"${TOKEN}" \
  'http://127.0.0.1:85/api2/json/version' \
  | yq -e '(.data // {}).version' > /dev/null 2>&1
