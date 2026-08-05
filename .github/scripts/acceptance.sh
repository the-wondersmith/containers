#!/bin/sh
# shellcheck shell=sh
#
# Acceptance suite for a built podman bundle.
#
# Runs as root inside `docker run --privileged --cgroupns=host` against the
# package in /pkg. POSIX sh throughout, because on Alpine this is busybox ash
# and the whole point is to exercise the package on a stock base image rather
# than one we have customised.
#
# This is the only gate between an upstream tag and a published package, so it
# tests behaviour rather than file placement. In particular `podman network
# create` plus cross-container DNS is the lockstep canary: if a netavark or
# aardvark-dns major bump is incompatible with the bundled podman, nothing else
# here would notice.
set -eu

DISTRO="${DISTRO:?DISTRO must be set}"
COMPONENTS="${COMPONENTS:?COMPONENTS must be set}"

rc=0
TEST_IMAGE="quay.io/podman/hello:latest"
BUSYBOX_IMAGE="docker.io/library/busybox:latest"

ok() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*" >&2
  rc=1
}

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

# ── Install ──────────────────────────────────────────────────────────────────
group "install the package"
case "${DISTRO}" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    # `apt-get install ./file.deb` resolves the declared dependencies, unlike
    # `dpkg -i`, which fails on them. The previous iteration of this repository
    # used dpkg -i under `set -e` and would have aborted here every time.
    apt-get install -y --no-install-recommends /pkg/*.deb
    # binutils supplies readelf. The linkage assertions below are worthless
    # without it: `readelf ... 2>/dev/null | grep -q NEEDED` on a missing readelf
    # produces no output, which reads as "statically linked" for every binary.
    apt-get install -y --no-install-recommends jq iproute2 binutils
    ;;
  alpine)
    # --allow-untrusted: the apk is built with no --signing-key, so it carries
    # no .SIGN.* entry at all. Signing belongs to the package repository, not
    # here; the control on these exact bytes is the SLSA build-provenance
    # attestation on the release. See docs/signing.md.
    apk add --no-cache --allow-untrusted /pkg/*.apk
    # See the Debian branch: binutils supplies readelf, without which the
    # linkage assertions pass vacuously. busybox does not provide it.
    apk add --no-cache jq iproute2 binutils
    ;;
  *)
    echo "unknown distro: ${DISTRO}" >&2
    exit 1
    ;;
esac

# The caller must supply real filesystems for these two paths -- see the
# `docker run -v /var/tmp -v /var/lib/containers` in the calling workflow.
# Both are overlay mount targets and overlayfs cannot be stacked on itself:
#
#   /var/lib/containers  graph driver root. On the container's own overlayfs:
#     "'overlay' is not supported over overlayfs, a mount_program is required"
#   /var/tmp             where buildah puts the upperdir/workdir when it
#     overlays a build context: "mounting an overlay over build context
#     directory: ... invalid argument"
#   /home                rootless storage lives under $HOME, so the same
#     constraint applies again for the unprivileged user's graph root
#
# With both on a real filesystem the suite runs on the genuine overlay graph
# driver, so it tests what users actually get. Forcing vfs would also work but
# would stop exercising the real driver, so it is deliberately NOT done.
# Tested via /proc/mounts rather than `stat -f -c %T`: busybox stat reports
# UNKNOWN for btrfs and friends, so the filesystem-type comparison silently
# matched nothing on Alpine and passed regardless. Whether the path is its own
# mount point is the property that actually matters and is reported reliably by
# both distros.
for required in /var/lib/containers /var/tmp /home; do
  if awk -v p="${required}" '$2 == p { found = 1 } END { exit !found }' /proc/mounts; then
    ok "${required} is a separate mount"
  else
    fail "${required} is on the container rootfs; the caller must mount a real filesystem there"
  fi
done
endgroup

# ── Versions match what was requested ────────────────────────────────────────
group "versions match the requested component set"
check_version() {
  _name="$1"
  _actual="$2"
  _expected="$(printf '%s' "${COMPONENTS}" | jq -er --arg c "${_name}" '.[$c].version')"

  if [ "${_actual}" = "${_expected}" ]; then
    ok "${_name} ${_actual}"
  else
    fail "${_name}: expected ${_expected}, got ${_actual}"
  fi
}

check_version podman "$(podman --version | awk '{print $3}')"
check_version buildah "$(buildah --version | awk '{print $3}')"
check_version netavark "$(/usr/libexec/podman/netavark --version | awk '{print $2}')"
check_version aardvark-dns "$(/usr/libexec/podman/aardvark-dns --version | awk '{print $2}')"
endgroup

# ── Helper binaries are the bundled ones ─────────────────────────────────────
group "podman resolves the bundled helpers"
for helper in netavark aardvark-dns catatonit rootlessport quadlet; do
  if [ -x "/usr/libexec/podman/${helper}" ]; then
    ok "helper present: ${helper}"
  else
    fail "helper missing: ${helper}"
  fi
done

if podman info --format '{{.Host.NetworkBackend}}' 2> /dev/null | grep -q netavark; then
  ok "network backend is netavark"
else
  fail "network backend is not netavark: $(podman info --format '{{.Host.NetworkBackend}}' 2>&1)"
fi
endgroup

# ── Linkage matches the model ────────────────────────────────────────────────
group "linkage matches the static/dynamic model"
# Fail closed: assert the tool exists before trusting any result from it.
if ! command -v readelf > /dev/null 2>&1; then
  fail "readelf not found; linkage assertions cannot be trusted"
fi
# Every bundled helper is a static musl build on both distros. Only the podman
# binary itself may be dynamic, and only on Debian.
for helper in netavark aardvark-dns catatonit; do
  if readelf -d "/usr/libexec/podman/${helper}" 2> /dev/null | grep -q NEEDED; then
    fail "${helper} is dynamically linked; expected static"
  else
    ok "${helper} is static"
  fi
done

if [ "${DISTRO}" = alpine ]; then
  if readelf -d /usr/bin/podman 2> /dev/null | grep -q NEEDED; then
    fail "podman is dynamically linked on Alpine; expected static"
  else
    ok "podman is static on Alpine"
  fi
fi
endgroup

# ── Run a container ──────────────────────────────────────────────────────────
group "podman run"
if podman run --rm "${TEST_IMAGE}" > /dev/null 2>&1; then
  ok "podman run (crun + conmon)"
else
  fail "podman run"
  podman run --rm "${TEST_IMAGE}" 2>&1 | tail -20 >&2 || true
fi

if podman run --rm --init "${BUSYBOX_IMAGE}" true > /dev/null 2>&1; then
  ok "podman run --init (bundled catatonit)"
else
  fail "podman run --init"
fi
endgroup

# ── Build an image ───────────────────────────────────────────────────────────
group "podman build"
build_dir="$(mktemp -d)"
cat > "${build_dir}/Containerfile" << EOF
FROM ${BUSYBOX_IMAGE}
RUN echo acceptance > /acceptance.txt
EOF

if podman build -t acceptance:local "${build_dir}" > /dev/null 2>&1; then
  ok "podman build"
  if [ "$(podman run --rm acceptance:local cat /acceptance.txt)" = acceptance ]; then
    ok "built image runs and contains the expected layer"
  else
    fail "built image content mismatch"
  fi
else
  fail "podman build"
  podman build -t acceptance:local "${build_dir}" 2>&1 | tail -20 >&2 || true
fi
endgroup

# ── The lockstep canary ──────────────────────────────────────────────────────
group "netavark network + aardvark-dns resolution"
# This is the test that catches an incompatible netavark or aardvark-dns major
# bump. Container-to-container resolution by name exercises the whole path:
# podman -> netavark (nftables) -> aardvark-dns.
if podman network create acceptance-net > /dev/null 2>&1; then
  ok "podman network create (netavark + nftables)"

  podman run -d --name acceptance-target --network acceptance-net \
    "${BUSYBOX_IMAGE}" sleep 300 > /dev/null 2>&1 || true

  # Give aardvark-dns a moment to publish the record.
  sleep 3

  # Query the FULLY-QUALIFIED name, and assert the answer is the target's real
  # address rather than trusting nslookup's exit status.
  #
  # A bare name walks the container's search list. On a cloud runner that list
  # inherits the host's own search domain, so busybox also queries
  # acceptance-target.<runner-domain>, gets NXDOMAIN, and exits non-zero -- even
  # though acceptance-target.dns.podman resolved correctly. That produced a false
  # negative on the one test guarding against an incompatible netavark or
  # aardvark-dns bump, and since acceptance is the only gate on a release, it
  # would have blocked every release rather than just looking flaky.
  #
  # Comparing against the address from `podman inspect` also makes this a real
  # assertion: aardvark-dns has to return the *right* record, not merely answer.
  target_ip="$(
    podman inspect -f \
      '{{ (index .NetworkSettings.Networks "acceptance-net").IPAddress }}' \
      acceptance-target 2> /dev/null
  )"

  if [ -z "${target_ip}" ]; then
    # Distinguish "the target never got an address" from a DNS fault; otherwise
    # a container that failed to start reads as an aardvark-dns regression.
    fail "container-to-container DNS: target has no address on acceptance-net"
    podman inspect acceptance-target 2>&1 | tail -20 >&2 || true
  elif dns_out="$(
    podman run --rm --network acceptance-net "${BUSYBOX_IMAGE}" \
      nslookup acceptance-target.dns.podman 2>&1
  )" && printf '%s' "${dns_out}" | grep -qF "${target_ip}"; then
    # -F, not a regex: an address's dots would otherwise match any character.
    ok "container-to-container DNS via aardvark-dns (${target_ip})"
  else
    fail "container-to-container DNS via aardvark-dns"
    printf '%s\n' "${dns_out}" | tail -10 >&2
  fi

  podman rm -f acceptance-target > /dev/null 2>&1 || true
  podman network rm -f acceptance-net > /dev/null 2>&1 || true
else
  fail "podman network create"
  podman network create acceptance-net 2>&1 | tail -20 >&2 || true
fi
endgroup

# ── Rootless ─────────────────────────────────────────────────────────────────
group "rootless operation (pasta)"
# Rootless is how most people actually run podman, and it is the only path that
# exercises pasta and rootlessport.
case "${DISTRO}" in
  # debian:trixie ships useradd but NOT adduser -- the earlier version of this
  # script called adduser and, because the failure was swallowed by `|| true`,
  # reported a confusing "rootless podman run failed" instead of "the test user
  # was never created". Setup failures are now surfaced as themselves.
  debian) useradd -m acceptance > /dev/null 2>&1 || true ;;
  alpine) adduser -D acceptance > /dev/null 2>&1 || true ;;
esac

if ! id acceptance > /dev/null 2>&1; then
  fail "could not create the unprivileged test user; rootless path not exercised"
else
  ok "unprivileged test user created"

  echo "acceptance:100000:65536" > /etc/subuid
  echo "acceptance:100000:65536" > /etc/subgid

  # Deliberately NO workaround here. Alpine's containers-common forces graphroot
  # and runroot, which would deny a rootless user, and the package ships
  # /usr/share/containers/storage.conf.d/50-rootless-storage.conf to undo that.
  # This suite must exercise the shipped fix rather than reapply it, so a
  # regression in that fragment fails the release.
  if [ "${DISTRO}" = alpine ]; then
    if [ -f /usr/share/containers/storage.conf.d/50-rootless-storage.conf ]; then
      ok "rootless storage fragment shipped"
    else
      fail "rootless storage fragment missing from the package"
    fi
  fi

  # Rootless podman needs a runtime directory. A bare container has no
  # /run/user/<uid>, and without XDG_RUNTIME_DIR podman falls back to a /tmp
  # path with a warning; create it explicitly so the test is deterministic.
  acc_uid="$(id -u acceptance)"
  install -d -o acceptance -g acceptance -m 700 "/run/user/${acc_uid}"

  # Two assertions, coarse then fine, so a failure localizes itself:
  #
  #   default networking -> pasta alone, which is podman 6's rootless default
  #   --network bridge   -> a rootless netns plus pasta plus rootlessport, which
  #                         additionally needs the uid/gid mapping to hold up
  #
  # Alpine currently fails the second while Debian passes both. Splitting them
  # says whether the userns mapping is broken generally or only the rootless-netns
  # path is, which the single combined assertion could not distinguish.
  rootless_env="XDG_RUNTIME_DIR=/run/user/${acc_uid}"
  rootless_plain="${rootless_env} podman run --rm ${BUSYBOX_IMAGE} true"

  if su acceptance -s /bin/sh -c "${rootless_plain}" > /dev/null 2>&1; then
    ok "rootless podman run, default networking (pasta)"
  else
    fail "rootless podman run, default networking (pasta)"
    su acceptance -s /bin/sh -c "${rootless_plain}" 2>&1 | tail -20 >&2 || true
  fi

  rootless_run="${rootless_env} podman run --rm --network bridge ${BUSYBOX_IMAGE} true"

  if su acceptance -s /bin/sh -c "${rootless_run}" > /dev/null 2>&1; then
    ok "rootless podman run with bridge networking (pasta + rootlessport)"
  else
    fail "rootless podman run with bridge networking"
    su acceptance -s /bin/sh -c "${rootless_run}" 2>&1 | tail -20 >&2 || true

    # podman reports pasta failures as `pasta failed with exit code 1:` with
    # nothing after the colon, so pasta's own message only reaches the log via
    # the re-run above. Record what determines whether the rootless path can
    # work at all.
    #
    # Every command here MUST terminate on its own. An earlier version invoked
    # bare `pasta` to capture its stderr, on the assumption that it would exit
    # once it found no netns to attach to. It does not -- it keeps running, so
    # the `| head` never saw EOF and the job hung until the six-hour timeout.
    echo "--- rootless diagnostics ---" >&2
    echo "pasta: $(command -v pasta || echo '<not on PATH>')" >&2
    pasta --version 2>&1 | head -3 >&2 || true
    echo "/dev/net/tun: $(ls -l /dev/net/tun 2>&1)" >&2
    echo "unprivileged_userns_clone: $(cat /proc/sys/kernel/unprivileged_userns_clone 2>&1 || echo n/a)" >&2
    echo "max_user_namespaces: $(cat /proc/sys/user/max_user_namespaces 2>&1 || echo n/a)" >&2
    echo "subuid: $(grep acceptance /etc/subuid 2>&1)" >&2
    echo "subgid: $(grep acceptance /etc/subgid 2>&1)" >&2

    # Existence is not enough: newuidmap has to be *usable*. Debian ships it
    # with file capabilities, Alpine setuid-root, and a nosuid mount or an
    # overlay that drops capabilities breaks those two in different ways. If the
    # mapping never gets established, pasta fails exactly as observed -- EACCES
    # on a world-readable /proc/sys entry and on the runtime dir.
    for helper in newuidmap newgidmap; do
      path="$(command -v "${helper}" 2> /dev/null || true)"
      if [ -n "${path}" ]; then
        echo "${helper}: $(ls -l "${path}" 2>&1)" >&2
        # getcap needs libcap, which neither base image is guaranteed to carry.
        command -v getcap > /dev/null 2>&1 && getcap "${path}" >&2 || true
      else
        echo "${helper}: <missing>" >&2
      fi
    done

    echo "mount options:" >&2
    grep -E ' (/|/usr|/run) ' /proc/mounts >&2 || true

    # Does the mapping work at all, independent of networking? This is the
    # cheapest way to separate "userns is broken" from "pasta is broken".
    echo "id inside a rootless userns:" >&2
    su acceptance -s /bin/sh -c \
      "XDG_RUNTIME_DIR=/run/user/${acc_uid} podman unshare id" 2>&1 | head -3 >&2 || true
    echo "--- end rootless diagnostics ---" >&2
  fi
fi
endgroup

# ── nftables reload watcher, Alpine only ─────────────────────────────────────
if [ "${DISTRO}" = alpine ]; then
  group "netavark nftables reload watcher"
  # Alpine's stand-in for netavark-nftables-reload.service. systemd couples that
  # oneshot to nftables declaratively; OpenRC cannot, so this watches the
  # kernel's netlink notifications via `nft monitor tables` instead. Both halves
  # are asserted: that ordinary container churn does NOT trigger a reload, and
  # that an actual ruleset flush does.
  monitor=/usr/libexec/podman/netavark-nftables-monitor

  if [ ! -x "${monitor}" ]; then
    fail "watcher missing: ${monitor}"
  else
    ok "watcher present"

    podman network create reloadtest > /dev/null 2>&1 || true
    podman run -d --name reloadtarget --network reloadtest \
      "${BUSYBOX_IMAGE}" sleep 120 > /dev/null 2>&1 || true

    if nft list table inet netavark > /dev/null 2>&1; then
      ok "netavark owns an nftables table"

      "${monitor}" > /tmp/watcher.log 2>&1 &
      watcher_pid=$!
      sleep 2

      # Negative control first: a container start/stop churns rules inside the
      # netavark table, and must not be mistaken for an external flush.
      podman run --rm --network reloadtest "${BUSYBOX_IMAGE}" true > /dev/null 2>&1 || true
      sleep 3

      if grep -q 'was deleted' /tmp/watcher.log; then
        fail "watcher triggered on ordinary container churn (false positive)"
      else
        ok "watcher silent during container churn"
      fi

      nft flush ruleset

      restored=no
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        if nft list table inet netavark > /dev/null 2>&1; then
          restored=yes
          break
        fi
      done

      if [ "${restored}" = yes ]; then
        ok "netavark rules restored after an external nftables flush"
      else
        fail "netavark rules NOT restored after an external nftables flush"
        sed 's/^/    /' /tmp/watcher.log >&2 || true
      fi

      kill "${watcher_pid}" 2> /dev/null || true
    else
      fail "no netavark table after creating a network; cannot test the watcher"
    fi

    podman rm -f reloadtarget > /dev/null 2>&1 || true
    podman network rm -f reloadtest > /dev/null 2>&1 || true
  fi
  endgroup
fi

# ── journald, Debian only ────────────────────────────────────────────────────
if [ "${DISTRO}" = debian ]; then
  group "journald log driver"
  # Keeping journald is the entire reason the Debian podman is a separate,
  # dynamically linked build. If this regresses, that trade-off bought nothing.
  if podman run --rm --log-driver=journald "${BUSYBOX_IMAGE}" \
    echo journald-canary > /dev/null 2>&1; then
    ok "podman run --log-driver=journald"
  else
    fail "podman run --log-driver=journald"
  fi

  if podman info --format '{{.Host.LogDriver}}' > /dev/null 2>&1; then
    ok "podman info reports a log driver"
  fi
  endgroup

  group "systemd unit files are present"
  for unit in podman.service podman.socket podman-auto-update.service; do
    if [ -f "/usr/lib/systemd/system/${unit}" ]; then
      ok "unit present: ${unit}"
    else
      fail "unit missing: ${unit}"
    fi
  done
  endgroup
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [ "${rc}" -eq 0 ]; then
  echo "acceptance suite passed (${DISTRO})"
else
  echo "acceptance suite FAILED (${DISTRO})" >&2
fi

exit "${rc}"
