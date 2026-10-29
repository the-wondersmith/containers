#!/usr/bin/env bash
# Checks a component's pinned Alpine branch against the toolchain floor its
# upstream source declares.
#
# The failure this exists to catch has now happened twice, identically. A stable
# Alpine branch freezes its compilers at one minor version for the branch's
# entire life, upstream raises its floor on its own schedule, and eventually the
# two cross:
#
#   go: go.mod requires go >= 1.26.0 (running go 1.25.10; GOTOOLCHAIN=local)
#   make: *** [Makefile:398: bin/podman] Error 1
#
# Alpine's `go` package ships a patched go.env setting GOTOOLCHAIN=local, so Go
# will not download a newer toolchain to rescue itself -- it fails, roughly 25
# minutes into a build matrix, in a workflow two levels below the one a human
# started. The same crossing took podman from Alpine 3.21 (Go 1.23.9) to 3.23
# (1.25.10), and then from 3.23 to 3.24 (1.26.10).
#
# Nothing here is specific to Go, and nothing is specific to a component: the
# toolchain to check is inferred from the packages the recipe actually installs,
# so adding a sixth component needs no change in this file.
#
# This reports; it does not block. The build already degrades gracefully when a
# component will not compile from its release tag (it holds at the last known
# good version), and hard-failing the watcher would throw away the perfectly
# good updates the other four components resolved in the same run. What was
# missing was not a gate but a diagnosis -- the build's own failure names a Go
# version and a Makefile line, neither of which points at the Alpine pin that
# actually caused it.
#
# Kept out of the workflow so it can be exercised against fixtures.
set -euo pipefail

readonly EXIT_USAGE=64
readonly EXIT_UNMET=70 # the floor is not satisfied; a tag build will fail

usage() {
  cat << 'EOF'
Usage:
  toolchain-floor.sh check <component> <upstream-repo> <ref> [options]
      Compare the toolchain the component's melange recipe would get against
      the floor the upstream source at <ref> declares.

      Exit 0   satisfied, or the recipe installs no checkable toolchain
      Exit 64  usage error
      Exit 70  the floor is NOT satisfied; building from this ref will fail
      Exit 1   a version could not be resolved

  Options:
    --recipe <path>   recipe to read the Alpine pin from
                      (default: packaging/melange/<component>.yaml)
    --have <version>  skip the APKINDEX fetch and use this version
    --need <version>  skip the upstream fetch and use this floor

  <upstream-repo> is in the OWNER/NAME form `gh api` takes. <ref> is anything
  /contents accepts: a tag, a branch, or a commit SHA.

  --have and --need exist for the tests, which must be able to reach the
  comparison without network access or a GitHub token.
EOF
}

# Compares dotted numeric versions; true when $1 >= $2.
#
# Not `sort -V`: it is absent from some BSD sorts and treats a trailing "-r0"
# as significant, and these are plain dotted numerics where the comparison is
# three lines of arithmetic. Missing components read as zero, so "1.26" and
# "1.26.0" compare equal, which is what a go.mod directive of "go 1.26" means.
#
# 10# forces base ten: a zero-padded component like "08" is a syntax error as a
# bash octal literal, and the arithmetic would abort the script under `set -e`.
version_ge() {
  local -a a b
  local i x y

  IFS=. read -ra a <<< "${1}"
  IFS=. read -ra b <<< "${2}"

  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x="${a[i]:-0}"
    y="${b[i]:-0}"

    ((10#${x} > 10#${y})) && return 0
    ((10#${x} < 10#${y})) && return 1
  done

  return 0
}

# The Alpine branch a recipe pins, as the "vX.Y" the CDN path uses.
#
# Read from the recipe rather than passed in, so the thing checked is the thing
# the build will actually use. A recipe that drifted to a different branch than
# its siblings (catatonit did exactly this, sitting on 3.21 long after the rest
# moved) is then checked against its own pin, not an assumed one.
recipe_branch() {
  local recipe="${1}"

  grep -oE 'dl-cdn\.alpinelinux\.org/alpine/v[0-9]+\.[0-9]+/' "${recipe}" \
    | grep -oE 'v[0-9]+\.[0-9]+' \
    | head -1
}

# True when the recipe's package list contains an exact entry.
#
# Anchored, because `grep -q go` matches "go-md2man" and "mongodb" alike -- and
# the netavark recipe installs go-md2man while building no Go at all, so a
# loose match would send this looking for a go.mod that does not exist.
recipe_installs() {
  local recipe="${1}" package="${2}"

  grep -qE "^[[:space:]]*-[[:space:]]+${package}[[:space:]]*$" "${recipe}"
}

# Version of a package in a branch, with the Alpine -rN build suffix stripped.
#
# Reads APKINDEX directly instead of scraping pkgs.alpinelinux.org: the index is
# what apk itself resolves against, so it cannot disagree with what the build
# gets, and it needs no HTML parsing. x86_64 only -- Alpine ships the same
# package versions across arches within a branch, and a second fetch would
# double the cost to re-confirm that.
#
# APKINDEX records are blank-line separated, hence RS=''. The P: line must match
# the whole package name.
alpine_version() {
  local branch="${1}" package="${2}"
  local repo url record version

  for repo in community main; do
    url="https://dl-cdn.alpinelinux.org/alpine/${branch}/${repo}/x86_64/APKINDEX.tar.gz"

    record="$(
      curl -fsSL "${url}" 2> /dev/null \
        | tar -xzO APKINDEX 2> /dev/null \
        | awk -v RS='' -v pkg="${package}" '$0 ~ "(^|\n)P:" pkg "\n"' \
        || true
    )"

    version="$(awk -F: '/^V:/ { print $2; exit }' <<< "${record}")"

    if [[ -n "${version}" ]]; then
      printf '%s\n' "${version%%-r*}"
      return 0
    fi
  done

  return 1
}

# Fetch one file from an upstream repository at a ref.
#
# The raw media type returns file content directly; without it /contents returns
# a JSON envelope with base64 in it, which would need decoding for no benefit.
upstream_file() {
  local repo="${1}" path="${2}" ref="${3}"

  gh api -H "Accept: application/vnd.github.raw" \
    "repos/${repo}/contents/${path}?ref=${ref}" 2> /dev/null
}

# The `go` directive from a go.mod.
#
# The `go` directive, NOT `toolchain`: under GOTOOLCHAIN=local the toolchain
# line is inert, and the `go` line is what produces "go.mod requires go >= X".
# It is always top level and always first of its kind, so the first match wins.
go_floor() {
  awk '/^go[[:space:]]+[0-9]/ { print $2; exit }' <<< "${1}"
}

# `rust-version` from a Cargo.toml, if the crate declares one.
#
# Optional in Cargo, and absent more often than not. An absent MSRV is not a
# floor of zero, it is an unstated floor -- the caller skips rather than
# pretending the check passed.
rust_floor() {
  awk -F'"' '/^[[:space:]]*rust-version[[:space:]]*=/ { print $2; exit }' <<< "${1}"
}

check() {
  local component="${1}" repo="${2}" ref="${3}"
  local recipe="" have="" need=""
  shift 3

  while (($# > 0)); do
    case "${1}" in
      --recipe)
        recipe="${2:-}"
        shift 2
        ;;
      --have)
        have="${2:-}"
        shift 2
        ;;
      --need)
        need="${2:-}"
        shift 2
        ;;
      *)
        echo "check: unknown argument ${1}" >&2
        return "${EXIT_USAGE}"
        ;;
    esac
  done

  if [[ -z "${component}" || -z "${repo}" || -z "${ref}" ]]; then
    echo "check: component, upstream-repo and ref are all required" >&2
    return "${EXIT_USAGE}"
  fi

  recipe="${recipe:-packaging/melange/${component}.yaml}"

  if [[ ! -f "${recipe}" ]]; then
    echo "::error::${component}: no such recipe: ${recipe}" >&2
    return 1
  fi

  # Which toolchain, decided by what the recipe installs. catatonit and the
  # bundle install neither and fall through to the skip below, which is correct
  # rather than an oversight: autotools and tar have no declared floor to cross.
  local toolchain="" manifest="" label=""
  if recipe_installs "${recipe}" go; then
    toolchain=go
    manifest=go.mod
    label=Go
  elif recipe_installs "${recipe}" rust || recipe_installs "${recipe}" cargo; then
    toolchain=rust
    manifest=Cargo.toml
    label=Rust
  else
    echo "::notice::${component}: no checkable toolchain in ${recipe}; skipping"
    return 0
  fi

  local branch
  branch="$(recipe_branch "${recipe}")"
  if [[ -z "${branch}" ]]; then
    echo "::error::${component}: no Alpine repository pin found in ${recipe}" >&2
    return 1
  fi

  if [[ -z "${have}" ]]; then
    if ! have="$(alpine_version "${branch}" "${toolchain}")"; then
      echo "::error::${component}: Alpine ${branch} has no ${toolchain} package" >&2
      return 1
    fi
  fi

  if [[ -z "${need}" ]]; then
    local content
    if ! content="$(upstream_file "${repo}" "${manifest}" "${ref}")" \
      || [[ -z "${content}" ]]; then
      echo "::notice::${component}: no ${manifest} at ${repo}@${ref}; skipping"
      return 0
    fi

    case "${toolchain}" in
      go) need="$(go_floor "${content}")" ;;
      rust) need="$(rust_floor "${content}")" ;;
    esac
  fi

  if [[ -z "${need}" ]]; then
    echo "::notice::${component}: ${manifest} declares no ${label} floor; skipping"
    return 0
  fi

  if version_ge "${have}" "${need}"; then
    echo "::notice::${component}: ${label} ${have} from Alpine ${branch} satisfies >= ${need}"
    return 0
  fi

  # Everything needed to act is in these four lines, because the build's own
  # error is a Makefile line number and says nothing about Alpine at all.
  echo "::error::${component}: Alpine ${branch} ships ${label} ${have}, but ${repo}@${ref} requires >= ${need}"
  echo "::error::${component}: the tag build WILL fail; bump the Alpine pin in ${recipe}"
  echo "::error::${component}: a stable Alpine branch never moves to a new ${label} minor, so this needs a newer branch"
  return "${EXIT_UNMET}"
}

main() {
  local command="${1:-}"
  shift || true

  case "${command}" in
    check)
      check "${1:-}" "${2:-}" "${3:-}" "${@:4}"
      ;;
    -h | --help)
      usage
      ;;
    *)
      usage >&2
      return "${EXIT_USAGE}"
      ;;
  esac
}

main "$@"
