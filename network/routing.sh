#!/usr/bin/env bash
# Configure routes for the project's local Linux network lab. Run as root, for
# example: sudo ./network/routing.sh

set -Eeuo pipefail

fail() {
  printf 'routing: %s\n' "$*" >&2
  exit 1
}

require_root_and_tools() {
  [[ ${EUID} -eq 0 ]] || fail "run as root (for example: sudo ./network/routing.sh)"
  command -v ip >/dev/null 2>&1 || fail "the ip command is missing; install iproute2 first"
  command -v sysctl >/dev/null 2>&1 || fail "the sysctl command is missing"
  ip netns list >/dev/null 2>&1 || fail "cannot inspect named network namespaces"
}

require_namespace() {
  local namespace="$1"
  ip netns exec "$namespace" true >/dev/null 2>&1 \
    || fail "namespace '$namespace' is missing; run ./network/setup.sh first"
}

require_address() {
  local namespace="$1" interface="$2" address="$3" addresses
  addresses="$(ip -n "$namespace" -o -4 address show dev "$interface")" \
    || fail "interface '$interface' is missing in namespace '$namespace'"
  [[ "$addresses" == *" inet $address "* ]] \
    || fail "namespace '$namespace' interface '$interface' must have address $address"
}

preflight_topology() {
  local namespace
  for namespace in client lb r1 r2 backend1 backend2 backend3; do
    require_namespace "$namespace"
  done

  require_address client eth0 10.10.1.10/24
  require_address lb eth0 10.10.1.20/24
  require_address r1 eth0 10.10.1.1/24
  require_address r1 eth1 10.10.12.1/30
  require_address r2 eth0 10.10.12.2/30
  require_address r2 eth1 10.10.3.1/24
  require_address backend1 eth0 10.10.3.11/24
  require_address backend2 eth0 10.10.3.12/24
  require_address backend3 eth0 10.10.3.13/24
}

configure_routes() {
  # Endpoints use the router on their directly connected subnet as a gateway.
  ip -n client route replace default via 10.10.1.1 dev eth0
  ip -n lb route replace default via 10.10.1.1 dev eth0
  ip -n backend1 route replace default via 10.10.3.1 dev eth0
  ip -n backend2 route replace default via 10.10.3.1 dev eth0
  ip -n backend3 route replace default via 10.10.3.1 dev eth0

  # Each router needs a route to the subnet on the far side of the transit link.
  ip -n r1 route replace 10.10.3.0/24 via 10.10.12.2 dev eth1
  ip -n r2 route replace 10.10.1.0/24 via 10.10.12.1 dev eth0
}

enable_router_forwarding() {
  # IPv4 forwarding is network-namespace scoped and enabled only on the routers.
  ip netns exec r1 sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ip netns exec r2 sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

main() {
  require_root_and_tools
  preflight_topology
  configure_routes
  enable_router_forwarding
  printf 'Static routes configured; IPv4 forwarding enabled in r1 and r2.\n'
}

main "$@"
