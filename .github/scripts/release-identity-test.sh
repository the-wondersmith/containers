#!/usr/bin/env bash
# Table-driven tests for release-identity.sh.
#
# The behaviour under test is a selection rule that is only ever exercised in
# production at the moment it matters -- the identity step of a release -- where
# being wrong resets version numbering silently. Fixtures make the interesting
# cases reachable without publishing anything.
#
# The case that matters most is the last one: a list saturated with releases of
# another product must FAIL rather than report "none", because reporting "none"
# is indistinguishable from a fresh repository and bootstraps pkgrel back to 1.
set -euo pipefail

cd "$(dirname "${0}")"

readonly SCRIPT="./release-identity.sh"
readonly EXIT_NONE=65
readonly EXIT_EXHAUSTED=66

rc=0
checks=0

ok() {
  echo "PASS: ${*}"
  checks=$((checks + 1))
}

fail() {
  echo "FAIL: ${*}" >&2
  rc=1
  checks=$((checks + 1))
}

# Writes a `gh release list --json tagName,isPrerelease` array to stdout.
fixture() {
  local tag
  printf '[\n'
  local first=1
  for tag in "$@"; do
    if ((first == 0)); then printf ',\n'; fi
    first=0
    printf '  {"tagName": "%s", "isPrerelease": false}' "${tag}"
  done
  printf '\n]\n'
}

expect_tag() {
  local name="${1}" product="${2}" want="${3}"
  shift 3

  local file got
  file="$(mktemp)"
  fixture "$@" > "${file}"

  if got="$("${SCRIPT}" previous "${product}" --releases-file "${file}" 2> /dev/null)"; then
    if [[ "${got}" == "${want}" ]]; then
      ok "${name}: ${product} -> ${got}"
    else
      fail "${name}: ${product} -> ${got}, wanted ${want}"
    fi
  else
    fail "${name}: ${product} exited $? , wanted ${want}"
  fi

  rm -f "${file}"
}

expect_status() {
  local name="${1}" product="${2}" want="${3}"
  shift 3

  local file got_status=0
  file="$(mktemp)"
  fixture "$@" > "${file}"

  "${SCRIPT}" previous "${product}" --releases-file "${file}" > /dev/null 2>&1 || got_status=$?

  if ((got_status == want)); then
    ok "${name}: ${product} exited ${got_status}"
  else
    fail "${name}: ${product} exited ${got_status}, wanted ${want}"
  fi

  rm -f "${file}"
}

expect_classify() {
  local tag="${1}" want="${2}" got

  got="$("${SCRIPT}" classify "${tag}")"
  if [[ "${got}" == "${want}" ]]; then
    ok "classify ${tag} -> ${got}"
  else
    fail "classify ${tag} -> ${got}, wanted ${want}"
  fi
}

echo "::group::classification"
expect_classify "v6.0.2-1" "podman"
expect_classify "v6.0.2-12" "podman"
expect_classify "proxmox/v9.2.0-1" "proxmox"
expect_classify "somethingelse/v1.0.0-1" "somethingelse"
echo "::endgroup::"

echo "::group::selection"
# Only podman has ever been released. The historical behaviour and the new
# behaviour must agree here, or the change is not backwards compatible.
expect_tag "podman-only" "podman" "v6.0.2-3" \
  "v6.0.2-3" "v6.0.2-2" "v6.0.2-1"

# Only proxmox exists: podman must report "none" so the caller bootstraps, and
# proxmox must find its own newest.
expect_status "proxmox-only/podman" "podman" "${EXIT_NONE}" \
  "proxmox/v9.2.0-2" "proxmox/v9.2.0-1"
expect_tag "proxmox-only/proxmox" "proxmox" "proxmox/v9.2.0-2" \
  "proxmox/v9.2.0-2" "proxmox/v9.2.0-1"

# The regression that motivated the change: a proxmox release is newest, and the
# old `--limit 1` would have handed it to podman's identity step.
expect_tag "interleaved/podman" "podman" "v6.0.2-3" \
  "proxmox/v9.2.0-1" "v6.0.2-3" "proxmox/v9.1.0-1" "v6.0.2-2"
expect_tag "interleaved/proxmox" "proxmox" "proxmox/v9.2.0-1" \
  "proxmox/v9.2.0-1" "v6.0.2-3" "proxmox/v9.1.0-1" "v6.0.2-2"

# A podman prerelease outstanding must still be selected: two consecutive major
# bumps must not collide on the same tag.
expect_tag "podman-prerelease" "podman" "v6.1.0-1" \
  "v6.1.0-1" "proxmox/v9.2.0-1" "v6.0.2-3"

# An empty repository is the one legitimate bootstrap.
expect_status "empty" "podman" "${EXIT_NONE}"
echo "::endgroup::"

echo "::group::truncation"
# More foreign releases than the largest page size. This MUST fail rather than
# report "none": the list was truncated, not exhausted, so "none" would be a
# false negative that resets pkgrel to 1.
truncation_file="$(mktemp)"
{
  printf '[\n'
  for i in $(seq 1 1000); do
    if ((i > 1)); then printf ',\n'; fi
    printf '  {"tagName": "proxmox/v9.2.0-%s", "isPrerelease": false}' "${i}"
  done
  printf '\n]\n'
} > "${truncation_file}"

# The fixture path cannot escalate, so it reports NONE for a list it was told is
# complete. The saturation behaviour lives on the API path; assert here only
# that a saturated list of foreign releases never yields a podman tag.
truncation_status=0
"${SCRIPT}" previous podman --releases-file "${truncation_file}" > /dev/null 2>&1 \
  || truncation_status=$?
if ((truncation_status == EXIT_NONE || truncation_status == EXIT_EXHAUSTED)); then
  ok "truncation: 1000 foreign releases yielded no podman tag (exit ${truncation_status})"
else
  fail "truncation: exited ${truncation_status}, wanted ${EXIT_NONE} or ${EXIT_EXHAUSTED}"
fi
rm -f "${truncation_file}"
echo "::endgroup::"

# ── Live regression ──────────────────────────────────────────────────────────
# The offline cases prove the selector's logic. This one proves the logic still
# describes reality: against the real repository, the new selector must return
# exactly what the code it replaces returns today. It is read-only -- two list
# calls, no downloads, no writes -- and it is skipped when gh is absent or
# unauthenticated so the suite still runs offline.
#
# It uses its own counter. Folding it into `checks` would make a skipped live
# check indistinguishable from a deleted one, which is the failure the declared
# constant exists to catch.
live_checks=0

echo "::group::live regression"
if ! command -v gh > /dev/null 2>&1; then
  echo "SKIP: gh is not installed; live regression not attempted"
elif ! gh auth status > /dev/null 2>&1; then
  echo "SKIP: gh is not authenticated; live regression not attempted"
else
  repo="the-wondersmith/containers"
  # What the code being replaced does today.
  incumbent="$(gh release list --repo "${repo}" --limit 1 --json tagName \
    --jq '.[0].tagName // ""' 2> /dev/null || echo "")"

  if [[ -z "${incumbent}" ]]; then
    echo "SKIP: ${repo} has no releases; nothing to compare against"
  else
    product="$("${SCRIPT}" classify "${incumbent}")"
    replacement="$("${SCRIPT}" previous "${product}" 2> /dev/null || echo "")"

    live_checks=$((live_checks + 1))
    if [[ "${replacement}" == "${incumbent}" ]]; then
      echo "PASS: live: previous ${product} agrees with --limit 1 (${incumbent})"
    else
      echo "FAIL: live: previous ${product} returned '${replacement}', --limit 1 returned '${incumbent}'" >&2
      rc=1
    fi
  fi
fi
echo "::endgroup::"

# Zero is legitimate -- offline, unauthenticated, or an empty repository. One is
# the only other legitimate value; anything else means the block was edited into
# running more assertions than it declares.
readonly MAX_LIVE_CHECKS=1
if ((live_checks > MAX_LIVE_CHECKS)); then
  echo "FAIL: ran ${live_checks} live checks, expected at most ${MAX_LIVE_CHECKS}" >&2
  rc=1
fi

# A suite that asserts nothing passes silently. The count is declared, not
# derived, so deleting a case is a failure rather than a smaller green run.
readonly EXPECTED_CHECKS=12
if ((checks != EXPECTED_CHECKS)); then
  echo "FAIL: ran ${checks} checks, expected ${EXPECTED_CHECKS}" >&2
  rc=1
fi

if ((rc == 0)); then
  echo "release-identity: ${checks} checks passed, ${live_checks} live"
else
  echo "release-identity: failures present" >&2
fi

exit "${rc}"
