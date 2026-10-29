#!/usr/bin/env bash
# Table-driven tests for toolchain-floor.sh.
#
# The behaviour under test is a version comparison that only matters on the one
# run where it changes -- the week upstream raises a floor past what the pinned
# Alpine branch can ever ship. Fixtures make that week reachable on demand, and
# the regression cases below are the two real crossings this repository has
# already lived through.
#
# --have and --need inject both sides of the comparison, so the whole suite runs
# with no network and no GitHub token.
set -euo pipefail

cd "$(dirname "${0}")/../.."

readonly SCRIPT=".github/scripts/toolchain-floor.sh"
readonly EXIT_UNMET=70

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

# Runs a check with both versions injected and asserts the exit status.
expect_status() {
  local name="${1}" component="${2}" have="${3}" need="${4}" want="${5}"
  local got=0

  "${SCRIPT}" check "${component}" example/repo v0.0.0 \
    --have "${have}" --need "${need}" > /dev/null 2>&1 || got=$?

  if ((got == want)); then
    ok "${name}: have ${have}, need ${need} -> exit ${got}"
  else
    fail "${name}: have ${have}, need ${need} -> exit ${got}, wanted ${want}"
  fi
}

echo "::group::version comparison"
# Equal satisfies: a floor of "go >= 1.26.0" is met by exactly 1.26.0.
expect_status "equal" podman 1.26.0 1.26.0 0
expect_status "patch above" podman 1.26.10 1.26.0 0
expect_status "patch below" podman 1.26.7 1.26.8 "${EXIT_UNMET}"
expect_status "minor above" podman 1.27.0 1.26.8 0
expect_status "minor below" podman 1.25.10 1.26.0 "${EXIT_UNMET}"

# The comparison must be numeric, not lexical. "1.9" sorts above "1.26" as text,
# which is the bug that makes version strings worth a dedicated function.
expect_status "numeric not lexical" podman 1.26.0 1.9.0 0

# A go.mod directive of "go 1.26" means 1.26.0; a missing component is zero, not
# unbounded.
expect_status "short floor" podman 1.26.0 1.26 0
expect_status "short have" podman 1.26 1.26.0 0

# Zero-padded components must not be read as octal. 1.26.08 under a bash octal
# literal is a syntax error, which would abort the script rather than compare.
expect_status "zero padded" podman 1.26.09 1.26.8 0
echo "::endgroup::"

echo "::group::historical regressions"
# Both real crossings. Each was a multi-week run of red builds whose only
# symptom was a Makefile line number.
#
# Alpine 3.21 shipped Go 1.23.9; podman 6 moved the floor to 1.25.9.
expect_status "podman 6 vs alpine 3.21" podman 1.23.9 1.25.9 "${EXIT_UNMET}"
# Alpine 3.23 shipped Go 1.25.10; podman 6.1.4 moved it to 1.26.0 and buildah
# 1.46.0 to 1.26.8. This is the failure that motivated the script.
expect_status "podman 6.1.4 vs alpine 3.23" podman 1.25.10 1.26.0 "${EXIT_UNMET}"
expect_status "buildah 1.46.0 vs alpine 3.23" buildah 1.25.10 1.26.8 "${EXIT_UNMET}"
# Alpine 3.24 ships Go 1.26.10, which clears both. If this ever fails, the
# branch the recipes were just moved to has stopped being sufficient.
expect_status "podman 6.1.4 vs alpine 3.24" podman 1.26.10 1.26.0 0
expect_status "buildah 1.46.0 vs alpine 3.24" buildah 1.26.10 1.26.8 0
echo "::endgroup::"

echo "::group::toolchain inference"
# catatonit is autotools-only: no go, no rust, nothing to check. It must skip
# rather than fail, or every run goes red over a component that has no floor.
catatonit_status=0
"${SCRIPT}" check catatonit openSUSE/catatonit v0.2.1 \
  --have 1.0.0 --need 99.0.0 > /dev/null 2>&1 || catatonit_status=$?
if ((catatonit_status == 0)); then
  ok "catatonit: skipped despite an unmeetable injected floor"
else
  fail "catatonit: exited ${catatonit_status}, wanted 0 (skip)"
fi

# netavark installs go-md2man but builds no Go. A loose package match would send
# the check after a go.mod that does not exist; it must resolve to Rust.
netavark_out="$(
  "${SCRIPT}" check netavark containers/netavark v2.1.0 \
    --have 1.96.1 --need 1.88 2>&1 || true
)"
if [[ "${netavark_out}" == *Rust* ]]; then
  ok "netavark: go-md2man did not make it look like a Go build"
else
  fail "netavark: expected a Rust check, got: ${netavark_out}"
fi

# A recipe that does not exist is an error, not a silent pass.
missing_status=0
"${SCRIPT}" check nonexistent example/repo v1.0.0 \
  --have 1.0.0 --need 1.0.0 > /dev/null 2>&1 || missing_status=$?
if ((missing_status == 1)); then
  ok "missing recipe: exited 1"
else
  fail "missing recipe: exited ${missing_status}, wanted 1"
fi
echo "::endgroup::"

echo "::group::pinned branch"
# Reads the pin out of each recipe and asserts every component agrees. A recipe
# drifting onto its own branch is exactly how catatonit sat on 3.21 long after
# the rest moved, and nothing caught it.
branches="$(
  grep -hoE 'dl-cdn\.alpinelinux\.org/alpine/v[0-9]+\.[0-9]+/' packaging/melange/*.yaml \
    | grep -oE 'v[0-9]+\.[0-9]+' | sort -u
)"
if [[ "$(wc -l <<< "${branches}")" -eq 1 ]]; then
  ok "every melange recipe pins the same Alpine branch (${branches})"
else
  fail "melange recipes pin divergent Alpine branches: $(tr '\n' ' ' <<< "${branches}")"
fi
echo "::endgroup::"

# A suite that asserts nothing passes silently. The count is declared, not
# derived, so deleting a case is a failure rather than a smaller green run.
readonly EXPECTED_CHECKS=18
if ((checks != EXPECTED_CHECKS)); then
  echo "FAIL: ran ${checks} checks, expected ${EXPECTED_CHECKS}" >&2
  rc=1
fi

if ((rc == 0)); then
  echo "toolchain-floor: ${checks} checks passed"
else
  echo "toolchain-floor: failures present" >&2
fi

exit "${rc}"
