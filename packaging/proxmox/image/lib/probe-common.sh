#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for the capability probes under ../probe/.
#
# Sourced, never executed.  Every probe emits exactly one JSON object on stdout
# and exits 0, 1, or 2 mirroring present, absent, indeterminate.  Keeping the
# emitter here rather than duplicating it in the probe scripts means the
# contract has one definition; a caller parsing one probe's output can parse
# them all.
#
# The contract deliberately carries no boolean field.  A boolean cannot express
# "the probe could not determine this", and that third state is the whole point:
# `require` treats an unverifiable claim as unsatisfied, which is a different
# decision from treating it as absent, and the reason field has to say which.

# Exit codes, mirroring the three outcomes.  Named rather than literal because a
# bare `exit 2` at the bottom of a probe reads as an error rather than a verdict.
# shellcheck disable=SC2034  # Consumed by the scripts that source this file.
readonly PROBE_PRESENT=0
# shellcheck disable=SC2034  # Consumed by the scripts that source this file.
readonly PROBE_ABSENT=1
# shellcheck disable=SC2034  # Consumed by the scripts that source this file.
readonly PROBE_INDETERMINATE=2

# emit_json <capability> <outcome> <reason> <detail> <remedy>
#
#   capability  machine-stable token, e.g. "fuse"
#   outcome     present | absent | indeterminate
#   reason      machine-stable token, e.g. "device_absent"
#   detail      human-readable; may contain any text, see the escaping below
#   remedy      the exact runtime flag that would provide the capability,
#               or the empty string when the capability is present
#
# The remedy is the field operators actually act on, so it names a flag rather
# than describing a condition.  "needs elevated privileges" is not actionable;
# "--cap-add SYS_ADMIN" is.
#
# Escaping happens here rather than at each call site.  Several probes
# interpolate the kernel's own error text into detail, which is not text this
# repository controls: a backslash in it produces a JSON string with a dangling
# escape, and a double quote ends the string early.  Fixing that per call site
# leaves the next probe free to reintroduce it, so the one function that
# produces the contract is where it belongs.  Backslash is replaced first --
# doing it second would escape the backslashes the quote replacement just
# introduced.
emit_json() {
  local capability="$1" outcome="$2" reason="$3" detail="$4" remedy="$5"

  detail="${detail//\\/\\\\}"
  detail="${detail//\"/\\\"}"
  remedy="${remedy//\\/\\\\}"
  remedy="${remedy//\"/\\\"}"

  printf '{"capability":"%s","outcome":"%s","reason":"%s","detail":"%s","remedy":"%s"}\n' \
    "${capability}" "${outcome}" "${reason}" "${detail}" "${remedy}"
}

# probe_field <json> <key> -- extract one field from a probe's output.
#
# sed rather than jq: these run during early container start-up, before any
# guarantee that jq is on PATH, and the JSON shape is fixed and self-controlled
# rather than arbitrary input.  A general-purpose parser would be a dependency
# bought for no benefit.
probe_field() {
  local json="$1" key="$2" value

  # [[:space:]]* after the colon is defensive: it lets this parser accept both
  # the compact JSON emit_json above prints and the spaced form json.dumps would
  # produce if a probe defaulted its separators.  The Python helper kvm-probe
  # emits compact JSON deliberately (separators=(",", ":")) so both producers of
  # the contract agree, but an earlier revision did not, and matching only the
  # compact form meant that on a host where /dev/kvm was present -- the one path
  # that reaches the Python helper -- the substitution failed, sed returned its
  # input unchanged, and every field of the summary line became the whole JSON
  # blob.  The resolver then compared that blob against "present", found no
  # match, and reported a working capability as disabled.  Tolerating both
  # spacings costs nothing and closes that failure for good.
  # Distinguish "key absent" from "key present and empty".  An empty remedy is
  # the correct value for every capability that resolved present -- there is
  # nothing for the operator to do -- so treating empty as a contract violation
  # printed a warning on every successful probe, which is exactly the sort of
  # routine noise that teaches an operator to stop reading warnings.  Test for
  # the key itself, and only then trust the extracted value.
  if ! printf '%s' "${json}" | grep -q "\"${key}\"[[:space:]]*:"; then
    printf 'probe-common: no "%s" field in probe output: %s\n' "${key}" "${json}" >&2
    return 1
  fi

  # sed's s/// leaves the line untouched when the pattern does not match, so
  # returning its output unfiltered would hand the caller something that looks
  # like an answer.  -n with /p prints nothing instead, so a key that is present
  # but unparseable yields an empty string rather than the whole blob.
  value="$(printf '%s' "${json}" | sed -n 's/.*"'"${key}"'":[[:space:]]*"\([^"]*\)".*/\1/p')"

  printf '%s' "${value}"
}
