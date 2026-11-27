#!/usr/bin/env bash
# Build the project's local Linux network lab. Run as root, for example:
#   sudo ./network/setup.sh
#
# This phase only creates namespaces, bridges, virtual Ethernet links, and IP
# addresses. It deliberately does not add routes, enable forwarding, apply
# traffic shaping, or start application services.

set -Eeuo pipefail

readonly PROJECT_TAG="slb-cs3001-project-v1"
readonly NAMESPACES=(client lb r1 r2 backend1 backend2 backend3)
readonly BRIDGES=(br-client br-backend)

# These short names are private to this lab. The peer ends are renamed to eth0
# or eth1 after being moved into their network namespaces.
readonly VETH_NAMES=(
  slb-c0h slb-c0n
  slb-l0h slb-l0n
  slb-r1ch slb-r1cn
  slb-r1th slb-r2th
  slb-r2bh slb-r2bn
  slb-b1h slb-b1n
  slb-b2h slb-b2n
  slb-b3h slb-b3n
)

# Root-side veth ends stay attached to the two bridges. The transit pair moves
# entirely into r1 and r2, so it has no interface left in the root namespace.
readonly ROOT_VETHS=(
  slb-c0h slb-l0h slb-r1ch slb-r2bh slb-b1h slb-b2h slb-b3h
)

CREATED_NAMESPACES=()
CREATED_BRIDGES=()
CREATED_ROOT_VETHS=()
CREATED_TRANSIT_VETHS=()

fail() {
  printf 'setup: %s\n' "$*" >&2
  exit 1
}

require_root_and_tools() {
  # Network namespaces, bridges, and veth devices require administrator rights.
  [[ ${EUID} -eq 0 ]] || fail "run as root (for example: sudo ./network/setup.sh)"
  command -v ip >/dev/null 2>&1 || fail "the ip command is missing; install iproute2 first"
  command -v awk >/dev/null 2>&1 || fail "awk is required for safe namespace-name checks"
  ip netns list >/dev/null 2>&1 || fail "cannot inspect named network namespaces"
}

namespace_exists() {
  local wanted="$1"
  # Also catch a pre-existing path that could make `ip netns add` fail, even
  # if it is not shown as a normal named namespace by iproute2.
  [[ -e "/run/netns/$wanted" || -L "/run/netns/$wanted" ]] && return 0
  ip netns list | awk -v wanted="$wanted" '$1 == wanted { found=1 } END { exit !found }'
}

namespace_contents_are_owned() {
  local namespace="$1" links line remainder interface expected saw_lo=0
  links="$(ip -n "$namespace" -o link show)" || return 1

  # Check every device, not just lo. This prevents cleanup from un-naming a
  # namespace that someone has populated with an unrelated interface.
  while IFS= read -r line; do
    remainder="${line#*: }"
    interface="${remainder%%:*}"
    interface="${interface%%@*}"
    case "$namespace:$interface" in
      client:lo|lb:lo|r1:lo|r2:lo|backend1:lo|backend2:lo|backend3:lo)
        expected="$PROJECT_TAG:namespace:$namespace"
        saw_lo=1
        ;;
      client:eth0|client:slb-c0n) expected="$PROJECT_TAG:peer:slb-c0h" ;;
      lb:eth0|lb:slb-l0n) expected="$PROJECT_TAG:peer:slb-l0h" ;;
      r1:eth0|r1:slb-r1cn) expected="$PROJECT_TAG:peer:slb-r1ch" ;;
      r1:eth1|r1:slb-r1th) expected="$PROJECT_TAG:veth:slb-r1th" ;;
      r2:eth0|r2:slb-r2th) expected="$PROJECT_TAG:veth:slb-r2th" ;;
      r2:eth1|r2:slb-r2bn) expected="$PROJECT_TAG:peer:slb-r2bh" ;;
      backend1:eth0|backend1:slb-b1n) expected="$PROJECT_TAG:peer:slb-b1h" ;;
      backend2:eth0|backend2:slb-b2n) expected="$PROJECT_TAG:peer:slb-b2h" ;;
      backend3:eth0|backend3:slb-b3n) expected="$PROJECT_TAG:peer:slb-b3h" ;;
      *) return 1 ;;
    esac
    [[ "$line" == *" alias $expected" ]] || return 1
  done <<< "$links"

  (( saw_lo == 1 ))
}

namespace_is_fresh_unmarked() {
  local namespace="$1" links line remainder interface count=0
  links="$(ip -n "$namespace" -o link show)" || return 1

  # Immediately after `ip netns add`, the only device is an untagged loopback.
  # Setup may remove that exact state because it recorded creating this name in
  # its in-memory list; teardown never accepts an untagged namespace.
  while IFS= read -r line; do
    remainder="${line#*: }"
    interface="${remainder%%:*}"
    interface="${interface%%@*}"
    [[ "$interface" == lo && "$line" != *" alias "* ]] || return 1
    ((count += 1))
  done <<< "$links"

  (( count == 1 ))
}

link_exists_in_root() {
  ip link show dev "$1" >/dev/null 2>&1
}

preflight_name_checks() {
  # Refuse to reuse any requested namespace. This keeps setup from altering a
  # namespace that may belong to another lab or another person.
  local name
  for name in "${NAMESPACES[@]}"; do
    if namespace_exists "$name"; then
      fail "namespace '$name' already exists; leaving it untouched"
    fi
  done

  # Bridges and temporary veth names are also checked before creating anything.
  # This avoids collisions with interfaces already present on the host.
  for name in "${BRIDGES[@]}" "${VETH_NAMES[@]}"; do
    if link_exists_in_root "$name"; then
      fail "interface '$name' already exists; leaving it untouched"
    fi
  done
}

remove_created_resources() {
  local failed=0 unsafe=0 name pids ports

  # Check all namespaces before deleting any. A namespace with live processes or
  # unexpected devices may belong to something outside this setup attempt.
  for name in "${CREATED_NAMESPACES[@]}"; do
    if namespace_exists "$name"; then
      if ! pids="$(ip netns pids "$name")"; then
        printf 'setup: could not inspect processes in namespace %s; leaving it for teardown\n' "$name" >&2
        unsafe=1
      elif [[ -n "$pids" ]]; then
        printf 'setup: namespace %s has process IDs: %s; leaving it for teardown\n' "$name" "$pids" >&2
        unsafe=1
      elif ! namespace_contents_are_owned "$name" && ! namespace_is_fresh_unmarked "$name"; then
        printf 'setup: namespace %s has an untagged or unexpected interface; leaving it for teardown\n' "$name" >&2
        unsafe=1
      fi
    fi
  done
  if (( unsafe != 0 )); then
    return 1
  fi

  # Deleting an empty, project-owned namespace removes its private veth ends.
  for name in "${CREATED_NAMESPACES[@]}"; do
    if namespace_exists "$name"; then
      if ! pids="$(ip netns pids "$name")" || [[ -n "$pids" ]] || { ! namespace_contents_are_owned "$name" && ! namespace_is_fresh_unmarked "$name"; }; then
        printf 'setup: namespace %s changed during cleanup; leaving remaining topology for teardown\n' "$name" >&2
        unsafe=1
      elif ! ip netns del "$name"; then
        failed=1
      fi
    fi
  done
  if (( unsafe != 0 )); then
    return 1
  fi

  # Remove remaining root-side ends of bridge veth pairs. These names were
  # confirmed absent before this script created them.
  for name in "${CREATED_ROOT_VETHS[@]}" "${CREATED_TRANSIT_VETHS[@]}"; do
    if link_exists_in_root "$name"; then
      ip link del dev "$name" || failed=1
    fi
  done

  # Bridges are removed last, after their attached veth ports are gone.
  for name in "${CREATED_BRIDGES[@]}"; do
    if link_exists_in_root "$name"; then
      if ! ports="$(ip -o link show master "$name")"; then
        printf 'setup: could not inspect ports on bridge %s; leaving it for manual review\n' "$name" >&2
        failed=1
      elif [[ -n "$ports" ]]; then
        printf 'setup: bridge %s still has attached ports; leaving it for manual review\n' "$name" >&2
        failed=1
      else
        ip link del dev "$name" || failed=1
      fi
    fi
  done

  return "$failed"
}

handle_failure() {
  local status="$1"
  trap - ERR INT TERM HUP
  set +e
  printf 'setup: failed; removing resources created by this run...\n' >&2
  if ! remove_created_resources; then
    printf 'setup: automatic cleanup was incomplete; run teardown for tagged resources and inspect any untagged leftovers manually\n' >&2
  fi
  exit "$status"
}

trap 'handle_failure $?' ERR
trap 'handle_failure 130' INT
trap 'handle_failure 143' TERM
trap 'handle_failure 129' HUP

create_namespace() {
  local name="$1"

  # A namespace gets its own virtual network stack and routing table. The
  # loopback alias is an ownership tag that teardown checks before deletion.
  ip netns add "$name"
  CREATED_NAMESPACES+=("$name")
  ip -n "$name" link set dev lo alias "$PROJECT_TAG:namespace:$name"
  ip -n "$name" link set dev lo up
}

create_bridge() {
  local name="$1"

  # A Linux bridge acts like a small Ethernet switch for one subnet.
  ip link add name "$name" type bridge
  CREATED_BRIDGES+=("$name")
  ip link set dev "$name" alias "$PROJECT_TAG:bridge:$name"
  ip link set dev "$name" up
}

connect_namespace_to_bridge() {
  local namespace="$1" namespace_interface="$2" host_interface="$3"
  local peer_interface="$4" bridge="$5" address="$6"

  # A veth pair is a virtual cable: one end stays on the host bridge and the
  # other end is moved into the namespace.
  ip link add name "$host_interface" type veth peer name "$peer_interface"
  CREATED_ROOT_VETHS+=("$host_interface")
  ip link set dev "$host_interface" alias "$PROJECT_TAG:veth:$host_interface"
  ip link set dev "$peer_interface" alias "$PROJECT_TAG:peer:$host_interface"
  ip link set dev "$host_interface" master "$bridge"
  ip link set dev "$host_interface" up
  ip link set dev "$peer_interface" netns "$namespace"

  # Give the namespace end a simple local name, assign the README address, and
  # bring it up so it can send and receive packets on its subnet.
  ip -n "$namespace" link set dev "$peer_interface" name "$namespace_interface"
  ip -n "$namespace" address add "$address" dev "$namespace_interface"
  ip -n "$namespace" link set dev "$namespace_interface" up
}

create_router_transit_link() {
  # This veth pair is the point-to-point cable between the two router namespaces.
  ip link add name slb-r1th type veth peer name slb-r2th
  CREATED_TRANSIT_VETHS+=(slb-r1th slb-r2th)
  # Tag both ends before moving them so teardown can recognize a partial setup.
  ip link set dev slb-r1th alias "$PROJECT_TAG:veth:slb-r1th"
  ip link set dev slb-r2th alias "$PROJECT_TAG:veth:slb-r2th"
  ip link set dev slb-r1th netns r1
  ip link set dev slb-r2th netns r2

  # Router 1 uses eth1 for the transit link; Router 2 uses eth0.
  ip -n r1 link set dev slb-r1th name eth1
  ip -n r2 link set dev slb-r2th name eth0
  ip -n r1 address add 10.10.12.1/30 dev eth1
  ip -n r2 address add 10.10.12.2/30 dev eth0
  ip -n r1 link set dev eth1 up
  ip -n r2 link set dev eth0 up
}

main() {
  require_root_and_tools
  preflight_name_checks

  printf 'Creating seven isolated network namespaces...\n'
  local namespace
  for namespace in "${NAMESPACES[@]}"; do
    create_namespace "$namespace"
  done

  printf 'Creating the client-side and backend-side Ethernet bridges...\n'
  create_bridge br-client
  create_bridge br-backend

  printf 'Connecting client, load balancer, and Router 1 to 10.10.1.0/24...\n'
  connect_namespace_to_bridge client eth0 slb-c0h slb-c0n br-client 10.10.1.10/24
  connect_namespace_to_bridge lb eth0 slb-l0h slb-l0n br-client 10.10.1.20/24
  connect_namespace_to_bridge r1 eth0 slb-r1ch slb-r1cn br-client 10.10.1.1/24

  printf 'Connecting the routers over 10.10.12.0/30...\n'
  create_router_transit_link

  printf 'Connecting Router 2 and the backends to 10.10.3.0/24...\n'
  connect_namespace_to_bridge r2 eth1 slb-r2bh slb-r2bn br-backend 10.10.3.1/24
  connect_namespace_to_bridge backend1 eth0 slb-b1h slb-b1n br-backend 10.10.3.11/24
  connect_namespace_to_bridge backend2 eth0 slb-b2h slb-b2n br-backend 10.10.3.12/24
  connect_namespace_to_bridge backend3 eth0 slb-b3h slb-b3n br-backend 10.10.3.13/24

  # All requested links are now up. Routes and forwarding are intentionally
  # left for a later project phase.
  trap - ERR INT TERM HUP
  printf 'Topology created. No routes, forwarding, netem, or services were configured.\n'
}

main "$@"
