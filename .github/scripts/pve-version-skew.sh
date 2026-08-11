#!/usr/bin/env bash
#
# Detect cross-architecture version divergence in the Proxmox VE package set.
#
# Reads docs/pve-package-matrix.json, produced by pve-package-matrix.sh, and
# fails when a package resolves to different versions on amd64 and arm64
# unless that specific package is on the allowlist below.
#
# Why this exists: the image is built from one Containerfile for both
# architectures and is supposed to ship the same component versions on each.
# Nothing in apt enforces that.  A package published for one architecture and
# not the other still installs cleanly, because apt falls back to whatever
# Debian offers -- so the divergence is invisible to any check that only asks
# whether the build succeeded.  ifupdown2 is exactly that case and was found
# this way rather than by reading a changelog.
#
# Two properties of this check are deliberate and easy to get wrong:
#
#   Skew is SYMMETRIC.  The obvious assumption is that arm64 lags, because
#   Proxmox says arm64 packages may be released later.  That assumption is
#   empirically false here: the ceph client stack is a full major version
#   AHEAD on arm64 (amd64 19.2.3-pve1 "squid" against arm64 20.2.0-pve1
#   "tentacle"), and proxmox-backup-client is one patch ahead.  A one-sided
#   check would have missed both.
#
#   The allowlist is PER PACKAGE, never blanket.  An accepted divergence is a
#   documented lie, and documented lies are the ones people forget.  Naming
#   each package individually means a NEW divergence in the same subsystem
#   still fails, which is the only property that makes the check worth having.
set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_UNEXPECTED=1
readonly EXIT_USAGE=64
readonly EXIT_NO_MATRIX=65

readonly DEFAULT_MATRIX="docs/pve-package-matrix.json"

# Packages whose cross-architecture divergence is accepted, with the reason.
#
# ceph client stack: Proxmox's published version sets are strictly DISJOINT
# per architecture -- amd64 offers only squid, arm64 only tentacle -- so there
# is no common version to pin.  pve-test carries the same versions as
# pve-no-subscription for ceph on both arches, so switching components buys
# nothing.  Sourcing from Debian is impossible because ceph-fuse is published
# amd64-only in Debian trixie while being an unconditional Depends of
# libpve-storage-perl.  The functional consequence is nil for the shipped
# image: the client libraries are only exercised when a ceph storage backend
# is configured, and the image configures none.  The divergence is in
# installed bytes, not in exercised behaviour.
#
# proxmox-backup-client / -file-restore: one patch apart, upstream-controlled,
# arm64 ahead.  This is caveat 5 (independent per-arch release cadence)
# behaving exactly as Proxmox documents.
readonly ALLOWED=(
  "ceph-common"
  "ceph-fuse"
  "libcephfs2"
  "librados2"
  "libradosstriper1"
  "librbd1"
  "librgw2"
  "python3-ceph-argparse"
  "python3-ceph-common"
  "python3-cephfs"
  "python3-rados"
  "python3-rbd"
  "python3-rgw"
  "proxmox-backup-client"
  "proxmox-backup-file-restore"
)

usage() {
  cat << EOF
Usage: ${0##*/} [--matrix <path>] [--json]

  Fails when a package in the Proxmox VE closure resolves to different
  versions on amd64 and arm64 and is not on the per-package allowlist.

  --matrix <path>  package matrix JSON (default: ${DEFAULT_MATRIX})
  --json           emit machine-readable output instead of a report
  -h, --help       this text

  Exit ${EXIT_OK}   no unexpected divergence
  Exit ${EXIT_UNEXPECTED}   at least one unexpected divergence
  Exit ${EXIT_USAGE}  usage error
  Exit ${EXIT_NO_MATRIX}  the matrix is missing or unparseable

  Entries are excluded from consideration when they cannot affect the image:

    disposition == not-installed-stubbed
        Reachable only through proxmox-default-kernel, which the shim
        satisfies via Provides/Conflicts, so they never install.

    binnmu_only == true
        A binNMU is a per-architecture rebuild of identical source.  The
        version strings differ by a +bN suffix and nothing else.  Reporting
        these buried the real divergences under archive bookkeeping.

    disposition == build-and-publish
        The divergence is real but already remediated: the pipeline builds
        the Proxmox version from source and installs it on both arches, so
        the image does not inherit the repository's asymmetry.  Reported
        separately rather than silently skipped, because the remediation has
        a sunset condition and someone has to notice when it expires.
EOF
}

main() {
  local matrix="${DEFAULT_MATRIX}"
  local as_json="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --matrix)
        [[ $# -ge 2 ]] || {
          echo "error: --matrix needs a path" >&2
          exit "${EXIT_USAGE}"
        }
        matrix="$2"
        shift 2
        ;;
      --json)
        as_json="true"
        shift
        ;;
      -h | --help)
        usage
        exit "${EXIT_OK}"
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit "${EXIT_USAGE}"
        ;;
    esac
  done

  if [[ ! -f "${matrix}" ]]; then
    echo "error: matrix not found: ${matrix}" >&2
    echo "error: generate it with .github/scripts/pve-package-matrix.sh" >&2
    exit "${EXIT_NO_MATRIX}"
  fi

  if ! jq -e 'type == "array" and length > 0' "${matrix}" > /dev/null 2>&1; then
    echo "error: matrix is not a non-empty JSON array: ${matrix}" >&2
    exit "${EXIT_NO_MATRIX}"
  fi

  local allow_json
  allow_json="$(printf '%s\n' "${ALLOWED[@]}" | jq -R . | jq -s .)"

  # An allowlist entry naming a package that is no longer in the closure is
  # dead weight that reads as coverage.  Fail on it rather than let the list
  # rot into a set of names that excuse nothing.
  local stale
  stale="$(
    jq -r --argjson allow "${allow_json}" '
      [.[].package] as $present
      | $allow - $present
      | .[]
    ' "${matrix}"
  )"
  if [[ -n "${stale}" ]]; then
    echo "error: allowlisted packages are absent from the matrix:" >&2
    while IFS= read -r name; do
      [[ -n "${name}" ]] && echo "  ${name}" >&2
    done <<< "${stale}"
    echo "error: remove them from ALLOWED or regenerate the matrix" >&2
    exit "${EXIT_UNEXPECTED}"
  fi

  local report
  report="$(
    jq -c --argjson allow "${allow_json}" '
      def considered:
        .skew != "none"
        and (.binnmu_only | not)
        and .disposition != "not-installed-stubbed";

      {
        accepted: [
          .[] | select(considered
            and .disposition != "build-and-publish"
            and (.package as $p | $allow | index($p)))
        ],
        remediated: [
          .[] | select(considered and .disposition == "build-and-publish")
        ],
        unexpected: [
          .[] | select(considered
            and .disposition != "build-and-publish"
            and (.package as $p | $allow | index($p) | not))
        ],
        mixed_origin: [
          .[] | select(.mixed_origin and .skew == "none") | .package
        ],
      }
    ' "${matrix}"
  )"

  if [[ "${as_json}" == "true" ]]; then
    printf '%s\n' "${report}" | jq .
  else
    emit_report "${report}"
  fi

  local unexpected_count
  unexpected_count="$(printf '%s' "${report}" | jq '.unexpected | length')"
  if [[ "${unexpected_count}" -gt 0 ]]; then
    exit "${EXIT_UNEXPECTED}"
  fi

  exit "${EXIT_OK}"
}

emit_report() {
  local report="$1"

  local line
  local count

  count="$(printf '%s' "${report}" | jq '.accepted | length')"
  echo "accepted divergences (${count}):"
  while IFS= read -r line; do
    [[ -n "${line}" ]] && echo "  ${line}"
  done < <(printf '%s' "${report}" | jq -r '.accepted[] | "\(.package) \(.skew) amd64=\(.versions.amd64[0]) arm64=\(.versions.arm64[0])"')

  count="$(printf '%s' "${report}" | jq '.remediated | length')"
  echo "remediated in-pipeline (${count}):"
  while IFS= read -r line; do
    [[ -n "${line}" ]] && echo "  ${line}"
  done < <(printf '%s' "${report}" | jq -r '.remediated[] | "\(.package) \(.skew) amd64=\(.versions.amd64[0]) arm64=\(.versions.arm64[0]) -- built from source for both arches"')

  # Not a failure and not a divergence: the two arches resolve the same
  # version from different repositories because Proxmox mirrors a handful of
  # stock Debian packages for its own installer.  Surfaced so that a future
  # real divergence in this set does not read as a brand-new problem.
  count="$(printf '%s' "${report}" | jq '.mixed_origin | length')"
  echo "mixed origin, identical version (${count}, informational):"
  while IFS= read -r line; do
    [[ -n "${line}" ]] && echo "  ${line}"
  done < <(printf '%s' "${report}" | jq -r '.mixed_origin[]')

  count="$(printf '%s' "${report}" | jq '.unexpected | length')"
  if [[ "${count}" -eq 0 ]]; then
    echo "unexpected divergences (0): none"
    return
  fi

  echo "unexpected divergences (${count}):" >&2
  while IFS= read -r line; do
    [[ -n "${line}" ]] && echo "  ${line}" >&2
  done < <(printf '%s' "${report}" | jq -r '.unexpected[] | "\(.package) \(.skew) amd64=\(.versions.amd64[0]) arm64=\(.versions.arm64[0])"')
  echo "" >&2
  echo "Each is a package the image installs at different versions per" >&2
  echo "architecture.  Either fix the divergence or add the package to" >&2
  echo "ALLOWED with the reason it cannot be fixed." >&2
}

main "$@"
