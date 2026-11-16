#!/usr/bin/env bash
# Table-driven tests for pasta-eacces-only.awk.
#
# The classifier decides whether a failed rootless-networking assertion in the
# Alpine acceptance suite may let a release through. It cannot be exercised by
# the acceptance run itself in any useful way: there it only ever sees whatever
# the current runner image happens to produce, so a change that widened it to
# accept everything would stay green. These fixtures pin both directions.
#
# The positive cases are verbatim pasta output from the two runner generations
# this repository has seen. The ubuntu-24.04 -> 26.04 move dropped the
# ip_local_port_range line, and matching on that one message is what broke
# upstream-watch, so both shapes are kept as regressions.
#
# It runs under BusyBox awk, the awk the Alpine acceptance container uses. A
# host awk (gawk, mawk, BSD awk) passing proves nothing about that one. A
# `busybox` on PATH is used directly; otherwise the same alpine image the
# acceptance matrix runs is started with docker. If neither is available the
# suite fails rather than skipping, because a skipped check here reads exactly
# like a passing one.
set -euo pipefail

cd "$(dirname "${0}")/../.."

readonly CLASSIFIER=".github/scripts/pasta-eacces-only.awk"
# Keep in step with the alpine `image` in test-podman-packages.yaml.
readonly ALPINE_IMAGE="alpine:3.24"

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

fixtures="$(mktemp -d)"
trap 'rm -rf "${fixtures}"' EXIT

# Fixture file names are <expected>__<case>; expected is "known" (exit 0) or
# "fail" (non-zero).
fixture() {
  cat > "${fixtures}/${1}__${2}"
}

# --- Tolerated: every pasta diagnostic is an EACCES --------------------------

fixture known ubuntu-26.04-pasta << 'EOF'
time="2026-11-16T17:55:27Z" level=warning msg="\"/\" is not a shared mount, this could cause issues ..."
Error: pasta failed with exit code 1:
Couldn't open network namespace /run/user/1000/netns/netns-acfceaf1-fb4b-d72c-3958-d2487c073544: Permission denied

EOF

fixture known ubuntu-26.04-bridge << 'EOF'
Error: setting up Pasta: pasta failed with exit code 1:
Couldn't open PID file /run/user/1000/containers/networks/rootless-netns/rootless-netns-conn.pid: Permission denied

EOF

fixture known ubuntu-24.04-pasta << 'EOF'
Error: pasta failed with exit code 1:
Unable to open /proc/sys/net/ipv4/ip_local_port_range: Permission denied
Couldn't open network namespace /run/user/1000/netns/netns-f6113897-b434-3b0d-d29d-828f17a9dbbc: Permission denied

EOF

fixture known ubuntu-24.04-bridge << 'EOF'
Error: setting up Pasta: pasta failed with exit code 1:
Unable to open /proc/sys/net/ipv4/ip_local_port_range: Permission denied
Couldn't open PID file /run/user/1000/containers/networks/rootless-netns/rootless-netns-conn.pid: Permission denied

EOF

# A trailing space on the header must not flip a known failure into a blocker.
printf 'Error: pasta failed with exit code 1: \nCouldn'"'"'t open PID file /run/user/1000/x.pid: Permission denied\n' \
  | fixture known header-trailing-space

# --- Blocking: anything else -------------------------------------------------

# One non-EACCES diagnostic is enough to make it a real failure.
fixture fail mixed-eacces-and-enoent << 'EOF'
Error: pasta failed with exit code 1:
Unable to open /proc/sys/net/ipv4/ip_local_port_range: Permission denied
Failed to open() /dev/net/tun: No such file or directory

EOF

# A blank line inside the block does not end the scan.
fixture fail enoent-after-blank-line << 'EOF'
Error: pasta failed with exit code 1:
Couldn't open network namespace /run/user/1000/netns/x: Permission denied

Failed to open() /dev/net/tun: No such file or directory
EOF

# A header with no diagnostics says nothing about why pasta failed.
fixture fail empty-block << 'EOF'
Error: pasta failed with exit code 1:

EOF

# EACCES that pasta did not report: a runtime regression, not the known issue.
fixture fail non-pasta-eacces << 'EOF'
Error: crun: open executable: Permission denied: OCI permission denied
EOF

# "Permission denied" must end the line, not merely appear in it.
fixture fail eacces-not-terminal << 'EOF'
Error: pasta failed with exit code 1:
Permission denied while parsing options: --bogus-flag
EOF

fixture fail empty-output < /dev/null

cp "${CLASSIFIER}" "${fixtures}/classifier.awk"

# Prints "<fixture> <exit status>" per fixture. Executed by BusyBox sh, with
# the directory holding the fixtures and the classifier as ${1}.
# shellcheck disable=SC2016  # Expanded by the inner shell, not this one.
readonly RUNNER='
cd "$1"
for f in *__*; do
  st=0
  $AWK -f classifier.awk "$f" > /dev/null 2>&1 || st=$?
  echo "$f $st"
done
'

if command -v busybox > /dev/null; then
  results="$(AWK="busybox awk" busybox sh -c "${RUNNER}" sh "${fixtures}")"
elif command -v docker > /dev/null; then
  # Plain `awk` in the image, exactly as acceptance.sh invokes it.
  results="$(docker run --rm -e AWK=awk -v "${fixtures}:/fx:ro" \
    "${ALPINE_IMAGE}" sh -c "${RUNNER}" sh /fx)"
else
  echo "FAIL: neither busybox nor docker is available to run BusyBox awk" >&2
  exit 1
fi

while read -r name status; do
  expected="${name%%__*}"
  case "${expected}:${status}" in
    known:0) ok "${name#*__}: tolerated as the known pasta failure" ;;
    known:*) fail "${name#*__}: exit ${status}, wanted 0 (known pasta failure)" ;;
    fail:0) fail "${name#*__}: tolerated, but must block the release" ;;
    fail:*) ok "${name#*__}: blocks the release (exit ${status})" ;;
    *) fail "${name}: unrecognised fixture name" ;;
  esac
done <<< "${results}"

# A suite that asserts nothing passes silently. The count is declared, not
# derived, so deleting a case is a failure rather than a smaller green run.
readonly EXPECTED_CHECKS=11
if ((checks != EXPECTED_CHECKS)); then
  echo "FAIL: ran ${checks} checks, expected ${EXPECTED_CHECKS}" >&2
  rc=1
fi

if ((rc == 0)); then
  echo "pasta-eacces-only: ${checks} checks passed"
else
  echo "pasta-eacces-only: failures present" >&2
fi

exit "${rc}"
