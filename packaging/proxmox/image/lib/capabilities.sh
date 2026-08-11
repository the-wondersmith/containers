#!/usr/bin/env bash
# shellcheck shell=bash
#
# Resolve the capability contract: probe what the runtime actually provides,
# compare it against what the operator asked for, and decide what starts.
#
# Sourced by entrypoint.sh, never executed directly.
#
# ---------------------------------------------------------------------------
# The contract
# ---------------------------------------------------------------------------
#
# Five environment variables, each taking auto | require | disable, each
# defaulting to auto:
#
#   PVE_KVM               hardware-assisted virtualisation via /dev/kvm
#   PVE_FUSE              FUSE mounts, which pmxcfs needs for /etc/pve
#   PVE_NESTED_LXC        running PVE's own LXC guests inside this container
#   PVE_CGROUP_DELEGATION cgroup v2 delegation for guest resource limits
#   PVE_GUEST_NETWORK     the guest bridge and its NAT, which need CAP_NET_ADMIN
#
#   policy   | present | absent                  | indeterminate
#   ---------+---------+-------------------------+---------------------------
#   require  | enable  | fail fast, naming the   | fail fast, with a distinct
#            |         | missing device and the  | reason: an unverifiable
#            |         | exact runtime flag      | claim is not a satisfied
#            |         |                         | claim
#   auto     | enable  | disable dependents,     | same as absent
#            |         | print a visible         |
#            |         | degradation line,       |
#            |         | continue                |
#   disable  | do not probe at all; do not start dependents; report off
#
# The third probe outcome is the reason this is a tri-state rather than a
# boolean.  "The probe could not determine this" is a different fact from "this
# is absent", and require must treat them the same way while saying which one
# happened.  A boolean contract cannot express that, which is why the probe
# output carries an outcome string rather than a true/false.
#
# There is deliberately NO global override.  No single variable downgrades every
# hard failure at once.  Each capability's fail-fast behaviour is independent,
# because an operator who accepts running without KVM has said nothing at all
# about whether they accept running without a working /etc/pve.  Collapsing
# those into one switch is how a missing management plane gets shipped as a
# warning.
#
# ---------------------------------------------------------------------------
# The state file
# ---------------------------------------------------------------------------
#
# /run/pve-container/capabilities.json, written BEFORE any require abort, so an
# operator debugging a container that refused to start can read what was
# decided rather than reconstructing it from log lines.  Per capability:
#
#   {"policy", "probe_ran", "outcome", "resolved", "reason", "remedy"}
#
# Invariants, asserted by construction below:
#   - outcome is null if and only if probe_ran is false
#   - resolved is one of enabled | disabled | aborted
#   - aborted appears only for a require failure, and means the start was
#     abandoned -- not that something was turned off
#   - when probe_ran is false the remedy comes from the static map below and is
#     never empty, because "you disabled it" is still the answer to "why is
#     this off"

readonly PROBE_ROOT="${PVE_PROBE_ROOT:-/usr/local/lib/pve/probe}"
readonly STATE_DIR="/run/pve-container"
readonly STATE_FILE="${STATE_DIR}/capabilities.json"

readonly POLICY_AUTO="auto"
readonly POLICY_REQUIRE="require"
readonly POLICY_DISABLE="disable"

# Capability name -> probe executable.  The names are the machine-stable tokens
# the probes themselves emit, so a summary line and a state-file key always
# agree.
declare -rA CAPABILITY_PROBES=(
  [kvm]="kvm"
  [fuse]="fuse"
  [nested_lxc]="nested-lxc"
  [cgroup_delegation]="cgroup-delegation"
  [guest_network]="guest-network"
)

# Capability name -> environment variable holding its policy.
declare -rA CAPABILITY_VARS=(
  [kvm]="PVE_KVM"
  [fuse]="PVE_FUSE"
  [nested_lxc]="PVE_NESTED_LXC"
  [cgroup_delegation]="PVE_CGROUP_DELEGATION"
  [guest_network]="PVE_GUEST_NETWORK"
)

# Remedy text used when no probe ran, i.e. policy=disable.  Without this the
# state file would carry an empty remedy for the one case where the answer is
# entirely knowable, and an operator reading it would think the field was
# broken rather than that they had turned the feature off themselves.
declare -rA CAPABILITY_DISABLED_REMEDY=(
  [kvm]="set PVE_KVM=auto and pass --device /dev/kvm to enable"
  [fuse]="set PVE_FUSE=auto and pass --device /dev/fuse --cap-add SYS_ADMIN to enable"
  [nested_lxc]="set PVE_NESTED_LXC=auto to enable"
  [cgroup_delegation]="set PVE_CGROUP_DELEGATION=auto to enable"
  [guest_network]="set PVE_GUEST_NETWORK=auto and pass --cap-add NET_ADMIN to enable"
)

# Resolution results, filled by resolve_capabilities.
declare -gA CAPABILITY_RESOLVED=()
declare -gA CAPABILITY_OUTCOME=()
declare -gA CAPABILITY_POLICY=()
declare -gA CAPABILITY_REASON=()
declare -gA CAPABILITY_REMEDY=()
declare -gA CAPABILITY_PROBE_RAN=()

# The order matters only for reproducible output; bash associative arrays have
# no stable iteration order and a summary whose lines shuffle between runs is
# harder to diff than one that does not.
readonly CAPABILITY_ORDER=(fuse kvm cgroup_delegation nested_lxc guest_network)

# ---------------------------------------------------------------------------

# capability_policy <capability>
#
# Read and validate the policy for one capability.  An unrecognised value is a
# hard failure rather than a silent fallback to auto: a typo like PVE_KVM=requre
# would otherwise be indistinguishable from not setting it at all, and the
# operator would believe they had a guarantee they do not have.
capability_policy() {
  local capability="$1"
  local var="${CAPABILITY_VARS[${capability}]}"
  local value="${!var:-${POLICY_AUTO}}"

  case "${value}" in
    "${POLICY_AUTO}" | "${POLICY_REQUIRE}" | "${POLICY_DISABLE}")
      printf '%s\n' "${value}"
      ;;
    *)
      printf 'error: %s has an unrecognised value: %s\n' "${var}" "${value}" >&2
      printf 'error: legal values are %s, %s, %s\n' \
        "${POLICY_AUTO}" "${POLICY_REQUIRE}" "${POLICY_DISABLE}" >&2
      exit 78
      ;;
  esac
}

# write_state_file
#
# Serialise the resolution table.  Called before any abort, and again after a
# clean resolution, so the file always describes the decision that was actually
# taken.  Hand-built rather than jq-generated because this runs before systemd
# and jq is not guaranteed to be on PATH that early; every value it interpolates
# is one this file or a probe produced, not arbitrary input.
write_state_file() {
  local capability first="true"

  mkdir -p "${STATE_DIR}"

  {
    printf '{\n'
    for capability in "${CAPABILITY_ORDER[@]}"; do
      # Emit only capabilities the resolver actually reached.  A require
      # failure writes this file before aborting, at which point the
      # capabilities later in CAPABILITY_ORDER have no entries at all, and
      # under `set -u` reading one is a fatal error that masks the very
      # message the abort exists to print.  Omitting them is also the honest
      # output: a capability that was never resolved has no state to report,
      # and inventing an entry for it would be worse than leaving it out.
      [[ -v "CAPABILITY_POLICY[${capability}]" ]] || continue

      [[ "${first}" == "true" ]] || printf ',\n'
      first="false"

      printf '  "%s": {\n' "${capability}"
      printf '    "policy": "%s",\n' "${CAPABILITY_POLICY[${capability}]}"
      printf '    "probe_ran": %s,\n' "${CAPABILITY_PROBE_RAN[${capability}]}"

      if [[ "${CAPABILITY_PROBE_RAN[${capability}]}" == "true" ]]; then
        printf '    "outcome": "%s",\n' "${CAPABILITY_OUTCOME[${capability}]}"
      else
        printf '    "outcome": null,\n'
      fi

      printf '    "resolved": "%s",\n' "${CAPABILITY_RESOLVED[${capability}]}"
      printf '    "reason": "%s",\n' "${CAPABILITY_REASON[${capability}]}"
      printf '    "remedy": "%s"\n' "${CAPABILITY_REMEDY[${capability}]}"
      printf '  }'
    done
    printf '\n}\n'
  } > "${STATE_FILE}"
}

# resolve_one <capability>
#
# Run the probe if policy allows, apply the policy table, and record the result.
# Aborts the process on a require failure, after writing the state file.
resolve_one() {
  local capability="$1"
  local policy probe json outcome reason remedy

  policy="$(capability_policy "${capability}")"
  CAPABILITY_POLICY[${capability}]="${policy}"

  if [[ "${policy}" == "${POLICY_DISABLE}" ]]; then
    CAPABILITY_PROBE_RAN[${capability}]="false"
    CAPABILITY_OUTCOME[${capability}]=""
    CAPABILITY_RESOLVED[${capability}]="disabled"
    CAPABILITY_REASON[${capability}]="policy_disable"
    CAPABILITY_REMEDY[${capability}]="${CAPABILITY_DISABLED_REMEDY[${capability}]}"
    return 0
  fi

  probe="${PROBE_ROOT}/${CAPABILITY_PROBES[${capability}]}"

  if [[ ! -x "${probe}" ]]; then
    # A missing probe is indeterminate, not absent.  The capability may well be
    # present; what is missing is our ability to say so, and require must treat
    # that as unsatisfied rather than guessing in either direction.
    json=""
    outcome="indeterminate"
    reason="probe_missing"
    remedy="reinstall the image; ${probe} is missing or not executable"
  else
    json="$("${probe}")" || true

    # probe_field fails when the key is absent, and these are command
    # substitutions in assignments: under `set -e` a failure here would abort
    # start-up entirely.  That is the wrong trade for a policy of `auto`, whose
    # whole purpose is to degrade visibly rather than refuse to run, so the
    # failure is caught and turned into the outcome the contract already has
    # for "the probe did not produce an answer this code can read".
    outcome="$(probe_field "${json}" outcome)" || outcome=""
    reason="$(probe_field "${json}" reason)" || reason=""
    remedy="$(probe_field "${json}" remedy)" || remedy=""

    # An unrecognised outcome is indeterminate, not absent.  Reporting it as
    # absent would claim the capability is missing when what is actually
    # missing is our ability to say, and `require` treats those two differently
    # on purpose.
    case "${outcome}" in
      present | absent | indeterminate) ;;
      *)
        printf 'warning: %s probe returned unreadable output; treating as indeterminate\n' \
          "${capability}" >&2
        outcome="indeterminate"
        reason="probe_output_unreadable"
        remedy="inspect ${probe} output by running it directly"
        ;;
    esac
  fi

  CAPABILITY_PROBE_RAN[${capability}]="true"
  CAPABILITY_OUTCOME[${capability}]="${outcome}"
  CAPABILITY_REASON[${capability}]="${reason}"
  CAPABILITY_REMEDY[${capability}]="${remedy}"

  if [[ "${outcome}" == "present" ]]; then
    CAPABILITY_RESOLVED[${capability}]="enabled"
    return 0
  fi

  if [[ "${policy}" == "${POLICY_REQUIRE}" ]]; then
    CAPABILITY_RESOLVED[${capability}]="aborted"
    write_state_file

    printf 'error: %s=require but %s is %s (%s)\n' \
      "${CAPABILITY_VARS[${capability}]}" "${capability}" "${outcome}" "${reason}" >&2
    if [[ -n "${remedy}" ]]; then
      printf 'error: remedy: %s\n' "${remedy}" >&2
    fi
    printf 'error: refusing to start; set %s=auto to degrade instead\n' \
      "${CAPABILITY_VARS[${capability}]}" >&2
    exit 79
  fi

  CAPABILITY_RESOLVED[${capability}]="disabled"
  return 0
}

# resolve_capabilities
#
# Resolve all five, then write the state file.  fuse is resolved first because
# it is the one the management plane cannot do without -- an operator watching
# the log sees the answer that matters most before anything else scrolls past.
resolve_capabilities() {
  local capability

  for capability in "${CAPABILITY_ORDER[@]}"; do
    resolve_one "${capability}"
  done

  write_state_file
}

# print_capability_summary
#
# One line per capability, in a stable order and a stable shape, so the operator
# learns the resolved state from a summary rather than by inferring it from the
# absence of an error.
print_capability_summary() {
  local capability line

  for capability in "${CAPABILITY_ORDER[@]}"; do
    line="capability ${capability}: ${CAPABILITY_RESOLVED[${capability}]}"
    line="${line} (policy=${CAPABILITY_POLICY[${capability}]}"

    if [[ "${CAPABILITY_PROBE_RAN[${capability}]}" == "true" ]]; then
      line="${line}, probe=${CAPABILITY_OUTCOME[${capability}]}"
    else
      line="${line}, probe=skipped"
    fi

    line="${line}, reason=${CAPABILITY_REASON[${capability}]})"

    if [[ "${CAPABILITY_RESOLVED[${capability}]}" == "disabled" ]] \
      && [[ -n "${CAPABILITY_REMEDY[${capability}]}" ]]; then
      line="${line} -- remedy: ${CAPABILITY_REMEDY[${capability}]}"
    fi

    printf '%s\n' "${line}"
  done
}

# mask_unit <unit> <why>
#
# Mask a systemd unit by symlinking it to /dev/null in /etc/systemd/system,
# which overrides the vendor unit without editing it.  Done before systemd is
# exec'd, so the unit is never attempted rather than started and failed.
mask_unit() {
  local unit="$1"
  local why="$2"

  ln -sf /dev/null "/etc/systemd/system/${unit}"
  printf 'masking %s: %s\n' "${unit}" "${why}"
}

# apply_capability_gating
#
# Translate resolved capabilities into masked units.  The mapping comes from
# docs/pve-systemd-units.json, which was generated by reading the unit files
# every package in the proxmox-ve closure actually ships -- not from memory.
#
# Note what is deliberately NOT here: no unit is masked for
# PVE_CGROUP_DELEGATION.  pct start needs delegation, so losing it is a real
# degradation, but there is no unit whose failure it causes; masking something
# would only hide the summary line that tells the operator why their guests will
# not start.
#
# Every mask this function can apply is cleared first.  A mask is a symlink in
# /etc/systemd/system, which lives in the container's writable layer and
# therefore outlives the process that created it: start once without /dev/kvm
# and pve-guests.service is masked, and without this it stays masked on every
# later start, including one that does have the device.  The capability
# contract is re-resolved from scratch on each start, so the units it drives
# have to be too, or a degraded first run silently becomes permanent.
#
# Only symlinks pointing at /dev/null are removed, and only for units this
# function knows about.  An operator who masked something themselves, or a mask
# the shim package ships as a real file, is left alone.
apply_capability_gating() {
  local guests_masked="false"
  local unit

  for unit in lxcfs.service pve-guests.service; do
    if [[ -L "/etc/systemd/system/${unit}" ]] \
      && [[ "$(readlink "/etc/systemd/system/${unit}")" == "/dev/null" ]]; then
      rm -f "/etc/systemd/system/${unit}"
    fi
  done

  # lxcfs.service mounts /var/lib/lxcfs through libfuse.  pve-container-shim
  # ships a drop-in clearing its ConditionVirtualization=!container
  # unconditionally, because the shim's dpkg surface has to be static.  That
  # means without this mask the unit runs and fails at its mount rather than
  # being cleanly skipped, and a failed unit is exactly what the acceptance
  # suite's failed-unit check reports.
  if [[ "${CAPABILITY_RESOLVED[fuse]}" != "enabled" ]]; then
    mask_unit "lxcfs.service" "FUSE is ${CAPABILITY_RESOLVED[fuse]}; lxcfs cannot mount /var/lib/lxcfs"
  fi

  # pve-guests.service starts guests marked for autostart.  It covers both VMs
  # and LXC containers, so either capability being off is enough to make it
  # attempt starts that cannot succeed -- and it is one unit, so it is masked
  # once no matter how many of its prerequisites are missing.
  if [[ "${CAPABILITY_RESOLVED[kvm]}" != "enabled" ]]; then
    mask_unit "pve-guests.service" "KVM is ${CAPABILITY_RESOLVED[kvm]}; autostarted VMs cannot boot"
    guests_masked="true"
  fi

  if [[ "${CAPABILITY_RESOLVED[nested_lxc]}" != "enabled" ]] \
    && [[ "${guests_masked}" == "false" ]]; then
    mask_unit "pve-guests.service" \
      "nested LXC is ${CAPABILITY_RESOLVED[nested_lxc]}; autostarted containers cannot start"
  fi
}
