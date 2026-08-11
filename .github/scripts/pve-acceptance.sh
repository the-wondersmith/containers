#!/usr/bin/env bash
# shellcheck shell=bash
#
# Acceptance suite for the Proxmox VE image.
#
# Runs on the host and drives containers, unlike acceptance.sh which runs
# inside one.  That difference is forced: several items are about how the
# image behaves under *different* runtime flags -- the capability contract,
# the no-privileged invocation, recovery from an unclean stop -- and none of
# those can be observed from inside a container that has already started.
#
# bash rather than POSIX sh because this runs on the CI runner, not inside a
# busybox guest, and the item table wants arrays.
#
# Every item reports pass, fail, or not-attempted.  `fail` never exits, so a
# single run reports every problem rather than the first one; there is one
# exit at the bottom.  A narrative summary is not a result: if an item did not
# run, it says not-attempted rather than being silently absent.
set -euo pipefail

IMAGE="${IMAGE:?IMAGE must be set to the image under test}"

# KVM_AVAILABLE is produced by the workflow probing /dev/kvm on the runner it
# is actually running on.  It is mandatory rather than defaulted because the
# whole point of Tier B is that a skipped KVM test must never be reported as a
# pass, and a default would let this suite decide the question for itself
# instead of consuming the observation.  Reports of working /dev/kvm on hosted
# runners are contradictory, so the only trustworthy answer is a live probe.
KVM_AVAILABLE="${KVM_AVAILABLE:?KVM_AVAILABLE must be set to true or false by the caller}"

# Resolved from the image, not from `uname -m` on this machine.  The two agree
# only when the Docker daemon is local.  Against a remote context -- a docker
# context pointing at a daemon on another host -- `uname -m` reports the
# architecture of the machine running this script, which is not the
# architecture anything under test is running on.  The Tier B dispatch below
# branches on it, so getting it from the wrong place silently selects the wrong
# guest architecture and reports the result as though it meant something.
ARCH="$(docker run --rm --entrypoint /bin/uname "${IMAGE}" -m)"
readonly ARCH

CONTAINER="pve-acceptance-$$"
readonly CONTAINER

# Name PREFIX, not an identifier.  `pveam download` takes the full filename
# from the index -- alpine-3.24-default_20260803_arm64.tar.xz -- and rejects
# the bare package name with `400 ... template: no such template`.  The
# filename carries an upstream build date that gets re-rolled, so it is
# resolved at run time rather than written down here, where it would rot
# silently.
#
# The prefix itself is not a free choice: Proxmox's arm64 appliance catalogue
# is two entries deep (alpine-3.24-default and debian-13-standard), so any
# other template would make item 7 architecture-asymmetric.  Alpine is the
# smaller of the two.
readonly LXC_TEMPLATE_PREFIX="alpine-3.24-default"

# Documented reduced-privilege invocation from docs/pve-image.md.  Item 9
# asserts the management plane comes up under exactly this, so the two must
# not drift apart.
#
# --shm-size is here because the documented invocation carries it.
# --stop-timeout is not: it governs how long `docker stop` waits before
# escalating to SIGKILL, and this suite never calls `docker stop` -- item 10
# uses `docker kill` deliberately, to produce the unclean stop it exists to
# test recovery from.  Adding it would be inert here and would suggest it had
# been exercised.
#
# --security-opt apparmor=unconfined is here because Docker's default profile
# denies mount(2) outright, regardless of CAP_SYS_ADMIN.  Measured on a GitHub
# runner: the FUSE probe reports mount_failed with the profile applied and
# functional without it, and systemd exits 255 during early boot rather than
# reaching a target, because it has filesystems of its own to mount.  This did
# not surface until the suite ran on Docker-on-Linux: the podman host does not
# apply Docker's profile, and Docker Desktop's VM loads no AppArmor at all, so
# both passed while the most common deployment target could never have worked.
# PRIVILEGED_FLAGS does not repeat it -- --privileged already implies it.
readonly REDUCED_FLAGS=(
  --shm-size 256m
  --cgroupns=host
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw
  --tmpfs /run
  --tmpfs /run/lock
  --cap-add SYS_ADMIN
  --device /dev/fuse
  --security-opt apparmor=unconfined
)

# Nested LXC guests need more than the reduced or full capability tiers give.
# Established by controlled testing, not assumed: `pct create` succeeds under
# both, but `pct start` fails at `lxc_setup: 3811 Failed to setup first
# automatic mounts` under the reduced tier AND under the full tier
# (--cap-add NET_ADMIN --security-opt seccomp=unconfined), and succeeds under
# --privileged.  Item 7 therefore runs in its own container: exercising the LXC
# lifecycle under a tier the evidence says cannot support it would be testing
# the wrong configuration, and reporting the resulting failure as a property of
# the image would be wrong twice over.
readonly PRIVILEGED_FLAGS=(
  --shm-size 256m
  --privileged
  --cgroupns=host
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw
  --tmpfs /run
  --tmpfs /run/lock
)

# Units allowed to be failed while the suite still passes, and the tier each
# belongs to.  Pre-declared rather than discovered: `degraded` with an
# unexamined failed-unit list is indistinguishable from `degraded` because
# something broke.  Both of these were identified by controlled capability
# removal and are documented in docs/pve-image.md.
readonly DECLARED_FAILED_UNITS=(
  "lxcfs.service"        # FUSE mount blocked by Docker's default seccomp profile
  "pvefw-logger.service" # nflog_bind_pf AF_INET needs CAP_NET_ADMIN
)

# Closed allowlist of known failures.  A KNOWN-FAIL emits a warning without
# setting rc, which makes it an escape hatch: left open, any inconvenient item
# could be reclassified and the suite would still report green.  The observed
# set is asserted to equal this declared set at the end, so an entry that stops
# firing is as much a failure as one that fires unexpectedly.
readonly DECLARED_KNOWN_FAIL=()

# Declared, not derived.  A count computed from the run is a tautology: it
# would agree with itself no matter how many items were deleted.
#
# The number is the observed counted total on both architectures, which agree
# at 42 because Tier B contributes exactly two results either way -- item 13 passes
# on amd64 and reports not-attempted on arm64, and item 14 reports
# not-attempted on both.  An earlier revision declared 20 against an actual 44,
# which made the >= comparison inert: over half the suite could have been
# deleted and the check would still have reported green, which is precisely the
# property the paragraph above claims to avoid.
#
# The comparison stays >= rather than == so that adding an assertion does not
# require editing this line in the same commit.  That is the deliberate
# trade-off: this catches an item that stops reporting, and does not catch an
# item that is added and then silently removed again before anyone raises the
# floor.  Raise it whenever the observed total moves up.
readonly EXPECTED_ITEMS=46

rc=0
items=0
observed_known_fail=()

ok() {
  items=$((items + 1))
  echo "PASS: $*"
}

fail() {
  items=$((items + 1))
  echo "FAIL: $*" >&2
  rc=1
}

# not_attempted is a first-class outcome, not a soft pass.  It counts toward
# the item total so a silently-absent item still trips the count assertion.
not_attempted() {
  items=$((items + 1))
  echo "NOT-ATTEMPTED: $*"
}

# shellcheck disable=SC2329  # Invoked only when a KNOWN-FAIL is declared;
# the declared set is currently empty and the helper must stay in place so
# adding one is a one-line change rather than a re-implementation.
known_fail() {
  items=$((items + 1))
  observed_known_fail+=("$1")
  echo "::warning::KNOWN-FAIL: $*"
}

# Classification is mandatory on every failure.  arch-specific, container-
# specific and pipeline failures have entirely different implications for what
# to do next, and conflating them wastes days.
classify() {
  echo "  cause-class: $1" >&2
}

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

# shellcheck disable=SC2329  # Invoked by the EXIT trap below.
cleanup() {
  docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# dexec <args...> -- run a command inside the container under test.
dexec() {
  docker exec "${CONTAINER}" "$@"
}

# start_container <name> <flag...> -- start detached and wait for systemd.
#
# The wait is bounded rather than a fixed sleep.  A fixed sleep either wastes
# time or races startup, and a race here samples `starting` and reports an
# empty failed-unit list because nothing has tried to start yet -- a pass that
# proves nothing.
start_container() {
  local name="$1"
  shift

  docker rm -f "${name}" > /dev/null 2>&1 || true
  docker run -d --name "${name}" "$@" "${IMAGE}" > /dev/null

  local deadline=$((SECONDS + 120))
  local state=""
  while ((SECONDS < deadline)); do
    state="$(docker exec "${name}" systemctl is-system-running 2> /dev/null || true)"
    case "${state}" in
      running | degraded) return 0 ;;
    esac
    sleep 3
  done

  # A start-up failure that reports only "<unreachable>" says nothing about
  # whether the container exited, is still running with systemd wedged, or
  # never got past the entrypoint.  Those have entirely different causes, and
  # the difference is one docker inspect away.  An earlier revision printed
  # the bare state and every CI failure had to be reproduced by hand before it
  # could be read at all.
  echo "  last observed system state: ${state:-<unreachable>}" >&2
  echo "  container: $(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}}' "${name}" 2> /dev/null || echo '<no such container>')" >&2
  echo "  --- last 40 lines of container output ---" >&2
  docker logs --tail 40 "${name}" 2>&1 | sed 's/^/  /' >&2 || true
  echo "  --- end container output ---" >&2
  return 1
}

# failed_units_are_declared -- true when every failed unit is pre-declared.
failed_units_are_declared() {
  local name="$1"
  local unit declared found
  local -a observed=()

  mapfile -t observed < <(
    docker exec "${name}" systemctl list-units --state=failed --plain --no-legend --no-pager 2> /dev/null \
      | awk '{print $1}'
  )

  for unit in "${observed[@]}"; do
    [[ -n "${unit}" ]] || continue
    found="false"
    for declared in "${DECLARED_FAILED_UNITS[@]}"; do
      [[ "${unit}" == "${declared}" ]] && found="true" && break
    done
    if [[ "${found}" != "true" ]]; then
      echo "  undeclared failed unit: ${unit}" >&2
      return 1
    fi
  done

  return 0
}

# ── Item 1: the container starts and systemd reaches a stable target ─────────
group "item 1: systemd reaches a stable target"
if start_container "${CONTAINER}" "${REDUCED_FLAGS[@]}"; then
  state="$(dexec systemctl is-system-running 2> /dev/null || true)"
  if [[ "${state}" == "running" ]]; then
    ok "item 1: systemd reached 'running'"
  elif failed_units_are_declared "${CONTAINER}"; then
    ok "item 1: systemd reached 'degraded' with only pre-declared failed units"
  else
    fail "item 1: 'degraded' with an undeclared failed unit"
    classify "container-specific"
  fi
else
  fail "item 1: systemd did not reach a stable target within 120s"
  classify "container-specific"
fi
endgroup

# ── Item 2: component versions are reported ─────────────────────────────────
#
# Cross-architecture parity is asserted by pve-version-skew.sh against the
# package matrix, which can compare both architectures at once.  A single
# container can only report what it has, so this item asserts the report is
# obtainable and non-empty and prints it for the record.
group "item 2: pveversion -v reports component versions"
if versions="$(dexec pveversion -v 2> /dev/null)" && [[ -n "${versions}" ]]; then
  echo "${versions}"
  ok "item 2: pveversion -v reported $(echo "${versions}" | wc -l) components on ${ARCH}"
else
  fail "item 2: pveversion -v produced no output"
  classify "container-specific"
fi
endgroup

# ── Item 3: /etc/pve is a real pmxcfs FUSE mount and is writable ────────────
#
# Asserted from /proc/mounts rather than by writing a file, because a tmpfs
# fallback is also writable: a write test alone passes on a broken image.  The
# fstype really is `fuse` with source /dev/fuse -- pmxcfs does not register a
# `fuse.pmxcfs` subtype, and asserting that would fail against a working image.
group "item 3: /etc/pve is a pmxcfs FUSE mount"
mounts="$(dexec cat /proc/mounts 2> /dev/null || true)"
if echo "${mounts}" | awk '$2 == "/etc/pve" && $3 == "fuse" && $1 == "/dev/fuse" { found = 1 } END { exit !found }'; then
  ok "item 3a: /etc/pve is mounted from /dev/fuse with fstype fuse"
else
  fail "item 3a: /etc/pve is not a FUSE mount"
  echo "${mounts}" | awk '$2 == "/etc/pve"' >&2
  classify "container-specific"
fi

if dexec sh -c 'touch /etc/pve/.acceptance && rm -f /etc/pve/.acceptance' 2> /dev/null; then
  ok "item 3b: /etc/pve is writable"
else
  fail "item 3b: /etc/pve is not writable"
  classify "container-specific"
fi
endgroup

# ── Item 4: the API answers, not merely the units ──────────────────────────
#
# `systemctl is-active` proves a unit did not exit, which is not the same as
# the API answering.  pvesh goes through the real authenticated API path.
group "item 4: the management API answers"
for unit in pve-cluster pvedaemon pveproxy pvestatd; do
  if dexec systemctl is-active --quiet "${unit}" 2> /dev/null; then
    ok "item 4: ${unit} is active"
  else
    fail "item 4: ${unit} is not active"
    classify "container-specific"
  fi
done

if dexec pvesh get /nodes --output-format json > /dev/null 2>&1; then
  ok "item 4: authenticated API call to /nodes succeeded"
else
  fail "item 4: authenticated API call to /nodes failed"
  classify "container-specific"
fi

if dexec curl -fsSk https://127.0.0.1:8006/ > /dev/null 2>&1; then
  ok "item 4: web UI answers on 8006 from inside the container"
else
  fail "item 4: web UI does not answer on 8006 from inside the container"
  classify "container-specific"
fi

# The loopback check above passes no matter what address pveproxy bound to,
# so on its own it does not support the claim the documentation actually
# makes -- that publishing 8006 reaches the web UI.  A service bound only to
# 127.0.0.1 would satisfy it and be unreachable to every operator.
#
# Asserting the bind address directly is the cheaper half.  pveproxy binds all
# interfaces with no configuration in this image: /etc/default/pveproxy does
# not exist here, and LISTEN_IP is therefore not something we set.  A regression
# to loopback-only would be invisible without this.
#
# Note 127.0.0.1:85 is pvedaemon and is *correctly* loopback-only -- it is
# plain HTTP with no TLS, and pveproxy reverse-proxies to it.  It must never
# appear in a reachability assertion.
bind_addr="$(dexec ss -ltn 2> /dev/null | awk '$4 ~ /:8006$/ { print $4 }' | head -n1)"
case "${bind_addr}" in
  '*:8006' | '0.0.0.0:8006' | '[::]:8006')
    ok "item 4: pveproxy binds all interfaces (${bind_addr})"
    ;;
  '')
    fail "item 4: nothing is listening on 8006"
    classify "container-specific"
    ;;
  *)
    fail "item 4: pveproxy bound ${bind_addr}, not all interfaces"
    classify "container-specific"
    ;;
esac

# The other half: reach it from outside the container's network namespace.
#
# Done from a sibling container rather than by publishing a port to the host,
# because a published port lands on the *daemon's* host -- which is a different
# machine when the suite drives a remote docker context, and the assertion would
# fail for a reason that has nothing to do with the image.  A sibling on the
# same daemon is external to the container under test either way.
#
# The image under test is reused as the client because it already carries curl;
# pulling a separate client image would add a network dependency to an assertion
# about networking.
container_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER}" 2> /dev/null | head -n1)"
if [[ -z "${container_ip}" ]]; then
  fail "item 4: could not determine the container address"
  classify "pipeline"
elif docker run --rm --entrypoint /usr/bin/curl "${IMAGE}" \
  -fsSk --max-time 15 "https://${container_ip}:8006/" > /dev/null 2>&1; then
  ok "item 4: web UI answers on 8006 from outside the container (${container_ip})"
else
  fail "item 4: web UI unreachable from outside the container (${container_ip})"
  classify "container-specific"
fi
endgroup

# ── Item 5: hostname resolves to a non-loopback address ────────────────────
#
# When it does not, pmxcfs clients fail with `ipcc_send_rec[1] failed:
# Connection refused` -- a message naming neither the hostname nor /etc/hosts.
group "item 5: hostname resolves off loopback"
hostname_value="$(dexec hostname 2> /dev/null || true)"
resolved="$(dexec getent hosts "${hostname_value}" 2> /dev/null | awk '{print $1}' | head -n1)"
if [[ -n "${resolved}" ]] && [[ "${resolved}" != 127.* ]]; then
  ok "item 5a: ${hostname_value} resolves to ${resolved}"
else
  fail "item 5a: ${hostname_value} resolves to '${resolved:-nothing}'"
  classify "container-specific"
fi

if dexec journalctl --no-pager 2> /dev/null | grep -q 'ipcc_send_rec.*failed'; then
  fail "item 5b: ipcc_send_rec failures present in the journal"
  classify "container-specific"
else
  ok "item 5b: no ipcc_send_rec failures in the journal"
fi
endgroup

# ── Item 6: a directory-backed storage goes online ─────────────────────────
group "item 6: directory-backed storage"
if dexec pvesm add dir acceptance --path /var/lib/vz-acceptance --content images,rootdir > /dev/null 2>&1; then
  if dexec pvesm status --storage acceptance 2> /dev/null | awk 'NR > 1 && $3 == "active" { found = 1 } END { exit !found }'; then
    ok "item 6: directory storage 'acceptance' is active"
  else
    fail "item 6: directory storage 'acceptance' did not go active"
    classify "container-specific"
  fi
  dexec pvesm remove acceptance > /dev/null 2>&1 || true
else
  fail "item 6: pvesm add dir failed"
  classify "container-specific"
fi
endgroup

# ── Item 7: LXC lifecycle ──────────────────────────────────────────────────
#
# Template unavailability is a hard failure rather than a skip.  A skip here
# would silently convert "LXC does not work" into "LXC was not tested", which
# is exactly the substitution this suite exists to prevent.
group "item 7: LXC lifecycle (privileged tier)"
LXC_CONTAINER="${CONTAINER}-lxc"
if start_container "${LXC_CONTAINER}" "${PRIVILEGED_FLAGS[@]}"; then
  ldexec() { docker exec "${LXC_CONTAINER}" "$@"; }

  # 7a asserts on the index artefact rather than on `pveam update`'s exit
  # status, because that command prints `update failed` and still exits 0.
  # That defect is exactly what let a broken image through earlier: the
  # slimming layer had deleted /usr/share/doc/pve-manager/trustedkeys.gpg,
  # every appliance-index signature check failed, and the guard saw success.
  ldexec pveam update > /dev/null 2>&1 || true
  if ldexec test -s /var/lib/pve-manager/apl-info/download.proxmox.com; then
    ok "item 7a: the Proxmox appliance index is present and non-empty"
  else
    fail "item 7a: the Proxmox appliance index is missing or empty (see /var/log/pveam.log)"
    classify "pipeline"
  fi

  # The architecture filter is mandatory.  `pveam available` lists every
  # architecture regardless of host, so matching the prefix alone would happily
  # select an amd64 template on an arm64 host and download something that
  # cannot run.  The filename carries an upstream build date, so it is resolved
  # here rather than written down where it would rot silently.
  host_arch="$(ldexec dpkg --print-architecture 2> /dev/null || true)"
  template="$(
    ldexec pveam available --section system 2> /dev/null \
      | awk -v prefix="${LXC_TEMPLATE_PREFIX}" -v arch="${host_arch}" \
        '$2 ~ ("^" prefix) && $2 ~ ("_" arch "\\.") { print $2 }' \
      | LC_ALL=C sort | tail -n1
  )"

  if [[ -z "${template}" ]]; then
    fail "item 7b: no ${LXC_TEMPLATE_PREFIX} template published for ${host_arch}"
    classify "pipeline"
    fail "item 7c: not reached -- no template resolved"
    classify "pipeline"
  elif ! ldexec pveam download local "${template}" > /dev/null 2>&1; then
    ok "item 7b: resolved template ${template}"
    fail "item 7c: pveam download of ${template} failed"
    classify "pipeline"
  else
    ok "item 7b: resolved template ${template}"

    # --rootfs local:0 is an unsized rootfs: the template is extracted straight
    # into /var/lib/vz/private/<vmid>.  A sized volume (local:1) creates a raw
    # image and attaches it through a loop device, which Docker does not expose
    # -- `losetup: failed to set up loop device: No such file or directory`.
    # The consequence, recorded in DEVIATIONS.md, is that dir-backed guests get
    # no per-container disk quota here.
    # lxc.apparmor.profile: unconfined is a host-environment accommodation, not
    # an image fix.  When the host kernel has AppArmor enabled but apparmor_parser
    # cannot reach its interface file from inside a container, lxc-start generates
    # a profile, fails to load it, and refuses to start:
    #
    #   run_apparmor_parser: 954 Failed to run apparmor_parser on
    #     "/var/lib/lxc/900/apparmor/lxc-900_<-var-lib-lxc>"
    #   apparmor_prepare: 1126 Failed to load generated AppArmor profile
    #   lxc_init: 1069 Failed to initialize LSM
    #
    # The determining variable is whether the host kernel has AppArmor, not the
    # architecture: a host with no AppArmor at all skips the LSM and starts
    # cleanly, so this failure appears on some hosts and not others regardless of
    # arch.  Setting it on the guest rather than passing --security-opt
    # apparmor=unconfined to the outer container keeps the blast radius to this
    # one guest; the outer container's own confinement is untouched.  The cost is
    # real and is stated in DEVIATIONS.md: the guest runs unconfined.  That is
    # already what probe/apparmor reports about this runtime, so the suite is
    # making an existing limitation explicit rather than hiding a new one.
    if ldexec pct create 900 "local:vztmpl/${template}" \
      --hostname acc --memory 256 --rootfs local:0 --unprivileged 1 > /dev/null 2>&1 \
      && ldexec sh -c 'echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/900.conf' \
      && ldexec pct start 900 > /dev/null 2>&1 \
      && ldexec pct exec 900 -- /bin/true > /dev/null 2>&1 \
      && ldexec pct stop 900 > /dev/null 2>&1 \
      && ldexec pct destroy 900 > /dev/null 2>&1; then
      ok "item 7c: LXC create/start/exec/stop/destroy with ${template}"
    else
      fail "item 7c: LXC lifecycle failed with ${template}"
      classify "container-specific"
      ldexec pct destroy 900 --force > /dev/null 2>&1 || true
    fi
  fi

  docker rm -f "${LXC_CONTAINER}" > /dev/null 2>&1 || true
else
  fail "item 7a: the privileged container did not reach a stable target"
  classify "container-specific"
  fail "item 7b: not reached"
  classify "container-specific"
  fail "item 7c: not reached"
  classify "container-specific"
fi
endgroup

# ── Item 8: the capability environment-variable contract ───────────────────
#
# Six reachable scenarios per variable, four variables.  The count is stated
# because "every capability variable behaves per contract" compressed into one
# assertion would let a partial implementation report a pass.
#
#   require + present       -> starts
#   require + absent        -> exit 79, message names device and flag
#   require + indeterminate -> exit 79, reason distinguishes it from absent
#   auto + present          -> enabled
#   auto + absent           -> degrades visibly, still starts
#   disable                 -> probe not run, dependents not started
#
# Scenarios needing a capability to be absent are driven by withholding the
# flag that provides it.  Those needing it present are driven by supplying it.
group "item 8: capability contract"
docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true

contract_checks=0
readonly EXPECTED_CONTRACT_CHECKS=8

contract_expect_exit() {
  local label="$1" expected="$2"
  shift 2
  local actual=0
  # /bin/true rather than the image CMD: the entrypoint ends with `exec "$@"`,
  # so a success-path scenario would exec systemd and never return, hanging a
  # foreground `docker run` forever.  Every probe, summary line and unit mask
  # still runs -- all of that happens before the exec -- so the assertion loses
  # nothing and completes in seconds instead of never.
  docker run --rm "$@" "${IMAGE}" /bin/true > /dev/null 2>&1 || actual=$?
  contract_checks=$((contract_checks + 1))
  # Reported through ok/fail rather than echo so these count toward the item
  # total.  An earlier revision printed them directly, which meant eight real
  # assertions were invisible to the count assertion at the end -- the check
  # that exists to notice when something stops reporting could not see the
  # largest single group of things that could stop reporting.
  if ((actual == expected)); then
    ok "item 8: ${label} exited ${expected}"
  else
    fail "item 8: ${label} exited ${actual}, expected ${expected}"
  fi
}

contract_expect_output() {
  local label="$1" pattern="$2"
  shift 2
  local output
  # See contract_expect_exit: /bin/true keeps success-path scenarios from
  # exec-ing systemd and hanging.
  output="$(docker run --rm "$@" "${IMAGE}" /bin/true 2>&1 || true)"
  contract_checks=$((contract_checks + 1))
  if grep -q -- "${pattern}" <<< "${output}"; then
    ok "item 8: ${label} reported '${pattern}'"
  else
    fail "item 8: ${label} did not report '${pattern}'"
  fi
}

# require + absent: no --device /dev/kvm is passed, so KVM cannot be present.
contract_expect_exit "PVE_KVM=require without /dev/kvm" 79 \
  "${REDUCED_FLAGS[@]}" -e PVE_KVM=require
contract_expect_output "PVE_KVM=require" "--device /dev/kvm" \
  "${REDUCED_FLAGS[@]}" -e PVE_KVM=require

# invalid value: must not silently degrade to auto.
contract_expect_exit "PVE_KVM=requre (typo)" 78 \
  "${REDUCED_FLAGS[@]}" -e PVE_KVM=requre
contract_expect_output "PVE_KVM=requre" "legal values are auto, require, disable" \
  "${REDUCED_FLAGS[@]}" -e PVE_KVM=requre

# auto + absent: degrades visibly and continues.
contract_expect_output "PVE_KVM=auto without /dev/kvm" "capability kvm: disabled" \
  "${REDUCED_FLAGS[@]}" -e PVE_KVM=auto

# disable: probe is skipped entirely.
contract_expect_output "PVE_KVM=disable" "probe=skipped" \
  "${REDUCED_FLAGS[@]}" -e PVE_KVM=disable

# require + present: FUSE is provided, so require must succeed and hand off.
contract_expect_output "PVE_FUSE=require with /dev/fuse" "capability fuse: enabled" \
  "${REDUCED_FLAGS[@]}" -e PVE_FUSE=require

# require + absent for FUSE: withhold the device.
contract_expect_exit "PVE_FUSE=require without /dev/fuse" 79 \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  --cap-add SYS_ADMIN -e PVE_FUSE=require

if ((contract_checks == EXPECTED_CONTRACT_CHECKS)); then
  ok "item 8: all ${EXPECTED_CONTRACT_CHECKS} contract assertions ran"
else
  fail "item 8: ${contract_checks} contract assertions ran, expected ${EXPECTED_CONTRACT_CHECKS}"
  classify "pipeline"
fi
endgroup

# ── Item 9: the image starts without --privileged ──────────────────────────
#
# Item 1 already ran under REDUCED_FLAGS, so this asserts the stronger claim:
# that the documented set contains no --privileged and none of its equivalents.
group "item 9: no --privileged required"
if printf '%s\n' "${REDUCED_FLAGS[@]}" | grep -q -- '--privileged'; then
  fail "item 9: the documented reduced set contains --privileged"
  classify "pipeline"
elif start_container "${CONTAINER}" "${REDUCED_FLAGS[@]}" \
  && dexec sh -c 'touch /etc/pve/.acceptance && rm -f /etc/pve/.acceptance' 2> /dev/null; then
  ok "item 9: management plane reached without --privileged"
else
  fail "item 9: management plane not reachable without --privileged"
  classify "container-specific"
fi
endgroup

# ── Item 10: restart survives an unclean stop ──────────────────────────────
group "item 10: restart after an unclean stop"
if docker kill --signal SIGKILL "${CONTAINER}" > /dev/null 2>&1 \
  && docker start "${CONTAINER}" > /dev/null 2>&1; then

  deadline=$((SECONDS + 120))
  restarted="false"
  while ((SECONDS < deadline)); do
    state="$(docker exec "${CONTAINER}" systemctl is-system-running 2> /dev/null || true)"
    case "${state}" in
      running | degraded)
        restarted="true"
        break
        ;;
    esac
    sleep 3
  done

  if [[ "${restarted}" == "true" ]] \
    && dexec cat /proc/mounts 2> /dev/null | grep -q '^/dev/fuse /etc/pve fuse '; then
    ok "item 10: restarted after SIGKILL with /etc/pve remounted"
  else
    fail "item 10: did not recover from an unclean stop"
    classify "container-specific"
  fi
else
  fail "item 10: could not kill and restart the container"
  classify "pipeline"
fi
endgroup

# ── Item 11: /dev/shm sizing ───────────────────────────────────────────────
#
# df is the primary metric because it counts everything.  qb-* is only the
# attribution breakdown: it names the libqb IPC segments the management plane
# creates, but QEMU memory-backend-file, spice and virtio-fs all consume
# /dev/shm without that prefix.  The number derived here is therefore a
# management-plane floor, not a VM-workload sizing.
group "item 11: /dev/shm headroom"
shm_used="$(dexec df -k /dev/shm 2> /dev/null | awk 'NR == 2 { print $3 }')"
shm_total="$(dexec df -k /dev/shm 2> /dev/null | awk 'NR == 2 { print $2 }')"
qb_count="$(dexec sh -c 'ls /dev/shm/qb-* 2>/dev/null | wc -l' 2> /dev/null || echo 0)"
if [[ -n "${shm_used}" ]] && [[ -n "${shm_total}" ]]; then
  echo "  /dev/shm: ${shm_used} KiB used of ${shm_total} KiB, ${qb_count} qb-* segments"
  if ((shm_used < shm_total)); then
    ok "item 11: /dev/shm has headroom (${shm_used}/${shm_total} KiB, ${qb_count} qb-* segments)"
  else
    fail "item 11: /dev/shm is full (${shm_used}/${shm_total} KiB)"
    classify "container-specific"
  fi
else
  fail "item 11: could not measure /dev/shm"
  classify "pipeline"
fi
endgroup

# ── Item 12: hash-based root credential ────────────────────────────────────
#
# The baseline image's equivalent is provably broken -- it pipes the hash to
# usermod's stdin, which usermod does not read -- so this path is worth
# asserting rather than assuming.  The hash below is a genuine SHA-512 crypt
# of the literal string "acceptance".  What is asserted is that chpasswd -e
# stored it verbatim: a hash that arrived mangled would not match, which is
# precisely the failure mode the baseline exhibits.
group "item 12: hash-based root credential"
# shellcheck disable=SC2016  # $6$ is crypt's SHA-512 marker, not a shell variable.
hash_value='$6$acceptsalt$U40wVOMHKViEzDH8tDSj5tp9qS.twK6DaQXLtSDIdzN/Fv9PNEBRycL17hkhm/8WW/bNSLqiXS8ijNNKvTwWE1'
docker rm -f "${CONTAINER}-hash" > /dev/null 2>&1 || true
if docker run -d --name "${CONTAINER}-hash" "${REDUCED_FLAGS[@]}" \
  -e "PVE_ROOT_PASSWORD_HASH=${hash_value}" "${IMAGE}" > /dev/null 2>&1; then
  sleep 20
  stored="$(docker exec "${CONTAINER}-hash" getent shadow root 2> /dev/null | cut -d: -f2 || true)"
  if [[ "${stored}" == "${hash_value}" ]]; then
    ok "item 12: PVE_ROOT_PASSWORD_HASH was applied verbatim to the shadow entry"
  else
    fail "item 12: shadow entry does not match the supplied hash"
    classify "container-specific"
  fi
  docker rm -f "${CONTAINER}-hash" > /dev/null 2>&1 || true
else
  fail "item 12: container did not start with PVE_ROOT_PASSWORD_HASH set"
  classify "container-specific"
fi
endgroup

# ── Item 15: guest networking ──────────────────────────────────────────────
#
# Runs in its own privileged container.  Guest networking needs CAP_NET_ADMIN
# to create a bridge and install NAT, which the documented management-plane
# tier does not carry -- the same reasoning that puts the LXC lifecycle here
# rather than on the reduced tier.  Asserting it against a tier the design
# says cannot support it would be testing the wrong configuration.
group "item 15: guest networking (privileged tier)"
NET_CONTAINER="${CONTAINER}-net"
if start_container "${NET_CONTAINER}" "${PRIVILEGED_FLAGS[@]}"; then
  ndexec() { docker exec "${NET_CONTAINER}" "$@"; }

  # 15a: the bridge exists as a device, not merely as a line in a config file.
  # /sys/class/net is the authority: ifquery reports success for an interface
  # that was never created, which is how an earlier revision of the helper came
  # to report a bridge up that did not exist.
  if ndexec test -d /sys/class/net/vmbr0 2> /dev/null; then
    bridge_addr="$(ndexec ip -4 -br addr show vmbr0 2> /dev/null | awk '{print $3}')"
    if [[ "${bridge_addr}" == "10.10.10.1/24" ]]; then
      ok "item 15a: vmbr0 exists and carries ${bridge_addr}"
    else
      fail "item 15a: vmbr0 exists but carries '${bridge_addr:-nothing}'"
      classify "container-specific"
    fi
  else
    fail "item 15a: vmbr0 was not created"
    classify "container-specific"
  fi

  # 15b: DHCP is served, not merely configured.  The unit is gated on
  # ConditionPathExists over the generated config, so an active unit with a
  # listener bound to the bridge is what proves the gate opened and dnsmasq
  # actually started -- an earlier revision wrote the config, announced DHCP
  # and shipped the unit disabled, so nothing ever ran.
  if ndexec systemctl is-active --quiet pve-guest-dnsmasq.service 2> /dev/null; then
    if ndexec ss -lun 2> /dev/null | grep -q 'vmbr0:67'; then
      ok "item 15b: pve-guest-dnsmasq.service is active with a DHCP listener on vmbr0"
    else
      fail "item 15b: pve-guest-dnsmasq.service is active but not listening on vmbr0:67"
      classify "container-specific"
    fi
  else
    fail "item 15b: pve-guest-dnsmasq.service is not active"
    classify "container-specific"
  fi

  # 15c: NAT is read back through the same binary that installed it.  Debian
  # ships iptables as an alternatives symlink over two back ends with separate
  # rule sets; an earlier revision installed into one and verified the other,
  # so the start-up line claimed NAT that was invisible to it.
  #
  # The rule is listed rather than matched with -C.  -C requires the whole rule
  # to match exactly, including the comment the entrypoint attaches, so a -C
  # written without it reports the rule missing when it is right there -- which
  # is what happened when the comment was added.  Listing and grepping asserts
  # both the rule and its tag, which is the stronger claim anyway: the tag is
  # what lets an operator identify and remove this image's rule specifically.
  nat_found="false"
  for ipt in iptables-nft iptables-legacy iptables; do
    if ndexec "${ipt}" -t nat -S POSTROUTING 2> /dev/null \
      | grep -q -- '-s 10\.10\.10\.0/24.*pve-container-shim guest NAT.*-j MASQUERADE'; then
      nat_found="${ipt}"
      break
    fi
  done
  if [[ "${nat_found}" != "false" ]]; then
    ok "item 15c: tagged MASQUERADE for 10.10.10.0/24 is present (${nat_found})"
  else
    fail "item 15c: no MASQUERADE rule for 10.10.10.0/24 in any iptables backend"
    classify "container-specific"
  fi

  # 15d: PVE's own Apply Configuration path, end to end.  This is the assertion
  # that exercises assert_ifupdown2_installed() passing, the worker forking, the
  # rename of interfaces.new over interfaces, and the shim's ifreload wrapper
  # actually creating the device -- four mechanisms that each failed
  # independently during development, every one of them silently.
  node="$(ndexec hostname 2> /dev/null)"
  ndexec sh -c 'cp /etc/network/interfaces /etc/network/interfaces.new && cat >> /etc/network/interfaces.new <<EOF

auto vmbr8
iface vmbr8 inet static
    address 10.88.88.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF' 2> /dev/null

  if ndexec test -d /sys/class/net/vmbr8 2> /dev/null; then
    fail "item 15d: vmbr8 already existed before the apply"
    classify "pipeline"
  elif ndexec pvesh set "/nodes/${node}/network" > /dev/null 2>&1 \
    && ndexec test -d /sys/class/net/vmbr8 2> /dev/null; then
    ok "item 15d: a staged bridge applied through the API and the device appeared"
  else
    fail "item 15d: applying a staged bridge through the API did not create it"
    classify "container-specific"
  fi

  docker rm -f "${NET_CONTAINER}" > /dev/null 2>&1 || true
else
  fail "item 15a: privileged container did not reach a stable target"
  classify "container-specific"
  fail "item 15b: privileged container did not reach a stable target"
  classify "container-specific"
  fail "item 15c: privileged container did not reach a stable target"
  classify "container-specific"
  fail "item 15d: privileged container did not reach a stable target"
  classify "container-specific"
fi
endgroup

# ── Item 16: start-up reporting and input validation ───────────────────────
#
# Item 16 covers the start-up affordances: what the image says about itself,
# and the two variables whose wrong values must not be absorbed silently.
# Each runs the entrypoint with /bin/true as the command, so the whole
# configuration sequence executes and then exits without booting systemd.
group "item 16: start-up reporting and input validation"

run_entrypoint() {
  docker run --rm "${PRIVILEGED_FLAGS[@]}" "$@" "${IMAGE}" /bin/true 2>&1
}

# The output is captured once and grepped from a variable rather than piped.
# `docker run | grep -q` looks equivalent and is not: grep -q exits at the first
# match, docker run takes SIGPIPE, and under `set -o pipefail` the pipeline then
# reports failure even though the string was found.  That turns a passing
# assertion into a failing one for a reason nothing in the message hints at.
startup_out="$(run_entrypoint)"

# 16a: the image identifies itself.  Every other line describes a decision;
# none of them says what is running, which is what a log aggregator needs.
if printf '%s\n' "${startup_out}" | grep -q '^Proxmox VE .* (shim .*) on .*, host kernel '; then
  ok "item 16a: the start-up banner identifies PVE version, shim version, arch and host kernel"
else
  fail "item 16a: no identification banner in start-up output"
  classify "container-specific"
fi

# 16b: handing control to something that is not an init system warns.  It does
# not refuse -- this very helper depends on /bin/true being accepted -- but an
# operator who mistyped the path should not have to infer it from a container
# that exited cleanly and served nothing.
if printf '%s\n' "${startup_out}" | grep -q 'is not a recognised init system'; then
  ok "item 16b: a non-init command warns that no Proxmox service will start"
else
  fail "item 16b: no warning when the command is not an init system"
  classify "container-specific"
fi

# 16c: an unrecognised TZ is fatal.  Absorbing it would leave every subsequent
# timestamp plausible and wrong, with the rejected name gone from the output.
tz_rc=0
docker run --rm "${PRIVILEGED_FLAGS[@]}" -e TZ=Not/AZone "${IMAGE}" /bin/true \
  > /dev/null 2>&1 || tz_rc=$?
if [[ "${tz_rc}" -eq 80 ]]; then
  ok "item 16c: an unrecognised TZ exits 80 rather than falling back to UTC"
else
  fail "item 16c: TZ=Not/AZone exited ${tz_rc}, expected 80"
  classify "container-specific"
fi

# 16d: PVE_DEBUG traces and changes nothing.  Comparing the capability lines
# with and without it is the assertion that matters: a debug switch that alters
# an outcome produces a system that only works while it is being watched.
plain_caps="$(printf '%s\n' "${startup_out}" | grep '^capability ' || true)"
debug_out="$(run_entrypoint -e PVE_DEBUG=1)"
debug_caps="$(printf '%s\n' "${debug_out}" | grep '^capability ' || true)"
if [[ -z "${plain_caps}" ]]; then
  fail "item 16d: no capability lines to compare"
  classify "pipeline"
elif ! printf '%s\n' "${debug_out}" | grep -q '^+'; then
  fail "item 16d: PVE_DEBUG=1 produced no trace output"
  classify "container-specific"
elif [[ "${plain_caps}" != "${debug_caps}" ]]; then
  fail "item 16d: PVE_DEBUG=1 changed the resolved capability outcomes"
  classify "container-specific"
else
  ok "item 16d: PVE_DEBUG traces without changing any capability outcome"
fi
endgroup

group "item 17: regressions that were previously silent"

# Each assertion here stands in for a defect that shipped, ran, and reported
# success.  None of them was caught by the suite at the time, which is why they
# are here rather than in the group whose behaviour they belong to: the point of
# an item 17 is that it exists because something got through.

# 17a: a mask is cleared when the capability it gated comes back.
#
# The masks live in /etc/systemd/system, which is the writable layer, so they
# outlive the process that created them.  One start without a capability used to
# mask its dependent unit permanently -- every later start, including starts
# that had the capability, found the unit already masked and left it alone.
#
# Committing the container is what makes that testable: a device or an
# environment variable is fixed when a container is created, so restarting the
# same container cannot change the capability outcome.  Committing turns the
# writable layer into an image and lets the second run resolve differently
# against the same filesystem, which is exactly what the defect required.
MASK_SEED="${CONTAINER}-mask-seed"
MASK_IMAGE="pve-acceptance-mask:$$"
docker rm -f "${MASK_SEED}" > /dev/null 2>&1 || true
if docker run --name "${MASK_SEED}" "${PRIVILEGED_FLAGS[@]}" -e PVE_FUSE=disable \
  "${IMAGE}" /bin/true > /dev/null 2>&1 \
  && docker commit "${MASK_SEED}" "${MASK_IMAGE}" > /dev/null 2>&1; then
  seeded="$(docker run --rm --entrypoint readlink "${MASK_IMAGE}" \
    /etc/systemd/system/lxcfs.service 2> /dev/null || true)"
  if [[ "${seeded}" != "/dev/null" ]]; then
    fail "item 17a: PVE_FUSE=disable did not mask lxcfs.service, so the guard proves nothing"
    classify "pipeline"
  else
    docker run --rm "${PRIVILEGED_FLAGS[@]}" -e PVE_FUSE=auto \
      "${MASK_IMAGE}" /bin/true > /dev/null 2>&1 || true
    # The mask must be gone in the layer the second run wrote, so it is read
    # back from a container started on that image rather than from the image.
    cleared="$(docker run --rm "${PRIVILEGED_FLAGS[@]}" -e PVE_FUSE=auto \
      --entrypoint sh "${MASK_IMAGE}" -c \
      '/usr/local/bin/entrypoint.sh /bin/true > /dev/null 2>&1; readlink /etc/systemd/system/lxcfs.service' \
      2> /dev/null || true)"
    if [[ "${cleared}" == "/dev/null" ]]; then
      fail "item 17a: lxcfs.service stayed masked after FUSE became available again"
      classify "container-specific"
    else
      ok "item 17a: a mask is cleared when its capability returns"
    fi
  fi
else
  fail "item 17a: could not seed a masked layer"
  classify "pipeline"
fi
docker rm -f "${MASK_SEED}" > /dev/null 2>&1 || true
docker rmi -f "${MASK_IMAGE}" > /dev/null 2>&1 || true

# 17b: an existing bridge stanza is adopted, not half-ignored.
#
# The subnet-collision search runs before the stanza guard, so it always
# produced an answer.  When a stanza already existed that answer used to be
# discarded for the bridge and kept for NAT and DHCP -- the bridge came up on
# the address in the file while guests were handed leases on a different range
# and NAT masqueraded a third.  Every line printed success.
#
# The seeded address is deliberately not the default, so a run that ignores the
# file and a run that adopts it cannot produce the same output.
#
# The commit restores the entrypoint explicitly.  docker commit preserves the
# container's config, and the seed container overrode the entrypoint to write
# the file, so without this the committed image would run the seeding shell
# instead of the start-up sequence under test and pass nothing through it.
STANZA_SEED="${CONTAINER}-stanza-seed"
STANZA_IMAGE="pve-acceptance-stanza:$$"
docker rm -f "${STANZA_SEED}" > /dev/null 2>&1 || true
if docker run --name "${STANZA_SEED}" --entrypoint sh "${IMAGE}" -c \
  'printf "\nauto vmbr0\niface vmbr0 inet static\n    address 10.77.77.1/24\n    bridge-ports none\n    bridge-stp off\n    bridge-fd 0\n" >> /etc/network/interfaces' \
  > /dev/null 2>&1 \
  && docker commit --change 'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]' \
    "${STANZA_SEED}" "${STANZA_IMAGE}" > /dev/null 2>&1; then
  stanza_out="$(docker run --rm "${PRIVILEGED_FLAGS[@]}" "${STANZA_IMAGE}" /bin/true 2>&1 || true)"
  stanza_dhcp="$(printf '%s\n' "${stanza_out}" | grep '^guest network: DHCP ' || true)"
  stanza_nat="$(printf '%s\n' "${stanza_out}" | grep '^guest network: vmbr0 up' || true)"
  if [[ "${stanza_dhcp}" == *10.77.77.* ]] && [[ "${stanza_nat}" == *10.77.77.0/24* ]]; then
    ok "item 17b: an existing bridge stanza is adopted by the bridge, NAT and DHCP alike"
  else
    fail "item 17b: seeded 10.77.77.1/24 but got DHCP '${stanza_dhcp:-none}' and NAT '${stanza_nat:-none}'"
    classify "container-specific"
  fi
else
  fail "item 17b: could not seed a bridge stanza"
  classify "pipeline"
fi
docker rm -f "${STANZA_SEED}" > /dev/null 2>&1 || true
docker rmi -f "${STANZA_IMAGE}" > /dev/null 2>&1 || true

# 17c: a FORWARD chain restricted by rules warns, not only one restricted by
# policy.  Docker expresses the restriction both ways; podman and firewalld
# leave the policy permissive and express it as rules alone, which the earlier
# policy-only check was silent about -- on exactly the runtimes where guests
# would be black-holed with nothing said.
#
# The rule is inserted inside the container's own network namespace before the
# entrypoint runs, so nothing on the host is touched.
fwd_out="$(docker run --rm "${PRIVILEGED_FLAGS[@]}" --entrypoint sh "${IMAGE}" -c \
  'iptables -I FORWARD -j DROP > /dev/null 2>&1; exec /usr/local/bin/entrypoint.sh /bin/true' \
  2>&1 || true)"
if printf '%s\n' "${fwd_out}" | grep -qi 'FORWARD'; then
  ok "item 17c: a rule-restricted FORWARD chain is reported"
else
  fail "item 17c: no warning when FORWARD is restricted by a rule rather than by policy"
  classify "container-specific"
fi

# 17d: probe output survives characters that would otherwise break it.
#
# The contract is JSON and was assembled with printf, so a backslash or a quote
# in a field taken from kernel error text produced something no parser would
# accept.  The consumer is a shell reading fields with sed, which would not have
# complained -- it would have extracted the wrong text and carried on.
#
# bash, not sh: /bin/sh is dash here and the library is bash, so sourcing it
# under sh fails on the first parameter expansion it does not implement.
json_probe="$(docker run --rm --entrypoint bash "${IMAGE}" -c \
  '. /usr/local/lib/pve/lib/probe-common.sh; emit_json probe absent test "back\slash and \"quote\"" "none"' \
  2> /dev/null || true)"
if [[ -z "${json_probe}" ]]; then
  fail "item 17d: emit_json produced no output"
  classify "pipeline"
elif printf '%s\n' "${json_probe}" \
  | docker run --rm -i --entrypoint python3 "${IMAGE}" -c \
    'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "\\" in d["detail"] and "\"" in d["detail"] else 1)' \
    > /dev/null 2>&1; then
  ok "item 17d: probe output stays valid JSON with a backslash and a quote in a field"
else
  fail "item 17d: emit_json output did not parse, or lost the characters under test"
  classify "container-specific"
fi
endgroup

# ── Tier B: KVM guests ─────────────────────────────────────────────────────
#
# Never inferred from Tier A passing.  KVM_AVAILABLE comes from a live probe on
# the runner; when it is false these report not-attempted, which is a distinct
# outcome from a pass and is counted as such.
group "tier B: KVM guest boot"

# Tier B is never inferred from Tier A passing.  KVM_AVAILABLE comes from a
# live probe on the runner, and where it is false these report not-attempted
# rather than silently passing -- a skipped guest boot reported as a pass is
# the single most misleading result this suite could produce.
#
# The x86 harness below runs in its own privileged container with /dev/kvm
# attached.  Guest execution needs the device, and the documented management
# plane tier deliberately does not carry it, so asserting against that tier
# would be testing the wrong configuration.
if [[ "${KVM_AVAILABLE}" != "true" ]]; then
  not_attempted "item 13: x86 guest boot -- /dev/kvm not available on this runner"
  not_attempted "item 14: aarch64 guest boot -- /dev/kvm not available on this runner"
else
  # One harness serves both architectures.  The sequence is identical; only the
  # release index, its list-entry format, and four qm create flags differ.  A
  # separate aarch64 implementation would duplicate the parts that took the
  # longest to get right -- the reader-before-start ordering above all -- and
  # the duplicate would drift.
  tb_extra=()
  case "${ARCH}" in
    x86_64)
      tb_run="item 13"
      tb_skip="item 14"
      tb_skip_label="aarch64"
      tb_guest="x86"
      tb_arch_path="x86_64"
      tb_vmid="950"
      ;;
    aarch64 | arm64)
      tb_run="item 14"
      tb_skip="item 13"
      tb_skip_label="x86"
      tb_guest="aarch64"
      tb_arch_path="aarch64"
      tb_vmid="951"
      # UEFI is not a preference on aarch64, it is the only option: SeaBIOS has
      # no aarch64 machine type.  The Containerfile installs
      # pve-edk2-firmware-aarch64 explicitly for exactly this, because
      # qemu-server lists it only under Suggests and it appears in neither
      # architecture's dependency closure.
      tb_extra=(
        --arch aarch64
        --machine virt
        --bios ovmf
        --efidisk0 "local:1,efitype=4m,pre-enrolled-keys=0"
      )
      ;;
    *)
      not_attempted "item 13: x86 guest boot -- unknown architecture ${ARCH}"
      not_attempted "item 14: aarch64 guest boot -- unknown architecture ${ARCH}"
      tb_run=""
      ;;
  esac

  if [[ -n "${tb_run}" ]]; then
    VM_CONTAINER="${CONTAINER}-vm"

    if start_container "${VM_CONTAINER}" "${PRIVILEGED_FLAGS[@]}" --device /dev/kvm; then
      vmexec() { docker exec "${VM_CONTAINER}" "$@"; }

      # The reader has to be connected before the guest starts.  PVE configures
      # the serial chardev with server=on,wait=off, so QEMU does not wait for a
      # client and discards everything written before one attaches; a reader
      # started after qm start captures an empty buffer having missed the boot.
      docker exec -i "${VM_CONTAINER}" sh -c 'cat > /tmp/tierb-serial.py' << 'READER'
import os
import socket
import sys
import time

sock_path, out_path, marker, timeout = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
deadline = time.time() + timeout

while time.time() < deadline and not os.path.exists(sock_path):
    time.sleep(0.2)

conn = None
while time.time() < deadline and conn is None:
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.connect(sock_path)
    except OSError:
        conn = None
        time.sleep(0.5)

if conn is None:
    sys.exit(2)

conn.settimeout(1.0)
buf = b""
found = False
while time.time() < deadline:
    try:
        chunk = conn.recv(4096)
    except socket.timeout:
        continue
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if marker.encode() in buf:
        found = True
        break

with open(out_path, "wb") as fh:
    fh.write(buf)

sys.exit(0 if found else 1)
READER

      # /etc/pve/storage.cfg does not exist in a fresh image.  pmxcfs synthesises
      # a local entry that accepts vztmpl -- which is why the LXC item works --
      # but not iso, so an ISO cannot be placed until this runs.  pvesm set
      # creates the file.
      vmexec pvesm set local --content iso,vztmpl,backup,images,rootdir > /dev/null 2>&1 || true

      # The filename carries a version upstream re-rolls, so it is read from the
      # release index rather than written down where it would rot.  The two
      # indices are not formatted alike: x86_64 uses inline "- key: value" list
      # entries, aarch64 puts a bare "-" on its own line with the fields indented
      # beneath.  Handling only the inline form reports the ISO missing when it
      # is present, which is exactly what happened on the first aarch64 attempt.
      iso_meta="$(
        vmexec python3 -c "
import urllib.request, sys
u='https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${tb_arch_path}/latest-releases.yaml'
txt=urllib.request.urlopen(u, timeout=30).read().decode()
cur={}
for line in txt.splitlines():
    t=line.strip()
    if t == '-':
        cur={}
        continue
    if t.startswith('- '):
        cur={}
        t=t[2:]
    if ':' in t:
        k,_,v=t.partition(':')
        cur[k.strip()]=v.strip()
    if cur.get('flavor')=='alpine-virt' and 'iso' in cur and 'sha256' in cur:
        print(cur['iso'], cur['sha256']); sys.exit(0)
sys.exit(1)
" 2> /dev/null
      )" || iso_meta=""

      iso_name="${iso_meta%% *}"
      iso_sha="${iso_meta##* }"

      if [[ -z "${iso_name}" ]] || [[ -z "${iso_sha}" ]]; then
        fail "${tb_run}: could not resolve the alpine-virt ISO from the ${tb_arch_path} release index"
        classify "pipeline"
      elif ! vmexec sh -c "
        set -e
        cd /var/lib/vz/template/iso
        curl -fsSL -o '${iso_name}' 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${tb_arch_path}/${iso_name}'
        echo '${iso_sha}  ${iso_name}' | sha256sum -c -
      " > /dev/null 2>&1; then
        fail "${tb_run}: ISO download or checksum verification failed for ${iso_name}"
        classify "pipeline"
      else
        vmexec qm destroy "${tb_vmid}" --purge > /dev/null 2>&1 || true

        # --cdrom is deliberately not used.  It attaches the ISO as ide2, and the
        # aarch64 virt machine type has no IDE controller, so QEMU is handed a
        # bus that does not exist and exits 1 with "Bus 'ide.1' not found" before
        # any guest code runs.  virtio-scsi exists on both machine types, so one
        # form serves both architectures.
        if ! vmexec qm create "${tb_vmid}" --name "tierb-${tb_guest}" --memory 1024 --cores 1 \
          --net0 "virtio,bridge=${PVE_GUEST_BRIDGE:-vmbr0}" \
          "${tb_extra[@]}" \
          --scsihw virtio-scsi-single \
          --scsi0 "local:iso/${iso_name},media=cdrom" \
          --boot order=scsi0 \
          --serial0 socket --vga serial0 \
          --ostype l26 > /dev/null 2>&1; then
          fail "${tb_run}: qm create failed"
          classify "container-specific"
        else
          docker exec -d "${VM_CONTAINER}" \
            python3 /tmp/tierb-serial.py \
            "/var/run/qemu-server/${tb_vmid}.serial0" /tmp/serial.log "login:" 240
          sleep 2

          if ! vmexec qm start "${tb_vmid}" > /dev/null 2>&1; then
            fail "${tb_run}: qm start failed"
            classify "container-specific"
            vmexec qm start "${tb_vmid}" 2>&1 | tail -n 5 >&2 || true
          else
            # qm start returning 0 only proves QEMU launched.  The marker is what
            # proves a guest kernel reached userspace.
            boot_deadline=$((SECONDS + 260))
            booted="false"
            while ((SECONDS < boot_deadline)); do
              if vmexec grep -q "login:" /tmp/serial.log 2> /dev/null; then
                booted="true"
                break
              fi
              sleep 5
            done

            if [[ "${booted}" == "true" ]]; then
              kernel="$(vmexec sh -c "grep -o 'Kernel [^ ]* on [^ ]*' /tmp/serial.log | head -n1" 2> /dev/null || true)"
              ok "${tb_run}: ${tb_guest} guest booted to a login prompt (${kernel:-marker seen})"
            else
              fail "${tb_run}: guest did not reach a login prompt within 260s"
              classify "container-specific"
              vmexec sh -c "tail -c 2000 /tmp/serial.log" >&2 2> /dev/null || true
            fi
          fi

          vmexec qm stop "${tb_vmid}" > /dev/null 2>&1 || true
          vmexec qm destroy "${tb_vmid}" --purge > /dev/null 2>&1 || true
        fi
      fi
    else
      fail "${tb_run}: the guest-boot container did not reach a stable target"
      classify "container-specific"
    fi

    docker rm -f "${VM_CONTAINER}" > /dev/null 2>&1 || true

    # The other architecture's item is not a gap in this harness -- the same code
    # would run it on the right host -- so the reason names the host, not the suite.
    not_attempted "${tb_skip}: ${tb_skip_label} guest boot -- wrong architecture for this runner (${ARCH})"
  fi
fi
endgroup

# ── Shim file-set cross-check ──────────────────────────────────────────────
#
# The argument for making the container adaptations a real package rather than
# loose RUN lines was that every deviation would then be enumerable with
# dpkg -L.  This closes that loop: if the package ships a path DEVIATIONS.md
# does not mention, the documentation has drifted from the artefact.
group "shim file set matches DEVIATIONS.md"
if [[ -f DEVIATIONS.md ]]; then
  docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true
  if shipped="$(docker run --rm --entrypoint dpkg "${IMAGE}" -L pve-container-shim 2> /dev/null)"; then
    undocumented=0
    while IFS= read -r path; do
      case "${path}" in
        /etc/systemd/system/* | /usr/lib/systemd/system/*.d/* | /usr/libexec/pve-container-shim/* | /usr/sbin/*)
          if ! grep -qF "$(basename "${path}")" DEVIATIONS.md; then
            echo "  undocumented shipped path: ${path}" >&2
            undocumented=1
          fi
          ;;
      esac
    done <<< "${shipped}"

    if ((undocumented == 0)); then
      ok "every functional path shipped by pve-container-shim is named in DEVIATIONS.md"
    else
      fail "pve-container-shim ships paths DEVIATIONS.md does not mention"
      classify "pipeline"
    fi
  else
    fail "dpkg -L pve-container-shim failed"
    classify "pipeline"
  fi
else
  fail "DEVIATIONS.md is missing"
  classify "pipeline"
fi
endgroup

# ── Suite integrity ────────────────────────────────────────────────────────
group "suite integrity"

# The observed KNOWN-FAIL set must equal the declared set.  Equality rather
# than containment: an entry that stops firing means the condition it excused
# is gone, and carrying a dead exemption forward is how an escape hatch widens.
declared_sorted="$(printf '%s\n' "${DECLARED_KNOWN_FAIL[@]+"${DECLARED_KNOWN_FAIL[@]}"}" | LC_ALL=C sort)"
observed_sorted="$(printf '%s\n' "${observed_known_fail[@]+"${observed_known_fail[@]}"}" | LC_ALL=C sort)"
if [[ "${declared_sorted}" == "${observed_sorted}" ]]; then
  echo "PASS: KNOWN-FAIL set matches the declaration"
else
  echo "FAIL: KNOWN-FAIL set differs from the declaration" >&2
  echo "  declared: ${declared_sorted:-<none>}" >&2
  echo "  observed: ${observed_sorted:-<none>}" >&2
  rc=1
fi

if ((items >= EXPECTED_ITEMS)); then
  echo "PASS: ${items} results reported (at least ${EXPECTED_ITEMS} expected)"
else
  echo "FAIL: ${items} results reported, expected at least ${EXPECTED_ITEMS}" >&2
  echo "  an item stopped reporting; find it rather than lowering the floor" >&2
  rc=1
fi
endgroup

if ((rc == 0)); then
  echo "pve-acceptance: ${items} results, no failures"
else
  echo "pve-acceptance: failures present" >&2
fi

exit "${rc}"
