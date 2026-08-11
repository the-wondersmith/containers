#!/usr/bin/env bash
# Verify that every local reusable-workflow call grants at least the permissions
# the called workflow requests.
#
# A reusable workflow can never hold more than its caller allows. When a caller
# grants less, GitHub rejects the run at workflow *validation* time: no job
# starts, nothing partial happens, and there is no step log to read. The error
# names the callee's job and the permission it wanted, pointing at a line in the
# caller that does not mention that permission at all -- so the message reads as
# though the wrong file is at fault.
#
# This is exactly how `Upstream Watch` broke. Its `release` job granted contents,
# packages, id-token and attestations, while release.yaml's nested `test` job
# requests `actions: read` to resolve build artifacts through the API. The word
# `actions` appeared nowhere in upstream-watch.yaml. release.yaml already carried
# the same grant one level down, with a comment explaining this failure mode --
# the lesson had been learned and simply never propagated up to the caller.
#
# Nothing else in this repository catches it. actionlint validated the broken
# file happily, before and after the fix: the defect lives in the call graph
# between two files, not inside either one. Hence a dedicated check.
#
# The comparison is transitive. A caller must satisfy not only its direct callee
# but everything that callee calls, because the constraint composes all the way
# down.
set -euo pipefail

readonly SELF="${0##*/}"
readonly WORKFLOW_DIR=".github/workflows"

# none < read < write. A grant satisfies a request when its rank is at least the
# request's rank.
rank() {
  case "$1" in
    write) printf '2' ;;
    read) printf '1' ;;
    *) printf '0' ;;
  esac
}

# Emit `scope=level` for a permissions block, or `__scalar__=<value>` when the
# block is the `read-all`/`write-all` shorthand.
#
# The shorthand is deliberately not modelled. Expanding it needs the complete
# set of scopes GitHub defines, which changes as GitHub adds them, and a check
# that silently under-expands would report a pass it did not verify. No workflow
# here uses it; if one ever does, this fails loudly rather than guessing.
perm_entries() {
  local file="$1" path="$2" kind

  # The node's tag decides how to read it. An earlier revision folded this into
  # a single yq expression using `if type == ... then ... else ... end`, which
  # this yq rejects outright -- and because the failure went to stderr inside a
  # command substitution, every lookup silently produced nothing. The comparison
  # then had nothing to compare and passed everything. The self-test below is
  # what caught it.
  kind="$(yq -r "(${path} // {}) | tag" "${file}")"

  if [[ "${kind}" == "!!str" ]]; then
    yq -r "\"__scalar__=\" + (${path})" "${file}"
    return 0
  fi

  yq -r "(${path} // {}) | to_entries[] | .key + \"=\" + (.value | tostring)" "${file}"
}

# Every permission a workflow requests: its workflow-level block plus each job's.
# Jobs are unioned rather than examined individually because the caller has to
# satisfy whichever job wants the most.
workflow_requests() {
  local file="$1" job
  perm_entries "${file}" '.permissions'
  while IFS= read -r job; do
    [[ -n "${job}" ]] || continue
    perm_entries "${file}" ".jobs.\"${job}\".permissions"
  done < <(yq -r '(.jobs // {}) | keys | .[]' "${file}")
}

# Union of a workflow's own requests and those of every local workflow it calls.
# `seen` breaks cycles; a cyclic call graph is invalid to GitHub anyway, but this
# should terminate rather than recurse forever while telling someone so.
transitive_requests() {
  local file="$1" seen="${2:-}" target
  workflow_requests "${file}"
  while IFS= read -r target; do
    [[ -n "${target}" ]] || continue
    target="${target#./}"
    case ":${seen}:" in
      *":${target}:"*) continue ;;
    esac
    [[ -f "${target}" ]] || {
      printf '%s: %s calls %s, which does not exist\n' "${SELF}" "${file}" "${target}" >&2
      return 1
    }
    transitive_requests "${target}" "${seen}:${target}"
  done < <(yq -r '(.jobs // {}) | to_entries[] | select(.value.uses // "" | test("^\./")) | .value.uses' "${file}")
}

# Reduce `scope=level` lines to the highest level requested per scope.
fold_max() {
  awk -F= '
    { if (!($1 in best) || rank($2) > rank(best[$1])) best[$1] = $2 }
    END { for (k in best) print k "=" best[k] }
    function rank(v) { return v == "write" ? 2 : (v == "read" ? 1 : 0) }
  '
}

check_tree() {
  local root="$1" rc=0
  local file jobs job target grant_path need have scope level
  local -a needs=()

  while IFS= read -r file; do
    jobs="$(yq -r '(.jobs // {}) | to_entries[] | select(.value.uses // "" | test("^\./")) | .key' "${file}")"
    while IFS= read -r job; do
      [[ -n "${job}" ]] || continue
      target="$(yq -r ".jobs.\"${job}\".uses" "${file}")"
      target="${target#./}"

      # A job without its own permissions block inherits the workflow-level one.
      if [[ "$(yq -r ".jobs.\"${job}\" | has(\"permissions\")" "${file}")" == "true" ]]; then
        grant_path=".jobs.\"${job}\".permissions"
      else
        grant_path='.permissions'
      fi

      mapfile -t needs < <(transitive_requests "${target}" "${target}" | fold_max | sort)

      for need in "${needs[@]}"; do
        scope="${need%%=*}"
        level="${need#*=}"

        if [[ "${scope}" == "__scalar__" ]]; then
          printf '::error::%s uses the %s permissions shorthand, which this check does not model\n' \
            "${target}" "${level}" >&2
          rc=1
          continue
        fi

        have="$(perm_entries "${file}" "${grant_path}" | awk -F= -v s="${scope}" '$1 == s { print $2 }')"
        if [[ "${have}" == "__scalar__" ]]; then
          printf '::error::%s uses a permissions shorthand, which this check does not model\n' "${file}" >&2
          rc=1
          continue
        fi

        if (($(rank "${have:-none}") < $(rank "${level}"))); then
          printf '::error::%s job %s calls %s, which requests %s: %s, but is granted %s\n' \
            "${file}" "${job}" "${target}" "${scope}" "${level}" "${have:-none}" >&2
          rc=1
        fi
      done

      ((rc == 0)) && printf 'ok   %s :: job %s -> %s\n' "${file}" "${job}" "${target}"
    done <<< "${jobs}"
  done < <(find "${root}" -maxdepth 1 -name '*.yaml' -o -maxdepth 1 -name '*.yml' | sort)

  return "${rc}"
}

# A check that cannot fail is not a check. This builds a caller that is short by
# one permission and asserts the comparison rejects it, then grants it and
# asserts the comparison accepts it -- so a refactor that quietly stops
# comparing anything is caught by the check itself rather than by the next
# broken scheduled run.
self_test() {
  local tmp="" rc=0
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/.github/workflows"

  cat > "${tmp}/.github/workflows/callee.yaml" << 'YAML'
---
name: callee
on:
  workflow_call: {}
permissions:
  contents: read
jobs:
  inner:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: read
    steps:
      - run: 'true'
YAML

  cat > "${tmp}/.github/workflows/caller.yaml" << 'YAML'
---
name: caller
on:
  workflow_dispatch: {}
permissions:
  contents: read
jobs:
  outer:
    permissions:
      contents: read
    uses: ./.github/workflows/callee.yaml
YAML

  if (cd "${tmp}" && check_tree "${WORKFLOW_DIR}" > /dev/null 2>&1); then
    printf 'FAIL: self-test -- a short grant was accepted\n' >&2
    rc=1
  else
    printf 'PASS: self-test -- a short grant is rejected\n'
  fi

  # Same pair, with the missing permission granted.
  sed -i.bak 's/^      contents: read$/      contents: read\n      actions: read/' \
    "${tmp}/.github/workflows/caller.yaml"
  rm -f "${tmp}/.github/workflows/caller.yaml.bak"

  if (cd "${tmp}" && check_tree "${WORKFLOW_DIR}" > /dev/null 2>&1); then
    printf 'PASS: self-test -- a sufficient grant is accepted\n'
  else
    printf 'FAIL: self-test -- a sufficient grant was rejected\n' >&2
    rc=1
  fi

  rm -rf "${tmp}"
  return "${rc}"
}

main() {
  case "${1:-}" in
    --self-test)
      self_test
      return
      ;;
    -h | --help)
      printf 'usage: %s [--self-test]\n' "${SELF}"
      return 0
      ;;
    '') ;;
    *)
      printf '%s: unknown argument: %s\n' "${SELF}" "$1" >&2
      return 64
      ;;
  esac

  self_test > /dev/null || {
    printf '::error::%s self-test failed; the comparison cannot be trusted\n' "${SELF}" >&2
    return 1
  }

  check_tree "${WORKFLOW_DIR}"
}

main "$@"
