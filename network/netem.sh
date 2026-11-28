#!/usr/bin/env bash
# Manage traffic impairment on a backend namespace's eth0 egress interface.
# Usage: sudo ./network/netem.sh {normal|delay|loss|bandwidth|combined|status} BACKEND

set -Eeuo pipefail

readonly QDISC_HANDLE="7e57:"
readonly INTERFACE="eth0"

fail() {
  printf 'netem: ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: sudo ./network/netem.sh {normal|delay|loss|bandwidth|combined|status} {backend1|backend2|backend3}\n' >&2
}

require_root_and_tools() {
  [[ ${EUID} -eq 0 ]] || fail "run as root (for example: sudo ./network/netem.sh delay backend1)"
  command -v ip >/dev/null 2>&1 || fail "the ip command is missing; install iproute2 first"
  command -v tc >/dev/null 2>&1 || fail "the tc command is missing; install iproute2 first"
  ip netns list >/dev/null 2>&1 || fail "cannot inspect named network namespaces"
}

validate_target() {
  local namespace="$1"
  ip netns exec "$namespace" true >/dev/null 2>&1 \
    || fail "namespace '$namespace' does not exist"
  ip -n "$namespace" link show dev "$INTERFACE" >/dev/null 2>&1 \
    || fail "interface '$INTERFACE' does not exist in namespace '$namespace'"
}

read_qdiscs() {
  ip netns exec "$1" tc qdisc show dev "$INTERFACE"
}

root_qdisc_info() {
  local qdiscs="$1" line marker kind handle placement rest found=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    read -r marker kind handle placement rest <<< "$line"
    if [[ "$marker" == qdisc && "$placement" == root ]]; then
      [[ -z "$found" ]] || return 1
      found="$kind $handle"
    fi
  done <<< "$qdiscs"

  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
  else
    printf 'none none\n'
  fi
}

is_managed_root_qdisc() {
  [[ "$1" == netem || "$1" == tbf ]] && [[ "$2" == "$QDISC_HANDLE" ]]
}

is_default_kernel_qdisc() {
  [[ "$2" == 0: ]] || return 1
  case "$1" in
    noqueue|pfifo_fast|fq_codel|fq) return 0 ;;
    *) return 1 ;;
  esac
}

show_status() {
  local namespace="$1" qdiscs root_info root_type root_handle
  qdiscs="$(read_qdiscs "$namespace")" \
    || fail "could not read qdisc status for $namespace/$INTERFACE"
  root_info="$(root_qdisc_info "$qdiscs")" \
    || fail "could not identify the root qdisc for $namespace/$INTERFACE"
  read -r root_type root_handle <<< "$root_info"

  printf 'Traffic shaping status for %s/%s:\n' "$namespace" "$INTERFACE"
  if [[ -n "$qdiscs" ]]; then
    printf '%s\n' "$qdiscs"
  else
    printf 'No qdiscs reported.\n'
  fi

  if [[ "$root_type" == netem ]] && is_managed_root_qdisc "$root_type" "$root_handle"; then
    printf 'Managed profile: netem impairment is active.\n'
  elif [[ "$root_type" == tbf ]] && is_managed_root_qdisc "$root_type" "$root_handle"; then
    printf 'Managed profile: bandwidth limit is active.\n'
  else
    printf 'Managed profile: none.\n'
  fi
}

apply_profile() {
  local profile="$1" namespace="$2" qdisc_kind message qdiscs root_info root_type root_handle
  local -a options
  case "$profile" in
    delay)
      qdisc_kind=netem
      options=(delay 100ms)
      message="Applied 100ms delay to $namespace/$INTERFACE."
      ;;
    loss)
      qdisc_kind=netem
      options=(loss 5%)
      message="Applied 5% packet loss to $namespace/$INTERFACE."
      ;;
    bandwidth)
      qdisc_kind=tbf
      options=(rate 10mbit burst 32kbit latency 400ms)
      message="Applied 10mbit bandwidth limit to $namespace/$INTERFACE."
      ;;
    combined)
      qdisc_kind=netem
      options=(delay 100ms loss 5%)
      message="Applied 100ms delay and 5% packet loss to $namespace/$INTERFACE."
      ;;
  esac

  qdiscs="$(read_qdiscs "$namespace")" \
    || fail "could not inspect qdiscs for $namespace/$INTERFACE"
  root_info="$(root_qdisc_info "$qdiscs")" \
    || fail "could not identify the root qdisc for $namespace/$INTERFACE"
  read -r root_type root_handle <<< "$root_info"

  if [[ "$root_type" != none ]] \
    && ! is_managed_root_qdisc "$root_type" "$root_handle" \
    && ! is_default_kernel_qdisc "$root_type" "$root_handle"; then
    fail "refusing to overwrite unrelated root qdisc '$root_type $root_handle' on $namespace/$INTERFACE"
  fi

  if is_managed_root_qdisc "$root_type" "$root_handle" && [[ "$root_type" != "$qdisc_kind" ]]; then
    ip netns exec "$namespace" tc qdisc del dev "$INTERFACE" root \
      || fail "could not remove the managed $root_type qdisc before switching profiles"
    ip netns exec "$namespace" tc qdisc replace dev "$INTERFACE" root \
      handle "$QDISC_HANDLE" "$qdisc_kind" "${options[@]}" \
      || fail "could not add the $qdisc_kind qdisc for $namespace/$INTERFACE"
  else
    ip netns exec "$namespace" tc qdisc replace dev "$INTERFACE" root \
      handle "$QDISC_HANDLE" "$qdisc_kind" "${options[@]}" \
      || fail "could not apply the $profile profile to $namespace/$INTERFACE"
  fi
  printf '%s\n' "$message"
}

apply_normal() {
  local namespace="$1" qdiscs root_info root_type root_handle
  qdiscs="$(read_qdiscs "$namespace")" \
    || fail "could not inspect qdiscs for $namespace/$INTERFACE"
  root_info="$(root_qdisc_info "$qdiscs")" \
    || fail "could not identify the root qdisc for $namespace/$INTERFACE"
  read -r root_type root_handle <<< "$root_info"

  if is_managed_root_qdisc "$root_type" "$root_handle"; then
    ip netns exec "$namespace" tc qdisc del dev "$INTERFACE" root \
      || fail "could not remove the managed root qdisc from $namespace/$INTERFACE"
    printf 'Removed the managed root qdisc from %s/%s.\n' "$namespace" "$INTERFACE"
  else
    printf 'No managed root qdisc on %s/%s; existing qdiscs were left unchanged.\n' \
      "$namespace" "$INTERFACE"
  fi
}

main() {
  [[ $# -eq 2 ]] || { usage; exit 2; }
  local profile="$1" namespace="$2"

  case "$profile" in
    normal|delay|loss|bandwidth|combined|status) ;;
    *) usage; fail "unknown command '$profile'" ;;
  esac
  case "$namespace" in
    backend1|backend2|backend3) ;;
    *) usage; fail "unsupported namespace '$namespace'; choose backend1, backend2, or backend3" ;;
  esac

  require_root_and_tools
  validate_target "$namespace"
  case "$profile" in
    normal) apply_normal "$namespace" ;;
    status) show_status "$namespace" ;;
    delay|loss|bandwidth|combined) apply_profile "$profile" "$namespace" ;;
  esac
}

main "$@"
