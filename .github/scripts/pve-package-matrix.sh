#!/usr/bin/env bash
#
# Resolve the proxmox-ve dependency closure from the real APT indices and emit
# the Phase 1 classification matrix.
#
# Everything here is derived from primary sources at run time. Nothing is
# hard-coded from memory, because the whole point of the exercise is to answer
# "which packages actually exist on arm64" with data rather than with packaging
# convention. Re-running this after an upstream publish is how version drift is
# detected.
#
# Three artefacts are produced under --out-dir:
#
#   pve-package-matrix.json   one object per closure member
#   pve-systemd-units.json    every static unit shipped by a closure member
#   pve-package-matrix.md     the human-readable matrix
#
# The unit inventory exists because the container-hostility work needs to know
# which units to mask and which service a capability gates, and the only way to
# know which package ships `watchdog-mux.service` is to look. The package set
# scanned is derived from the closure computed here, never from a hand-written
# list: a fixed list silently misses units shipped by packages nobody thought
# of, which is exactly the failure mode that makes a mask incomplete.
#
# Unpacking every closure member is expensive, so it is opt-in via --units.
set -euo pipefail

readonly PVE_BASE="http://download.proxmox.com/debian/pve"
readonly DEBIAN_BASE="http://deb.debian.org/debian"
readonly SUITE="trixie"
readonly PVE_COMPONENT="pve-no-subscription"
readonly DEBIAN_COMPONENT="main"
readonly ROOT_PACKAGE="proxmox-ve"
# Satisfied by pve-container-shim via Provides/Conflicts, so this node and
# everything reachable only through it never enters the image.
readonly STUB_PACKAGE="proxmox-default-kernel"
readonly ARCHES=(amd64 arm64)

# The reference architecture for closure resolution. The closure is computed
# once, from amd64, because amd64 is the complete index; arm64 availability is
# then reported per member. Computing two closures and diffing them would hide
# the interesting case, which is a package that is *in* the closure and *absent*
# on arm64 -- such a package simply would not appear in an arm64-derived
# closure, and its absence would read as "not needed" rather than "missing".
readonly REFERENCE_ARCH="amd64"

work_dir="${PVE_MATRIX_WORKDIR:-.pve-matrix}"
out_dir="docs"
want_units="no"
offline="no"

usage() {
  cat << 'EOF'
Usage: pve-package-matrix.sh [options]

  --out-dir DIR    where to write the artefacts (default: docs)
  --work-dir DIR   scratch and download cache (default: .pve-matrix)
  --units          also unpack every closure member and inventory its units
  --offline        fail rather than fetch; use whatever is already cached
  -h, --help       this text
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --work-dir)
      work_dir="$2"
      shift 2
      ;;
    --units)
      want_units="yes"
      shift
      ;;
    --offline)
      offline="yes"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for tool in curl gunzip awk jq dpkg; do
  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "required tool not found: ${tool}" >&2
    exit 3
  fi
done

mkdir -p "${work_dir}" "${out_dir}"

# ── Fetch ────────────────────────────────────────────────────────────────────
#
# Both the PVE component and Debian main are needed. Roughly two thirds of the
# closure resolves outside the Proxmox repository, and a dependency satisfied by
# Debian is a materially different finding from one that is missing altogether.

fetch_index() {
  local url="$1" dest="$2"

  if [[ -s "${dest}" ]]; then
    return 0
  fi
  if [[ "${offline}" == "yes" ]]; then
    echo "offline and no cached index at ${dest}" >&2
    return 1
  fi

  echo "fetching ${url}" >&2
  curl -fsSL "${url}" | gunzip > "${dest}"
}

for arch in "${ARCHES[@]}"; do
  fetch_index \
    "${PVE_BASE}/dists/${SUITE}/${PVE_COMPONENT}/binary-${arch}/Packages.gz" \
    "${work_dir}/pve-${arch}.Packages"
  fetch_index \
    "${DEBIAN_BASE}/dists/${SUITE}/${DEBIAN_COMPONENT}/binary-${arch}/Packages.gz" \
    "${work_dir}/debian-${arch}.Packages"
done

# ── Flatten ──────────────────────────────────────────────────────────────────
#
# Every stanza becomes one tab-separated record: name, version, arch, origin,
# depends, pre-depends, provides, filename, index. Empty fields are emitted as
# "-" so that field splitting stays positional; a genuinely empty Depends and a
# missing column are otherwise indistinguishable.
#
# The trailing "index" field records which binary-<arch>/Packages file the
# stanza was read from, and it is the only sound basis for deciding whether a
# package is installable on a given architecture. The `Architecture:` field is
# not: an `Architecture: all` package still has to be listed in
# binary-arm64/Packages to be installable on arm64, and Proxmox publishes
# several `all` packages -- ifupdown2 among them -- into the amd64 index only.
# Inferring availability from `Architecture: all` erases exactly the gaps this
# script exists to find.

flatten_index() {
  local src="$1" origin="$2" from_index="$3"

  awk -v origin="${origin}" -v from_index="${from_index}" '
    function flush() {
      if (name == "") { return }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        name, version, arch, origin,
        (depends    == "" ? "-" : depends),
        (predepends == "" ? "-" : predepends),
        (provides   == "" ? "-" : provides),
        (filename   == "" ? "-" : filename),
        from_index
      name = ""; version = ""; arch = ""
      depends = ""; predepends = ""; provides = ""; filename = ""
    }
    /^Package: /      { flush(); name       = substr($0, 10); next }
    /^Version: /      { version    = substr($0, 10); next }
    /^Architecture: / { arch       = substr($0, 15); next }
    /^Depends: /      { depends    = substr($0, 10); next }
    /^Pre-Depends: /  { predepends = substr($0, 14); next }
    /^Provides: /     { provides   = substr($0, 11); next }
    /^Filename: /     { filename   = substr($0, 11); next }
    END { flush() }
  ' "${src}"
}

# ── Newest-version selection ─────────────────────────────────────────────────
#
# The Proxmox indices accumulate history: the amd64 component carries several
# years of superseded versions of the same package. Only the newest matters, and
# "newest" is dpkg's ordering, not sort's -- the two disagree on epochs, tildes
# and the +pmxNN suffixes that appear throughout this closure.
#
# This runs over the Proxmox records only. Debian main publishes exactly one
# version per package per suite, so paying dpkg's process-per-comparison cost
# across sixty thousand Debian stanzas would buy nothing.

dedupe_newest() {
  local src="$1"
  local -A best=()
  local name version from_index rest key

  # Keyed on name plus source index, not name plus `Architecture:`. An
  # `Architecture: all` package appears once per index it is published in, and
  # collapsing those into a single record would discard the very fact that
  # per-arch availability is derived from.
  while IFS=$'\t' read -r name version from_index; do
    key="${name}|${from_index}"
    if [[ -z "${best[${key}]:-}" ]]; then
      best["${key}"]="${version}"
    elif dpkg --compare-versions "${version}" gt "${best[${key}]}"; then
      best["${key}"]="${version}"
    fi
  done < <(cut -f 1,2,9 "${src}")

  while IFS=$'\t' read -r name version rest; do
    from_index="${rest##*$'\t'}"
    key="${name}|${from_index}"
    if [[ "${best[${key}]:-}" == "${version}" ]]; then
      printf '%s\t%s\t%s\n' "${name}" "${version}" "${rest}"
    fi
  done < "${src}"
}

echo "flattening indices" >&2

: > "${work_dir}/pve.raw.tsv"
: > "${work_dir}/debian.tsv"
for arch in "${ARCHES[@]}"; do
  flatten_index "${work_dir}/pve-${arch}.Packages" "proxmox" "${arch}" >> "${work_dir}/pve.raw.tsv"
  flatten_index "${work_dir}/debian-${arch}.Packages" "debian" "${arch}" >> "${work_dir}/debian.tsv"
done

dedupe_newest "${work_dir}/pve.raw.tsv" | sort -u > "${work_dir}/pve.tsv"
cat "${work_dir}/pve.tsv" "${work_dir}/debian.tsv" > "${work_dir}/all.tsv"

echo "proxmox: $(wc -l < "${work_dir}/pve.raw.tsv" | tr -d ' ') stanzas, $(wc -l < "${work_dir}/pve.tsv" | tr -d ' ') after newest-version selection" >&2
echo "debian:  $(wc -l < "${work_dir}/debian.tsv" | tr -d ' ') stanzas" >&2

# ── Closure ──────────────────────────────────────────────────────────────────
#
# Breadth-first over Depends and Pre-Depends, done entirely inside awk. Doing it
# in the shell would mean re-scanning a two-hundred-thousand-line table once per
# dependency edge; the graph fits in memory comfortably and the traversal is the
# only part of this script whose cost is superlinear in the index size.
#
# A Depends field is a comma-separated list of alternative groups. Within a
# group the alternatives are `|`-separated, each optionally carrying a version
# constraint in parentheses, an architecture qualifier after a colon, and a
# build-profile restriction in angle brackets. Only the bare name is wanted.
#
# Alternatives resolve to the first one that actually exists, preferring Proxmox
# over Debian, which is what apt does when both offer a candidate and the
# Proxmox suite outranks Debian. Virtual packages are followed through Provides
# so that `mail-transport-agent` lands on postfix instead of reading as missing.
# Where nothing resolves, the first literal is kept and marked `unresolved`, so
# a genuinely missing dependency is visible rather than silently dropped.

echo "resolving the ${ROOT_PACKAGE} closure" >&2

# The program is held in a variable because the traversal is run twice: once
# in full, and once stopping at the stubbed kernel metapackage, so that the
# packages reachable only through the stub can be identified by difference
# rather than by a hand-written list that would rot.
# shellcheck disable=SC2016  # $1..$9 are awk fields; expansion is not wanted.
closure_program='
  function bare(spec,   s) {
    s = spec
    sub(/\(.*/, "", s)
    sub(/</,    "", s)
    sub(/:.*/,  "", s)
    gsub(/[ \t]+/, "", s)
    return s
  }

  # Field 9 is the binary-<arch>/Packages file the stanza came from, which is
  # the only sound availability signal. The `Architecture:` field is not: an
  # `Architecture: all` package still has to be listed in binary-arm64/Packages
  # to be installable there, and Proxmox publishes several `all` packages into
  # the amd64 index only.
  $9 != ref { next }

  {
    key = $4 SUBSEP $1
    exists[key] = 1

    {
      d = ($5 == "-" ? "" : $5)
      p = ($6 == "-" ? "" : $6)
      if (p != "") { d = (d == "" ? p : d ", " p) }
      depends[key] = d
    }

    if ($7 != "-") {
      n = split($7, provided, ",")
      for (i = 1; i <= n; i++) {
        provider[$4 SUBSEP bare(provided[i])] = $1
      }
    }
  }

  END {
    head = 1; tail = 1
    queue[tail++] = root
    seen[root] = 1
    how[root] = "root"

    while (head < tail) {
      current = queue[head++]

      # A stubbed node is satisfied by pve-container-shim, so nothing below it
      # is ever installed. Expanding it would manufacture phantom arm64 gaps
      # and phantom skew for packages that never enter the image.
      if (prune != "" && current == prune) { continue }

      raw = ""
      if (("proxmox" SUBSEP current) in depends) {
        raw = depends["proxmox" SUBSEP current]
      } else if (("debian" SUBSEP current) in depends) {
        raw = depends["debian" SUBSEP current]
      }
      if (raw == "") { continue }

      ngroups = split(raw, groups, ",")
      for (g = 1; g <= ngroups; g++) {
        if (bare(groups[g]) == "") { continue }

        nalt = split(groups[g], alts, "|")
        child = ""; resolution = ""

        for (a = 1; a <= nalt && child == ""; a++) {
          b = bare(alts[a])
          if (b != "" && (("proxmox" SUBSEP b) in exists)) {
            child = b; resolution = "proxmox"
          }
        }
        for (a = 1; a <= nalt && child == ""; a++) {
          b = bare(alts[a])
          if (b != "" && (("debian" SUBSEP b) in exists)) {
            child = b; resolution = "debian"
          }
        }
        for (a = 1; a <= nalt && child == ""; a++) {
          b = bare(alts[a])
          if (b != "" && (("proxmox" SUBSEP b) in provider)) {
            child = provider["proxmox" SUBSEP b]; resolution = "virtual-proxmox"
          } else if (b != "" && (("debian" SUBSEP b) in provider)) {
            child = provider["debian" SUBSEP b]; resolution = "virtual-debian"
          }
        }
        if (child == "") {
          child = bare(alts[1]); resolution = "unresolved"
          if (child == "") { continue }
        }

        if (!(child in parents)) {
          parents[child] = current
        } else if (index(" " parents[child] " ", " " current " ") == 0) {
          parents[child] = parents[child] " " current
        }

        if (!(child in seen)) {
          seen[child] = 1
          how[child] = resolution
          queue[tail++] = child
        }
      }
    }

    for (p in seen) {
      printf "%s\t%s\t%s\n", p, how[p], (p in parents ? parents[p] : "")
    }
  }
'

run_closure() {
  awk -F '\t' -v root="${ROOT_PACKAGE}" -v ref="${REFERENCE_ARCH}" -v prune="$1" \
    "${closure_program}" "${work_dir}/all.tsv" | sort
}

run_closure "" > "${work_dir}/closure.tsv"
run_closure "${STUB_PACKAGE}" | cut -f 1 > "${work_dir}/closure.installed.names"

closure_size="$(wc -l < "${work_dir}/closure.tsv" | tr -d ' ')"
echo "closure contains ${closure_size} packages" >&2

# Restrict the record table to closure members so that the per-package lookups
# below scan hundreds of lines rather than hundreds of thousands.
cut -f 1 "${work_dir}/closure.tsv" | sort -u > "${work_dir}/closure.names"
awk -F '\t' 'NR == FNR { want[$1] = 1; next } ($1 in want)' \
  "${work_dir}/closure.names" "${work_dir}/all.tsv" > "${work_dir}/closure.tsv.records"

# ── Classification ───────────────────────────────────────────────────────────
#
# Two independent axes, deliberately not collapsed into one verdict:
#
#   arch-hostile      unavailable or behaviourally different on arm64 alone.
#                     Maps to one of the five documented upstream caveats.
#   container-hostile breaks because it is in a container, on any architecture.
#
# The second column is the one under test. If it is populated and the first is
# not, the working hypothesis holds: the hard problems are arch-independent.
#
# The first axis is derived from the indices -- availability and version skew
# are facts the data can answer. The second cannot be derived from packaging
# metadata at all, so it comes from the enumerated table below. That table is
# the script's only editorial content and is kept here, in one place, so it can
# be argued with rather than discovered scattered through the output.

container_hostile_reason() {
  case "$1" in
    pve-cluster)
      echo "pmxcfs mounts /etc/pve through FUSE; needs /dev/fuse and CAP_SYS_ADMIN"
      ;;
    ifupdown2)
      echo "owns /etc/network/interfaces and bridge state the container does not have"
      ;;
    lxcfs)
      echo "libfuse mount at /var/lib/lxcfs, behind ConditionVirtualization=!container"
      ;;
    corosync | libknet1t64)
      echo "cluster membership over UDP; needs stable node identity"
      ;;
    pve-ha-manager)
      echo "ships watchdog-mux.service, which expects a hardware watchdog device"
      ;;
    proxmox-default-kernel | proxmox-kernel-helper | pve-firmware)
      echo "kernel and firmware management is inert; the host kernel is already running"
      ;;
    systemd | systemd-sysv | udev)
      echo "PID 1 and device management behave differently under a container runtime"
      ;;
    open-iscsi | multipath-tools | smartmontools | lvm2 | dmsetup)
      echo "expects direct block-device and udev access"
      ;;
    postfix)
      echo "expects to own the host mail spool and a resolvable FQDN"
      ;;
    pve-qemu-kvm | qemu-server)
      echo "guest execution needs /dev/kvm exposed and usable"
      ;;
    pve-container | lxc-pve)
      echo "nested LXC needs cgroup v2 delegation and an AppArmor stack"
      ;;
    *)
      echo ""
      ;;
  esac
}

lookup_newest() {
  local name="$1" arch="$2" origin="$3"
  local newest="" candidate

  while read -r candidate; do
    if [[ -z "${candidate}" ]]; then
      continue
    fi
    if [[ -z "${newest}" ]] || dpkg --compare-versions "${candidate}" gt "${newest}"; then
      newest="${candidate}"
    fi
  done < <(
    awk -F '\t' -v n="${name}" -v a="${arch}" -v o="${origin}" \
      '$1 == n && $4 == o && $9 == a { print $2 }' \
      "${work_dir}/closure.tsv.records"
  )

  printf '%s' "${newest}"
}

echo "classifying" >&2
: > "${work_dir}/matrix.ndjson"

while IFS=$'\t' read -r package resolved_as package_parents; do
  amd64_version="$(lookup_newest "${package}" "amd64" "proxmox")"
  amd64_origin="proxmox"
  if [[ -z "${amd64_version}" ]]; then
    amd64_version="$(lookup_newest "${package}" "amd64" "debian")"
    amd64_origin="debian"
  fi
  if [[ -z "${amd64_version}" ]]; then
    amd64_origin="none"
  fi

  arm64_version="$(lookup_newest "${package}" "arm64" "proxmox")"
  arm64_origin="proxmox"
  if [[ -z "${arm64_version}" ]]; then
    arm64_version="$(lookup_newest "${package}" "arm64" "debian")"
    arm64_origin="debian"
  fi
  if [[ -z "${arm64_version}" ]]; then
    arm64_origin="none"
  fi

  arch_field="$(
    awk -F '\t' -v n="${package}" '$1 == n { print $3 }' \
      "${work_dir}/closure.tsv.records" | sort -u | paste -sd '/' -
  )"

  # A Debian binNMU is a per-architecture rebuild of identical source, marked
  # with a +bN suffix. Reporting those as divergence buries the handful of real
  # skews under twenty entries of routine archive bookkeeping, so the comparison
  # is made on the source version and the binNMU difference is recorded
  # separately rather than discarded.
  skew="none"
  binnmu_only="no"
  if [[ -n "${amd64_version}" && -n "${arm64_version}" ]]; then
    amd64_source="${amd64_version%+b*}"
    arm64_source="${arm64_version%+b*}"
    if dpkg --compare-versions "${amd64_source}" gt "${arm64_source}"; then
      skew="arm64-behind"
    elif dpkg --compare-versions "${arm64_source}" gt "${amd64_source}"; then
      skew="arm64-ahead"
    elif [[ "${amd64_version}" != "${arm64_version}" ]]; then
      binnmu_only="yes"
    fi
  fi

  # Different repository, byte-identical version. Proxmox mirrors a handful of
  # stock Debian packages for its own installer; surfacing that keeps a future
  # divergence visible instead of letting it appear as a sudden new skew.
  mixed_origin="no"
  if [[ "${amd64_origin}" != "${arm64_origin}" &&
    "${amd64_origin}" != "none" && "${arm64_origin}" != "none" ]]; then
    mixed_origin="yes"
  fi

  arch_hostile=""
  if [[ -n "${amd64_version}" && -z "${arm64_version}" ]]; then
    arch_hostile="not published for arm64"
  elif [[ "${skew}" != "none" ]]; then
    arch_hostile="version skew (${skew})"
  fi

  container_hostile="$(container_hostile_reason "${package}")"
  affects_both="no"
  if [[ -n "${container_hostile}" ]]; then
    affects_both="yes"
  fi

  # Disposition is mechanical. Anything needing judgement resolves to `review`
  # so that it surfaces in the matrix instead of being decided silently here.
  if [[ "${amd64_origin}" == "none" && "${arm64_origin}" == "none" ]]; then
    disposition="unresolved"
  elif [[ "${package}" == "${STUB_PACKAGE}" ]]; then
    disposition="stub"
  elif ! grep -qxF "${package}" "${work_dir}/closure.installed.names"; then
    disposition="not-installed-stubbed"
  elif [[ "${amd64_origin}" == "proxmox" && "${arm64_origin}" == "none" ]]; then
    disposition="build-and-publish"
  elif [[ "${amd64_origin}" == "proxmox" && "${arm64_origin}" == "debian" &&
    "${skew}" != "none" ]]; then
    # Proxmox publishes an `Architecture: all` package into the amd64 index
    # only, so on arm64 the dependency still resolves but silently falls back
    # to Debian at an older version. That is a cross-architecture divergence
    # wearing the costume of a satisfied dependency, and it is invisible to any
    # check that only asks whether the package installs. Building the Proxmox
    # version once and serving it to both arches is the only disposition that
    # preserves parity.
    disposition="build-and-publish"
  elif [[ "${amd64_origin}" == "none" || "${arm64_origin}" == "none" ]]; then
    disposition="review"
  elif [[ "${skew}" != "none" ]]; then
    disposition="install-with-known-skew"
  elif [[ "${amd64_origin}" == "proxmox" ]]; then
    disposition="install-from-proxmox"
  else
    disposition="install-from-debian"
  fi

  jq -c -n \
    --arg package "${package}" \
    --arg arch_field "${arch_field:-unknown}" \
    --arg amd64 "${amd64_version}" \
    --arg arm64 "${arm64_version}" \
    --arg amd64_origin "${amd64_origin}" \
    --arg arm64_origin "${arm64_origin}" \
    --arg skew "${skew}" \
    --arg binnmu_only "${binnmu_only}" \
    --arg mixed_origin "${mixed_origin}" \
    --arg arch_hostile "${arch_hostile}" \
    --arg container_hostile "${container_hostile}" \
    --arg affects_both "${affects_both}" \
    --arg resolved_as "${resolved_as}" \
    --arg package_parents "${package_parents}" \
    --arg disposition "${disposition}" \
    '{
      package: $package,
      arch_field: $arch_field,
      versions: {
        amd64: (if $amd64 == "" then [] else [$amd64] end),
        arm64: (if $arm64 == "" then [] else [$arm64] end)
      },
      origin: { amd64: $amd64_origin, arm64: $arm64_origin },
      skew: $skew,
      binnmu_only: ($binnmu_only == "yes"),
      mixed_origin: ($mixed_origin == "yes"),
      arch_hostile: (if $arch_hostile == "" then null else $arch_hostile end),
      container_hostile: (if $container_hostile == "" then null else $container_hostile end),
      affects_both_arches: ($affects_both == "yes"),
      resolved_as: $resolved_as,
      in_closure_via: ($package_parents | split(" ") | map(select(length > 0))),
      disposition: $disposition
    }' >> "${work_dir}/matrix.ndjson"
done < "${work_dir}/closure.tsv"

jq -s 'sort_by(.package)' "${work_dir}/matrix.ndjson" > "${out_dir}/pve-package-matrix.json"
echo "wrote ${out_dir}/pve-package-matrix.json" >&2

# ── Healthcheck tooling probe ────────────────────────────────────────────────
#
# The image healthcheck needs an HTTP client. Whether one is already present is
# a property of the closure, not something to assume: installing curl to satisfy
# a healthcheck is a defensible Debian-sourced addition, but doing so without
# noticing it was already there is waste, and assuming it is there when it is
# not produces a healthcheck that reports unhealthy for the wrong reason.

for candidate in curl wget ca-certificates openssl; do
  if jq -e --arg c "${candidate}" 'any(.[]; .package == $c)' \
    "${out_dir}/pve-package-matrix.json" > /dev/null; then
    echo "closure probe: ${candidate} IS in the closure" >&2
  else
    echo "closure probe: ${candidate} is NOT in the closure" >&2
  fi
done

# ── Unit inventory ───────────────────────────────────────────────────────────

if [[ "${want_units}" == "yes" ]]; then
  if ! command -v dpkg-deb > /dev/null 2>&1; then
    echo "--units requires dpkg-deb" >&2
    exit 3
  fi

  echo "inventorying systemd units across the closure" >&2

  deb_cache="${work_dir}/deb"
  unpack_root="${work_dir}/unpack"
  mkdir -p "${deb_cache}"
  rm -rf "${unpack_root}"
  mkdir -p "${unpack_root}"

  : > "${work_dir}/units.ndjson"

  while read -r package; do
    located="$(
      awk -F '\t' -v n="${package}" -v a="${REFERENCE_ARCH}" \
        '$1 == n && $9 == a && $8 != "-" { print $4 "\t" $8 }' \
        "${work_dir}/closure.tsv.records" | sort | head -n 1
    )"
    if [[ -z "${located}" ]]; then
      continue
    fi

    origin="${located%%$'\t'*}"
    path="${located##*$'\t'}"
    local_deb="${deb_cache}/$(basename "${path}")"

    if [[ ! -s "${local_deb}" ]]; then
      if [[ "${offline}" == "yes" ]]; then
        continue
      fi
      if [[ "${origin}" == "proxmox" ]]; then
        url="${PVE_BASE}/${path}"
      else
        url="${DEBIAN_BASE}/${path}"
      fi
      if ! curl -fsSL -o "${local_deb}" "${url}"; then
        echo "warning: could not fetch ${url}" >&2
        rm -f "${local_deb}"
        continue
      fi
    fi

    target="${unpack_root}/${package}"
    rm -rf "${target}"
    mkdir -p "${target}"
    if ! dpkg-deb -x "${local_deb}" "${target}" 2> /dev/null; then
      echo "warning: could not unpack ${local_deb}" >&2
      rm -rf "${target}"
      continue
    fi

    while read -r unit; do
      if [[ -z "${unit}" ]]; then
        continue
      fi
      jq -c -n \
        --arg package "${package}" \
        --arg unit "$(basename "${unit}")" \
        --arg path "${unit#"${target}"}" \
        --arg requires "$(sed -n 's/^Requires=//p' "${unit}" | paste -sd ' ' -)" \
        --arg wants "$(sed -n 's/^Wants=//p' "${unit}" | paste -sd ' ' -)" \
        --arg after "$(sed -n 's/^After=//p' "${unit}" | paste -sd ' ' -)" \
        --arg before "$(sed -n 's/^Before=//p' "${unit}" | paste -sd ' ' -)" \
        --arg binds_to "$(sed -n 's/^BindsTo=//p' "${unit}" | paste -sd ' ' -)" \
        --arg conditions "$(grep -E '^Condition[A-Za-z]+=' "${unit}" | paste -sd ' ' -)" \
        --arg wanted_by "$(sed -n 's/^WantedBy=//p' "${unit}" | paste -sd ' ' -)" \
        '{
          package: $package,
          unit: $unit,
          path: $path,
          requires:   ($requires   | split(" ") | map(select(length > 0))),
          wants:      ($wants      | split(" ") | map(select(length > 0))),
          after:      ($after      | split(" ") | map(select(length > 0))),
          before:     ($before     | split(" ") | map(select(length > 0))),
          binds_to:   ($binds_to   | split(" ") | map(select(length > 0))),
          conditions: ($conditions | split(" ") | map(select(length > 0))),
          wanted_by:  ($wanted_by  | split(" ") | map(select(length > 0)))
        }' >> "${work_dir}/units.ndjson"
    done < <(
      find "${target}/lib/systemd/system" "${target}/usr/lib/systemd/system" \
        -maxdepth 1 -type f \
        \( -name '*.service' -o -name '*.target' -o -name '*.socket' \
        -o -name '*.timer' -o -name '*.path' \) 2> /dev/null | sort
    )

    rm -rf "${target}"
  done < "${work_dir}/closure.names"

  jq -s --arg ref "${REFERENCE_ARCH}" '{
    scope: "Static unit files shipped by closure members. Units synthesised at run time by systemd generators are NOT represented; treat this inventory as a lower bound.",
    reference_arch: $ref,
    units: (. | sort_by(.package, .unit))
  }' "${work_dir}/units.ndjson" > "${out_dir}/pve-systemd-units.json"
  echo "wrote ${out_dir}/pve-systemd-units.json ($(jq '.units | length' "${out_dir}/pve-systemd-units.json") units)" >&2
fi

# ── Markdown ─────────────────────────────────────────────────────────────────

intro_fragment="${out_dir}/pve-package-matrix.intro.md"
related_fragment="${out_dir}/pve-package-matrix.related.md"

{
  cat << EOF
<!-- Generated by .github/scripts/pve-package-matrix.sh. Do not edit by hand. -->

# Proxmox VE package matrix

Resolved from the live APT indices on $(date -u '+%Y-%m-%d'), rooted at
\`${ROOT_PACKAGE}\` and closed over \`Depends\` and \`Pre-Depends\`.

- Proxmox: \`${PVE_BASE}\` suite \`${SUITE}\` component \`${PVE_COMPONENT}\`
- Debian: \`${DEBIAN_BASE}\` suite \`${SUITE}\` component \`${DEBIAN_COMPONENT}\`
- Closure resolved against \`${REFERENCE_ARCH}\`, then evaluated for both arches.

Closure size: **$(jq 'length' "${out_dir}/pve-package-matrix.json")** packages.
EOF

  # The analysis is hand-written and version-controlled separately, because this
  # document is regenerated wholesale and anything written into it directly would
  # be destroyed on the next run. Splicing the fragment keeps the deliverable a
  # single file, as the brief requires, without making the prose disposable.
  if [[ -f "${intro_fragment}" ]]; then
    printf '\n'
    cat "${intro_fragment}"
  else
    echo "note: ${intro_fragment} is absent; emitting the table without the analysis" >&2
  fi

  cat << EOF

## Package matrix

| package | amd64 | arm64 | \`Architecture:\` | arch-hostile | container-hostile | both | notes | disposition |
|---|---|---|---|---|---|---|---|---|
EOF

  jq -r '
    .[] |
    "| `\(.package)` "
    + "| \(if (.versions.amd64 | length) > 0 then .versions.amd64[0] + " (" + .origin.amd64 + ")" else "**absent**" end) "
    + "| \(if (.versions.arm64 | length) > 0 then .versions.arm64[0] + " (" + .origin.arm64 + ")" else "**absent**" end) "
    + "| \(.arch_field) "
    + "| \(.arch_hostile // "-") "
    + "| \(.container_hostile // "-") "
    + "| \(if .affects_both_arches then "yes" else "-" end) "
    + "| \([ (if .mixed_origin then "mixed-origin" else empty end),
            (if .binnmu_only then "binNMU-only" else empty end) ]
        | if length > 0 then join(", ") else "-" end) "
    + "| \(.disposition) |"
  ' "${out_dir}/pve-package-matrix.json"

  # Every document in docs/ ends with a cross-link block. It has to be spliced
  # after the table rather than carried in the intro fragment, because the rows
  # are the last thing the generator emits.
  if [[ -f "${related_fragment}" ]]; then
    cat "${related_fragment}"
  else
    echo "note: ${related_fragment} is absent; emitting the table without cross-links" >&2
  fi
} > "${out_dir}/pve-package-matrix.md"

echo "wrote ${out_dir}/pve-package-matrix.md" >&2
