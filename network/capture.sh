#!/usr/bin/env bash
# Capture packets from an interface inside one of the project's namespaces.
# Usage: sudo ./network/capture.sh NAMESPACE INTERFACE OUTPUT.pcap [PACKET_COUNT]

set -Eeuo pipefail

readonly DEFAULT_PACKET_COUNT=100
OUTPUT_FILE=""

fail() {
  printf 'capture: ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage: sudo ./network/capture.sh <namespace> <interface> <output.pcap> [packet-count]
Namespaces: client, lb, r1, r2, backend1, backend2, backend3
Example: sudo ./network/capture.sh backend1 eth0 backend1.pcap 100
The packet count defaults to 100.
USAGE
}

require_root_and_tools() {
  [[ ${EUID} -eq 0 ]] || fail "run as root (for example: sudo ./network/capture.sh client eth0 client.pcap)"
  command -v ip >/dev/null 2>&1 || fail "the ip command is missing; install iproute2 first"
  command -v tcpdump >/dev/null 2>&1 || fail "tcpdump is missing; install it first"
  ip netns list >/dev/null 2>&1 || fail "cannot inspect named network namespaces"
}

validate_namespace() {
  case "$1" in
    client|lb|r1|r2|backend1|backend2|backend3) ;;
    *) fail "unsupported namespace '$1'; choose client, lb, r1, r2, backend1, backend2, or backend3" ;;
  esac
  ip netns exec "$1" true >/dev/null 2>&1 \
    || fail "namespace '$1' does not exist; set up the network lab first"
}

validate_interface() {
  local namespace="$1" interface="$2"
  [[ -n "$interface" ]] || fail "interface name cannot be empty"
  ip -n "$namespace" link show dev "$interface" >/dev/null 2>&1 \
    || fail "interface '$interface' does not exist in namespace '$namespace'"
}

validate_packet_count() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] \
    || fail "packet count must be a positive integer"
}

validate_output_path() {
  local path="$1" directory
  [[ "$path" == *.pcap ]] || fail "output file must use the .pcap extension"
  [[ "$path" != */ ]] || fail "output path must name a .pcap file"

  if [[ "$path" != /* ]]; then
    path="$PWD/$path"
  fi
  directory="${path%/*}"
  [[ -n "$directory" ]] || directory="/"

  [[ -d "$directory" ]] || fail "output directory does not exist: $directory"
  [[ -w "$directory" ]] || fail "output directory is not writable: $directory"
  [[ ! -e "$path" && ! -L "$path" ]] || fail "output file already exists: $path"
  OUTPUT_FILE="$path"
}

main() {
  [[ $# -ge 3 && $# -le 4 ]] || { usage; exit 2; }

  local namespace="$1" interface="$2" packet_count="${4:-$DEFAULT_PACKET_COUNT}"
  require_root_and_tools
  validate_namespace "$namespace"
  validate_interface "$namespace" "$interface"
  validate_packet_count "$packet_count"
  validate_output_path "$3"

  printf 'Capturing up to %s packets on %s/%s into %s...\n' \
    "$packet_count" "$namespace" "$interface" "$OUTPUT_FILE"
  if ip netns exec "$namespace" tcpdump -nn -U -i "$interface" \
    -c "$packet_count" -w "$OUTPUT_FILE"; then
    printf 'Capture saved to %s.\n' "$OUTPUT_FILE"
  else
    fail "tcpdump failed while capturing $namespace/$interface"
  fi
}

main "$@"
