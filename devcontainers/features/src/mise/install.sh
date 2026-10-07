#!/usr/bin/env sh
# shellcheck shell=sh disable=SC2016

set -eu

marker='/usr/local/share/mise-install-from-github.status'

apt_updated=false

install() {
  if command -v apt > /dev/null 2>&1; then
    if [ "${apt_updated}" = 'false' ]; then
      apt update > /dev/null 2>&1
      apt_updated=true
    fi
    apt install -yq --no-install-recommends "${@}"
  elif command -v apk > /dev/null 2>&1; then
    apk add --update --no-cache "${@}"
  else
    printf 'no known package installer found!' >&2
    exit 111
  fi
}

if ! command -v bash > /dev/null 2>&1; then
  install 'bash'
fi

if command -v wget > /dev/null 2>&1; then
  fetch='wget -q -O -'
else
  if ! command -v curl > /dev/null 2>&1; then
    install 'curl' 'ca-certificates'
  fi

  fetch='curl -fsSLo -'
fi

if [ "${MISE_VERSION:-}" = 'latest' ]; then
  unset MISE_VERSION
fi

if [ "${MISE_INSTALL_MUSL:-false}" != 'detect' ]; then
  (:) # no-op
elif getconf GNU_LIBC_VERSION > /dev/null 2>&1; then
  export MISE_INSTALL_MUSL='false'
elif [ -n "$(find /lib /usr/lib -name "ld-musl-$(uname -m).so.1" -print -quit 2> /dev/null)" ]; then
  export MISE_INSTALL_MUSL='true'
else
  printf '⚠️ unable to confidently detect ABI, excluding `MISE_INSTALL_MUSL` from installation environment' >&2
  unset MISE_INSTALL_MUSL
fi

installer="${fetch} 'https://mise.run'"
script="$(mktemp)"

trap 'rm -f "${script}"' EXIT

# NOTE: deliberately *not* piped -- a pipeline's status is its last command's,
#       so a failed download would be silently swallowed by a happy `sh`
eval "${installer}" > "${script}"

if [ "${DEVCONTAINERS_FEATURE_TESTING:-false}" != 'true' ] \
  || [ "${MISE_INSTALL_FROM_GITHUB:-false}" != 'true' ]; then
  env -u MISE_AUTO_ACTIVATE MISE_INSTALL_PATH='/usr/local/bin/mise' sh "${script}"
else
  # `MISE_INSTALL_FROM_GITHUB` reaches GitHub for real, and a feature install
  # that fails aborts the entire `devcontainer features test` run rather than
  # being recorded as a result. So when `feature-testing` has flagged that we're
  # under test, record the outcome to a marker file and let the build continue
  # either way -- the scenario asserts on the marker rather than on the build.
  status=0

  env -u MISE_AUTO_ACTIVATE MISE_INSTALL_PATH='/usr/local/bin/mise' sh "${script}" \
    || status="${?}"

  mkdir -p "$(dirname "${marker}")"
  printf 'status=%s\n' "${status}" > "${marker}"

  if [ "${status}" -ne 0 ]; then
    printf '⚠️ install from GitHub failed (status %s), recorded to %s\n' "${status}" "${marker}" >&2
    exit 0
  fi
fi

if [ "${MISE_AUTO_ACTIVATE:-'false'}" = 'true' ]; then
  homes="$(printf '%s\n' "${_REMOTE_USER_HOME}" "${_CONTAINER_USER_HOME}" | sort -u)"

  for home in ${homes}; do
    printf '\n\neval "$(mise activate zsh)"\n\n' | tee -a "${home}/.zshrc" > /dev/null
    printf '\n\neval "$(mise activate bash)"\n\n' | tee -a "${home}/.bashrc" > /dev/null
    mkdir -p "${home}/.config/fish" \
      && printf '\n\nmise activate fish | source\n\n' | tee -a "${home}/.config/fish/config.fish" > /dev/null
  done
fi

version="$(mise --version)"

printf '✅ installed `mise` version %s\n' "${version}"
