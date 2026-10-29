#!/usr/bin/env bash
# Table-driven tests for toolchain-floor.sh.
#
# The behaviour under test is a version comparison that only matters on the one
# run where it changes -- the week upstream raises a floor past what the pinned
# Alpine branch can ever ship. Fixtures make that week reachable on demand, and
# the regression cases below are the two real crossings this repository has
# already lived through.
#
# Two layers, because they fail differently. The comparison cases inject both
# sides with --have/--need and assert an exit status. The reader cases source
# the script and call go_floor, rust_floor and alpine_version against fixtures,
# because an injected version proves nothing about the code that would have
# produced it: a reader that returned the empty string on every input would
# leave the whole injected suite green.
#
# Nothing here touches the network. `gh` and `curl` are shadowed on PATH by
# stubs that replay canned responses, including the failures.
set -euo pipefail

cd "$(dirname "${0}")/../.."

readonly SCRIPT=".github/scripts/toolchain-floor.sh"

# Brings in version_ge, the readers, and EXIT_UNMET/RC_ABSENT. Guarded against
# running main, so this defines functions and nothing else.
# shellcheck source=.github/scripts/toolchain-floor.sh
source "${SCRIPT}"

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

# Asserts a reader returned exactly what it should have. The empty string is a
# meaningful result here -- "no floor declared" -- so it is asserted, not
# treated as the absence of one.
expect_value() {
  local name="${1}" want="${2}" got="${3}"

  if [[ "${got}" == "${want}" ]]; then
    ok "${name}: -> '${got}'"
  else
    fail "${name}: -> '${got}', wanted '${want}'"
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

# Everything below shadows `gh` and `curl` with stubs. Done here rather than at
# the top of the file so the cases above provably ran against the real PATH and
# still needed no network.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "${STUB_DIR}"' EXIT
PATH="${STUB_DIR}:${PATH}"

# Replays one `gh api` response. The 404 and 5xx stderr lines are copied from
# real gh output, because the script distinguishes them by parsing exactly that.
cat > "${STUB_DIR}/gh" << 'STUB'
#!/usr/bin/env bash
case "${GH_STUB_STATUS:-200}" in
  200)
    cat "${GH_STUB_BODY}"
    ;;
  404)
    echo "gh: Not Found (HTTP 404)" >&2
    echo '{"message":"Not Found","status":"404"}'
    exit 1
    ;;
  *)
    echo "gh: Server Error (HTTP ${GH_STUB_STATUS})" >&2
    exit 1
    ;;
esac
STUB

# Serves a fixture APKINDEX tarball chosen by the repository segment of the URL,
# so the main-after-community fallback is a real second request. Exit 22 is what
# `curl -f` returns for an HTTP error, which is the failure being modelled.
cat > "${STUB_DIR}/curl" << 'STUB'
#!/usr/bin/env bash
url="${*: -1}"
case "${url}" in
  */community/*) fixture="${CURL_STUB_COMMUNITY:-}" ;;
  */main/*) fixture="${CURL_STUB_MAIN:-}" ;;
  *) exit 22 ;;
esac
[[ -n "${fixture}" && -f "${fixture}" ]] || exit 22
cat "${fixture}"
STUB

chmod +x "${STUB_DIR}/gh" "${STUB_DIR}/curl"

echo "::group::go.mod reader"
# The `go` directive and the `toolchain` directive disagree on purpose. Under
# GOTOOLCHAIN=local only the former produces "go.mod requires go >= X", so
# reading the wrong line would report a floor the build never enforces.
go_mod="$(
  cat << 'EOF'
module github.com/containers/podman/v6

go 1.26.0

toolchain go1.27.1
EOF
)"
expect_value "go.mod: go directive, not toolchain" "1.26.0" "$(go_floor "${go_mod}")"

# "go 1.26" is a legal directive and means 1.26.0; version_ge handles the
# missing component, but only if the reader passes it through unpadded.
expect_value "go.mod: two-component directive" "1.26" "$(go_floor 'go 1.26')"

# A go.mod with no `go` line leaves the floor unstated, and the empty string is
# what makes check() skip rather than compare against nothing.
expect_value "go.mod: no go directive" "" "$(go_floor 'module example.com/x')"

# Anchored at column zero: a commented or indented mention is not a directive.
expect_value "go.mod: commented directive ignored" "" "$(go_floor '// go 1.99')"
echo "::endgroup::"

echo "::group::Cargo.toml reader"
cargo_toml="$(
  cat << 'EOF'
[package]
name = "netavark"
edition = "2021"
rust-version = "1.88"

[dependencies]
clap = "4"
EOF
)"
expect_value "Cargo.toml: indented rust-version" "1.88" "$(rust_floor "${cargo_toml}")"

# rust-version is optional and absent more often than not. An unstated MSRV is
# not a floor of zero -- returning anything but empty here would invent one.
expect_value "Cargo.toml: no rust-version" "" "$(
  rust_floor '[package]
edition = "2021"'
)"

# A commented-out MSRV is not an MSRV.
expect_value "Cargo.toml: commented rust-version ignored" "" "$(
  rust_floor '# rust-version = "9.9"'
)"

# The first match wins, so a workspace stanza further down cannot override the
# package's own floor.
expect_value "Cargo.toml: first match wins" "1.88" "$(
  rust_floor 'rust-version = "1.88"
rust-version = "1.99"'
)"
echo "::endgroup::"

echo "::group::APKINDEX reader"
# Records are blank-line separated. go-md2man sits ahead of go on purpose: the
# package match has to be the whole P: value, or this fixture resolves `go` to
# go-md2man's 2.0.7 and the Go floor check silently compares the wrong numbers.
mkdir -p "${STUB_DIR}/community" "${STUB_DIR}/main"
printf '%s\n' \
  'C:Q1aaa' 'P:go-md2man' 'V:2.0.7-r0' '' \
  'C:Q1bbb' 'P:go' 'V:9.26.10-r0' '' \
  'C:Q1ccc' 'P:rust' 'V:9.96.1-r1' \
  > "${STUB_DIR}/community/APKINDEX"
printf '%s\n' \
  'C:Q1ddd' 'P:cargo' 'V:8.1.2-r3' \
  > "${STUB_DIR}/main/APKINDEX"
tar -czf "${STUB_DIR}/community.tar.gz" -C "${STUB_DIR}/community" APKINDEX
tar -czf "${STUB_DIR}/main.tar.gz" -C "${STUB_DIR}/main" APKINDEX

export CURL_STUB_COMMUNITY="${STUB_DIR}/community.tar.gz"
export CURL_STUB_MAIN="${STUB_DIR}/main.tar.gz"

expect_value "APKINDEX: exact name, -rN stripped" "9.26.10" "$(alpine_version v3.24 go)"

# Nothing in community, so this only resolves if the main fallback really fires.
expect_value "APKINDEX: falls back to main" "8.1.2" "$(alpine_version v3.24 cargo)"

# A package in neither repository is a failure, not an empty version that would
# compare as zero and report every floor unmet.
absent_status=0
alpine_version v3.24 nosuchpackage > /dev/null 2>&1 || absent_status=$?
if ((absent_status != 0)); then
  ok "APKINDEX: unknown package exits ${absent_status}"
else
  fail "APKINDEX: unknown package exited 0"
fi

# A CDN that does not answer must not look like a resolved version either.
fetch_status=0
CURL_STUB_COMMUNITY='' CURL_STUB_MAIN='' \
  alpine_version v3.24 go > /dev/null 2>&1 || fetch_status=$?
if ((fetch_status != 0)); then
  ok "APKINDEX: failed fetch exits ${fetch_status}"
else
  fail "APKINDEX: failed fetch exited 0"
fi
echo "::endgroup::"

echo "::group::upstream fetch"
# The case the fetch split exists for. A 404 is a fact about the repository --
# openSUSE/catatonit really has no go.mod -- and skipping is correct. A 502 is a
# fact about GitHub, and reporting it as a missing file would leave an unknown
# compiler floor looking like a deliberate decision.
printf '%s\n' 'module example.com/x' '' 'go 1.99.0' > "${STUB_DIR}/go.mod"
export GH_STUB_BODY="${STUB_DIR}/go.mod"

expect_fetch() {
  local name="${1}" status="${2}" want="${3}"
  local got=0

  GH_STUB_STATUS="${status}" "${SCRIPT}" check podman containers/podman v6.1.4 \
    --have 1.26.10 > /dev/null 2>&1 || got=$?

  if ((got == want)); then
    ok "${name}: HTTP ${status} -> exit ${got}"
  else
    fail "${name}: HTTP ${status} -> exit ${got}, wanted ${want}"
  fi
}

expect_fetch "absent manifest skips" 404 0
expect_fetch "server error is not a skip" 502 1

# And the floor actually read from the fetched file reaches the comparison: the
# fixture declares go 1.99.0, which Alpine will not ship this decade.
expect_fetch "fetched floor is compared" 200 "${EXIT_UNMET}"
echo "::endgroup::"

# A suite that asserts nothing passes silently. The count is declared, not
# derived, so deleting a case is a failure rather than a smaller green run.
readonly EXPECTED_CHECKS=33
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
