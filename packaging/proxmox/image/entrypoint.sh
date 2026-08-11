#!/usr/bin/env bash
# shellcheck shell=bash
#
# PID 1 for the Proxmox VE image.
#
# Resolves the capability contract, reports what it decided, applies the
# consequences, sets up the root credential, then hands off to systemd.
#
# Everything here runs before systemd starts.  That ordering is the whole point:
# a unit that cannot succeed is masked rather than started and failed, so the
# acceptance suite's "no units in failed state" check means what it says instead
# of needing a list of failures that are fine actually.
#
# The capability contract itself lives in lib/capabilities.sh.  Read that file
# for the policy table and the state-file schema.
set -euo pipefail

readonly LIB_ROOT="${PVE_LIB_ROOT:-/usr/local/lib/pve}"

# shellcheck source=packaging/proxmox/image/lib/probe-common.sh
. "${LIB_ROOT}/lib/probe-common.sh"
# shellcheck source=packaging/proxmox/image/lib/capabilities.sh
. "${LIB_ROOT}/lib/capabilities.sh"

# configure_root_password
#
# PVE_ROOT_PASSWORD_HASH takes precedence over PVE_ROOT_PASSWORD.  Both are read
# from the environment and fed to chpasswd on stdin, which is the interface
# chpasswd actually has.
#
# This is worth stating because the obvious-looking alternative does not work.
# The baseline image this one is measured against runs
#
#     usermod -p  root <<<"$PASSWORD_HASH"
#
# which is broken three ways at once: usermod does not read stdin, so the hash
# is discarded; `root` is consumed as the argument to -p, so the account is set
# to the literal string "root" as a hash; and no LOGIN operand is left, so
# usermod errors out.  Under `set -e` that aborts startup.  The hash path there
# has never worked.  chpasswd -e is the correct tool: it takes user:hash pairs
# on stdin and -e says the second field is already hashed.
configure_root_password() {
  local password="${PVE_ROOT_PASSWORD:-}"
  local hash="${PVE_ROOT_PASSWORD_HASH:-}"

  if [[ -n "${hash}" ]]; then
    if [[ -n "${password}" ]]; then
      printf 'warning: both PVE_ROOT_PASSWORD and PVE_ROOT_PASSWORD_HASH are set\n' >&2
      printf 'warning: using the hash and ignoring the plaintext\n' >&2
    fi
    printf 'root:%s\n' "${hash}" | chpasswd -e
    printf 'root credential: set from PVE_ROOT_PASSWORD_HASH\n'
    return 0
  fi

  # Defaulting to a known password is a deliberate parity choice: the image is
  # useless if the web UI cannot be logged into, and an operator who cares sets
  # one.  The default is announced rather than applied quietly.
  if [[ -z "${password}" ]]; then
    password="root"
    printf 'root credential: PVE_ROOT_PASSWORD is unset; defaulting to "root"\n' >&2
  else
    printf 'root credential: set from PVE_ROOT_PASSWORD\n'
  fi

  printf 'root:%s\n' "${password}" | chpasswd
}

# configure_shm
#
# PVE_SHM_SIZE attempts to resize /dev/shm in place.  This is a fallback, not
# the documented path.
#
# The documented path is the runtime's own --shm-size, because that sizing is in
# place before any process starts, whereas a remount here happens after the
# kernel has already created the tmpfs and can be refused.  When it is refused
# this reports the flag that would have worked and continues: failing startup
# over a tuning knob would be a worse outcome than running with the default.
configure_shm() {
  local size="${PVE_SHM_SIZE:-}"

  [[ -n "${size}" ]] || return 0

  if mount -o "remount,size=${size}" /dev/shm 2> /dev/null; then
    printf '/dev/shm: resized to %s\n' "${size}"
    return 0
  fi

  printf 'warning: /dev/shm remount to %s unavailable, use --shm-size=%s\n' \
    "${size}" "${size}" >&2
}

# configure_timezone
#
# Point /etc/localtime and /etc/timezone at the zone named by TZ.
#
# TZ is used rather than a PVE_-prefixed name because it is the POSIX variable
# the C library already reads; inventing a synonym for something glibc honours
# natively would mean two names for one setting, which drift apart.
#
# Without this the container runs on whatever the base image shipped, which is
# UTC. That is defensible for a server, but PVE stamps task logs, backup
# schedules and the cluster log with local time, so an operator reading them is
# silently reading a different clock from the one their host uses.
configure_timezone() {
  local zone="${TZ:-}"
  local zonefile

  if [[ -z "${zone}" ]]; then
    return 0
  fi

  zonefile="/usr/share/zoneinfo/${zone}"
  if [[ ! -f "${zonefile}" ]]; then
    # Fatal, not a warning.  An earlier revision warned and carried on with UTC,
    # which is the same shape of failure as accepting PVE_KVM=requre and quietly
    # treating it as auto: the operator asked for something specific, the value
    # was not understood, and the result was a default that looks deliberate.
    # A typo in a zone name is indistinguishable from a correct one in the logs
    # afterwards -- every timestamp is plausible, just wrong -- so the moment to
    # object is now, while the name that was rejected can still be printed.
    printf 'error: TZ=%s is not a zone under /usr/share/zoneinfo\n' "${zone}" >&2
    printf 'error: refusing to start on a clock the operator did not ask for; unset TZ for UTC\n' >&2
    exit 80
  fi

  ln -sf "${zonefile}" /etc/localtime
  printf '%s\n' "${zone}" > /etc/timezone
  printf 'timezone: %s\n' "${zone}"
}

# configure_tun
#
# Ensure /dev/net/tun exists, because QEMU opens it to attach a guest NIC to a
# bridge and fails at machine creation without it.
#
# This is opportunistic, exactly like the /dev/shm remount: some runtimes expose
# the node already, some expose it only with --device /dev/net/tun, and creating
# it here needs CAP_MKNOD. When the node cannot be created the message names the
# flag that would supply it rather than failing startup, because a management
# plane without guest NICs is still a working management plane -- and refusing to
# start over a device only VMs need would be the wrong trade.
#
# 10:200 is the fixed major:minor the kernel assigns to the TUN/TAP driver.
configure_tun() {
  if [[ -c /dev/net/tun ]]; then
    printf 'tun: /dev/net/tun present\n'
    return 0
  fi

  if mkdir -p /dev/net 2> /dev/null && mknod /dev/net/tun c 10 200 2> /dev/null; then
    chmod 0666 /dev/net/tun
    printf 'tun: created /dev/net/tun\n'
    return 0
  fi

  printf 'tun: /dev/net/tun unavailable, use --device /dev/net/tun (guest NICs will not attach)\n' >&2
}

# ipv4_dhcp_range <cidr>
#
# Print "<first> <last> <netmask>" for the usable host range of <cidr>,
# excluding the network address, the broadcast address, and the address in
# <cidr> itself, which is the bridge and therefore the router.
#
# Computed rather than assumed.  Hard-coding a /24 and a .100-.200 range
# would hand out addresses outside the subnet the moment an operator chose a
# different prefix, and a DHCP server that leases unroutable addresses fails
# in a way the guest cannot diagnose.
ipv4_dhcp_range() {
  local cidr="$1" addr prefix mask net bcast first last size
  local -a o

  [[ "${cidr}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]+)$ ]] || return 1

  o=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
  prefix="${BASH_REMATCH[5]}"

  # A /31 has no host addresses and a /32 is a single address; neither can
  # carry a router plus a lease, so there is nothing to hand out.
  ((prefix >= 8 && prefix <= 30)) || return 1

  addr=$(((o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]))
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  net=$((addr & mask))
  size=$((1 << (32 - prefix)))
  bcast=$((net + size - 1))

  first=$((net + 1))
  last=$((bcast - 1))

  # Step over the router if it sits at the bottom of the range, which is the
  # conventional placement and the default this image uses.
  ((first == addr)) && first=$((first + 1))
  ((first <= last)) || return 1

  printf '%d.%d.%d.%d %d.%d.%d.%d %d.%d.%d.%d\n' \
    $(((first >> 24) & 255)) $(((first >> 16) & 255)) $(((first >> 8) & 255)) $((first & 255)) \
    $(((last >> 24) & 255)) $(((last >> 16) & 255)) $(((last >> 8) & 255)) $((last & 255)) \
    $(((mask >> 24) & 255)) $(((mask >> 16) & 255)) $(((mask >> 8) & 255)) $((mask & 255))
}

# configure_guest_dhcp <bridge> <cidr>
#
# Generate the dnsmasq configuration the pve-guest-dnsmasq.service unit is
# gated on.  Writing the file is what starts the service: the unit carries
# ConditionPathExists on this path, so at a privilege tier where the bridge
# could not be created the file is absent and systemd skips the unit rather
# than failing it.
configure_guest_dhcp() {
  local bridge="$1" cidr="$2" mtu="${3:-}" router range first last netmask conf

  router="${cidr%%/*}"
  range="$(ipv4_dhcp_range "${cidr}")" || return 1
  read -r first last netmask <<< "${range}"

  conf="/run/pve-container/guest-dnsmasq.conf"
  mkdir -p /run/pve-container

  # interface= plus bind-interfaces confines the server to the guest bridge.
  # Without bind-interfaces dnsmasq opens a wildcard socket and filters by
  # arrival interface, which still answers a DHCP request that reaches it by
  # another path -- on a host whose uplink shares a segment with a real DHCP
  # server that is an outage, not a misconfiguration.
  #
  # Upstream resolvers are deliberately not listed: dnsmasq reads
  # /etc/resolv.conf, which the container runtime wrote and which already
  # points at whatever DNS this container was given.  Naming servers here
  # would pin guests to whatever was true when the image was built.
  cat > "${conf}" << EOF
# Generated by the pve-container-shim entrypoint. Do not edit; this file is
# rewritten on every start and lives on a tmpfs.
interface=${bridge}
bind-interfaces
except-interface=lo
listen-address=${router}
dhcp-range=${first},${last},${netmask},12h
dhcp-option=option:router,${router}
dhcp-option=option:dns-server,${router}
dhcp-authoritative
domain-needed
bogus-priv
EOF

  # This bridge has no IPv6 path: the uplink is reached through IPv4 NAT and
  # nothing hands out a v6 prefix.  A dual-stack guest that still receives AAAA
  # records will try the v6 address first on every lookup and wait out the
  # connect timeout before falling back, which presents as every name
  # resolving slowly rather than as a networking fault.
  printf 'filter-AAAA\n' >> "${conf}"

  # Tell guests the MTU rather than letting them assume 1500.  A guest that
  # assumes wrong emits frames the uplink silently drops, and the symptom --
  # a connection that establishes and then stalls on the first large transfer
  # -- looks like a remote problem from inside the guest.
  if [[ -n "${mtu}" ]]; then
    printf 'dhcp-option=option:mtu,%s\n' "${mtu}" >> "${conf}"
  fi

  printf 'guest network: DHCP %s-%s, router %s, on %s%s\n' \
    "${first}" "${last}" "${router}" "${bridge}" "${mtu:+, MTU ${mtu}}"
}

# uplink_is_shared_namespace <interface>
#
# True when the named interface is NOT one end of a veth pair, which means this
# container is looking at a network namespace it did not get to itself --
# almost always because it was started with host networking.
#
# This matters because everything below this point mutates network state.  In a
# shared namespace the bridge and the NAT rule are created in the host's own
# namespace and nat table, they outlive the container, and nothing here removes
# them.  Refusing is the only safe answer; there is no version of this that
# leaves the host as it found it.
#
# The test is `iflink` against `ifindex`.  For a veth, iflink names the peer
# interface, which lives in another namespace, so the two differ.  For anything
# the host owns outright -- a physical NIC, a bond, a bridge -- they are equal.
#
# An earlier revision tested for a `device` symlink in sysfs instead, on the
# reasoning that a physical NIC has one and a veth does not.  That is true and
# useless: measured against a real Linux host, the default route left through
# `vmbr0`, a bridge, which has no `device` symlink either.  The check reported
# "not a host interface" for a genuine host namespace, and every host whose
# uplink is a bridge -- which is every Proxmox host, and most hosts running any
# container runtime -- would have walked straight past the guard.
#
# One known gap, stated because it is not obvious: Docker Desktop's
# `--network host` places the container in the namespace of the Linux VM that
# Docker Desktop runs, and reaches it through a veth.  This test sees the veth
# and allows the run.  State does persist in that VM between containers, but
# the VM is the runtime's own disposable machine rather than the operator's
# host, so the consequence is bounded in a way it is not on real Linux.
uplink_is_shared_namespace() {
  local dev="$1" ifindex iflink

  [[ -n "${dev}" ]] || return 1

  ifindex="$(cat "/sys/class/net/${dev}/ifindex" 2> /dev/null || true)"
  iflink="$(cat "/sys/class/net/${dev}/iflink" 2> /dev/null || true)"

  # Unreadable sysfs is not evidence of a shared namespace, and refusing on it
  # would turn an unknown into a hard stop for every run.
  [[ -n "${ifindex}" ]] && [[ -n "${iflink}" ]] || return 1

  [[ "${ifindex}" == "${iflink}" ]]
}

# subnet_is_routed <network/prefix>
#
# True when the kernel already reaches the given network by some route more
# specific than the default.  Used to avoid claiming a range the host can
# already reach: a guest subnet that overlaps the operator's own LAN does not
# fail at start-up, it fails later and selectively, when some destinations stop
# being reachable from inside the container and not others.
#
# Two questions, because one lookup does not answer both.  `root` lists routes
# that fall inside the prefix -- the case where part of our proposed range is
# already spoken for.  `match` lists routes that cover it, which is the case
# where the whole range sits behind something else.
#
# `match` needs filtering, because a route covering everything covers this too.
# Two revisions got this wrong in turn.  The first used `match` alone, so the
# default route made every candidate look taken on any host that has one --
# which is every host -- and the feature was inert while appearing to work.
# The second filtered lines beginning "default", which missed the catch-all
# forms that do not: Docker Desktop's namespace carries `local default dev lo
# table 984`, and that one line was enough to reject all six alternatives.
#
# Filtering on the destination field being an actual address is what holds:
# it admits real prefixes and rejects `default`, `local`, `broadcast`,
# `unreachable` and anything else iproute2 prints in that position, without
# needing to know the full set in advance.
subnet_is_routed() {
  local net="$1"

  [[ -n "$(ip -4 route show table all root "${net}" 2> /dev/null)" ]] && return 0

  ip -4 route show table all match "${net}" 2> /dev/null \
    | awk '$1 ~ /^[0-9]+\./ && $1 != "0.0.0.0/0" { found = 1 } END { exit !found }'
}

# stable_mac <seed>
#
# Print a deterministic locally-administered unicast MAC derived from a seed
# that is stable for the life of the container.  Without one the bridge gets a
# fresh random address on every start, and guests see their default gateway
# change identity across a restart -- Windows re-runs network-location
# discovery, NetworkManager reports a new network, and DHCP clients that key
# their lease on the server MAC discard it.
#
# The locally-administered bit is set and the multicast bit cleared, so the
# address cannot collide with a real vendor assignment.
stable_mac() {
  local seed="$1" digest
  digest="$(printf '%s' "${seed}" | md5sum | cut -c1-12)"
  printf '%02x:%s:%s:%s:%s:%s\n' \
    $(((0x${digest:0:2} & 0xFE) | 0x02)) \
    "${digest:2:2}" "${digest:4:2}" "${digest:6:2}" "${digest:8:2}" "${digest:10:2}"
}

# configure_guest_network
#
# Declare a guest bridge in /etc/network/interfaces and make traffic leaving it
# reach the outside.  Runs only when the guest_network capability resolved
# enabled, which means CAP_NET_ADMIN is effective; at the reduced capability
# tier nothing here happens and no bridge is declared, so the shim's
# ifup-guest-bridges helper finds nothing to bring up.
#
# Declarative rather than imperative: the stanza is written to the file PVE
# itself reads, and ifupdown2 brings the bridge up from it.  Creating the
# bridge directly with `ip link` would work too, but then /etc/network/interfaces
# would describe a network nobody built and the web UI's Network page would be
# decoration.  Writing the file makes it the source of truth, which is also what
# gives `ifreload -a` something real to apply later.
#
# The uplink is never touched.  It belongs to the container runtime, which
# created it and assigned its address from a pool this file knows nothing about.
# All that is taken from it is its name, so NAT knows which way is out.
configure_guest_network() {
  local bridge="${PVE_GUEST_BRIDGE:-vmbr0}"
  local cidr="${PVE_GUEST_SUBNET:-10.10.10.1/24}"
  local subnet uplink forwarding ipt mtu mac
  local forward_policy_drops forward_rules_present
  local declared_cidr

  # The dnsmasq unit is gated on ConditionPathExists against this file, so a
  # stale one from an earlier start where guest networking WAS enabled would
  # start dnsmasq bound to a bridge that no longer exists.  /run is a tmpfs in
  # the documented invocation, which clears it -- but the operator who omits
  # that flag gets a failed unit and no indication why, so remove it here
  # rather than relying on how the runtime was invoked.
  if [[ "${CAPABILITY_RESOLVED[guest_network]:-disabled}" != "enabled" ]]; then
    rm -f /run/pve-container/guest-dnsmasq.conf
    return 0
  fi

  # Resolved before anything is written, because the host-network guard below
  # has to run before the first mutation rather than after it.
  uplink="$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' | head -n1)"

  if uplink_is_shared_namespace "${uplink}"; then
    printf 'error: guest network: %s is not a veth, so this container shares another network namespace\n' \
      "${uplink}" >&2
    printf 'error: guest network: refusing to create a bridge and NAT rule the host would keep after this container exits\n' >&2
    printf 'error: guest network: run without --network host, or set PVE_GUEST_NETWORK=disable to suppress this\n' >&2
    printf 'guest network: disabled (host network namespace)\n'
    return 0
  fi

  # Inherit the uplink's MTU.  A bridge left at the default 1500 on a host
  # whose uplink is smaller -- an overlay network, a tunnel, a cloud fabric at
  # 1460 -- silently black-holes full-size guest frames.  A larger uplink is
  # not inherited: jumbo frames only work if every hop agrees, and the guest's
  # path leaves through NAT to destinations that have made no such promise.
  if [[ -n "${uplink}" ]]; then
    mtu="$(cat "/sys/class/net/${uplink}/mtu" 2> /dev/null || true)"
    if [[ -n "${mtu}" ]] && ((mtu > 1500)); then
      mtu=1500
    fi
  fi

  # The address carries the prefix, and the NAT rule needs the network.  Derive
  # the second from the first rather than asking for both, so they cannot
  # disagree: an operator who sets one and forgets the other would otherwise get
  # a bridge that works and a NAT rule that silently matches nothing.
  subnet="$(ipv4_network "${cidr}")" || {
    printf 'warning: PVE_GUEST_SUBNET=%s is not an IPv4 address with a prefix; skipping guest networking\n' \
      "${cidr}" >&2
    return 0
  }

  # A stanza written by an earlier start is authoritative for the address.
  # /etc/network/interfaces lives in the writable layer, so it survives a
  # restart -- and the address in it is what the bridge will actually come up
  # with.  Re-deriving here and using the result anyway would produce a bridge
  # at the old address with NAT and DHCP configured for the new one: guests
  # would be handed leases on a range their gateway is not on.  Adopting the
  # existing address keeps the three in agreement, and is also the kinder
  # choice for guests already holding leases on it.
  #
  # The consequence, stated rather than hidden: a subnet that only became
  # routed after the first start is not moved off.  That is a deliberate
  # trade -- collision avoidance is a first-run decision, and renumbering a
  # network underneath running guests to fix it would be the worse failure.
  declared_cidr=""
  if [[ -r /etc/network/interfaces ]]; then
    declared_cidr="$(
      awk -v ifn="${bridge}" '
        $1 == "iface" && $2 == ifn { in_stanza = 1; next }
        $1 == "iface" || $1 == "auto" { in_stanza = 0 }
        in_stanza && $1 == "address" { print $2; exit }
      ' /etc/network/interfaces 2> /dev/null
    )"
  fi

  if [[ -n "${declared_cidr}" ]]; then
    if [[ "${declared_cidr}" != "${cidr}" ]]; then
      printf 'guest network: adopting %s already declared for %s\n' "${declared_cidr}" "${bridge}"
    fi
    cidr="${declared_cidr}"
    subnet="$(ipv4_network "${cidr}")" || {
      printf 'warning: guest network: %s declared for %s is not an IPv4 address with a prefix; skipping guest networking\n' \
        "${cidr}" "${bridge}" >&2
      return 0
    }
  fi

  # Move off the default range if the host can already reach it.  The default
  # is a guess, and a guess that collides with the operator's own LAN does not
  # fail visibly: the container simply stops being able to reach some
  # addresses, and which ones depends on rule order.  An explicitly configured
  # subnet is never moved -- an operator who named a range meant it, and
  # silently substituting another would be worse than the collision.
  if [[ -z "${declared_cidr}" ]] && [[ -z "${PVE_GUEST_SUBNET:-}" ]] && subnet_is_routed "${subnet}"; then
    local candidate found="false"
    for candidate in 10.10.10 10.20.30 172.30.40 172.31.40 192.168.230 192.168.231; do
      if ! subnet_is_routed "${candidate}.0/24"; then
        cidr="${candidate}.1/24"
        subnet="${candidate}.0/24"
        found="true"
        break
      fi
    done
    if [[ "${found}" == "true" ]]; then
      printf 'guest network: default subnet is already routed; using %s instead\n' "${subnet}"
    else
      printf 'warning: guest network: %s is already routed and no alternative was free; guests may not reach some hosts\n' \
        "${subnet}" >&2
    fi
  fi

  if ! grep -qE "^[[:space:]]*iface[[:space:]]+${bridge}[[:space:]]" /etc/network/interfaces 2> /dev/null; then
    # bridge-ports none is what makes this legal with no physical member.  A
    # bridge with no ports still switches between the tap devices QEMU and LXC
    # attach to it, which is the whole job here -- the uplink is reached through
    # NAT below, not by enslaving it.
    # PVE expects /etc/network/interfaces to source its SDN fragment directory,
    # and warns on every apply when the directive is absent -- "missing 'source
    # /etc/network/interfaces.d/sdn' directive for SDN support!".  SDN is not
    # configured here, so the warning is harmless, but an apply that always
    # finishes with "Task finished with 1 warning(s)!" trains an operator to
    # ignore warnings, and the next one may matter.  The directory is created
    # because ifupdown2 reads the sourced path at parse time.
    if ! grep -qE '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/sdn' /etc/network/interfaces 2> /dev/null; then
      mkdir -p /etc/network/interfaces.d
      # The sourced file has to exist, not just the directory.  ifupdown2
      # emits "cannot find source file" for a source directive pointing at
      # nothing and then exits non-zero even though it brought the interface
      # up, so ifup reports failure for an operation that succeeded.  PVE
      # creates this file itself once SDN is configured; an empty placeholder
      # is what it expects to find before then.
      : > /etc/network/interfaces.d/sdn
      printf '\nsource /etc/network/interfaces.d/sdn\n' >> /etc/network/interfaces
    fi

    cat >> /etc/network/interfaces << EOF

auto ${bridge}
iface ${bridge} inet static
    address ${cidr}
    bridge-ports none
    bridge-stp off
    bridge-fd 0${mtu:+
    mtu ${mtu}}
EOF
    printf 'guest network: declared %s %s in /etc/network/interfaces\n' "${bridge}" "${cidr}"
  else
    printf 'guest network: %s already declared in /etc/network/interfaces\n' "${bridge}"
  fi

  # Bring it up now rather than waiting for networking.service.  The entrypoint
  # runs before systemd, so at this point no unit has started and the bridge
  # would otherwise not exist until the unit ran -- which is fine for guests but
  # means the summary line below would be describing something that is not there
  # yet.  ifup is idempotent via ifquery, so the later unit start is a no-op.
  mkdir -p /run/network
  # Judged by whether the device appeared, not by ifup's exit status.
  # ifupdown2 exits non-zero when any warning was emitted while parsing, even
  # though the interface came up -- an earlier revision trusted the status,
  # took the degraded path on a cosmetic warning, and silently skipped DHCP,
  # forwarding and NAT while the bridge itself was fine.  The device either
  # exists or it does not, and that is the only question that matters.
  ifup "${bridge}" > /dev/null 2>&1 || true
  if [[ ! -d "/sys/class/net/${bridge}" ]]; then
    printf 'warning: guest network: %s declared but could not be brought up\n' "${bridge}" >&2
    return 0
  fi

  # Guests need addresses, and nothing upstream will give them any.  On real
  # hardware the guest bridge is enslaved to a physical port and guests are
  # addressed by whatever serves that network.  Here the bridge has no member
  # port and reaches the outside through NAT, so a guest's DHCP request is
  # never seen by anything but this host.  Without a server on the bridge a
  # guest boots, brings up its NIC, waits out its timeout and looks hung.
  #
  # The config is written to /run rather than /etc because it describes this
  # boot's addressing, not a persistent operator choice, and because the unit
  # that consumes it is gated on the file's existence: at a privilege tier
  # that cannot create a bridge the file is absent, the unit is skipped rather
  # than failed, and nothing has to be masked to keep it out of the way.
  # Pin the bridge address so guests see the same gateway identity across a
  # restart.  Seeded from machine-id where the runtime provides one and from
  # the hostname otherwise; both are stable for the life of the container, and
  # neither leaks anything about the host.
  mac="$(stable_mac "${bridge}:$(cat /etc/machine-id 2> /dev/null || hostname)")"
  ip link set "${bridge}" address "${mac}" > /dev/null 2>&1 || true

  if ! configure_guest_dhcp "${bridge}" "${cidr}" "${mtu}"; then
    printf 'warning: guest network: DHCP is not configured; guests must be addressed statically\n' >&2
  fi
  # Read it back rather than trusting the write.  /proc/sys can be mounted
  # read-only in a container, and a write that fails there is silent unless the
  # value is checked afterwards.
  printf '1' > /proc/sys/net/ipv4/ip_forward 2> /dev/null || true
  forwarding="$(cat /proc/sys/net/ipv4/ip_forward 2> /dev/null || echo 0)"
  if [[ "${forwarding}" != "1" ]]; then
    printf 'warning: guest network: IP forwarding is off and could not be enabled; guests will not route\n' >&2
    return 0
  fi

  if [[ -z "${uplink}" ]]; then
    printf 'warning: guest network: no default route; guests will reach each other but not the outside\n' >&2
    return 0
  fi

  # -C tests for the rule before -A adds it, so a restart does not accumulate a
  # second identical rule every time the container starts.
  # Resolve one iptables binary and use it for every operation below.
  #
  # Debian ships iptables as an alternatives symlink that can point at either
  # the nft-based or the legacy back end, and the two keep entirely separate
  # rule sets.  An earlier revision let the alias decide: the rule landed in
  # the nft back end while verification read legacy, so the start-up line
  # claimed NAT was installed while `iptables -t nat -S` showed nothing.  The
  # rule existed and the message was true of a table nobody was reading.
  #
  # Pinning one binary makes the guard, the install and the verification
  # address the same table by construction.  nft is preferred because it is
  # Debian's default and what the kernel side of a modern image expects; the
  # fallbacks exist so an image built on a differently-configured base still
  # works rather than failing on a missing name.
  # Every rule this image installs carries a comment tag.  Without one our rule
  # is indistinguishable from one the operator wrote, so it cannot be found,
  # audited, or removed selectively -- and a `-C` probe that matched a
  # coincidentally identical operator rule would make us skip an install we
  # still needed.
  local NAT_TAG="pve-container-shim guest NAT"

  if command -v iptables-nft > /dev/null 2>&1; then
    ipt="iptables-nft"
  elif command -v iptables-legacy > /dev/null 2>&1; then
    ipt="iptables-legacy"
  else
    ipt="iptables"
  fi

  # -C first so a restart does not stack duplicate rules.  It exits non-zero
  # both when the rule is absent and when the chain cannot be read at all, so
  # its failure is treated as "not present yet" rather than as an error.
  if ! "${ipt}" -t nat -C POSTROUTING -s "${subnet}" ! -o "${bridge}" -m comment --comment "${NAT_TAG}" -j MASQUERADE 2> /dev/null; then
    if ! "${ipt}" -t nat -A POSTROUTING -s "${subnet}" ! -o "${bridge}" -m comment --comment "${NAT_TAG}" -j MASQUERADE 2> /dev/null; then
      printf 'warning: guest network: could not install the NAT rule via %s; guests will not reach the outside\n' \
        "${ipt}" >&2
      printf 'guest network: %s up, no NAT (guests are isolated to the bridge)\n' "${bridge}"
      return 0
    fi
  fi

  # Verify rather than assume.  The install above can report success while the
  # rule is unreachable to the back end that will actually be consulted, and a
  # start-up line claiming NAT that is not there sends an operator looking for
  # the fault everywhere except where it is.
  if ! "${ipt}" -t nat -C POSTROUTING -s "${subnet}" ! -o "${bridge}" -m comment --comment "${NAT_TAG}" -j MASQUERADE 2> /dev/null; then
    printf 'warning: guest network: NAT rule is not readable back from %s; guests may not reach the outside\n' \
      "${ipt}" >&2
    printf 'guest network: %s up, NAT unverified (guests may be isolated to the bridge)\n' "${bridge}"
    return 0
  fi

  # A MASQUERADE rule only helps if the packet reaches POSTROUTING.  Docker
  # sets the FORWARD policy to DROP and inserts its own accept rules, and a
  # container-created bridge is not among them, so guest traffic is dropped
  # before NAT ever sees it.  Nothing here can fix that -- the rules belong to
  # the runtime -- but claiming NAT works while every guest packet is being
  # dropped is exactly the kind of true-but-useless message this image tries
  # not to emit.
  #
  # Policy alone is not the whole question.  Docker sets the policy to DROP and
  # inserts DOCKER-USER and DOCKER-ISOLATION-STAGE rules; podman with netavark,
  # and firewalld, instead leave the policy permissive and express the same
  # restriction as rules.  Checking only the policy therefore reports nothing
  # on exactly the runtimes that express it as rules, while the comment above
  # describes the rule case -- so the check and its own rationale disagreed.
  # Both forms are worth naming, and both are warnings: the rules belong to the
  # runtime and this image is not entitled to rewrite them.
  forward_policy_drops="false"
  forward_rules_present="false"

  if "${ipt}" -S FORWARD 2> /dev/null | grep -qE '^-P FORWARD (DROP|REJECT)'; then
    forward_policy_drops="true"
  fi

  if "${ipt}" -S FORWARD 2> /dev/null \
    | grep -qE '^-A FORWARD .*-j (DOCKER-USER|DOCKER-ISOLATION-STAGE-[0-9]+|DROP|REJECT)'; then
    forward_rules_present="true"
  fi

  if [[ "${forward_rules_present}" == "true" ]] && [[ "${forward_policy_drops}" == "false" ]]; then
    printf 'warning: guest network: FORWARD carries restrictive rules; guest traffic may be dropped before NAT applies\n' >&2
    printf 'warning: guest network: inspect %s -S FORWARD on the host and allow traffic from %s\n' \
      "${ipt}" "${bridge}" >&2
  fi

  if [[ "${forward_policy_drops}" == "true" ]]; then
    printf 'warning: guest network: the FORWARD policy is DROP; guest traffic may be dropped before NAT applies\n' >&2
    printf 'warning: guest network: add an accept rule for %s on the host, or run with --network none and route manually\n' \
      "${subnet}" >&2
  fi

  printf 'guest network: %s up, NAT %s out via %s (%s)\n' "${bridge}" "${subnet}" "${uplink}" "${ipt}"
}

# ipv4_network <address/prefix>
#
# Print the network address for a CIDR, e.g. 10.10.10.1/24 -> 10.10.10.0/24.
# Pure bash arithmetic rather than ipcalc, which is not installed, and rather
# than assuming /24, which would quietly produce a NAT rule matching the wrong
# range for any operator who chose a different prefix.
ipv4_network() {
  local cidr="$1" addr prefix mask
  local -a o

  [[ "${cidr}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]+)$ ]] || return 1

  o=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
  prefix="${BASH_REMATCH[5]}"
  ((prefix >= 0 && prefix <= 32)) || return 1

  addr=$(((o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]))
  if ((prefix == 0)); then
    mask=0
  else
    mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  fi
  addr=$((addr & mask))

  printf '%d.%d.%d.%d/%d\n' \
    $(((addr >> 24) & 255)) $(((addr >> 16) & 255)) $(((addr >> 8) & 255)) $((addr & 255)) "${prefix}"
}

# print_banner
#
# Identify what is about to start: the Proxmox VE version, the shim version,
# the architecture and the kernel the container is borrowing.
#
# Every other line this entrypoint prints describes a decision it made.  None
# of them says what this image *is*, which matters when the output arrives in
# an aggregated log next to three other containers, or in a bug report where
# the reporter is sure they were running the latest tag.  The kernel is the
# host's -- this image ships none -- so printing it names the one component of
# the running system that this repository did not build and cannot pin.
print_banner() {
  local pve shim
  pve="$(dpkg-query -W -f='${Version}' proxmox-ve 2> /dev/null || echo unknown)"
  shim="$(dpkg-query -W -f='${Version}' pve-container-shim 2> /dev/null || echo unknown)"

  printf 'Proxmox VE %s (shim %s) on %s, host kernel %s\n' \
    "${pve}" "${shim}" "$(uname -m)" "$(uname -r)"
}

# check_init_command
#
# Warn when the command being handed control is not a recognised init system.
#
# This image expects to run systemd as PID 1: pmxcfs, pveproxy and the rest are
# units, and nothing starts them otherwise.  Overriding the command is still
# legitimate -- `/bin/true` runs the whole configuration sequence and exits,
# which is how the capability contract gets exercised without a boot -- so this
# warns rather than refuses.  What it prevents is the case where an operator
# meant to boot the image, mistyped the path, and spent the next ten minutes
# wondering why the web UI never came up on a container that exited cleanly.
check_init_command() {
  case "$1" in
    /sbin/init | /usr/sbin/init | /lib/systemd/systemd | /usr/lib/systemd/systemd) ;;
    *)
      printf 'warning: %s is not a recognised init system\n' "$1" >&2
      printf 'warning: no Proxmox service will start unless systemd is PID 1\n' >&2
      ;;
  esac
}

main() {
  if [[ $# -eq 0 ]]; then
    printf 'error: no command given; expected an init system such as /sbin/init\n' >&2
    exit 64
  fi

  # PVE_DEBUG turns on shell tracing and nothing else.  It deliberately cannot
  # change an outcome: no probe verdict is softened, no required capability is
  # downgraded, no failure becomes a warning.  A debug switch that alters what
  # the program decides produces a system that only works when observed, and
  # leaves the operator debugging a configuration they will never run.
  if [[ "${PVE_DEBUG:-}" == "1" ]]; then
    printf 'debug: tracing enabled; policy outcomes are unaffected\n' >&2
    set -x
  fi

  print_banner
  check_init_command "$1"

  resolve_capabilities
  print_capability_summary
  apply_capability_gating

  configure_root_password
  configure_shm
  configure_timezone
  configure_tun
  configure_guest_network

  printf 'handing off to %s\n' "$1"
  exec "$@"
}

main "$@"
