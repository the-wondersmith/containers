#!/usr/bin/env bash
# Resolves which product a GitHub release belongs to, and finds the most recent
# release of a given product.
#
# The repository publishes more than one product from one release stream. Every
# workflow that reasons about "the previous release" previously took the newest
# release outright, which is only correct while exactly one product exists. A
# release of any other product becomes the newest release, is then read for a
# manifest it does not carry, and the caller either hard-fails or -- worse --
# falls through to a bootstrap branch and silently resets version numbering.
#
# Tag prefix is the sole discriminator. Reading each candidate's manifest to
# decide what it is would cost one API call per candidate and, more importantly,
# would make "a foreign product" and "a corrupt manifest" indistinguishable --
# the second of which must stay a hard failure.
#
# Kept out of the workflows so it can be exercised directly against fixtures.
set -euo pipefail

# The product whose tags carry no prefix. podman shipped before this repository
# published anything else, so its tags are bare `vX.Y.Z-N` and cannot be
# retrofitted without rewriting release history.
readonly UNPREFIXED_PRODUCT="podman"

# Page sizes tried in order. `gh release list --limit` paginates internally, so
# these are result caps rather than page boundaries; escalating avoids fetching
# a thousand releases to answer a question the first thirty almost always
# answer.
readonly PAGE_SIZES=(30 100 300 1000)

# Exit codes are part of the contract, because callers branch on them.
readonly EXIT_USAGE=64
readonly EXIT_NONE=65      # the product has never been released -- bootstrap is correct
readonly EXIT_EXHAUSTED=66 # the cap was reached with more releases possibly unseen

usage() {
  cat << 'EOF'
Usage:
  release-identity.sh classify <tag>
      Print the product a tag belongs to.

  release-identity.sh previous <product> [--releases-file <path>]
      Print the tag of the most recent release of <product>, including
      prereleases.

      Exit 0   a match was found; the tag is on stdout
      Exit 65  no release of that product exists anywhere in the list
      Exit 66  the search cap was reached without a match and more releases
                may exist; the caller must not treat this as "none"

      --releases-file reads a `gh release list --json tagName,isPrerelease`
      array from disk instead of calling the API. Used by the tests.
EOF
}

# A tag either names its product explicitly with a `<product>/` prefix or it is
# the one product that predates the convention. Deriving the name from the
# prefix rather than matching a fixed list means a third product needs no change
# here.
classify() {
  local tag="${1}"

  if [[ -z "${tag}" ]]; then
    echo "classify: empty tag" >&2
    return "${EXIT_USAGE}"
  fi

  if [[ "${tag}" == */* ]]; then
    printf '%s\n' "${tag%%/*}"
  else
    printf '%s\n' "${UNPREFIXED_PRODUCT}"
  fi
}

# Emits the first tag in the list belonging to `product`. The list is assumed to
# be in the order `gh release list` returns it, which is newest first.
select_previous() {
  local product="${1}" releases_json="${2}"

  jq -r --arg product "${product}" --arg unprefixed "${UNPREFIXED_PRODUCT}" '
    map(.tagName)
    | map(select(
        if (. | test("/")) then (. | split("/")[0]) == $product
        else $product == $unprefixed
        end))
    | .[0] // ""
  ' <<< "${releases_json}"
}

previous() {
  local product="${1}" releases_file="${2:-}"
  local releases_json count match

  if [[ -z "${product}" ]]; then
    echo "previous: empty product" >&2
    return "${EXIT_USAGE}"
  fi

  # Fixture path: the caller supplies the whole list, so there is nothing to
  # escalate. An unmatched fixture means the product is genuinely absent.
  if [[ -n "${releases_file}" ]]; then
    releases_json="$(cat "${releases_file}")"
    match="$(select_previous "${product}" "${releases_json}")"

    if [[ -n "${match}" ]]; then
      printf '%s\n' "${match}"
      return 0
    fi

    echo "no ${product} release found in ${releases_file}" >&2
    return "${EXIT_NONE}"
  fi

  # GITHUB_REPOSITORY is set in Actions and unset everywhere else. Falling back
  # to the checkout `gh` already resolves keeps the script runnable locally,
  # which is what makes the live regression in the test suite possible at all.
  local repo="${GITHUB_REPOSITORY:-}"
  if [[ -z "${repo}" ]]; then
    repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
  fi

  local limit
  for limit in "${PAGE_SIZES[@]}"; do
    releases_json="$(
      gh release list --repo "${repo}" \
        --limit "${limit}" --json tagName,isPrerelease
    )"

    match="$(select_previous "${product}" "${releases_json}")"
    if [[ -n "${match}" ]]; then
      printf '%s\n' "${match}"
      return 0
    fi

    # Fewer results than asked for means the whole list was seen. Only then is
    # "no release of this product" a fact rather than an artefact of the cap,
    # and only then may the caller bootstrap.
    count="$(jq 'length' <<< "${releases_json}")"
    if ((count < limit)); then
      echo "no ${product} release exists (${count} releases examined)" >&2
      return "${EXIT_NONE}"
    fi
  done

  # Reaching here means every page size was saturated. Returning "none" would
  # bootstrap version numbering off a false negative, which is precisely the
  # failure this script exists to prevent.
  echo "::error::no ${product} release within the newest ${PAGE_SIZES[-1]} releases" >&2
  echo "::error::refusing to report 'none': the list was truncated, not exhausted" >&2
  return "${EXIT_EXHAUSTED}"
}

main() {
  local command="${1:-}"
  shift || true

  case "${command}" in
    classify)
      classify "${1:-}"
      ;;
    previous)
      local product="${1:-}" releases_file=""
      shift || true

      while (($# > 0)); do
        case "${1}" in
          --releases-file)
            releases_file="${2:-}"
            shift 2
            ;;
          *)
            echo "previous: unknown argument ${1}" >&2
            return "${EXIT_USAGE}"
            ;;
        esac
      done

      previous "${product}" "${releases_file}"
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
