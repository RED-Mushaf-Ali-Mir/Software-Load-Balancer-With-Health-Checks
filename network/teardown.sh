#!/usr/bin/env bash
# Remove only the topology created by network/setup.sh. Run as root:
#   sudo ./network/teardown.sh

set -Eeuo pipefail

readonly PROJECT_TAG="slb-cs3001-project-v1"
readonly NAMESPACES=(client lb r1 r2 backend1 backend2 backend3)
readonly BRIDGES=(br-client br-backend)
# Transit pair names are included because a failed setup may leave them in the
# root namespace before they have been moved into r1 and r2.
readonly ROOT_VETHS=(slb-c0h slb-l0h slb-r1ch slb-r1th slb-r2th slb-r2bh slb-b1h slb-b2h slb-b3h)

fail() {
  printf 'teardown: %s\n' "$*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "run as root (for example: sudo ./network/teardown.sh)"
command -v ip >/dev/null 2>&1 || fail "the ip command is missing; install iproute2 first"
command -v awk >/dev/null 2>&1 || fail "awk is required for safe namespace-name checks"
ip netns list >/dev/null 2>&1 || fail "cannot inspect named network namespaces"

namespace_exists() {
  local wanted="$1"
  [[ -e "/run/netns/$wanted" || -L "/run/netns/$wanted" ]] && return 0
  ip netns list | awk -v wanted="$wanted" '$1 == wanted { found=1 } END { exit !found }'
}

link_exists_in_root() {
  ip link show dev "$1" >/dev/null 2>&1
}

namespace_is_owned() {
  local name="$1" links line remainder interface expected saw_lo=0
  links="$(ip -n "$name" -o link show 2>/dev/null)" || return 1

  # Check all devices, not only lo. This prevents deleting a namespace that
  # contains an unrelated interface that would otherwise be moved back to host.
  while IFS= read -r line; do
    remainder="${line#*: }"
    interface="${remainder%%:*}"
    interface="${interface%%@*}"
    case "$name:$interface" in
      client:lo|lb:lo|r1:lo|r2:lo|backend1:lo|backend2:lo|backend3:lo)
        expected="$PROJECT_TAG:namespace:$name"
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
    # iproute2 prints the interface alias as the final field. Match the whole
    # suffix so a longer, unrelated alias cannot pass as this project's tag.
    [[ "$line" == *" alias $expected" ]] || return 1
  done <<< "$links"

  (( saw_lo == 1 ))
}

link_is_owned() {
  local name="$1" kind="$2" expected line
  expected="$PROJECT_TAG:$kind:$name"
  line="$(ip -o link show dev "$name" 2>/dev/null)" || return 1
  [[ "$line" == *" alias $expected" ]]
}

bridge_ports_are_owned() {
  local bridge="$1" ports line remainder interface

  # Only the expected project veths may be attached to these bridges. Deleting
  # a bridge with an unrelated port would detach that unrelated interface.
  ports="$(ip -o link show master "$bridge")" || return 1
  if [[ -z "$ports" ]]; then
    return 0
  fi
  while IFS= read -r line; do
    remainder="${line#*: }"
    interface="${remainder%%:*}"
    interface="${interface%%@*}"
    case "$bridge:$interface" in
      br-client:slb-c0h|br-client:slb-l0h|br-client:slb-r1ch|\
      br-backend:slb-r2bh|br-backend:slb-b1h|br-backend:slb-b2h|br-backend:slb-b3h)
        link_is_owned "$interface" veth || return 1
        ;;
      *)
        return 1
        ;;
    esac
  done <<< "$ports"
}

# Check every matching name before deleting anything. If an object lacks this
# project's ownership tag, stop rather than risk deleting a teammate's resource.
conflict=0
pids=""
for name in "${NAMESPACES[@]}"; do
  if namespace_exists "$name"; then
    if ! namespace_is_owned "$name"; then
      printf 'teardown: namespace %s lacks its tagged loopback or has an unexpected/untagged interface; leaving it untouched\n' "$name" >&2
      conflict=1
    else
      # Removing a namespace name does not stop processes still using it.
      # Refuse teardown until the caller stops those processes explicitly.
      if ! pids="$(ip netns pids "$name")"; then
        printf 'teardown: could not inspect processes in namespace %s; leaving everything untouched\n' "$name" >&2
        conflict=1
      elif [[ -n "$pids" ]]; then
        printf 'teardown: namespace %s still has process IDs: %s; leaving everything untouched\n' "$name" "$pids" >&2
        conflict=1
      fi
    fi
  fi
done
for name in "${BRIDGES[@]}"; do
  if link_exists_in_root "$name"; then
    if ! link_is_owned "$name" bridge; then
      printf 'teardown: bridge %s is not tagged as project-owned; leaving everything untouched\n' "$name" >&2
      conflict=1
    elif ! bridge_ports_are_owned "$name"; then
      printf 'teardown: bridge %s has an unexpected or untagged port; leaving everything untouched\n' "$name" >&2
      conflict=1
    fi
  fi
done
for name in "${ROOT_VETHS[@]}"; do
  if link_exists_in_root "$name" && ! link_is_owned "$name" veth; then
    printf 'teardown: interface %s is not tagged as project-owned; leaving everything untouched\n' "$name" >&2
    conflict=1
  fi
done
(( conflict == 0 )) || exit 1

removed=0
failed=0

# Remove namespaces first. Their private interfaces, including the router
# transit link, disappear along with them.
for name in "${NAMESPACES[@]}"; do
  if namespace_exists "$name"; then
    if namespace_is_owned "$name"; then
      # Recheck immediately before deletion in case a process joined after the
      # initial preflight checks.
      if ! pids="$(ip netns pids "$name")"; then
        printf 'teardown: could not inspect processes in namespace %s; leaving it\n' "$name" >&2
        failed=1
      elif [[ -n "$pids" ]]; then
        printf 'teardown: namespace %s became busy (process IDs: %s); leaving it\n' "$name" "$pids" >&2
        failed=1
      elif ip netns del "$name"; then
        printf 'Removed namespace %s\n' "$name"
        removed=1
      else
        printf 'teardown: could not remove namespace %s\n' "$name" >&2
        failed=1
      fi
    else
      printf 'teardown: ownership tag changed for namespace %s; leaving it\n' "$name" >&2
      failed=1
    fi
  fi
done

# Remove the host ends of veth pairs, then the bridges they were attached to.
for name in "${ROOT_VETHS[@]}"; do
  if link_exists_in_root "$name"; then
    if link_is_owned "$name" veth; then
      if ip link del dev "$name"; then
        printf 'Removed veth interface %s\n' "$name"
        removed=1
      else
        printf 'teardown: could not remove interface %s\n' "$name" >&2
        failed=1
      fi
    else
      printf 'teardown: ownership tag changed for interface %s; leaving it\n' "$name" >&2
      failed=1
    fi
  fi
done

for name in "${BRIDGES[@]}"; do
  if link_exists_in_root "$name"; then
    if ! link_is_owned "$name" bridge; then
      printf 'teardown: ownership tag changed for bridge %s; leaving it\n' "$name" >&2
      failed=1
    elif ! bridge_ports_are_owned "$name"; then
      printf 'teardown: bridge %s gained an unexpected or untagged port; leaving it\n' "$name" >&2
      failed=1
    else
      if ip link del dev "$name"; then
        printf 'Removed bridge %s\n' "$name"
        removed=1
      else
        printf 'teardown: could not remove bridge %s\n' "$name" >&2
        failed=1
      fi
    fi
  fi
done

(( failed == 0 )) || exit 1
if (( removed == 0 )); then
  printf 'No tagged project topology was found; nothing was removed.\n'
else
  printf 'Project topology removed.\n'
fi
