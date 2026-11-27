#!/usr/bin/env bash
# Read-only checks for the project's local Linux network lab.
# Run as root, for example: sudo ./network/verify.sh

set -uo pipefail

PASSED=0
FAILED=0

pass() {
  printf 'PASS: %s\n' "$1"
  PASSED=$((PASSED + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILED=$((FAILED + 1))
}

check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$description"
  else
    fail "$description"
  fi
}

namespace_exists() {
  ip -n "$1" link show dev lo
}

has_address() {
  local namespace="$1" interface="$2" expected="$3" addresses
  addresses="$(ip -n "$namespace" -o -4 address show dev "$interface" 2>/dev/null)" \
    || return 1
  [[ "$addresses" == *" inet $expected "* ]]
}

is_bridge() {
  local bridge="$1" bridges
  bridges="$(ip -o link show type bridge 2>/dev/null)" || return 1
  [[ "$bridges" == *": $bridge:"* ]]
}

has_default_gateway() {
  local namespace="$1" gateway="$2" interface="$3" routes
  routes="$(ip -n "$namespace" -4 route show default 2>/dev/null)" || return 1
  [[ "$routes" == *"via $gateway dev $interface"* ]]
}

has_static_route() {
  local namespace="$1" destination="$2" gateway="$3" interface="$4" routes
  routes="$(ip -n "$namespace" -4 route show "$destination" 2>/dev/null)" || return 1
  [[ "$routes" == *"$destination via $gateway dev $interface"* ]]
}

forwarding_enabled() {
  local namespace="$1" value
  value="$(ip netns exec "$namespace" sysctl -n net.ipv4.ip_forward 2>/dev/null)" \
    || return 1
  [[ "$value" == 1 ]]
}

can_ping() {
  local source_namespace="$1" destination="$2"
  ip netns exec "$source_namespace" ping -n -c 1 -W 1 "$destination"
}

print_summary() {
  printf '\nSummary: %d passed, %d failed\n' "$PASSED" "$FAILED"
}

main() {
  local tool

  if [[ ${EUID} -ne 0 ]]; then
    fail "run as root (for example: sudo ./network/verify.sh)"
    print_summary
    return 1
  fi

  for tool in ip ping sysctl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "required command '$tool' is missing"
      print_summary
      return 1
    fi
  done

  check "namespace client exists" namespace_exists client
  check "namespace lb exists" namespace_exists lb
  check "namespace r1 exists" namespace_exists r1
  check "namespace r2 exists" namespace_exists r2
  check "namespace backend1 exists" namespace_exists backend1
  check "namespace backend2 exists" namespace_exists backend2
  check "namespace backend3 exists" namespace_exists backend3

  check "client has 10.10.1.10/24 on eth0" has_address client eth0 10.10.1.10/24
  check "lb has 10.10.1.20/24 on eth0" has_address lb eth0 10.10.1.20/24
  check "r1 has 10.10.1.1/24 on eth0" has_address r1 eth0 10.10.1.1/24
  check "r1 has 10.10.12.1/30 on eth1" has_address r1 eth1 10.10.12.1/30
  check "r2 has 10.10.12.2/30 on eth0" has_address r2 eth0 10.10.12.2/30
  check "r2 has 10.10.3.1/24 on eth1" has_address r2 eth1 10.10.3.1/24
  check "backend1 has 10.10.3.11/24 on eth0" has_address backend1 eth0 10.10.3.11/24
  check "backend2 has 10.10.3.12/24 on eth0" has_address backend2 eth0 10.10.3.12/24
  check "backend3 has 10.10.3.13/24 on eth0" has_address backend3 eth0 10.10.3.13/24

  check "bridge br-client exists and is a bridge" is_bridge br-client
  check "bridge br-backend exists and is a bridge" is_bridge br-backend

  check "client default gateway is 10.10.1.1 via eth0" has_default_gateway client 10.10.1.1 eth0
  check "lb default gateway is 10.10.1.1 via eth0" has_default_gateway lb 10.10.1.1 eth0
  check "backend1 default gateway is 10.10.3.1 via eth0" has_default_gateway backend1 10.10.3.1 eth0
  check "backend2 default gateway is 10.10.3.1 via eth0" has_default_gateway backend2 10.10.3.1 eth0
  check "backend3 default gateway is 10.10.3.1 via eth0" has_default_gateway backend3 10.10.3.1 eth0

  check "r1 route to 10.10.3.0/24 uses 10.10.12.2 via eth1" \
    has_static_route r1 10.10.3.0/24 10.10.12.2 eth1
  check "r2 route to 10.10.1.0/24 uses 10.10.12.1 via eth0" \
    has_static_route r2 10.10.1.0/24 10.10.12.1 eth0

  check "IPv4 forwarding is enabled in r1" forwarding_enabled r1
  check "IPv4 forwarding is enabled in r2" forwarding_enabled r2

  check "client can reach lb at 10.10.1.20" can_ping client 10.10.1.20
  check "client can reach backend1 at 10.10.3.11" can_ping client 10.10.3.11
  check "client can reach backend2 at 10.10.3.12" can_ping client 10.10.3.12
  check "client can reach backend3 at 10.10.3.13" can_ping client 10.10.3.13
  check "lb can reach backend1 at 10.10.3.11" can_ping lb 10.10.3.11
  check "lb can reach backend2 at 10.10.3.12" can_ping lb 10.10.3.12
  check "lb can reach backend3 at 10.10.3.13" can_ping lb 10.10.3.13

  print_summary
  (( FAILED == 0 ))
}

main "$@"
